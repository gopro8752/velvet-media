import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, writeFile, rm, stat, rename, mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {SpectrumProvider} from '../src/provider.mjs';
import {BridgeError} from '../src/http.mjs';

const NOW = 1800000000000;
const saved = {accessToken:'fixture-access',refreshToken:'fixture-refresh',deviceId:'fixture-device',
  deviceVerifier:'fixture-verifier',contextToken:'fixture-context',expiresAt:NOW-60000};
const reply = (value, status = 200) => ({status,headers:{},body:Buffer.isBuffer(value)?value:Buffer.from(JSON.stringify(value))});
const jwt = claims => `eyJhbGciOiJmaXh0dXJlIn0.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.fixture`;
const code = expected => error => error instanceof BridgeError && error.code === expected && error.message === expected;
async function fixture(t, request, auth = saved) {
  const directory = await mkdtemp(join(tmpdir(),'velvet-spectrum-auth-test-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const authFile = join(directory,'auth.json');
  await writeFile(authFile,JSON.stringify(auth),{mode:0o600});
  const calls=[];
  const provider = new SpectrumProvider({authFile,tuneQuery:{}},{now:()=>NOW,request:async options=>{
    assert.equal(new URL(options.url).origin,'https://apis.spectrum.net');
    assert.equal(options.headers['x-client-id'],'stva-ovp');
    assert.equal(options.headers['x-client-device-id'],'fixture-device');
    calls.push(options); return request(options,calls.length);
  }});
  return {provider,authFile,directory,calls};
}

test('an expired session validates once and retains tokens when Spectrum extends its TTL',async t=>{
  const f=await fixture(t,options=>{
    assert.equal(new URL(options.url).pathname,'/auth/oauth/v2/validateSession');
    assert.equal(new URL(options.url).searchParams.get('getLocation'),'false');
    assert.equal(options.headers['x-access-token'],saved.accessToken);
    assert.equal(options.headers['x-refresh-token'],saved.refreshToken);
    assert.equal(options.headers['x-device-verifier'],saved.deviceVerifier);
    assert.equal(options.headers['x-context-token'],saved.contextToken);
    assert.equal(options.headers.Authorization,undefined);
    return reply({isValidSession:true,accessTokenTTL:3600});
  });
  const values=await Promise.all(Array.from({length:8},()=>f.provider.token()));
  assert.equal(f.calls.length,1);
  assert.ok(values.every(v=>v.accessToken===saved.accessToken && v.expiresAt===NOW+3600000));
  assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),{...saved,expiresAt:NOW+3600000});
});

test('provider-directed device renewal uses PKCE and nonce binding and persists rotated context together',async t=>{
  let nonce,challenge;
  const f=await fixture(t,(options,attempt)=>{
    if(attempt===1)return reply({isValidSession:false,nextAction:'DEVICEVERIFIER_AUTH'});
    const fields=new URLSearchParams(options.body.toString());
    assert.equal(options.method,'POST');
    assert.equal(options.headers['Content-Type'],'application/x-www-form-urlencoded');
    if(attempt===2){
      assert.equal(new URL(options.url).pathname,'/auth/oauth/v2/consumer/video/deviceverifier/auth');
      assert.equal(options.headers.Authorization,'Bearer fixture-verifier');
      assert.equal(options.headers['x-context-token'],'fixture-context');
      assert.equal(fields.get('client_id'),'stva-ovp');
      assert.equal(fields.get('client_device_id'),'fixture-device');
      assert.equal(fields.get('response_type'),'code');
      assert.equal(fields.get('state'),'state');
      assert.equal(fields.get('supportSMB'),'false');
      assert.equal(fields.get('supportMDUBulk'),'false');
      assert.equal(fields.get('code_challenge_method'),'S256');
      nonce=fields.get('nonce'); challenge=fields.get('code_challenge');
      assert.match(nonce,/^[A-Za-z0-9_-]{32}$/);
      return reply({authCode:'fixture-code',deviceVerifier:'fixture-verifier-rotated'});
    }
    assert.equal(attempt,3);
    assert.equal(new URL(options.url).pathname,'/auth/oauth/v2/token');
    assert.equal(fields.get('grant_type'),'authorization_code');
    assert.equal(fields.get('code'),'fixture-code');
    assert.equal(fields.get('client_device_id'),'fixture-device');
    assert.match(fields.get('code_verifier'),/^[A-Za-z0-9_-]{128}$/);
    assert.equal(createHash('sha256').update(fields.get('code_verifier')).digest('base64url'),challenge);
    assert.equal(options.headers.Authorization,undefined);
    return reply({access_token:'rotated-access',refresh_token:'rotated-refresh',expires_in:3600,
      id_token:jwt({nonce,context_token:'rotated-context'})});
  });
  await Promise.all(Array.from({length:6},()=>f.provider.token()));
  assert.equal(f.calls.length,3);
  assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),{...saved,accessToken:'rotated-access',refreshToken:'rotated-refresh',
    expiresAt:NOW+3600000,deviceVerifier:'fixture-verifier-rotated',contextToken:'rotated-context'});
  assert.equal((await stat(f.authFile)).mode&0o777,0o600);
});

