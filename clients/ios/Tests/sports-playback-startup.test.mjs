import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// Execute the app's own startup helper, never a fetched player/provider script.
const swift = readFileSync(new URL('../Velvet/UI/LiveSports/SportsPlaybackStartup.swift', import.meta.url), 'utf8');
const script = swift.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/u)?.[1];
assert.ok(script, 'The test must extract the actual Swift startup script.');

function fixture({ url = 'https://embed.st/embed/golf/2181/1', selectedEmbed = 'https://embed.st/embed/golf/2181/1', width = 1280, height = 720, hidden = false } = {}) {
  let now = 0;
  let nextTimer = 0;
  const timers = new Map();
  const messages = [];
  const videos = [];
  const controls = [];
  const location = new URL(url);
  const parts = new URL(selectedEmbed).pathname.split('/').filter(Boolean);
  const config = { embedURL: selectedEmbed };
  if (parts.length === 4 && parts[0] === 'embed' && parts[1] === 'golf') {
    config.golfID = parts[2];
  }
  const configuredScript = script.replace('__VELVET_STARTUP_CONFIG__', JSON.stringify(config));
  const document = {
    hidden,
    location,
    querySelectorAll(selector) {
      if (selector === 'video') return videos;
      assert.match(selector, /jwplayer|player-poster/u, 'Only known player controls may be queried.');
      assert.doesNotMatch(selector, /\ba\[|button|innerText|textContent/u, 'Do not widen startup to links or generic buttons.');
      return controls;
    },
  };
  const context = vm.createContext({
    URL, document, location, innerWidth: width, innerHeight: height,
    performance: { now: () => now },
    addEventListener() {},
    getComputedStyle: element => element.style,
    setInterval(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { callback, delay, due: now + delay });
      return id;
    },
    clearInterval: id => timers.delete(id),
    webkit: { messageHandlers: { sportsPlaybackState: { postMessage: body => messages.push(JSON.parse(JSON.stringify(body))) } } },
  });
  context.window = context;
  context.self = context;
  const element = ({ w = 1280, h = 720, anchor = false, opacity = '1' } = {}) => ({
    style: { display: 'block', visibility: 'visible', opacity },
    getBoundingClientRect: () => ({ width: w, height: h, top: 0, left: 0, right: w, bottom: h }),
    closest: selector => selector.includes('a') && anchor ? {} : null,
    hasAttribute: () => false,
  });
  return {
    document, videos, controls, messages,
    control(options = {}) {
      const control = { ...element(options), clicks: 0, click() { this.clicks++; } };
      controls.push(control);
      return control;
    },
    video(options = {}) {
      const video = {
        ...element(options), isConnected: true, currentTime: 0, videoWidth: 1280, videoHeight: 720,
        readyState: 4, paused: true, ended: false, plays: 0,
        hasAttribute: name => name === 'src', getAttribute: name => name === 'src' ? 'fixture-video-source' : null,
        querySelector: () => null, querySelectorAll: () => [],
        play() { this.plays++; this.paused = false; return Promise.resolve(); },
        ...options,
      };
      videos.push(video);
      return video;
    },
    start(approve = true) {
      vm.runInContext(configuredScript, context, { timeout: 1000 });
      if (approve) vm.runInContext('window.__velvetStartApprovedStartup?.()', context);
    },
    approve() { vm.runInContext('window.__velvetStartApprovedStartup?.()', context); },
    cancel() { vm.runInContext('window.__velvetCancelStartup?.()', context); },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        const pending = [...timers.entries()].filter(([, value]) => value.due <= end).sort((a, b) => a[1].due - b[1].due)[0];
        if (!pending) break;
        const [id, timer] = pending;
        now = timer.due;
        timer.due += timer.delay;
        timer.callback();
        if (timers.has(id)) assert.ok(timer.delay > 0);
      }
      now = end;
    },
    get timerCount() { return timers.size; },
  };
}

test('retries only the intended initial Play control at a bounded cadence', () => {
  const f = fixture();
  const control = f.control();
  f.start();
  assert.equal(control.clicks, 1);
  f.advance(1200);
  assert.equal(control.clicks, 1);
  f.advance(300);
  assert.equal(control.clicks, 2);
  assert.equal(f.messages.some(message => message.state === 'playing'), false);
});

test('candidate frames cannot play or click before native approval', () => {
  const f = fixture({ url: 'https://embed.st/embed/ingest/streamedportlandtrailblazers/1' });
  const control = f.control();
  f.start(false);
  assert.deepEqual(f.messages, [{ state: 'ready' }]);
  f.advance(5000);
  assert.equal(control.clicks, 0);
  assert.equal(f.timerCount, 0);
  f.approve();
  assert.equal(control.clicks, 1);
  assert.equal(f.timerCount, 1);
});

