import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

// Execute the app's own startup helper, never a fetched player/provider script.
const swift = readFileSync(new URL('../Velvet/UI/LiveSports/SportsPlaybackStartup.swift', import.meta.url), 'utf8');
const script = swift.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/u)?.[1];
assert.ok(script, 'The test must extract the actual Swift startup script.');

function fixture({ url = 'https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p', selectedEmbed = 'https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p', width = 1280, height = 720, hidden = false } = {}) {
  let now = 0;
  let nextTimer = 0;
  const timers = new Map();
  const messages = [];
  const videos = [];
  const controls = [];
  const location = new URL(url);
  const config = { embedURL: selectedEmbed };
  const configuredScript = script.replace('__VELVET_STARTUP_CONFIG__', JSON.stringify(config));
  const document = {
    hidden,
    location,
    querySelectorAll(selector) {
      if (selector === 'video') return videos;
      assert.match(selector, /jwplayer/u, 'Only known player controls may be queried.');
      assert.doesNotMatch(selector, /\ba\[|button|innerText|textContent/u, 'Do not widen startup to links or generic buttons.');
      return controls;
    },
  };
  const context = vm.createContext({
    URL, document, location, innerWidth: width, innerHeight: height,
    PointerEvent: class { constructor(type, options) { this.type = type; Object.assign(this, options); } },
    MouseEvent: class { constructor(type, options) { this.type = type; Object.assign(this, options); } },
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
      const control = { ...element(options), clicks: 0, events: [], dispatchEvent(event) { this.events.push(event.type); if (event.type === "click") this.clicks++; } };
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
    approve(remaining) { vm.runInContext(`window.__velvetStartApprovedStartup?.(${remaining === undefined ? '' : Number(remaining)})`, context); },
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
  assert.deepEqual(control.events, ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]);
  f.advance(1200);
  assert.equal(control.clicks, 1);
  f.advance(300);
  assert.equal(control.clicks, 2);
  assert.equal(f.messages.some(message => message.state === 'playing'), false);
});

test('the selected embed cannot play or click before native approval', () => {
  const f = fixture();
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
  const f = fixture();
  const control = f.control();
  f.start(false); f.cancel(); f.approve(); f.advance(5000);
  assert.equal(control.clicks, 0);
  assert.equal(f.timerCount, 0);
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

test('ads, other events, other variants, and old providers cannot act or report progress', () => {
  for (const url of [
    'https://advertising.example/player',
    'https://strmfree.st/ad.html',
    'https://strmfree.st/embed/basketball/other-game1080p',
    'https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p2',
    'https://streamfree.top/embed/basketball/wizards-vs-cavaliers1080p',
    'https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p?redirect=ad',
    'https://embed.st/embed/golf/2181/1',
    'https://rockylive.st/source/streamed1.php?id=2181&no=1',
  ]) {
    const f = fixture({ url });
    const control = f.control();
    const video = f.video({ paused: false });
    f.start(); video.currentTime = 4; f.advance(3000);
    assert.equal(control.clicks, 0, url);
    assert.equal(video.plays, 0, url);
    assert.equal(f.messages.length, 0, url);
    assert.equal(f.timerCount, 0, url);
  }
});

test('the exact selected Unicode embed receives approval', () => {
  const selectedEmbed = 'https://strmfree.st/embed/soccer/cf-montr%C3%A9al1080p';
  const f = fixture({ url: selectedEmbed, selectedEmbed });
  const control = f.control(); f.start();
  assert.equal(control.clicks, 1);
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
  const f = fixture();
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

test('the JW initial poster owns startup when a prepared source already exists', () => {
  const f = fixture();
  const video = f.video();
  const control = f.control();
  f.start();
  f.advance(3000);
  assert.equal(video.plays, 0);
  assert.equal(control.clicks, 3);
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

test('startup milestones separate source attachment and metadata from decoded playback without leaking URLs', () => {
  const f = fixture();
  const video = f.video({readyState: 0, videoWidth: 0, videoHeight: 0, paused: false});
  f.start();
  assert.deepEqual(f.messages, [{state: 'ready'}, {state: 'media-source'}]);
  f.advance(3000);
  assert.equal(f.messages.length, 2);
  video.readyState = 1;
  f.advance(300);
  assert.deepEqual(f.messages.at(-1), {state: 'media-metadata'});
  f.advance(3000);
  assert.equal(f.messages.length, 3);
  video.readyState = 4; video.videoWidth = 1920; video.videoHeight = 1080;
  video.currentTime = .5; f.advance(300);
  assert.deepEqual(f.messages.at(-1), {state: 'playing'});
  for (const message of f.messages) assert.deepEqual(Object.keys(message), ['state']);
  assert.equal(video.plays, 0);
});

test('a DNS replacement receives only the remaining original startup time', () => {
  const f = fixture();
  const control = f.control(); f.start(false); f.approve(1000);
  assert.equal(control.clicks, 1);
  f.advance(1200);
  assert.equal(f.timerCount, 0);
  f.advance(5000);
  assert.equal(control.clicks, 1);
  assert.equal(f.messages.some(message => message.state === 'playing'), false);
});
