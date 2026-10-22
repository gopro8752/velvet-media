import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, stat, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {SpectrumProvider} from '../src/provider.mjs';
import {BridgeError} from '../src/http.mjs';

const NOW = 1800000000000;
const auth = (extra = {}) => ({accessToken:'fixture-access',refreshToken:'fixture-refresh',deviceId:'fixture-device',expiresAt:NOW+3600000,...extra});
const reply = (value, status = 200, headers = {}) => ({status,headers,body:Buffer.isBuffer(value)?value:Buffer.from(JSON.stringify(value))});
const deferred = () => { let resolve; const promise = new Promise(r => {resolve=r;}); return {promise,resolve}; };
async function fixture(t, request, {saved = auth(), config = {}, now = ()=>NOW} = {}) {
  const directory = await mkdtemp(join(tmpdir(),'velvet-spectrum-provider-test-'));
  t.after(() => rm(directory,{recursive:true,force:true}));
  const authFile = join(directory,'auth.json');
  await writeFile(authFile,JSON.stringify(saved),{mode:0o600});
  const calls=[];
  const provider = new SpectrumProvider({authFile,tuneQuery:{},...config},{now,request:async options => {
    calls.push(options); return request(options,calls.length);
  }});
  return {provider,calls,authFile,directory};
}
const code = expected => error => error instanceof BridgeError && error.code===expected;

test('refresh is singleflight, atomically persists rotated tokens with0600, and retains device identity', async t => {
  const started=deferred(), release=deferred();
  const f=await fixture(t,async options => {
    assert.equal(new URL(options.url).href,'https://apis.spectrum.net/auth/oauth/v2/token');
    assert.equal(options.method,'POST');
    assert.equal(options.headers.Authorization,undefined);
    assert.equal(new URLSearchParams(options.body.toString()).get('refresh_token'),'fixture-refresh');
    started.resolve(); await release.promise;
    return reply({access_token:'fixture-access-rotated',refresh_token:'fixture-refresh-rotated',expires_in:3600});
  },{saved:auth({expiresAt:NOW+1000})});
  const pending=Array.from({length:8},()=>f.provider.token());
  await started.promise; release.resolve();
  const values=await Promise.all(pending);
  assert.equal(f.calls.length,1);
  assert.ok(values.every(v=>v.accessToken==='fixture-access-rotated' && v.deviceId==='fixture-device'));
  const stored=JSON.parse(await readFile(f.authFile,'utf8'));
  assert.equal(stored.refreshToken,'fixture-refresh-rotated');
  assert.equal(stored.expiresAt,NOW+3600000);
  assert.equal((await stat(f.authFile)).mode & 0o777,0o600);
  assert.deepEqual(await readdir(f.directory),['auth.json']);
});

test('invalid stored credentials fail before any authenticated request', async t => {
  for (const saved of [null,{},auth({accessToken:''}),auth({refreshToken:'bad\r\nheader'}),auth({deviceId:'bad\0device'})]) {
    await t.test(JSON.stringify(saved),async t => {
      const f=await fixture(t,()=>{throw new Error('unexpected network');},{saved});
      await assert.rejects(()=>f.provider.token(),code('sign_in_required'));
      assert.equal(f.calls.length,0);
    });
  }
});

test('malformed refresh responses never overwrite persisted credentials and allow a later retry', async t => {
  const invalid=[reply(Buffer.from('not JSON')),reply({},401),reply({access_token:'bad\r\nheader',refresh_token:'next',expires_in:3600}),
    reply({access_token:'next',refresh_token:'bad\0token',expires_in:3600}),reply({access_token:'next',refresh_token:'next',expires_in:0}),
    reply({access_token:'next',refresh_token:'next',expires_in:'not-a-number'})];
  for (let i=0;i<invalid.length;i++) await t.test(`invalid response${i}`,async t => {
    const f=await fixture(t,(_options,attempt)=>attempt===1?invalid[i]:reply({access_token:'recovered',refresh_token:'recovered-refresh',expires_in:3600}));
    const before=await readFile(f.authFile,'utf8');
    await assert.rejects(()=>f.provider.refresh(),code('sign_in_required'));
    assert.equal(await readFile(f.authFile,'utf8'),before);
    assert.equal((await f.provider.refresh()).accessToken,'recovered');
    assert.equal(f.calls.length,2);
  });
});