test('Golf 2 declared alternate wrapper waits for approval despite its internal no=1', () => {
  const f = fixture({
    selectedEmbed: 'https://embed.st/embed/golf/2181/2',
    url: 'https://rockylive.st/source/streamed.php?id=2181&no=1',
  });
  const control = f.control();
  f.start(false);
  assert.deepEqual(f.messages, [{ state: 'ready' }]);
  f.advance(5000);
  assert.equal(control.clicks, 0);
  assert.equal(f.timerCount, 0);
  f.approve();
  assert.equal(control.clicks, 1);
  assert.equal(f.timerCount, 1);
});

test('declared ingest trailing slash remains a candidate requiring native approval', () => {
  const f = fixture({
    selectedEmbed: 'https://embed.st/embed/golf/2181/2',
    url: 'https://embed.st/embed/ingest/streamedportlandtrailblazers/1/',
  });
  const video = f.video();
  f.start(false);
  assert.deepEqual(f.messages, [{ state: 'ready' }]);
  f.advance(5000);
  assert.equal(video.plays, 0);
  assert.equal(f.timerCount, 0);
  f.approve();
  assert.equal(video.plays, 1);
  assert.equal(f.timerCount, 1);
});

test('declared Clappr autoplay fragment still needs explicit native approval', () => {
  const f = fixture({
    selectedEmbed: 'https://embed.st/embed/golf/2181/2',
    url: 'https://embed.st/embed/ingest/streamedportlandtrailblazers/1/#player=clappr&autoplay=true',
  });
  const control = f.control();
  f.start(false);
  assert.deepEqual(f.messages, [{ state: 'ready' }]);
  f.advance(5000);
  assert.equal(control.clicks, 0);
  assert.equal(f.timerCount, 0);
  f.approve();
  assert.equal(control.clicks, 1);
  assert.equal(f.timerCount, 1);
});

test('late approval cannot restart a canceled candidate', () => {
  const f = fixture({ url: 'https://embed.st/embed/ingest/streamedportlandtrailblazers/1' });
  const control = f.control();
  f.start(false);
  f.cancel();
  f.approve();
  f.advance(5000);
  assert.equal(control.clicks, 0);
  assert.equal(f.timerCount, 0);
});

test('malformed or unrelated ingest candidates cannot request or receive startup', () => {
  const child = 'https://embed.st/embed/ingest/streamedportlandtrailblazers/1';
  for (const options of [
    { url: `${child}?event=other` },
    { url: `${child}#player` },
    { url: `${child}#player=jw&autoplay=true` },
    { url: `${child}#player=clappr&autoplay=false` },
    { url: `${child}#autoplay=true&player=clappr` },
    { url: `${child}#player=clappr&autoplay=true&autoplay=true` },
    { url: child.replace('embed.st', 'embed.st.evil.example') },
    { url: child.replace('embed.st', 'embed.st:444') },
    { url: child.replace('embed.st', 'user:pass@embed.st') },
    { url: child.replace('https:', 'http:') },
    { url: child.replace('/1', '/0') },
    { url: child.replace('/1', '/1000') },
    { url: child.replace('streamedportlandtrailblazers', '_unrelated') },
    { url: child, selectedEmbed: 'https://embed.st/embed/admin/game/1' },
  ]) {
    const f = fixture(options);
    const control = f.control();
    const video = f.video();
    f.start();
    f.advance(5000);
    assert.equal(f.messages.length, 0, options.url);
    assert.equal(control.clicks, 0, options.url);
    assert.equal(video.plays, 0, options.url);
    assert.equal(f.timerCount, 0, options.url);
  }
});

test('does not click anchors or invisible player controls', () => {
  const f = fixture();
  const anchor = f.control({ anchor: true });
  const invisible = f.control({ opacity: '0' });
  f.start();
  f.advance(3000);
  assert.equal(anchor.clicks, 0);
  assert.equal(invisible.clicks, 0);
});

test('ignores hidden advertising frames and background documents', () => {
  for (const options of [{ width: 1, height: 1 }, { hidden: true }]) {
    const f = fixture(options);
    const control = f.control();
    const video = f.video();
    f.start();
    f.advance(3000);
    assert.equal(control.clicks, 0);
    assert.equal(video.plays, 0);
    assert.equal(f.messages.some(message => message.state === 'playing'), false);
  }
});

