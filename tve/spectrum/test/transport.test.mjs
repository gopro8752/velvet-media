import test, {before, after} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {boundedRequest, BridgeError} from '../src/http.mjs';
import {createControlRequest} from '../src/transport.mjs';

const failure = error => error instanceof BridgeError && error.message === 'source_unavailable' && !error.cause;
let directory, certificate, key;
before(async () => {
  // Generate an ephemeral test-only CA/key; never commit a private key fixture.
  directory = await mkdtemp(join(tmpdir(), 'velvet-spectrum-connect-test-'));
  const configuration = join(directory, 'openssl.cnf');
  await writeFile(configuration, '[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=apis.spectrum.net\n[extensions]\nsubjectAltName=DNS:apis.spectrum.net\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', configuration, '-keyout', join(directory, 'key.pem'), '-out', join(directory, 'cert.pem')], {stdio: 'ignore'});
  certificate = await readFile(join(directory, 'cert.pem'));
  key = await readFile(join(directory, 'key.pem'));
});
after(async () => { if (directory) await rm(directory, {recursive: true, force: true}); });

async function listen(server) {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return server.address().port;
}
async function fixture(t, {origin, connect} = {}) {
  const connections = new Set(), calls = [], originCalls = [], tlsOptions = [];
  const track = socket => { connections.add(socket); socket.on('error', () => {}); socket.on('close', () => connections.delete(socket)); };
  const upstream = https.createServer({key, cert: certificate}, (request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      originCalls.push({method: request.method, url: request.url, headers: request.headers, body: Buffer.concat(chunks)});
      if (origin) origin(request, response); else response.end(Buffer.from([0, 255, 128, 1]));
    });
  });
  upstream.on('connection', track);
  const upstreamPort = await listen(upstream);
  const proxy = http.createServer((_request, response) => { response.writeHead(405); response.end(); });
  proxy.on('connection', track);
  proxy.on('connect', (request, socket, head) => {
    calls.push({method: request.method, url: request.url, headers: request.headers, head});
    if (connect) { connect(request, socket); return; }
    const target = net.connect(upstreamPort, '127.0.0.1', () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      socket.pipe(target); target.pipe(socket);
    });
    track(target);
    socket.on('close', () => target.destroy()); target.on('close', () => socket.destroy());
  });
  const proxyPort = await listen(proxy);
  const originalConnect = tls.connect;
  // Real TLS handshake and hostname checks; trust only our ephemeral local CA.
  t.mock.method(tls, 'connect', options => {
    tlsOptions.push(options);
    return originalConnect({...options, ca: certificate});
  });
  t.after(async () => {
    for (const socket of connections) socket.destroy();
    await Promise.all([new Promise(resolve => proxy.close(resolve)), new Promise(resolve => upstream.close(resolve))]);
  });
  return {url: `http://127.0.0.1:${proxyPort}`, calls, originCalls, tlsOptions};
}

test('unset proxy preserves ordinary direct transport', () => {
  for (const config of [undefined, null, '']) assert.equal(createControlRequest(config), boundedRequest);
});

test('invalid proxy configuration fails without echoing credentials', () => {
  for (const value of ['https://private:secret@proxy:3128', 'socks5://proxy:1080', 'http://proxy:0', 'http://proxy/path',
    'http://proxy/?token=private', 'http://proxy/#private', 'http://:secret@proxy', 'http://user%0asecret:password@proxy',
    'http://user%3aname:secret@proxy', 'http://user:%zz@proxy', 'http://proxy\n', ' http://proxy', 'private', {}, 'x'.repeat(4097)]) {
    assert.throws(() => createControlRequest(value), failure);
  }
});

test('CONNECT preserves native challenge bytes with end-to-end TLS and separates proxy credentials', async t => {
  const fx = await fixture(t);
  const request = createControlRequest(fx.url.replace('http://', 'http://proxy-user:private%3Aproxy-password@'));
  const body = Buffer.from([255, 0, 128, 1]);
  const result = await request({url: 'https://apis.spectrum.net/license?fixture=yes', method: 'POST',
    headers: {Authorization: 'Bearer private-provider-token', 'AST-Authorization': 'private-ast',
      'Content-Type': 'application/octet-stream', 'Proxy-Authorization': 'must-not-reach-origin'}, body, maxBytes: 4});
  assert.equal(result.status, 200); assert.deepEqual(result.body, Buffer.from([0, 255, 128, 1]));
  assert.equal(fx.calls.length, 1); assert.equal(fx.originCalls.length, 1);
  assert.equal(fx.calls[0].url, 'apis.spectrum.net:443');
  assert.equal(fx.calls[0].headers['proxy-authorization'], `Basic ${Buffer.from('proxy-user:private:proxy-password').toString('base64')}`);
  assert.equal(fx.calls[0].headers.authorization, undefined); assert.equal(fx.calls[0].headers['ast-authorization'], undefined);
  assert.equal(fx.originCalls[0].headers['proxy-authorization'], undefined);
  assert.equal(fx.originCalls[0].headers.authorization, 'Bearer private-provider-token');
  assert.equal(fx.originCalls[0].headers['ast-authorization'], 'private-ast');
  assert.equal(fx.originCalls[0].url, '/license?fixture=yes'); assert.deepEqual(fx.originCalls[0].body, body);
  assert.equal(fx.tlsOptions[0].servername, 'apis.spectrum.net'); assert.equal(fx.tlsOptions[0].rejectUnauthorized, true);
  assert.deepEqual(fx.tlsOptions[0].ALPNProtocols, ['http/1.1']);
});

