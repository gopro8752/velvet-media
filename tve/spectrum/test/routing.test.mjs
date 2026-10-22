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
import {createBridge, validateConfig} from '../src/server.mjs';

let directory, certificate, key;
before(async () => {
  directory = await mkdtemp(join(tmpdir(), 'velvet-spectrum-routing-test-'));
  const configuration = join(directory, 'openssl.cnf');
  await writeFile(configuration, '[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=apis.spectrum.net\n[extensions]\nsubjectAltName=DNS:apis.spectrum.net,DNS:apis-vid.spectrum.net,DNS:apis-drm.spectrum.net,DNS:pi-lite.spectrum.net\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', configuration, '-keyout', join(directory, 'key.pem'), '-out', join(directory, 'cert.pem')], {stdio: 'ignore'});
  certificate = await readFile(join(directory, 'cert.pem')); key = await readFile(join(directory, 'key.pem'));
});
after(async () => { if (directory) await rm(directory, {recursive: true, force: true}); });
async function listen(server) {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return server.address().port;
}

async function fixture(t, {home = true} = {}) {
  const sockets = new Set(), controls = [], connects = [], media = [];
  const track = socket => { sockets.add(socket); socket.on('error', () => {}); socket.on('close', () => sockets.delete(socket)); };
  let clock = Date.now(), proxyAvailable = true;
  const upstream = https.createServer({key, cert: certificate}, (request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      const url = new URL(request.url, `https://${request.headers.host}`);
      controls.push({url, method: request.method, headers: request.headers, body: Buffer.concat(chunks)});
      const json = (value, status = 200, headers = {}) => { response.writeHead(status, {'Content-Type': 'application/json', ...headers}); response.end(JSON.stringify(value)); };
      if (url.pathname === '/auth/oauth/v2/token') return json({access_token: 'rotated-fixture-access', refresh_token: 'rotated-fixture-refresh', expires_in: 3600});
      if (url.pathname.endsWith('/channels/v3')) {
        if (request.headers.authorization === 'Bearer fixture-access') return json({}, 401);
        return json([{entitlementId: '123', tmsGuideId: '456', online: true, onlineEntitled: true, networkName: 'Fixture'}]);
      }
      if (url.pathname === '/pinxt/customer/location/v1') return json({behindOwnModem: home, inMarket: true, stateAbbr: 'OH'});
      if (url.pathname.endsWith('/stream/live/v6/123')) return json({
        streamUrl: 'https://edge-mm.spectrum.net/live/start.m3u8', outputFeedId: 'fixture-feed', initLocation: {behindOwnModem: home},
        ...(home ? {} : {aegis: {aegisToken: 'fixture-lease', aegisTokenRefreshSeconds: 3600}}),
      }, 200, {'x-set-ast': 'fixture-tune-ast'});
      if (url.pathname.includes('/ast/live/v2/')) return json({}, 200, {'x-set-ast': 'fixture-renewed-ast'});
      if (url.pathname.endsWith('/getcertificate/v2')) return response.end(Buffer.from([0x30, 1, 0]));
      if (url.pathname.endsWith('/getckc/v2')) return response.end(Buffer.from([255, 0, 128, 1]));
      if (url.pathname.endsWith('/aegis/v1') && request.method === 'DELETE') return json({});
      if (url.pathname.endsWith('/twctv/grid')) return json({'456': [{tmsGuideId: '456', tmsProgramId: 'fixture-program', title: 'Fixture program', startTimeSec: Math.floor(clock / 3600000) * 3600, durationMinutes: 60}]});
      return json({}, 404);
    });
  });
  upstream.on('connection', track);
  const upstreamPort = await listen(upstream);
  const proxy = http.createServer(); proxy.on('connection', track);
  proxy.on('connect', (request, socket) => {
    connects.push({url: request.url, headers: request.headers});
    if (!proxyAvailable) { socket.end('HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n'); return; }
    const target = net.connect(upstreamPort, '127.0.0.1', () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n'); socket.pipe(target); target.pipe(socket);
    });
    track(target); target.on('close', () => socket.destroy()); socket.on('close', () => target.destroy());
  });
  const proxyPort = await listen(proxy), originalTlsConnect = tls.connect;
  t.mock.method(tls, 'connect', options => originalTlsConnect({...options, ca: certificate}));
  const authFile = join(directory, `auth-${home ? 'home' : 'away'}.json`);
  await writeFile(authFile, JSON.stringify({accessToken: 'fixture-access', refreshToken: 'fixture-refresh', deviceId: 'fixture-device', expiresAt: clock + 3600000}), {mode: 0o600});
  const config = {authFile, controlProxyUrl: `http://fixture-user:fixture-password@127.0.0.1:${proxyPort}`, refreshLocation: true,
    tuneQuery: {behindOwnModem: false}, manifestQuery: {behindOwnModem: false}};
  const directRequest = async options => {
    const url = new URL(options.url); media.push({...options, url});
    assert.ok(['edge-mm.spectrum.net', 'video.edge-mm.spectrum.com'].includes(url.hostname), 'control traffic must not use the direct transport');
    assert.deepEqual(options.headers, {}, 'provider, AST and proxy credentials never reach the CDN');
    if (url.pathname.endsWith('/start.m3u8')) return {status: 302, headers: {location: 'https://video.edge-mm.spectrum.com/own/main.m3u8'}, body: Buffer.alloc(0)};
    const body = url.pathname.endsWith('.m3u8') ? Buffer.from('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skds://provider/key?ContentId=fixture-content&KeyId=fixture-key",KEYFORMAT="com.apple.streamingkeydelivery"\n#EXTINF:6,\nsegment.ts\n') : Buffer.from([0x47, 0xff, 0, 0x80]);
    return {status: 200, headers: {}, body};
  };
  // Use the real default SpectrumProvider and real CONNECT transport; only the
  // distinct media adapter is injected so no external network is contacted.
  const bridge = createBridge(config, {request: directRequest, now: () => clock});
  t.after(async () => {
    await bridge.close();
    for (const socket of sockets) socket.destroy();
    await Promise.all([new Promise(resolve => proxy.close(resolve)), new Promise(resolve => upstream.close(resolve))]);
  });
  return {bridge, controls, connects, media, authFile, advance: milliseconds => {clock += milliseconds;}, disconnect: () => {proxyAvailable = false;}};
}

