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

test('expired sessions use saved-device auth directly with PKCE, no expired context or validate gate',async t=>{
  let nonce,challenge;
  const f=await fixture(t,(options,attempt)=>{
    const fields=new URLSearchParams(options.body.toString());
    if(attempt===1){
      assert.equal(new URL(options.url).pathname,'/auth/oauth/v2/consumer/video/deviceverifier/auth');
      assert.equal(options.headers.Authorization,'Bearer fixture-verifier');
      assert.equal(options.headers['x-context-token'],undefined);
      assert.equal(fields.get('client_id'),'stva-ovp');assert.equal(fields.get('client_device_id'),'fixture-device');
      assert.equal(fields.get('response_type'),'code');assert.equal(fields.get('code_challenge_method'),'S256');
      nonce=fields.get('nonce');challenge=fields.get('code_challenge');
      assert.match(nonce,/^[A-Za-z0-9_-]{32}$/);
      return reply({authCode:'fixture-code',deviceVerifier:'fixture-verifier-rotated'});
    }
    assert.equal(attempt,2);assert.equal(new URL(options.url).pathname,'/auth/oauth/v2/token');
    assert.equal(fields.get('grant_type'),'authorization_code');assert.equal(fields.get('code'),'fixture-code');
    assert.equal(fields.get('client_device_id'),'fixture-device');assert.match(fields.get('code_verifier'),/^[A-Za-z0-9_-]{128}$/);
    assert.equal(createHash('sha256').update(fields.get('code_verifier')).digest('base64url'),challenge);
    return reply({access_token:'rotated-access',refresh_token:'rotated-refresh',expires_in:3600,id_token:jwt({nonce,context_token:'rotated-context'})});
  });
  await Promise.all(Array.from({length:8},()=>f.provider.token()));assert.equal(f.calls.length,2);
  assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),{...saved,accessToken:'rotated-access',refreshToken:'rotated-refresh',
    expiresAt:NOW+3600000,deviceVerifier:'fixture-verifier-rotated',contextToken:'rotated-context'});
  assert.equal((await stat(f.authFile)).mode&0o777,0o600);
});

test('invalid refresh credentials fall back once to saved-device auth without validating the expired session',async t=>{
  for(const rejected of [reply({resultCode:2076,resultCodeName:'INVALID_TOKEN'},401),reply(Buffer.alloc(0),401),reply({error:'invalid_grant'},400)])await t.test(String(rejected.status),async t=>{
    let nonce;
    const f=await fixture(t,(options,attempt)=>{
      const fields=new URLSearchParams(options.body.toString());
      if(attempt===1){assert.equal(fields.get('grant_type'),'refresh_token');return rejected;}
      if(attempt===2){assert.match(new URL(options.url).pathname,/deviceverifier\/auth$/);nonce=fields.get('nonce');return reply({authCode:'fixture-code'});}
      assert.equal(attempt,3);assert.equal(fields.get('grant_type'),'authorization_code');
      return reply({access_token:'next',refresh_token:'next-refresh',expires_in:3600,id_token:jwt({nonce})});
    },{...saved,expiresAt:NOW+1000});
    assert.equal((await f.provider.token()).accessToken,'next');assert.equal(f.calls.length,3);
  });
});

test('explicit challenges, forced sign-in and forbidden refresh never fall through to another credential',async t=>{
  const cases=[reply({nextAction:'COUNTERMEASURES'},401),reply({nextAction:'STANDARD_AUTH'},401),reply({},403),
    ...Array.from({length:7},(_,i)=>reply({resultCode:1300+i},401)),
    {status:401,headers:{'x-pi-auth-failure':'1300'},body:Buffer.alloc(0)}];
  for(const [i,response]of cases.entries())await t.test(String(i),async t=>{
    const auth={...saved,expiresAt:NOW+1000},f=await fixture(t,()=>response,auth);
    await assert.rejects(()=>f.provider.token(),code('sign_in_required'));assert.equal(f.calls.length,1);
    await assert.rejects(()=>f.provider.refresh(),code('sign_in_required'));assert.equal(f.calls.length,1,'denials are not hammered');
    assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),auth);
  });
});

test('saved-device rejection is terminal and never retries password, validation, or refresh',async t=>{
  for(const response of [reply({},401),reply({},403),reply({nextAction:'COUNTERMEASURES'},200)])await t.test(String(response.status),async t=>{
    const f=await fixture(t,()=>response);await assert.rejects(()=>f.provider.token(),code('sign_in_required'));
    assert.equal(f.calls.length,1);assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),saved);
  });
});

test('nonce mismatch or malformed token responses never overwrite credentials',async t=>{
  for(const id_token of [undefined,jwt({nonce:'wrong'}),'malformed'])await t.test(String(id_token),async t=>{
    const f=await fixture(t,(_options,attempt)=>attempt===1?reply({authCode:'fixture-code'}):reply({access_token:'next',refresh_token:'next',expires_in:3600,id_token}));
    await assert.rejects(()=>f.provider.token(),code('source_unavailable'));
    assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),saved);
  });
});

test('outages and malformed refresh responses do not fall through or claim the user signed out',async t=>{
  for(const expired of [true,false])for(const response of [reply({},503),reply({},429),reply(Buffer.from('not JSON')),reply({})])await t.test(`${expired}-${response.status}-${response.body.length}`,async t=>{
    const auth={...saved,expiresAt:expired?NOW-1:NOW+1000},f=await fixture(t,()=>response,auth);
    await assert.rejects(()=>f.provider.token(),code('source_unavailable'));assert.equal(f.calls.length,1);
    assert.deepEqual(JSON.parse(await readFile(f.authFile,'utf8')),auth);
  });
});

test('disk-write retry persists the rotated credential instead of spending the old refresh token again',async t=>{
  let f;
  f=await fixture(t,async()=>{
    await rename(f.authFile,f.authFile+'.backup');await mkdir(f.authFile);
    return reply({access_token:'next',refresh_token:'rotated',expires_in:3600});
  },{...saved,expiresAt:NOW+1000});
  await assert.rejects(()=>f.provider.refresh(),code('source_unavailable'));assert.equal(f.calls.length,1);
  await rm(f.authFile,{recursive:true});await rename(f.authFile+'.backup',f.authFile);
  assert.equal((await f.provider.refresh()).refreshToken,'rotated');assert.equal(f.calls.length,1);
  assert.equal(JSON.parse(await readFile(f.authFile,'utf8')).refreshToken,'rotated');
});
