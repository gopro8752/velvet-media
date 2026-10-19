import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import {EventEmitter} from 'node:events';
import {BridgeError,MESSAGES,providerError,boundedRequest,cdnUrl,fetchCdn} from '../src/http.mjs';

const failure = error => error instanceof BridgeError && error.code==='source_unavailable' && error.message==='source_unavailable';
function fakeHttps(t, deliver) {
  const calls=[];
  t.mock.method(https,'request',(url,options,onResponse)=>{
    const request=new EventEmitter();request.chunks=[];request.destroyed=false;
    request.write=body=>request.chunks.push(Buffer.from(body));request.destroy=()=>{request.destroyed=true;};
    request.end=()=>queueMicrotask(()=>deliver(request,onResponse));
    calls.push({url:new URL(url),options,request});return request;
  });
  return calls;
}
function response(onResponse,{status=200,headers={},chunks=[],error=false,end=true}={}) {
  const stream=new EventEmitter();stream.statusCode=status;stream.headers=headers;
  onResponse(stream);
  for(const chunk of chunks) stream.emit('data',Buffer.from(chunk));
  if(error) stream.emit('error',new Error('private provider detail'));
  if(end) stream.emit('end');
}

test('provider errors expose only allowlisted codes and never raw private bodies',()=>{
  for(const [status,body,expected] of [[401,{message:'private'},'sign_in_required'],[429,{},'concurrency_limit'],
    [403,{nested:{blockedOOH:true}},'home_network_required'],[403,{unentitled:true},'channel_not_entitled'],
    [403,{code:'dmaMismatch'},'location_restricted'],[403,{InUSAOnly:true},'location_restricted'],
    [403,{blockedDRM:true},'drm_unavailable'],[500,{message:'private token and URL'},'source_unavailable']]) {
    const error=providerError(status,Buffer.from(JSON.stringify(body)));
    assert.equal(error.code,expected);assert.ok(MESSAGES[error.code]);assert.equal(error.message,expected);assert.ok(!JSON.stringify(error).includes('private'));
  }
  assert.equal(providerError(503,Buffer.from('private html')).code,'source_unavailable');
  let nested={blockedOOH:true};for(let i=0;i<8;i++)nested={child:nested};
  assert.equal(providerError(403,Buffer.from(JSON.stringify(nested))).code,'source_unavailable');
});

test('bounded HTTPS transport preserves bytes and headers without following redirects',async t=>{
  const calls=fakeHttps(t,(_request,done)=>response(done,{status:302,headers:{location:'https://unapproved.example/path'},chunks:[[0,255,128,0]]}));
  const body=Buffer.from([255,1,0]);
  const result=await boundedRequest({url:'https://apis.example/test',method:'POST',headers:{'Content-Type':'application/octet-stream'},body,maxBytes:4});
  assert.equal(calls.length,1);assert.equal(result.status,302);assert.deepEqual(result.body,Buffer.from([0,255,128,0]));
  assert.equal(calls[0].options.method,'POST');assert.deepEqual(Buffer.concat(calls[0].request.chunks),body);
  assert.equal(calls[0].options.maxHeaderSize,128*1024);
});

test('bounded HTTPS rejects unsafe transport addresses before opening a request',async t=>{
  const calls=fakeHttps(t,()=>{throw new Error('unexpected request');});
  for(const url of ['http://apis.example/test','https://user:password@apis.example/test','https://apis.example:444/test','https://apis.example/test#fragment']) {
    await assert.rejects(()=>boundedRequest({url}),failure);
  }
  assert.equal(calls.length,0);
});

test('declared and chunked body limits, transport errors, and deadlines destroy the request',async t=>{
  const cases=[
    (request,done)=>response(done,{headers:{'content-length':'5'},chunks:[]}),
    (request,done)=>response(done,{chunks:[[0,1,2],[3,4]]}),
    (request,done)=>response(done,{error:true}),
    request=>request.emit('error',new Error('private signed URL')),
    ()=>{},
  ];
  for(let i=0;i<cases.length;i++) await t.test(`bounded failure${i}`,async t=>{
    const calls=fakeHttps(t,cases[i]);
    await assert.rejects(()=>boundedRequest({url:'https://apis.example/test',maxBytes:4,timeoutMs:5}),failure);
    assert.equal(calls.length,1);assert.equal(calls[0].request.destroyed,true);
  });
});