test('401 performs one refresh and retry, forwarding auth only to the fixed API origin', async t => {
  const f=await fixture(t,options => {
    const u=new URL(options.url);
    if(u.hostname==='apis.spectrum.net') return reply({access_token:'fresh-access',refresh_token:'fresh-refresh',expires_in:3600});
    assert.equal(u.origin,'https://apis-vid.spectrum.net');
    assert.equal(options.headers.device_id,'fixture-device');
    return options.headers.Authorization==='Bearer fixture-access'?reply({code:'expired'},401):reply({ok:true});
  });
  assert.deepEqual((await f.provider.api('/fixture',{query:{id:'one two'}})).value,{ok:true});
  assert.equal(f.calls.length,3);
  assert.equal(new URL(f.calls[2].url).searchParams.get('id'),'one two');
  assert.equal(f.calls[2].headers.Authorization,'Bearer fresh-access');
  f.provider.request=async()=>reply({},401);
  await assert.rejects(()=>f.provider.api('/fixture'),code('sign_in_required'));
});

test('a delayed401 from the old access token reuses the already rotated token', async t => {
  const oldRequestsStarted=deferred(), releaseFirst=deferred(), releaseSecond=deferred();
  let oldRequests=0,refreshes=0;
  const f=await fixture(t,async options=>{
    const u=new URL(options.url);
    if(u.hostname==='apis.spectrum.net'){
      refreshes++;
      return reply({access_token:'rotated-access',refresh_token:'rotated-refresh',expires_in:3600});
    }
    if(options.headers.Authorization==='Bearer fixture-access'){
      oldRequests++;
      if(oldRequests===2)oldRequestsStarted.resolve();
      await (u.pathname==='/first'?releaseFirst.promise:releaseSecond.promise);
      return reply({},401);
    }
    assert.equal(options.headers.Authorization,'Bearer rotated-access');
    return reply({ok:true});
  });
  // Ensure both original requests really use the old token, then deliver the
  // second401 only after the first refresh has completed and been persisted.
  const first=f.provider.api('/first'),second=f.provider.api('/second');
  await oldRequestsStarted.promise;releaseFirst.resolve();
  assert.deepEqual((await first).value,{ok:true});
  assert.equal(refreshes,1);
  releaseSecond.resolve();
  assert.deepEqual((await second).value,{ok:true});
  assert.equal(refreshes,1);
  assert.equal(f.calls.filter(call=>new URL(call.url).hostname==='apis.spectrum.net').length,1);
  assert.equal(JSON.parse(await readFile(f.authFile,'utf8')).refreshToken,'rotated-refresh');
});

test('API addresses cannot escape the provider origin or inject a raw query', async t => {
  const f=await fixture(t,()=>{throw new Error('unexpected network');});
  for(const path of ['https://elsewhere.example/path','//elsewhere.example/path','/\\elsewhere.example/path','/x?secret=1','/x#fragment']) {
    await assert.rejects(()=>f.provider.api(path),error=>error instanceof BridgeError);
  }
  assert.equal(f.calls.length,0);
});

test('catalog uses entitlementId, preserves reviewed aliases, filters access, deduplicates, and caches', async t => {
  const started=deferred(), release=deferred();
  const rows=[{entitlementId:'source-hd',mystroServiceId:'wrong-guide-id',tmsGuideId:'guide-hd',online:true,onlineEntitled:true,networkName:'Network HD',channelNumbers:['42'],logoUri:'https://logos.example/channel.png'},
    {entitlementId:'source-hd',online:true,onlineEntitled:true,networkName:'duplicate'},
    {entitlementId:'free-source',online:true,onlineEntitled:true,callSign:'FREE',channelNumbers:[7],logoUri:'https://user:password@logos.example/image'},
    {entitlementId:'not-entitled',online:true,onlineEntitled:false},{entitlementId:'offline',online:false,onlineEntitled:true},
    {entitlementId:'../invalid',online:true,onlineEntitled:true}];
  const f=await fixture(t,async options=>{assert.equal(new URL(options.url).searchParams.get('streamVersion'),'5');started.resolve();await release.promise;return reply(rows);},
    {config:{channelAliases:[{entitlementId:'source-hd',id:'existing-network',name:'Existing Network'}]}});
  const first=f.provider.channels(),second=f.provider.channels();await started.promise;release.resolve();
  const [a,b]=await Promise.all([first,second]);
  assert.deepEqual(a,b);assert.equal(f.calls.length,1);assert.equal(a.length,2);
  assert.equal(a[0].service,'source-hd');assert.equal(a[0].guideId,'guide-hd');assert.equal(a[0].channel.id,'existing-network');assert.equal(a[0].channel.name,'Existing Network');
  assert.equal(a[1].channel.id,'spectrum-free-source');assert.equal(a[1].channel.logoUrl,null);assert.equal(a[1].channel.number,'7');
  await f.provider.channels();assert.equal(f.calls.length,1);
  await f.provider.channels(true);assert.equal(f.calls.length,2);
});