test('login, countermeasures, unknown directions and forbidden renewal never attempt device authorization',async t=>{
  for(const [nextAction,status] of [['STANDARD_AUTH',200],['COUNTERMEASURES',200],['unknown',200],[undefined,200],['DEVICEVERIFIER_AUTH',403]]){
    await t.test(`${nextAction}-${status}`,async t=>{
      const f=await fixture(t,()=>reply({isValidSession:false,nextAction},status));
      await assert.rejects(()=>f.provider.token(),code('sign_in_required'));
      assert.equal(f.calls.length,1);
      assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),saved);
    });
  }
});

test('invalid nonce or token response never overwrites saved credentials',async t=>{
  for(const id_token of [undefined,jwt({nonce:'wrong'}),'malformed'])await t.test(String(id_token),async t=>{
    const f=await fixture(t,(_options,attempt)=>attempt===1?reply({nextAction:'DEVICEVERIFIER_AUTH'}):attempt===2?
      reply({authCode:'fixture-code'}):reply({access_token:'next',refresh_token:'next',expires_in:3600,id_token}));
    await assert.rejects(()=>f.provider.token(),code('source_unavailable'));
    assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),saved);
  });
});

test('validation and refresh outages are temporary and do not attempt verifier auth',async t=>{
  for(const expired of [true,false])for(const response of [reply({},503),reply({},429),reply(Buffer.from('not JSON')),reply({isValidSession:true,accessTokenTTL:0})]){
    await t.test(`${expired}-${response.status}-${response.body.length}`,async t=>{
      const auth={...saved,expiresAt:expired?NOW-1:NOW+1000};
      const f=await fixture(t,()=>response,auth);
      await assert.rejects(()=>f.provider.token(),code('source_unavailable'));
      assert.equal(f.calls.length,1);
      assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),auth);
    });
  }
});

test('an explicit refresh direction is bounded and a near-expiry rejection validates once',async t=>{
  const f=await fixture(t,(_options,attempt)=>attempt===1?reply({nextAction:'REFRESH_AUTH'}):
    reply({access_token:'next',refresh_token:'next-refresh',expires_in:3600}));
  assert.equal((await f.provider.token()).accessToken,'next');
  assert.equal(f.calls.length,2);
  const g=await fixture(t,(_options,attempt)=>attempt===1?reply({resultCodeName:'INVALID_TOKEN'},401):reply({nextAction:'REFRESH_AUTH'}),{...saved,expiresAt:NOW+1000});
  await assert.rejects(()=>g.provider.token(),code('sign_in_required'));
  assert.equal(g.calls.length,2,'a rejected refresh cannot loop through validation');
});

test('an empty refresh401 still validates and follows an explicit device renewal direction',async t=>{
  let nonce;
  const f=await fixture(t,(options,attempt)=>{
    if(attempt===1)return reply(Buffer.alloc(0),401);
    if(attempt===2)return reply({isValidSession:false,nextAction:'DEVICEVERIFIER_AUTH'});
    if(attempt===3){nonce=new URLSearchParams(options.body.toString()).get('nonce');return reply({authCode:'fixture-code'});}
    assert.equal(attempt,4);
    return reply({access_token:'next',refresh_token:'next-refresh',expires_in:3600,id_token:jwt({nonce})});
  },{...saved,expiresAt:NOW+1000});
  assert.equal((await f.provider.token()).accessToken,'next');
  assert.equal(f.calls.length,4);
});

test('empty401 or403 validation remains an authentication denial, never a device renewal',async t=>{
  for(const status of [401,403])await t.test(String(status),async t=>{
    const f=await fixture(t,()=>reply(Buffer.alloc(0),status));
    await assert.rejects(()=>f.provider.token(),code('sign_in_required'));
    assert.equal(f.calls.length,1);
  });
});

test('disk-write retry persists already rotated credentials without consuming another refresh token',async t=>{
  const f=await fixture(t,()=>reply({access_token:'next',refresh_token:'rotated',expires_in:3600}),{...saved,expiresAt:NOW+1000});
  await f.provider.loadAuth();
  const backup=f.authFile+'.backup';
  await rename(f.authFile,backup); await mkdir(f.authFile);
  await assert.rejects(()=>f.provider.refresh(),code('source_unavailable'));
  assert.equal(f.calls.length,1);
  await rm(f.authFile,{recursive:true});
  assert.equal((await f.provider.refresh()).refreshToken,'rotated');
  assert.equal(f.calls.length,1);
  assert.equal(JSON.parse(await readFile(f.authFile,'utf8')).refreshToken,'rotated');
});