test('unrelated/ad frames and wrong Golf identity cannot act or report progress', () => {
  for (const url of [
    'https://advertising.example/player',
    'https://embed.st/ad.html',
    'https://embed.st/embed/golf/2180/1',
    'https://rockylive.st/source/streamed1.php?id=2180&no=1',
    'https://rockylive.st/source/streamed1.php?id=2181&id=2181&no=1',
    'https://rockylive.st/source/streamed1.php?id=2181&no=1&no=1',
    'https://rockylive.st/source/streamed.php?id=2181&no=0',
    'https://rockylive.st/source/streamed.php?id=2181&no=1000',
    'https://rockylive.st/source/streamed.php?id=2181&no=1&hd=531&hd=531',
    'https://rockylive.st/source/streamed.php?id=2181&no=1&hd=not-numeric',
    'https://rockylive.st/source/streamed.php?id=2181&no=1&redirect=other',
    'https://rockylive.st/source/streamed.php?id=2181&no=1#player',
    'https://rockylive.st:444/source/streamed1.php?id=2181&no=1',
    'https://user:pass@rockylive.st/source/streamed1.php?id=2181&no=1',
    'http://rockylive.st/source/streamed1.php?id=2181&no=1',
    'https://rockylive.st/unrelated?id=2181&no=1',
  ]) {
    const f = fixture({ url });
    const control = f.control();
    const video = f.video({ paused: false });
    f.start();
    video.currentTime = 4;
    f.advance(3000);
    assert.equal(control.clicks, 0, url);
    assert.equal(video.plays, 0, url);
    assert.equal(f.messages.length, 0, url);
    assert.equal(f.timerCount, 0, url);
  }
});

test('a Golf nested frame cannot report progress for an Admin selection', () => {
  const f = fixture({ url: 'https://rockylive.st/source/streamed1.php?id=2181&no=1', selectedEmbed: 'https://embed.st/embed/admin/game/1' });
  const video = f.video({ paused: false });
  f.start();
  video.currentTime = 4;
  f.advance(3000);
  assert.equal(f.messages.length, 0);
});

test('small video elements are not treated as the event player', () => {
  const f = fixture();
  const video = f.video({ w: 300, h: 150, paused: false });
  f.start();
  video.currentTime = 4;
  f.advance(3000);
  assert.equal(video.plays, 0);
  assert.equal(f.messages.some(message => message.state === 'playing'), false);
});

test('a decoded picture and advancing time are both required; later Pause remains paused', () => {
  const f = fixture({ url: 'https://rockylive.st/source/streamed1.php?hd=531&id=2181&no=1' });
  const video = f.video({ videoWidth: 0, videoHeight: 0 });
  f.start();
  assert.equal(video.plays, 1);
  video.currentTime = 2;
  f.advance(300);
  assert.equal(f.messages.some(message => message.state === 'playing'), false);
  video.videoWidth = 1280;
  video.videoHeight = 720;
  f.advance(300);
  assert.equal(f.messages.some(message => message.state === 'playing'), false);
  video.currentTime = 2.4;
  f.advance(300);
  assert.equal(f.messages.filter(message => message.state === 'playing').length, 1);
  assert.equal(f.timerCount, 1); // Only the passive playback observer remains.
  video.paused = true;
  f.advance(5000);
  assert.equal(video.plays, 1);
  assert.equal(video.paused, true);
});

test('a source-bearing video uses play without also pressing player controls', () => {
  const f = fixture();
  const video = f.video();
  const control = f.control();
  f.start();
  f.advance(3000);
  assert.equal(video.plays, 1);
  assert.equal(control.clicks, 0);
});

test('an empty video source still reaches the intended initial Play control', () => {
  const f = fixture();
  const video = f.video({ getAttribute: () => '' });
  const control = f.control();
  f.start();
  assert.equal(video.plays, 0);
  assert.equal(control.clicks, 1);
});

test('deadline permanently stops retrying a source that never starts', () => {
  const f = fixture();
  const control = f.control();
  f.start();
  f.advance(46_000);
  assert.equal(f.timerCount, 0);
  const clicks = control.clicks;
  assert.ok(clicks > 1 && clicks <= 30);
  f.advance(60_000);
  assert.equal(control.clicks, clicks);
  assert.equal(f.messages.some(message => message.state === 'playing'), false);
});

test('native cancellation stops every further play attempt', () => {
  const f = fixture();
  const control = f.control();
  f.start();
  f.cancel();
  f.advance(60_000);
  assert.equal(control.clicks, 1);
  assert.equal(f.timerCount, 0);
});

test('passive reporting requires ongoing clock movement and stops when backgrounded', () => {
  const f = fixture();
  const video = f.video();
  f.start(); video.currentTime = .5; f.advance(300);
  video.currentTime = 1.5; f.advance(1000);
  assert.equal(f.messages.at(-1).state, 'playing');
  f.advance(1000);
  assert.equal(f.messages.at(-1).state, 'buffering');
  video.currentTime = 120; f.advance(1000);
  assert.equal(f.messages.at(-1).state, 'buffering');
  video.paused = true; f.advance(1000);
  assert.equal(f.messages.at(-1).state, 'paused');
  assert.equal(video.plays, 1);
  const count = f.messages.length;
  f.document.hidden = true; f.advance(5000);
  assert.equal(f.messages.length, count);
  assert.equal(f.timerCount, 0);
});