test('provider relative artwork paths resolve against its public image CDN',async t=>{
  const rows=[{entitlementId:'art',online:true,onlineEntitled:true,networkName:' Channel ',logoUri:'/logos/channel.png'},
    {entitlementId:'missing',online:true,onlineEntitled:true,networkName:'Missing'}];
  const f=await fixture(t,()=>reply(rows));const entries=await f.provider.channels();
  assert.equal(entries[0].channel.logoUrl,'https://cdnimg.spectrum.net/logos/channel.png');
  assert.equal(entries[0].channel.name,'Channel');assert.equal(entries[1].channel.logoUrl,null);
});
test('an alias cannot collide with another channel generated ID in either catalog order',async t=>{
  const rows=[{entitlementId:'A',online:true,onlineEntitled:true,networkName:'Fixture A'},
    {entitlementId:'B',online:true,onlineEntitled:true,networkName:'Fixture B'}];
  for(const reversed of [false,true])await t.test(reversed?'generated first':'alias first',async t=>{
    const f=await fixture(t,()=>reply(reversed?[...rows].reverse():rows),
      {config:{channelAliases:[{id:'spectrum-B',entitlementId:'A'}]}});
    await assert.rejects(()=>f.provider.channels(),code('source_unavailable'));
    assert.equal(f.provider.cached,null,'an ambiguous catalog must never be cached or presented');
    f.provider.config.channelAliases=[{id:'reviewed-A',entitlementId:'A'}];
    const repaired=await f.provider.channels();
    assert.equal(repaired.length,2);
    assert.equal(new Set(repaired.map(entry=>entry.channel.id)).size,2);
    assert.equal(repaired.find(entry=>entry.channel.id==='spectrum-B').service,'B');
  });
});

test('malformed or empty entitled catalogs fail safely',async t=>{
  for(const value of [{},[],[{entitlementId:'x',online:true,onlineEntitled:false}]]) await t.test(JSON.stringify(value),async t=>{
    const f=await fixture(t,()=>reply(value));await assert.rejects(()=>f.provider.channels(),e=>e instanceof BridgeError);
  });
});

test('tune builds real platform capabilities and never reuses borrowed session identifiers',async t=>{
  const f=await fixture(t,()=>reply({ok:true}),{config:{tuneQuery:{privacy:'fixture',adID:'wrong-device',aegis:'not-reused',sessionId:'not-reused',streamSessionId:'not-reused'}}});
  for(const format of ['widevine','fairplay']) {
    await f.provider.tune({service:'actual-entitlement'},format);
    const call=f.calls.at(-1),u=new URL(call.url),body=JSON.parse(call.body);
    assert.equal(u.pathname,'/lantern/foc-ipvs/api/smarttv/stream/live/v6/actual-entitlement');
    assert.equal(u.searchParams.get('adID'),'fixture-device');assert.equal(u.searchParams.get('privacy'),'fixture');
    for(const key of ['aegis','sessionId','streamSessionId']) assert.equal(u.searchParams.has(key),false);
    assert.deepEqual(body,{deviceCapabilities:{packaging:format==='fairplay'?'hls':'dash',drm:format==='fairplay'?'fairplay':'cenc',videoCodecs:['avc'],audioCodecs:format==='fairplay'?['aac']:['aac','ac3','eac3']}});
  }
});

