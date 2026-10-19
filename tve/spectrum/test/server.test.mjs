import test from 'node:test';
import assert from 'node:assert/strict';
import {createBridge,createHttpServer,validateConfig} from '../src/server.mjs';
import {BridgeError} from '../src/http.mjs';

const config={authFile:'/private/auth.json',tuneQuery:{behindOwnModem:false},manifestQuery:{behindOwnModem:false}};
const manifest=Buffer.from('<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period><AdaptationSet><Representation id="video" bandwidth="1000"><SegmentTemplate media="segment-$Number$.m4s" initialization="init.mp4" duration="2" /></Representation></AdaptationSet></Period></MPD>');
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
function fixture(t,overrides={}){
  const stops=[],licenses=[],cdnRequests=[];
  const entry={service:'123',channel:{id:'example',name:'Example'}};
  const provider={channels:async()=>[entry],tune:async()=>({value:{aegis:{aegisToken:'owned-lease',aegisTokenRefreshSeconds:60},streamUrl:'https://edge-mm.spectrum.net/live/manifest.mpd',outputFeedId:'feed'},headers:{'x-set-ast':'private-ast'}}),stop:async token=>stops.push(token),renew:async()=>{throw new Error('unexpected renew');},ast:async()=>'fresh-ast',license:async(format,session,bytes,query)=>{licenses.push({format,ast:session.ast,bytes,query});return Buffer.from([4,5,6]);},...overrides};
  const request=async options=>{cdnRequests.push(options);return {status:200,headers:{},body:manifest};};
  const bridge=createBridge(config,{provider,request});
  t.after(()=>bridge.close());
  return {bridge,provider,stops,licenses,cdnRequests};
}
test('tune returns capability paths, encrypted manifests and opaque license bytes',async t=>{
  const f=fixture(t),result=await f.bridge.tune('example','hls-clear,dash-widevine');
  assert.match(result.sessionId,/^[a-f0-9]{48}$/);
  assert.equal(result.drm.licensePath,`/live/drm/${result.sessionId}`);
  const resource=result.playbackPath.split('/').at(-1);
  const body=await f.bridge.media(result.sessionId,resource);
  assert.ok(body.body.toString().includes(`/live/streams/${result.sessionId}/`));
  assert.ok(!body.body.toString().includes('edge-mm'));
  const challenge=Buffer.from([1,2,3]);
  assert.deepEqual(await f.bridge.license(result.sessionId,null,challenge),Buffer.from([4,5,6]));
  assert.deepEqual(f.licenses[0].bytes,challenge);
  assert.equal(f.licenses[0].format,'widevine');
  assert.deepEqual(f.cdnRequests[0].headers,{});
  await f.bridge.stop(result.sessionId);await f.bridge.stop(result.sessionId);
  assert.deepEqual(f.stops,['owned-lease']);
  await assert.rejects(f.bridge.media(result.sessionId,resource),{code:'session_ended'});
});
test('old clients and unknown channels do not allocate provider leases',async t=>{
  let tunes=0;const f=fixture(t,{tune:async()=>{tunes++;throw new Error();}});
  await assert.rejects(f.bridge.tune('example','hls-clear'),{code:'native_update_required',status:426});
  await assert.rejects(f.bridge.tune('unknown','dash-widevine'),{code:'channel_not_entitled'});
  assert.equal(tunes,0);
});
test('invalid tune response releases the lease that it allocated',async t=>{
  const f=fixture(t,{tune:async()=>({value:{aegis:{aegisToken:'partial-owned-lease'}},headers:{}})});
  await assert.rejects(f.bridge.tune('example','dash-widevine'));
  assert.deepEqual(f.stops,['partial-owned-lease']);
});
test('failed lease cleanup remains retryable and is never reported as success',async t=>{
  const f=fixture(t);let attempts=0;
  f.provider.stop=async token=>{assert.equal(token,'owned-lease');if(++attempts===1)throw new BridgeError();};
  const result=await f.bridge.tune('example','dash-widevine');
  await assert.rejects(f.bridge.stop(result.sessionId),{code:'source_unavailable'});
  await assert.rejects(f.bridge.media(result.sessionId,result.playbackPath.split('/').at(-1)),{code:'session_ended'});
  await f.bridge.stop(result.sessionId);assert.equal(attempts,2);
  await f.bridge.stop(result.sessionId);assert.equal(attempts,2);
});
test('shutdown retries previously failed lease cleanup',async t=>{
  const f=fixture(t);let attempts=0;
  f.provider.stop=async()=>{if(++attempts===1)throw new BridgeError();};
  const result=await f.bridge.tune('example','dash-widevine');
  await assert.rejects(f.bridge.stop(result.sessionId));
  await f.bridge.close();assert.equal(attempts,2);
});
test('shutdown waits for an allocating tune and releases its eventual lease',async t=>{
  const entered=deferred(),result=deferred();const f=fixture(t);
  const normal=f.provider.tune;
  f.provider.tune=async()=>{entered.resolve();await result.promise;return normal();};
  const tune=f.bridge.tune('example','dash-widevine');
  const rejected=assert.rejects(tune,{code:'session_ended'});
  await entered.promise;
  let finished=false;const close=f.bridge.close().then(()=>{finished=true;});
  await new Promise(r=>setImmediate(r));assert.equal(finished,false);
  result.resolve();await rejected;await close;
  assert.deepEqual(f.stops,['owned-lease']);assert.equal(f.cdnRequests.length,0);
  await assert.rejects(f.bridge.tune('example','dash-widevine'),{code:'session_ended'});
});
test('cancelled tune cannot orphan an allocated provider lease',async t=>{
  const entered=deferred(),result=deferred(),abort=new AbortController();const f=fixture(t);
  const normal=f.provider.tune;
  f.provider.tune=async()=>{entered.resolve();await result.promise;return normal();};
  const tune=f.bridge.tune('example','dash-widevine',abort.signal);
  const rejected=assert.rejects(tune,{code:'session_ended'});
  await entered.promise;abort.abort();result.resolve();await rejected;
  assert.deepEqual(f.stops,['owned-lease']);
});
test('parallel allocations are bounded independently of active sessions',async t=>{
  const waiting=deferred();const f=fixture(t,{channels:async()=>{await waiting.promise;return [];}});
  const jobs=Array.from({length:3},()=>assert.rejects(f.bridge.tune('example','dash-widevine'),{code:'channel_not_entitled'}));
  await assert.rejects(f.bridge.tune('example','dash-widevine'),{code:'concurrency_limit'});
  waiting.resolve();await Promise.all(jobs);
});
test('normal concurrent license requests queue and different session IDs are rejected',async t=>{
  const f=fixture(t),entered=deferred(),done=deferred();let calls=0;
  f.provider.license=async(_format,_session,bytes)=>{calls++;entered.resolve();await done.promise;return bytes;};
  const result=await f.bridge.tune('example','dash-widevine');
  const first=f.bridge.license(result.sessionId,null,Buffer.from([1]));
  await entered.promise;
  const second=f.bridge.license(result.sessionId,null,Buffer.from([2]));
  await new Promise(r=>setImmediate(r));assert.equal(calls,1);
  await assert.rejects(f.bridge.license('0'.repeat(48),null,Buffer.from([2])),{code:'session_ended'});
  done.resolve();assert.deepEqual(await first,Buffer.from([1]));
  assert.deepEqual(await second,Buffer.from([2]));assert.equal(calls,2);
});
test('license queue is bounded and drops cancelled waiters before contacting provider',async t=>{
  const f=fixture(t),entered=deferred(),done=deferred(),abort=new AbortController();let calls=0;
  f.provider.license=async()=>{calls++;entered.resolve();await done.promise;return Buffer.from([1]);};
  const result=await f.bridge.tune('example','dash-widevine');
  const first=f.bridge.license(result.sessionId,null,Buffer.from([1]));await entered.promise;
  const cancelled=f.bridge.license(result.sessionId,null,Buffer.from([2]),abort.signal);
  const rejected=assert.rejects(cancelled,{code:'session_ended'});abort.abort();
  const third=f.bridge.license(result.sessionId,null,Buffer.from([3]));
  const fourth=f.bridge.license(result.sessionId,null,Buffer.from([4]));
  await assert.rejects(f.bridge.license(result.sessionId,null,Buffer.from([5])),{code:'source_unavailable'});
  done.resolve();await Promise.all([first,rejected,third,fourth]);assert.equal(calls,3);
});
test('configuration rejects duplicate alias identities',()=>{
  for(const aliases of [[{id:'a',entitlementId:1},{id:'a',entitlementId:2}],[{id:'a',entitlementId:1},{id:'b',entitlementId:1}]]){
    assert.throws(()=>validateConfig({...config,channelAliases:aliases}),{code:'invalid_request'});
  }
});
test('HTTP routes sanitize errors and reject arbitrary proxy requests',async t=>{
  const f=fixture(t);const server=createHttpServer(f.bridge);
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>{server.close(resolve);server.closeAllConnections();}));
  const base=`http://127.0.0.1:${server.address().port}`;
  const blocked=await fetch(base+'/live/channels',{headers:{Origin:'https://untrusted.example'}});
  assert.equal(blocked.status,400);
  f.provider.channels=async()=>{throw new Error('SENSITIVE-UPSTREAM-TOKEN');};
  const response=await fetch(base+'/live/channels');
  assert.equal(response.status,503);assert.ok(!(await response.text()).includes('SENSITIVE'));
  const invalid=await fetch(base+'/live/tune',{method:'POST',body:JSON.stringify({channelId:'example',url:'https://untrusted.example'})});
  assert.equal(invalid.status,400);
});
