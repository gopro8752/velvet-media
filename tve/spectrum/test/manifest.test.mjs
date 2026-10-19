import test from 'node:test';
import assert from 'node:assert/strict';
import { createMediaRegistry } from '../src/manifest.mjs';
import { BridgeError } from '../src/http.mjs';

const id = 'a'.repeat(48), base = 'https://cdn.example.test/root/master.mpd?signature=private-fixture';
const prefix = `/live/streams/${id}/`;
const registry = (format = 'widevine', options = {}) => createMediaRegistry({ id, format, extraHosts: ['cdn.example.test'], ...options });
const rewrite = (r, value, kind = 'dash', final = base) => r.rewrite(Buffer.from(value), final, kind).toString();
const attr = (s, name) => [...s.matchAll(new RegExp(`\\b${name}="([^"]*)"`, 'g'))].map(m => m[1].replaceAll('&amp;', '&'));
const resolve = (r, path) => r.resolve(path.slice(prefix.length));
const simple = (template = 'seg-$Number$.m4s', idValue = 'v1') => `<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period><AdaptationSet><SegmentTemplate media="${template}" initialization="init-$RepresentationID$.mp4"/><Representation id="${idValue}" bandwidth="9000"/></AdaptationSet></Period></MPD>`;

test('static registry returns opaque stable resources and rejects unknown/arbitrary URLs', () => {
  const r = registry();
  const first = r.register(base, 'dash');
  assert.match(first, /^[a-f0-9]{32}\.mpd$/);
  assert.equal(r.register(base, 'dash'), first);
  assert.deepEqual(r.resolve(first), { url: base, kind: 'dash' });
  assert.throws(() => r.resolve('https://cdn.example.test/secret'), BridgeError);
  assert.throws(() => r.resolve('../' + first), BridgeError);
  for (const u of ['http://cdn.example.test/a', 'https://127.0.0.1/a', 'https://cdn.example.test.attacker.test/a',
    'https://user:pass@cdn.example.test/a', 'https://cdn.example.test/a#fragment', 'file:///tmp/file'])
    assert.throws(() => r.register(u, 'segment'), BridgeError);
});

test('DASH inherits BaseURL/template/timeline per representation without altering DRM', () => {
  const drm = '<ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"><cenc:pssh xmlns:cenc="urn:mpeg:cenc:2013">AAEC//==</cenc:pssh></ContentProtection>';
  const source = `<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><BaseURL>https://cdn.example.test/live/</BaseURL><Period><BaseURL>period/</BaseURL><AdaptationSet>${drm}<BaseURL>video/</BaseURL><SegmentTemplate timescale="90000" startNumber="7" media="$RepresentationID$/s-$Bandwidth$-$Time$.m4s?sig=fixture&amp;x=1" initialization="$RepresentationID$/init.mp4"><SegmentTimeline><S t="900000" d="180000" r="2"/></SegmentTimeline></SegmentTemplate><Representation id="low" bandwidth="1000"/><Representation id="high" bandwidth="2000"><BaseURL>alternate/</BaseURL><SegmentTemplate presentationTimeOffset="42"/></Representation></AdaptationSet></Period></MPD>`;
  const r = registry(), out = rewrite(r, source);
  assert.ok(out.includes(drm));
  assert.ok(!out.includes('https://') && !out.includes('?sig=') && !out.includes('<BaseURL>'));
  assert.equal((out.match(/<SegmentTemplate /g) || []).length, 2);
  assert.equal((out.match(/<SegmentTimeline>/g) || []).length, 2);
  const urls = attr(out, 'media').map(path => resolve(r, path.replace('$Time$', '900000')).url);
  assert.deepEqual(urls, ['https://cdn.example.test/live/period/video/low/s-1000-900000.m4s?sig=fixture&x=1',
    'https://cdn.example.test/live/period/video/alternate/high/s-2000-900000.m4s?sig=fixture&x=1']);
  const inits = attr(out, 'initialization').map(path => resolve(r, path).url);
  assert.deepEqual(inits, ['https://cdn.example.test/live/period/video/low/init.mp4', 'https://cdn.example.test/live/period/video/alternate/high/init.mp4']);
  assert.ok(out.includes('presentationTimeOffset="42"'));
});