test('proxy configuration cannot use stale captured location flags', () => {
  const base = {authFile: '/private/auth.json', tuneQuery: {}, manifestQuery: {}};
  for (const refreshLocation of [undefined, false, 'true', 1]) {
    assert.throws(() => validateConfig({...base, refreshLocation, controlProxyUrl: 'http://proxy:3128'}), {code: 'invalid_request'});
  }
  for (const controlProxyUrl of ['', null, {}, true]) {
    assert.throws(() => validateConfig({...base, refreshLocation: true, controlProxyUrl}), {code: 'invalid_request'});
  }
  assert.equal(validateConfig({...base, refreshLocation: true, controlProxyUrl: 'http://proxy:3128'}).refreshLocation, true);
  assert.throws(() => createBridge({...base, refreshLocation: true, controlProxyUrl: 'https://user:private@proxy:3128'}), {code: 'source_unavailable'});
});

test('default provider routes authorization, guide and DRM over CONNECT while manifests, redirects and segments stay direct', async t => {
  const fx = await fixture(t);
  const [guide, tuned] = await Promise.all([fx.bridge.guide(), fx.bridge.tune('spectrum-123', 'hls-fairplay')]);
  assert.equal(guide.channels[0].programs[0].title, 'Fixture program');
  assert.deepEqual(await fx.bridge.certificate(tuned.sessionId), Buffer.from([0x30, 1, 0]));
  const manifest = await fx.bridge.media(tuned.sessionId, tuned.playbackPath.split('/').at(-1));
  const keyReference = manifest.body.toString().match(/skd:\/\/velvet\/([a-f0-9]{32})\?/)[1];
  const segmentReference = manifest.body.toString().split('\n').find(line => line.startsWith('/live/streams/'));
  assert.deepEqual((await fx.bridge.media(tuned.sessionId, segmentReference.split('/').at(-1))).body, Buffer.from([0x47, 0xff, 0, 0x80]));
  const challenge = Buffer.from([0xff, 0, 0x80, 0x01]);
  assert.deepEqual(await fx.bridge.license(tuned.sessionId, keyReference, challenge), Buffer.from([255, 0, 128, 1]));
  fx.advance(20001);
  assert.deepEqual(await fx.bridge.license(tuned.sessionId, keyReference, challenge), Buffer.from([255, 0, 128, 1]));
  assert.deepEqual(new Set(fx.connects.map(call => call.url)), new Set(['apis.spectrum.net:443', 'apis-vid.spectrum.net:443', 'apis-drm.spectrum.net:443', 'pi-lite.spectrum.net:443']));
  for (const connection of fx.connects) {
    assert.equal(connection.headers.authorization, undefined); assert.equal(connection.headers['ast-authorization'], undefined);
    assert.ok(connection.headers['proxy-authorization'].startsWith('Basic '));
  }
  assert.equal(fx.controls.filter(call => call.url.pathname === '/auth/oauth/v2/token').length, 1);
  assert.equal(JSON.parse(await readFile(fx.authFile, 'utf8')).accessToken, 'rotated-fixture-access');
  for (const call of fx.controls) assert.equal(call.headers['proxy-authorization'], undefined);
  const licenses = fx.controls.filter(call => call.url.pathname.endsWith('/getckc/v2'));
  assert.equal(licenses.length, 2); assert.equal(licenses[0].headers['ast-authorization'], 'fixture-tune-ast');
  assert.equal(licenses[1].headers['ast-authorization'], 'fixture-renewed-ast');
  assert.deepEqual(licenses[1].body, challenge); assert.ok(licenses[1].url.search.endsWith('ContentId=fixture-content&KeyId=fixture-key'));
  assert.ok(fx.media.some(call => call.url.pathname.endsWith('/segment.ts')));
  assert.ok(fx.media.some(call => call.url.hostname === 'video.edge-mm.spectrum.com'));
  const directCount = fx.media.length;
  fx.disconnect();
  await assert.rejects(() => fx.bridge.tune('spectrum-123', 'hls-fairplay'), {code: 'source_unavailable'});
  assert.equal(fx.media.length, directCount, 'proxy failure must not cause a direct authorization fallback');
  await fx.bridge.stop(tuned.sessionId);
});

test('out-of-home Aegis cleanup uses the same proxied provider transport', async t => {
  const fx = await fixture(t, {home: false});
  const tuned = await fx.bridge.tune('spectrum-123', 'hls-fairplay');
  await fx.bridge.stop(tuned.sessionId);
  const stops = fx.controls.filter(call => call.method === 'DELETE');
  assert.equal(stops.length, 1); assert.equal(stops[0].url.hostname, 'apis-vid.spectrum.net');
  assert.equal(stops[0].url.searchParams.get('aegis'), 'fixture-lease');
  assert.equal(stops[0].headers.authorization, 'Bearer rotated-fixture-access');
  assert.ok(fx.media.every(call => !call.url.hostname.startsWith('apis')));
});
