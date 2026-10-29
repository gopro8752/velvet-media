import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rename,rm,stat,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {SpectrumProvider} from '../src/provider.mjs';
import {BridgeError} from '../src/http.mjs';
const NOW=1800000000000;
const saved={accessToken:'fixture-access',refreshToken:'fixture-refresh',deviceId:'fixture-device',expiresAt:NOW+1000};
const reply=(value,status=200)=>({status,headers:{},body:Buffer.from(JSON.stringify(value))});
const token=()=>reply({access_token:'rotated-access',refresh_token:'rotated-refresh',expires_in:3600});
const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {resolve,promise};};
const code=value=>error=>error instanceof BridgeError&&error.code===value;
async function fixture(t,request,auth=saved){
  const directory=await mkdtemp(join(tmpdir(),'spectrum-lifecycle-'));t.after(()=>rm(directory,{recursive:true,force:true}));
  const authFile=join(directory,'auth.json');await writeFile(authFile,JSON.stringify(auth),{mode:0o600});
  const calls=[];const provider=new SpectrumProvider({authFile,tuneQuery:{}},{now:()=>NOW,request:async options=>{calls.push(options);return request(options,calls.length);}});
  const install=async auth=>{const path=join(directory,'auth.pending.json');await writeFile(path+'.tmp',JSON.stringify(auth),{mode:0o600});await rename(path+'.tmp',path);};
  return {provider,authFile,directory,calls,install};
}

test('completed sign-in is adopted on the next request without service restart',async t=>{
  const f=await fixture(t,()=>reply({nextAction:'STANDARD_AUTH'},401));
  await assert.rejects(()=>f.provider.token(),code('sign_in_required'));assert.equal(f.calls.length,1);
  const fresh={...saved,accessToken:'new-login',refreshToken:'new-refresh',expiresAt:NOW+3600000};await f.install(fresh);
  assert.deepEqual(await f.provider.token(),fresh);assert.equal(f.calls.length,1);
  assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),fresh);
  assert.equal(f.provider.getAuthStatus().ready,true);assert.equal(f.provider.getAuthStatus().phase,'ready');
  assert.equal((await readdir(f.directory)).includes('auth.pending.json'),false);
});

test('denied credentials stay quiet across restart but a fresh pending session re-enables renewal',async t=>{
  const f=await fixture(t,()=>reply({resultCode:1300},401));await assert.rejects(()=>f.provider.refresh(),code('sign_in_required'));
  let network=0;const restarted=new SpectrumProvider({authFile:f.authFile},{now:()=>NOW,request:async()=>{network++;return token();}});
  await assert.rejects(()=>restarted.refresh(),code('sign_in_required'));assert.equal(network,0);
  assert.equal(restarted.getAuthStatus().failureReason,'provider_challenge');assert.equal(restarted.getAuthStatus().ready,false);
  await f.install({...saved,accessToken:'fresh-login',refreshToken:'fresh-login-refresh'});
  assert.equal((await restarted.refresh()).accessToken,'rotated-access');assert.equal(network,1);
});

test('pending sign-in wins over an in-flight successful or failed renewal',async t=>{
  for(const failed of [false,true])await t.test(String(failed),async t=>{
    const entered=deferred(),release=deferred();const f=await fixture(t,async()=>{entered.resolve();await release.promise;return failed?reply({},401):token();});
    const renewal=f.provider.refresh();await entered.promise;
    const fresh={...saved,accessToken:'interactive-login',refreshToken:'interactive-refresh',expiresAt:NOW+7200000};await f.install(fresh);
    release.resolve();assert.deepEqual(await renewal,fresh);
    assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),fresh);assert.equal(f.provider.pendingAuth,null);
    assert.equal((await f.provider.token()).accessToken,'interactive-login');assert.equal(f.calls.length,1);
  });
});

test('legacy direct atomic replacement detected during renewal is not overwritten',async t=>{
  const entered=deferred(),release=deferred();const f=await fixture(t,async()=>{entered.resolve();await release.promise;return token();});
  const work=f.provider.refresh();await entered.promise;
  const fresh={...saved,accessToken:'external-login',refreshToken:'external-refresh',expiresAt:NOW+7200000};
  await writeFile(f.authFile+'.install',JSON.stringify(fresh),{mode:0o600});await rename(f.authFile+'.install',f.authFile);
  release.resolve();assert.deepEqual(await work,fresh);assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),fresh);
});