test('DASH numbered formats, bandwidth formats, literal dollar and repeated numeric values resolve safely', () => {
  const r = registry();
  const out = rewrite(r, simple('$$literal/$RepresentationID$/$Bandwidth%05d$/$Number%05d$/$Time$/$Number$.m4s'));
  const path = attr(out, 'media')[0];
  const filled = path.replace('$Number%05d$', '00012').replace('$Time$', '360000').replace('$Number$', '12');
  assert.equal(resolve(r, filled).url, 'https://cdn.example.test/root/$literal/v1/09000/00012/360000/12.m4s');
  assert.throws(() => resolve(r, filled.replace('-12.bin', '-13.bin')), BridgeError);
  assert.throws(() => resolve(r, path.replace('$Number%05d$', '../x').replace('$Time$', '3').replace('$Number$', '3')), BridgeError);
  assert.throws(() => resolve(r, path.replace('$Number%05d$', '18446744073709551616').replace('$Time$', '3').replace('$Number$', '3')), BridgeError);
});

test('DASH namespaced elements and XML entities remain valid', () => {
  const r = registry();
  const source = '<d:MPD xmlns:d="urn:mpeg:dash:schema:mpd:2011"><d:Period><d:AdaptationSet><d:SegmentTemplate media="seg-$Number$.m4s?x=one&amp;y=&#x32;"/><d:Representation id="v" bandwidth="1"/></d:AdaptationSet></d:Period></d:MPD>';
  const out = rewrite(r, source), media = attr(out, 'media')[0];
  assert.ok(out.includes('<d:SegmentTemplate'));
  assert.equal(resolve(r, media.replace('$Number$', '5')).url, 'https://cdn.example.test/root/seg-5.m4s?x=one&y=2');
  const spectrum = rewrite(r, simple('$RepresentationID$-$Time$.m4s', 'audio=128000'));
  assert.equal(resolve(r, attr(spectrum, 'media')[0].replace('$Time$', '123')).url, 'https://cdn.example.test/root/audio=128000-123.m4s');
});

test('DASH SegmentList/SegmentBase and ranges are relayed without exposing media URLs', () => {
  const r = registry();
  const source = '<MPD><Period><AdaptationSet><Representation id="list"><BaseURL>list/</BaseURL><SegmentList timescale="1"><Initialization sourceURL="init.mp4" range="0-31"/><SegmentURL media="one.m4s" mediaRange="32-99" index="one.idx"/></SegmentList></Representation><Representation id="base"><BaseURL>https://cdn.example.test/full.mp4?sig=fixture</BaseURL><SegmentBase indexRange="12-300"><Initialization range="0-11"/></SegmentBase></Representation></AdaptationSet></Period></MPD>';
  const out = rewrite(r, source);
  assert.ok(out.includes('mediaRange="32-99"') && out.includes('indexRange="12-300"'));
  assert.equal(resolve(r, attr(out, 'media')[0]).url, 'https://cdn.example.test/root/list/one.m4s');
  assert.equal(resolve(r, attr(out, 'sourceURL')[0]).url, 'https://cdn.example.test/root/list/init.mp4');
  const segmentBase = out.match(/<BaseURL>([^<]+)<\/BaseURL>/)[1];
  assert.equal(resolve(r, segmentBase).url, 'https://cdn.example.test/full.mp4?sig=fixture');
});

test('DASH rejects XXE, malformed XML, unsafe base URLs and unknown template substitutions', () => {
  const bad = [
    '<!DOCTYPE MPD [<!ENTITY secret SYSTEM "file:///etc/passwd">]><MPD>&secret;</MPD>',
    simple().replace('</Period>', '</Wrong>'),
    simple().replace('<Period>', '<Period xml:base="https://evil.test/">'),
    simple().replace('<Period>', '<Period><BaseURL>https://evil.test/</BaseURL>'),
    simple().replace('<Representation', '<Representation xlink:href="https://evil.test/"'),
    simple('part-$Unknown$.mp4'), simple('part-$Number%099d$.mp4'), simple('part-$Number.mp4'),
    simple('https://$RepresentationID$.example.test/$Number$.m4s'),
    simple('part-$RepresentationID$-$Number$.m4s', '../unsafe'),
    simple('part-$Number$.m4s').replace('<Period>', '<Period><UTCTiming value="https://time.example.test/"/>'),
    '<MPD>' + '&'.repeat(20000) + '</MPD>',
  ];
  for (const value of bad) assert.throws(() => rewrite(registry(), value), BridgeError);
});

const hlsBase = 'https://cdn.example.test/live/master.m3u8?sig=fixture';
const hls = (r, source) => rewrite(r, source, 'hls', hlsBase);
test('HLS master renditions, iframe playlists and ordinary variants are registered as HLS', () => {
  const r = registry('fairplay');
  const source = '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",URI="audio/main.m3u8?token=fixture"\n#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English",INSTREAM-ID="CC1"\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100,URI="iframe.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=200,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="a"\nvideo/main.m3u8?token=fixture\n';
  const out = hls(r, source);
  assert.ok(!out.includes('token=') && !out.includes('https://'));
  const paths = [...attr(out, 'URI'), ...out.split('\n').filter(line => line.startsWith('/'))];
  assert.equal(paths.length, 3);
  assert.ok(paths.every(path => resolve(r, path).kind === 'hls'));
  assert.equal(resolve(r, paths[0]).url, 'https://cdn.example.test/live/audio/main.m3u8?token=fixture');
});