test('CDN allowlist accepts only exact reviewed hosts or their explicit subdomains',()=>{
  for(const url of ['https://edge-mm.spectrum.net/a?signature=fixture','https://a.edge-mm.spectrum.com/a','https://segment.stvacdn.spectrum.com/a']) assert.equal(cdnUrl(url).protocol,'https:');
  assert.equal(cdnUrl('https://reviewed.example/media',['reviewed.example']).hostname,'reviewed.example');
  for(const url of ['http://edge-mm.spectrum.net/a','https://edge-mm.spectrum.net.attacker.example/a','https://edge-mm.spectrum.com/a',
    'https://evil-stvacdn.spectrum.com/a','https://user:password@edge-mm.spectrum.net/a','https://edge-mm.spectrum.net:8443/a',
    'https://edge-mm.spectrum.net/a#fragment','https://127.0.0.1/a','https://2130706433/a','file:///private/path']) assert.throws(()=>cdnUrl(url),failure);
  assert.throws(()=>cdnUrl('https://127.0.0.1/a',['127.0.0.1']),failure);
  assert.throws(()=>cdnUrl('https://[::1]/a',['[::1]']),failure);
});

test('CDN redirects are revalidated and never receive provider or backend credentials',async()=>{
  const calls=[];
  const body=Buffer.from([0,255,0,128]);
  const request=async options=>{
    calls.push(options);
    if(calls.length===1)return {status:302,headers:{location:'https://a.edge-mm.spectrum.com/next?signature=fixture'},body:Buffer.alloc(0)};
    return {status:206,headers:{'content-range':'bytes 1-4/8'},body};
  };
  const result=await fetchCdn('https://edge-mm.spectrum.net/source',{request,maxBytes:8192,headers:{Range:'bytes=1-4',Authorization:'private',Cookie:'private','AST-Authorization':'private'}});
  assert.equal(calls.length,2);assert.equal(result.status,206);assert.deepEqual(result.body,body);
  assert.equal(result.url,'https://a.edge-mm.spectrum.com/next?signature=fixture');
  for(const call of calls){assert.deepEqual(call.headers,{Range:'bytes=1-4'});assert.equal(call.maxBytes,8192);assert.ok(call.timeoutMs>0&&call.timeoutMs<=20000);}
});

test('CDN rejects escaped redirect hosts, insecure redirects, and excessive redirects',async()=>{
  for(const target of ['https://attacker.example/media','//127.0.0.1/media','http://edge-mm.spectrum.net/media','https://edge-mm.spectrum.net.attacker.example/media']) {
    let calls=0;await assert.rejects(()=>fetchCdn('https://edge-mm.spectrum.net/source',{request:async()=>{calls++;return {status:302,headers:{location:target},body:Buffer.alloc(0)};}}),failure);assert.equal(calls,1);
  }
  let calls=0;
  await assert.rejects(()=>fetchCdn('https://edge-mm.spectrum.net/source',{request:async()=>{calls++;return {status:307,headers:{location:'/loop'},body:Buffer.alloc(0)};}}),failure);
  assert.equal(calls,4);
});

test('range forwarding permits a single byte range and drops malformed or multiline values',async()=>{
  for(const range of ['bytes=0-','bytes=100-200','bytes=0-0']) {
    let sent;await fetchCdn('https://edge-mm.spectrum.net/a',{headers:{Range:range},request:async options=>{sent=options.headers;return {status:200,headers:{},body:Buffer.alloc(0)};}});assert.deepEqual(sent,{Range:range});
  }
  for(const range of ['bytes=0-1,2-3','bytes=-200','bytes=0-4\r\nAuthorization: private','items=0-1','bytes=123456789012345678901-',undefined]) {
    let sent;await fetchCdn('https://edge-mm.spectrum.net/a',{headers:{Range:range},request:async options=>{sent=options.headers;return {status:200,headers:{},body:Buffer.alloc(0)};}});assert.deepEqual(sent,{});
  }
});

test('CDN errors are sanitized instead of returning arbitrary upstream bytes',async()=>{
  await assert.rejects(()=>fetchCdn('https://edge-mm.spectrum.net/a',{request:async()=>({status:403,headers:{},body:Buffer.from('{"blockedOOH":true,"private":"secret-url"}')})}),e=>e instanceof BridgeError&&e.code==='home_network_required'&&!e.message.includes('secret'));
});