test('only exact Spectrum HTTPS control hosts can use the tunnel', async t => {
  const fx = await fixture(t, {connect: (_request, socket) => socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')});
  const request = createControlRequest(fx.url);
  for (const url of ['https://edge-mm.spectrum.net/media', 'https://apis.spectrum.net.attacker.example/path',
    'https://apis.spectrum.net:8443/path', 'http://apis.spectrum.net/path', 'https://user:password@apis.spectrum.net/path',
    'https://apis.spectrum.net/path#fragment', 'https://127.0.0.1/path', 'not a url']) {
    await assert.rejects(() => request({url}), failure);
  }
  assert.equal(fx.calls.length, 0);
  for (const hostname of ['apis.spectrum.net', 'apis-vid.spectrum.net', 'apis-drm.spectrum.net', 'pi-lite.spectrum.net']) {
    await assert.rejects(() => request({url: `https://${hostname}/path`}), failure);
  }
  assert.equal(fx.calls.length, 4); assert.equal(fx.originCalls.length, 0);
});

test('Spectrum redirects are returned to the caller and never followed through the proxy', async t => {
  const fx = await fixture(t, {origin: (_request, response) => { response.writeHead(302, {Location: 'https://edge-mm.spectrum.net/media'}); response.end(); }});
  const result = await createControlRequest(fx.url)({url: 'https://apis.spectrum.net/redirect'});
  assert.equal(result.status, 302); assert.equal(result.headers.location, 'https://edge-mm.spectrum.net/media');
  assert.equal(fx.calls.length, 1); assert.equal(fx.originCalls.length, 1);
});

test('TLS hostname validation rejects a different allowed hostname even when the CA is trusted', async t => {
  const fx = await fixture(t);
  await assert.rejects(() => createControlRequest(fx.url)({url: 'https://apis-drm.spectrum.net/license'}), failure);
  assert.equal(fx.calls.length, 1); assert.equal(fx.originCalls.length, 0);
});

test('proxy failures and response limits fail closed with sanitized errors', async t => {
  const cases = [
    {connect: (_request, socket) => socket.end('HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n')},
    {connect: (_request, socket) => socket.end('HTTP/1.1 200 Connection Established\r\n\r\nprivate-unexpected-bytes')},
    {connect: (_request, socket) => socket.destroy()},
    {origin: (_request, response) => { response.writeHead(200, {'Content-Length': 5}); response.end('12345'); }},
    {origin: (_request, response) => { response.write('123'); response.end('45'); }},
    {origin: (_request, response) => { response.write('1'); response.socket.destroy(); }},
  ];
  for (let index = 0; index < cases.length; index++) await t.test(`failure ${index}`, async t => {
    const fx = await fixture(t, cases[index]);
    await assert.rejects(() => createControlRequest(fx.url)({url: 'https://apis.spectrum.net/path', maxBytes: 4}), failure);
    assert.equal(fx.calls.length, 1);
  });
});

test('one deadline bounds stalled CONNECT, TLS, and response bodies', async t => {
  const cases = [
    {connect: () => {}},
    {connect: (_request, socket) => socket.write('HTTP/1.1 200 Connection Established\r\n\r\n')},
    {origin: (_request, response) => { response.write('1'); }},
  ];
  for (let index = 0; index < cases.length; index++) await t.test(`deadline ${index}`, async t => {
    const fx = await fixture(t, cases[index]);
    const started = Date.now();
    await assert.rejects(() => createControlRequest(fx.url)({url: 'https://apis.spectrum.net/path', timeoutMs: 60}), failure);
    assert.ok(Date.now() - started < 2000); assert.equal(fx.calls.length, 1);
  });
});

test('invalid budgets and oversized challenges never open a tunnel', async t => {
  const fx = await fixture(t);
  const request = createControlRequest(fx.url);
  for (const options of [{maxBytes: -1}, {maxBytes: Infinity}, {maxBytes: 64 * 1024 * 1024 + 1},
    {timeoutMs: 0}, {timeoutMs: Infinity}, {timeoutMs: 120001}, {body: {}}, {body: Buffer.alloc(8 * 1024 * 1024 + 1)}]) {
    await assert.rejects(() => request({url: 'https://apis.spectrum.net/path', ...options}), failure);
  }
  assert.equal(fx.calls.length, 0);
});