test('HLS FairPlay keys retain raw IDs and original queries only in a session-local map', () => {
  const r = registry('fairplay');
  const original = 'skd://provider.example/key?cOnTeNtId=raw%2Fid+plus&KeyId=fixture%2Bid';
  const line = `#EXT-X-KEY:METHOD=SAMPLE-AES,URI="${original}",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"`;
  const out = hls(r, '#EXTM3U\n' + line + '\n#EXTINF:6,\nsegment.ts?sig=fixture\n');
  const rewritten = attr(out, 'URI')[0], match = rewritten.match(/^skd:\/\/velvet\/([a-f0-9]{32})\?ContentId=(.+)$/);
  assert.ok(match); assert.equal(match[2], 'raw%2Fid+plus');
  assert.deepEqual(r.key(match[1]), { query: 'cOnTeNtId=raw%2Fid+plus&KeyId=fixture%2Bid', contentId: 'raw%2Fid+plus' });
  assert.equal(r.key('not-registered'), undefined);
  assert.ok(!out.includes('provider.example') && !out.includes('KeyId=') && !out.includes('sig='));
  assert.ok(out.includes('METHOD=SAMPLE-AES') && out.includes('KEYFORMATVERSIONS="1"'));
  const again = hls(r, '#EXTM3U\n' + line.replace('EXT-X-KEY', 'EXT-X-SESSION-KEY') + '\n');
  assert.ok(again.includes(`skd://velvet/${match[1]}?`));
  assert.equal(registry('fairplay').key(match[1]), undefined);
  const spectrum = hls(r, '#EXTM3U\n' + line.replace('skd://', 'skds://') + '\n');
  const spectrumRef = attr(spectrum, 'URI')[0].match(/velvet\/([^?]+)/)[1];
  assert.equal(r.key(spectrumRef).query, 'cOnTeNtId=raw%2Fid+plus&KeyId=fixture%2Bid');
  assert.ok(spectrum.includes('URI="skd://velvet/'));
});

test('HLS MAP, AES128 keys, media byteranges and low-latency references preserve their roles', () => {
  const r = registry('fairplay');
  const source = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin?sig=fixture",IV=0x0001\n#EXT-X-MAP:URI="init.mp4",BYTERANGE="32@0"\n#EXT-X-PART:DURATION=0.5,URI="part.m4s",BYTERANGE="100@32"\n#EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.m4s"\n#EXT-X-RENDITION-REPORT:URI="other.m3u8",LAST-MSN=1\n#EXT-X-BYTERANGE:100@132\n#EXTINF:6,\nfull.mp4?sig=fixture\n';
  const out = hls(r, source), paths = attr(out, 'URI');
  assert.ok(out.includes('BYTERANGE="32@0"') && out.includes('#EXT-X-BYTERANGE:100@132'));
  assert.deepEqual(paths.map(p => resolve(r, p).kind), ['segment', 'segment', 'segment', 'segment', 'hls']);
  assert.equal(resolve(r, paths[0]).url, 'https://cdn.example.test/live/key.bin?sig=fixture');
});

test('HLS rejects unsupported DRM, malformed attributes, arbitrary URLs and SKD overrides', () => {
  const bad = [
    '#EXTM3U\n#EXT-X-DEFINE:NAME="bad",VALUE="https://evil.test"\n',
    '#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI="https://evil.test"\n',
    '#EXTM3U\n#EXT-X-MAP:URI="https://evil.test/init"\n',
    '#EXTM3U\nhttp://cdn.example.test/plain.ts\n',
    '#EXTM3U\n#EXT-X-MAP:URI="x",URI="y"\n',
    '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n',
    '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x?ContentId=x",KEYFORMAT="other"\n',
    '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x?ContentId=x&ContentId=y",KEYFORMAT="com.apple.streamingkeydelivery"\n',
    '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x?ContentId=x&%63ontentType=VOD",KEYFORMAT="com.apple.streamingkeydelivery"\n',
    '#EXTM3U\n#EXT-X-KEY:METHOD=NONE,URI="https://cdn.example.test/x"\n',
    '#EXTM3U\n#EXT-X-UNKNOWN:URI="https://cdn.example.test/private"\n',
  ];
  for (const value of bad) assert.throws(() => hls(registry('fairplay'), value), BridgeError);
});