test('fresh provider location replaces captured flags for tunes while preserving privacy and capabilities',async t=>{
  const f=await fixture(t,options=>{
    const u=new URL(options.url);
    if(u.pathname==='/pinxt/customer/location/v1'){
      assert.equal(u.href,'https://apis.spectrum.net/pinxt/customer/location/v1');
      assert.equal(options.headers.Authorization,'Bearer fixture-access');
      assert.equal(options.headers.device_id,'fixture-device');
      assert.equal(options.maxBytes,256*1024);
      assert.equal(options.timeoutMs,15000);
      return reply({behindOwnModem:true,inMarket:true,stateAbbr:'OH',OTT:false,geoDMA:'private-dma',customerId:'private-customer'});
    }
    assert.equal(u.origin,'https://apis-vid.spectrum.net');
    assert.equal(u.searchParams.get('behindOwnModem'),'true');
    assert.equal(u.searchParams.get('inMarket'),'true');
    assert.equal(u.searchParams.get('stateAbbr'),'OH');
    assert.equal(u.searchParams.has('behindTheRouter'),false,'missing current state must remove the captured router flag');
    assert.equal(u.searchParams.get('OTT'),'false');
    assert.equal(u.searchParams.get('privacy'),'fixture-privacy');
    assert.equal(u.searchParams.has('geoDMA'),false);
    assert.equal(u.searchParams.has('customerId'),false);
    return reply({initLocation:{behindOwnModem:true,inMarket:true},ok:true});
  },{config:{refreshLocation:true,tuneQuery:{behindOwnModem:false,inMarket:false,stateAbbr:'CA',behindTheRouter:true,OTT:false,privacy:'fixture-privacy'}}});
  const result=await f.provider.tune({service:'fixture-channel'},'widevine');
  assert.deepEqual(result.location,{behindOwnModem:true,inMarket:true,stateAbbr:'OH'});
  assert.equal(Object.isFrozen(result.location),true);
  assert.equal(f.calls.length,2);
  assert.equal(JSON.stringify(result.location).includes('private'),false);
});

test('location lookup is singleflight, caches for fifteen minutes, and follows a changed network',async t=>{
  let now=NOW,lookups=0;
  const started=deferred(),release=deferred();
  const f=await fixture(t,async()=>{
    lookups++;
    if(lookups===1){started.resolve();await release.promise;}
    return reply({behindOwnModem:lookups===1,inMarket:lookups===1,behindTheRouter:lookups===1,stateAbbr:lookups===1?'OH':'CA'});
  },{now:()=>now});
  const pending=Array.from({length:8},()=>f.provider.location());
  await started.promise;release.resolve();
  const values=await Promise.all(pending);
  assert.equal(lookups,1);
  assert.ok(values.every(value=>value===values[0]));
  now+=15*60*1000-1;
  assert.deepEqual(await f.provider.location(),{behindOwnModem:true,inMarket:true,stateAbbr:'OH',behindTheRouter:true});
  assert.equal(lookups,1);
  now++;
  assert.deepEqual(await f.provider.location(),{behindOwnModem:false,inMarket:false,stateAbbr:'CA',behindTheRouter:false});
  assert.equal(lookups,2);
});

test('expired or forced location refresh failure never authorizes a tune using stale captured home state',async t=>{
  for(const forced of [false,true]) await t.test(forced?'forced':'expired',async t=>{
    let now=NOW,lookups=0;
    const f=await fixture(t,options=>{
      assert.equal(new URL(options.url).pathname,'/pinxt/customer/location/v1','no tune should be sent after a failed location refresh');
      lookups++;
      return lookups===1?reply({behindOwnModem:true,inMarket:true,stateAbbr:'OH'}):reply({secret:'provider detail'},503);
    },{now:()=>now,config:{refreshLocation:true,tuneQuery:{behindOwnModem:true,inMarket:true,stateAbbr:'OH'}}});
    await f.provider.location();
    if(forced)await assert.rejects(()=>f.provider.location(true),code('source_unavailable'));
    else now+=15*60*1000;
    await assert.rejects(()=>f.provider.tune({service:'fixture-channel'},'widevine'),error=>{
      assert.equal(error.message,'source_unavailable');return code('source_unavailable')(error);
    });
    assert.equal(f.provider.locationCache,null);
    assert.equal(f.provider.locationLoading,null);
    assert.equal(lookups,forced?3:2);
  });
});