test('last successful renewal survives restart and status contains no credential values',async t=>{
  const f=await fixture(t,token);await f.provider.refresh();
  const raw=await readFile(f.authFile+'.status.json','utf8'),status=JSON.parse(raw);
  for(const secret of ['fixture-access','fixture-refresh','fixture-device','rotated-access','rotated-refresh'])assert.equal(raw.includes(secret),false);
  assert.equal(status.lastSuccessAt,NOW);assert.equal(status.lastMethod,'refresh_token');assert.equal(status.nextRenewalAt,NOW+3000000);
  assert.equal((await stat(f.authFile+'.status.json')).mode&0o777,0o600);
  const restarted=new SpectrumProvider({authFile:f.authFile},{now:()=>NOW+10000,request:async()=>{throw Error('no refresh needed');}});
  await restarted.loadAuth();assert.equal(restarted.getAuthStatus().lastSuccessAt,NOW);assert.equal(restarted.getAuthStatus().lastMethod,'refresh_token');assert.equal(restarted.getAuthStatus().ready,true);
});

test('expired saved-device auth succeeds after process restart instead of validation-gating a valid verifier',async t=>{
  let nonce;
  const f=await fixture(t,(options,index)=>{
    const fields=new URLSearchParams(options.body.toString());
    if(index===1){assert.match(String(options.url),/deviceverifier\/auth$/);nonce=fields.get('nonce');return reply({authCode:'fixture-code'});}
    return reply({access_token:'renewed',refresh_token:'renewed-refresh',expires_in:3600,id_token:`header.${Buffer.from(JSON.stringify({nonce})).toString('base64url')}.signature`});
  },{...saved,expiresAt:NOW-3600000,deviceVerifier:'fixture-device-verifier'});
  assert.equal((await f.provider.token()).accessToken,'renewed');assert.equal(f.calls.length,2);
});

test('operator reload imports a new session without spending any token',async t=>{
  const f=await fixture(t,()=>{throw Error('unexpected auth request');});await f.provider.loadAuth();
  const fresh={...saved,accessToken:'fresh-sign-in',refreshToken:'fresh-refresh',expiresAt:NOW+3600000};await f.install(fresh);
  assert.deepEqual(await f.provider.operatorAuth({reload:true}),fresh);assert.equal(f.calls.length,0);
});

test('private one-shot device renewal command uses the same writer and consumes only a fresh valid command',async t=>{
  let nonce;const f=await fixture(t,(options,index)=>{
    if(index===1){assert.match(String(options.url),/deviceverifier\/auth$/);nonce=new URLSearchParams(options.body.toString()).get('nonce');return reply({authCode:'code'});}
    return reply({access_token:'device-access',refresh_token:'device-refresh',expires_in:3600,id_token:`a.${Buffer.from(JSON.stringify({nonce})).toString('base64url')}.z`});
  },{...saved,expiresAt:NOW+3600000,deviceVerifier:'fixture-verifier'});
  await writeFile(f.authFile+'.command.json',JSON.stringify({action:'renew_device',createdAt:NOW}),{mode:0o600});
  assert.equal((await f.provider.operatorAuth()).accessToken,'device-access');assert.equal(f.calls.length,2);
  assert.equal((await readdir(f.directory)).includes('auth.json.command.json'),false);
  for(const command of [{action:'renew_device',createdAt:NOW-61000},{action:'renew_device',createdAt:NOW+6000},{action:'password',createdAt:NOW},{action:'renew_device',createdAt:NOW,secret:'fixture-secret'}]){
    await writeFile(f.authFile+'.command.json',JSON.stringify(command));await assert.rejects(()=>f.provider.operatorAuth(),code('invalid_request'));
  }
  assert.equal(f.calls.length,2);
});

test('many concurrent requests import one pending login and coalesce its renewal',async t=>{
  const f=await fixture(t,token);await f.provider.loadAuth();await f.install({...saved,refreshToken:'fresh-import-refresh'});
  const results=await Promise.all(Array.from({length:24},()=>f.provider.token()));
  assert.equal(f.calls.length,1);assert.ok(results.every(value=>value.accessToken==='rotated-access'));
});

test('private status rejects arbitrary persisted fields and keeps real error text out of diagnostics',async t=>{
  const f=await fixture(t,()=>{throw Error('Bearer private-provider-detail');});
  await writeFile(f.authFile+'.status.json',JSON.stringify({lastSuccessAt:NOW-100,accessToken:'do-not-load',lastMethod:'private-provider-detail',failureReason:'private-provider-detail'}));
  await assert.rejects(()=>f.provider.refresh(),code('source_unavailable'));
  const state=f.provider.getAuthStatus(),raw=await readFile(f.authFile+'.status.json','utf8');
  assert.equal(state.lastSuccessAt,NOW-100);assert.equal(state.failureReason,'provider_unavailable');assert.equal(state.failureStep,'refresh_token');
  assert.equal(raw.includes('private-provider-detail'),false);assert.equal(raw.includes('do-not-load'),false);
});