test('resource map is bounded and keeps recent media through refresh before safe old eviction', () => {
  let stamp = 0;
  const r = registry('fairplay', { now: () => stamp });
  const first = r.register('https://cdn.example.test/0.ts', 'segment');
  for (let i = 1; i < 4096; i++) r.register(`https://cdn.example.test/${i}.ts`, 'segment');
  stamp = 119999;
  assert.throws(() => r.register('https://cdn.example.test/new.ts', 'segment'), BridgeError);
  assert.equal(r.resolve(first).kind, 'segment'); // actively used old segments retain grace
  stamp = 120001;
  r.register('https://cdn.example.test/new.ts', 'segment');
  assert.equal(r.resolve(first).kind, 'segment');
  assert.throws(() => r.resolve('f'.repeat(32) + '.bin'), BridgeError);
});

test('malformed refresh rolls back all newly registered references', () => {
  const r = registry('fairplay');
  for (let i = 0; i < 4095; i++) r.register(`https://cdn.example.test/${i}.ts`, 'segment');
  assert.throws(() => hls(r, '#EXTM3U\ntransient.ts\nhttps://evil.test/no.ts\n'), BridgeError);
  assert.doesNotThrow(() => r.register('https://cdn.example.test/still-room.ts', 'segment'));
  assert.throws(() => r.register('https://cdn.example.test/no-room.ts', 'segment'), BridgeError);
});

test('unselected HLS rendition manifests remain available when old segment entries are evicted', () => {
  let stamp = 0;
  const r = registry('fairplay', { now: () => stamp });
  const rendition = r.register('https://cdn.example.test/unselected.m3u8', 'hls');
  const oldSegment = r.register('https://cdn.example.test/0.ts', 'segment');
  for (let i = 1; i < 4095; i++) r.register(`https://cdn.example.test/${i}.ts`, 'segment');
  stamp = 120001;
  r.register('https://cdn.example.test/new.ts', 'segment');
  assert.equal(r.resolve(rendition).kind, 'hls');
  assert.throws(() => r.resolve(oldSegment), BridgeError);
});

test('live DASH refresh reuses unchanged template URLs and key references expire only under pressure after grace', () => {
  let stamp = 0;
  const dash = registry('widevine', { now: () => stamp });
  const original = attr(rewrite(dash, simple()), 'media')[0];
  stamp = 60000;
  assert.equal(attr(rewrite(dash, simple()), 'media')[0], original);
  assert.equal(resolve(dash, original.replace('$Number$', '33')).kind, 'segment');
  const h = registry('fairplay', { now: () => stamp });
  let first;
  for (let i = 0; i < 256; i++) {
    const out = hls(h, `#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x?ContentId=${i}",KEYFORMAT="com.apple.streamingkeydelivery"\n`);
    if (i === 0) first = attr(out, 'URI')[0].match(/velvet\/([^?]+)/)[1];
  }
  assert.throws(() => hls(h, '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x?ContentId=new",KEYFORMAT="com.apple.streamingkeydelivery"\n'), BridgeError);
  assert.equal(h.key(first).contentId, '0');
  stamp += 120001;
  hls(h, '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x?ContentId=new",KEYFORMAT="com.apple.streamingkeydelivery"\n');
  assert.equal(h.key(first), undefined);
});

test('template map is capped; numeric resolution does not allocate per-segment entries', () => {
  const r = registry();
  for (let i = 0; i < 256; i++) rewrite(r, simple(`path${i}/$Number$.m4s`));
  assert.throws(() => rewrite(r, simple('another/$Number$.m4s')), BridgeError);
  const media = attr(rewrite(r, simple('path0/$Number$.m4s')), 'media')[0];
  for (let i = 0; i < 5000; i++) assert.equal(resolve(r, media.replace('$Number$', String(i))).kind, 'segment');
  assert.ok(media.length - prefix.length <= 240);
});

test('format, size, depth and binary UTF8 validation fail closed', () => {
  assert.throws(() => rewrite(registry('fairplay'), simple()), BridgeError);
  assert.throws(() => hls(registry(), '#EXTM3U\n'), BridgeError);
  assert.throws(() => registry().rewrite(Buffer.from([0xff]), base, 'dash'), BridgeError);
  assert.throws(() => registry().rewrite(Buffer.alloc(2 * 1024 * 1024 + 1, 65), base, 'dash'), BridgeError);
  assert.throws(() => rewrite(registry(), '<MPD>' + '<X>'.repeat(65) + '</X>'.repeat(65) + '</MPD>'), BridgeError);
});