test('malformed provider location fails closed and never forwards unvalidated location fields',async t=>{
  for(const value of [null,[],{}, {behindOwnModem:'true',inMarket:true}, {behindOwnModem:true,inMarket:'false'},
    {behindOwnModem:true,inMarket:true,stateAbbr:'OH\r\nsecret'}, {behindOwnModem:true,inMarket:true,behindTheRouter:'true'}]) {
    await t.test(JSON.stringify(value),async t=>{
      const f=await fixture(t,()=>reply(value),{config:{refreshLocation:true}});
      await assert.rejects(()=>f.provider.tune({service:'fixture-channel'},'widevine'),code('source_unavailable'));
      assert.equal(f.calls.length,1);assert.equal(f.provider.locationCache,null);
    });
  }
});

test('location401 refreshes through the normal credential rotation guard and retries only the fixed endpoint',async t=>{
  const f=await fixture(t,options=>{
    const u=new URL(options.url);
    if(u.pathname==='/auth/oauth/v2/token')return reply({access_token:'rotated',refresh_token:'rotated-refresh',expires_in:3600});
    assert.equal(u.href,'https://apis.spectrum.net/pinxt/customer/location/v1');
    return options.headers.Authorization==='Bearer fixture-access'?reply({},401):reply({behindOwnModem:false,inMarket:false});
  });
  assert.deepEqual(await f.provider.location(),{behindOwnModem:false,inMarket:false});
  assert.equal(f.calls.length,3);
  assert.equal(JSON.parse(await readFile(f.authFile,'utf8')).accessToken,'rotated');
});

test('a tune observing a different network invalidates future location checks without rewriting its original context',async t=>{
  let lookups=0;
  const f=await fixture(t,options=>{
    if(new URL(options.url).pathname==='/pinxt/customer/location/v1'){
      lookups++;
      return reply({behindOwnModem:lookups===1,inMarket:true,stateAbbr:'OH'});
    }
    return reply({initLocation:{behindOwnModem:false,inMarket:true,stateAbbr:'OH'}});
  },{config:{refreshLocation:true}});
  const first=await f.provider.tune({service:'fixture-channel'},'widevine');
  assert.equal(first.location.behindOwnModem,true);
  assert.equal(f.provider.locationCache,null);
  const second=await f.provider.tune({service:'fixture-channel'},'widevine');
  assert.equal(second.location.behindOwnModem,false);
  assert.equal(lookups,2);
});

test('license relay preserves binary CDM bytes and exact raw FairPlay query encoding',async t=>{
  const response=Buffer.from([0,255,2,0,128]),challenge=Buffer.from([255,0,1,128,0]);
  const f=await fixture(t,()=>reply(response));
  const session={playerId:'own-player-id',ast:'fixture-session-ast'};
  assert.deepEqual(await f.provider.license('widevine',session,challenge),response);
  const w=f.calls.at(-1),wu=new URL(w.url);
  assert.equal(wu.origin,'https://apis-drm.spectrum.net');assert.equal(wu.pathname,'/drm/licenseServer/widevine/v2');
  assert.equal(wu.searchParams.get('streamSessionId'),'own-player-id');assert.deepEqual(w.body,challenge);
  assert.equal(w.headers.Authorization,'Bearer fixture-access');assert.equal(w.headers['AST-Authorization'],'fixture-session-ast');
  const original='ContentId=one%2ftwo%20three%2Bfour&token=a%3Db%26c&repeat=1&repeat=2';
  assert.deepEqual(await f.provider.license('fairplay',session,challenge,original),response);
  const fcall=f.calls.at(-1),raw=new URL(fcall.url).search;
  assert.ok(raw.endsWith('&'+original),'provider key query remains byte-for-byte identical');
  assert.deepEqual(fcall.body,challenge);
  const before=f.calls.length;
  for(const query of ['ContentId=x#fragment','bad=one\r\ntwo','streamSessionId=another','contentType=OTHER']) await assert.rejects(()=>f.provider.license('fairplay',session,challenge,query),e=>e instanceof BridgeError);
  assert.equal(f.calls.length,before);
});

test('license errors are allowlisted and an empty license never reaches the device',async t=>{
  const f=await fixture(t,()=>reply({private:'never forwarded',blockedDRM:true},403));
  await assert.rejects(()=>f.provider.license('widevine',{playerId:'own',ast:'fixture'},Buffer.from('challenge')),code('drm_unavailable'));
  f.provider.request=async()=>reply(Buffer.alloc(0));
  await assert.rejects(()=>f.provider.license('widevine',{playerId:'own',ast:'fixture'},Buffer.from('challenge')),code('drm_unavailable'));
});