test('last failure survives successful renewal and another process restart without retaining provider text',async t=>{
  const f=await fixture(t,(_options,index)=>index===1?reply({secret:'never-persist-provider-body'},503):token());
  await assert.rejects(()=>f.provider.refresh(),code('source_unavailable'));
  assert.equal(f.provider.getAuthStatus().lastFailureAt,NOW);
  assert.equal(f.provider.getAuthStatus().lastFailureReason,'provider_unavailable');
  assert.equal(f.provider.getAuthStatus().lastFailureStep,'refresh_token');
  await f.provider.refresh();assert.equal(f.provider.getAuthStatus().failureReason,null);
  const restarted=new SpectrumProvider({authFile:f.authFile},{now:()=>NOW+10000,request:async()=>{throw Error('no request');}});
  await restarted.loadAuth();const status=restarted.getAuthStatus();
  assert.equal(status.ready,true);assert.equal(status.lastSuccessAt,NOW);assert.equal(status.lastFailureAt,NOW);
  assert.equal(status.lastFailureReason,'provider_unavailable');assert.equal(status.lastFailureStep,'refresh_token');
  assert.equal(status.failureReason,null);assert.equal((await readFile(f.authFile+'.status.json','utf8')).includes('never-persist-provider-body'),false);
});

test('an optional live verifier diagnostic rejection preserves the valid normal renewal path',async t=>{
  const auth={...saved,expiresAt:NOW+3600000,deviceVerifier:'fixture-verifier'};
  const f=await fixture(t,(options)=>String(options.url).endsWith('/deviceverifier/auth')?reply({},401):token(),auth);
  await assert.rejects(()=>f.provider.refresh({method:'device_verifier'}),code('sign_in_required'));
  assert.equal(f.provider.getAuthStatus().ready,true);assert.equal(f.provider.getAuthStatus().phase,'ready');
  assert.equal(f.provider.getAuthStatus().lastFailureReason,'authentication_rejected');assert.equal(f.provider.getAuthStatus().lastFailureStep,'device_verifier');
  assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),auth);
  assert.equal((await f.provider.refresh()).accessToken,'rotated-access');assert.equal(f.calls.length,2);
  assert.equal(f.provider.getAuthStatus().lastFailureReason,'authentication_rejected');
});

test('diagnostics never weaken forced-login, challenge, forbidden, expired, or code-exchange denials',async t=>{
  const cases=[{response:reply({},403)},{response:reply({resultCode:1300},401)},
    {response:reply({nextAction:'COUNTERMEASURES'},401)},{response:reply({nextAction:'STANDARD_AUTH'},401)},
    {response:reply({},401),expired:true},{response:reply({},401),codeExchange:true}];
  for(const [i,item]of cases.entries())await t.test(String(i),async t=>{
    const f=await fixture(t,(_options,index)=>item.codeExchange&&index===1?reply({authCode:'fixture-code'}):item.response,
      {...saved,expiresAt:item.expired?NOW-1:NOW+3600000,deviceVerifier:'fixture-verifier'});
    await assert.rejects(()=>f.provider.refresh({method:'device_verifier'}),code('sign_in_required'));
    assert.equal(f.provider.getAuthStatus().ready,false);assert.equal(f.provider.getAuthStatus().phase,'waiting_for_sign_in');
    const count=f.calls.length;await assert.rejects(()=>f.provider.refresh(),code('sign_in_required'));assert.equal(f.calls.length,count);
  });
});

test('interactive sign-in recovery also retains the preceding forced-sign-in reason across restart',async t=>{
  const f=await fixture(t,()=>reply({nextAction:'STANDARD_AUTH'},401));
  await assert.rejects(()=>f.provider.refresh(),code('sign_in_required'));
  await f.install({...saved,accessToken:'new-login-access',refreshToken:'new-login-refresh',expiresAt:NOW+3600000});
  await f.provider.operatorAuth({reload:true});
  const restarted=new SpectrumProvider({authFile:f.authFile},{now:()=>NOW+1000,request:async()=>{throw Error('unexpected request');}});
  await restarted.loadAuth();const state=restarted.getAuthStatus();
  assert.equal(state.ready,true);assert.equal(state.failureReason,null);
  assert.equal(state.lastFailureAt,NOW);assert.equal(state.lastFailureReason,'interactive_sign_in_required');assert.equal(state.lastFailureStep,'refresh_token');
});
