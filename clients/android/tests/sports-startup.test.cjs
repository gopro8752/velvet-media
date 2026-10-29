const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname, '../app/src/main/assets/sports-startup/startup.js'), 'utf8');

function fixture({ viewport = [1280, 720], video = true, allow = true, source = true, poster = false, posterInLink = false } = {}) {
  let time = 0, timerId = 0, plays = 0, connected = 0, clicks = 0;
  const timers = new Map();
  const messages = [], events = {}, portEvents = {};
  const media = { isConnected: true, paused: true, readyState: 0, videoWidth: 0, videoHeight: 0, currentTime: 0,
    getBoundingClientRect: () => ({ width: 1280, height: 720, top: 0, left: 0, bottom: 720, right: 1280 }),
    getAttribute: () => source ? "fixture" : null, querySelectorAll: () => [],
    play: () => { plays++; return Promise.reject(new Error('Not ready')); } };
  const port = { onMessage: { addListener: f => portEvents.message = f }, onDisconnect: { addListener: f => portEvents.disconnect = f }, postMessage: m => { if (m.state !== 'startup') messages.push(m); } };
  const control = { closest: name => name === 'a' ? (posterInLink ? {} : null) : name === '#jwplayer.jwplayer' ? media : null, click: () => { clicks++; } };
  const document = { hidden: false, querySelectorAll: () => video ? [media] : [], querySelector: selector => poster && selector === '#jwplayer.jwplayer.jw-state-idle .jw-icon-display' ? control : null, addEventListener: (n,f) => events[n] = f };
  const context = { location: {hostname:"strmfree.st",pathname:"/embed/basketball/wizards-vs-cavaliers1080p"}, URL, window: { innerWidth: viewport[0], innerHeight: viewport[1], addEventListener: (n,f) => events[n] = f }, document,
    browser: { runtime: { connectNative: () => { connected++; return port; } } },
    getComputedStyle: () => ({ display: 'block', visibility: 'visible', opacity: '1' }), Date: { now: () => time },
    setInterval: f => { const id = ++timerId; timers.set(id, f); return id; }, clearInterval: id => timers.delete(id), Promise };
  vm.runInNewContext(script, context);
  if(allow)portEvents.message?.({type:"start"});
  return { window: context.window, media, control, messages, events, portEvents, document, get plays() { return plays; }, get clicks() { return clicks; }, get connected() { return connected; },
    step: async delta => { await Promise.resolve(); await Promise.resolve(); time += delta; for (const tick of [...timers.values()]) tick(); await Promise.resolve(); await Promise.resolve(); } };
}
test('starts by ordinary media play, waits for advancement, then respects manual pause', async () => {
  const f=fixture(); assert.equal(f.plays,1);
  f.media.readyState=4; f.media.videoWidth=1280; f.media.videoHeight=720; f.media.paused=false;
  await f.step(400); assert.equal(f.messages.length,0);
  f.media.currentTime=.5; await f.step(400);
  assert.equal(f.messages.length,1); assert.equal(f.messages[0].state,'playing');
  f.media.paused=true; await f.step(4000); assert.equal(f.plays,1);
});
test('failed startup has bounded attempts and a fixed deadline', async () => {
  const f=fixture(); for(let i=0;i<25;i++)await f.step(2000);
  assert.equal(f.plays,8); assert.equal(f.messages.length,0);
});
test('small frames never act, while intended frames can finish laying out', async () => { const f=fixture({viewport:[1,1]}); assert.equal(f.plays,0); f.window.innerWidth=1280; f.window.innerHeight=720; await f.step(400); assert.equal(f.plays,1); });
test('source close and native completion cancel all remaining startup work', async () => {
  for(const cancel of ['disconnect','message']) {
    const f=fixture(); if(cancel==='message')f.portEvents.message({type:'stop'});else f.portEvents.disconnect();
    await f.step(10000); assert.equal(f.plays,1); assert.equal(f.messages.length,0);
  }
});
test('background stops startup permanently', async () => { const f=fixture();f.document.hidden=true;f.events.visibilitychange();f.document.hidden=false;await f.step(4000);assert.equal(f.plays,1); });

test('no actions before native origin validation', async () => { const f=fixture({allow:false});await f.step(10000);assert.equal(f.plays,0);f.portEvents.message({type:'start'});assert.equal(f.plays,1); });
test('empty video uses only the exact intended poster', async () => { const f=fixture({source:false,poster:true});assert.equal(f.plays,0);assert.equal(f.clicks,1);await f.step(2000);assert.equal(f.clicks,2); });

test('passive telemetry observes progress, pause and buffering without restarting playback', async () => {
  const f = fixture();
  f.media.readyState = 4; f.media.videoWidth = 1280; f.media.videoHeight = 720; f.media.paused = false;
  f.media.currentTime = .5; await f.step(400);
  f.media.currentTime = 1.5; await f.step(1000);
  assert.equal(f.messages.at(-1).playbackState, 'playing');
  await f.step(1000);
  assert.equal(f.messages.at(-1).playbackState, 'buffering');
  f.media.paused = true; await f.step(1000);
  assert.equal(f.messages.at(-1).playbackState, 'paused');
  assert.equal(f.plays, 1);
  const count = f.messages.length;
  f.portEvents.disconnect(); await f.step(1000);
  assert.equal(f.messages.length, count);
});
test('sports telemetry does not treat a seek as watched time and stops when hidden', async () => {
  const f = fixture();
  f.media.readyState = 4; f.media.videoWidth = 1280; f.media.videoHeight = 720; f.media.paused = false;
  f.media.currentTime = .5; await f.step(400);
  f.media.currentTime = 120; await f.step(1000);
  assert.equal(f.messages.at(-1).playbackState, 'buffering');
  const count = f.messages.length;
  f.document.hidden = true; await f.step(1000); await f.step(1000);
  assert.equal(f.messages.length, count);
});

test('JWPlayer idle poster is started even when its media source is already attached', async () => {
  const f=fixture({source:true,poster:true});
  assert.equal(f.clicks,1); assert.equal(f.plays,0);
  await f.step(2000); assert.equal(f.clicks,2);
  f.media.paused=false; f.media.readyState=4; f.media.videoWidth=1920; f.media.videoHeight=1080;
  f.media.currentTime=.5; await f.step(400);
  assert.equal(f.messages.at(-1).state,'playing');
  await f.step(4000); assert.equal(f.clicks,2);
});
test('no generic advertising links are clicked and missing player respects action deadline', async () => {
  const linked=fixture({source:false,poster:true,posterInLink:true});
  await linked.step(2000); assert.equal(linked.clicks,0); assert.equal(linked.plays,0);
  const empty=fixture({video:false,poster:false});
  await empty.step(30000); empty.document.querySelector=()=>({closest:()=>empty.media,click:()=>assert.fail('clicked after deadline')});
  await empty.step(2000);
  assert.equal(empty.plays,0); assert.equal(empty.clicks,0);
});

test('JWPlayer idle control can recover a media element waiting unpaused for its initial data', async () => {
  const f=fixture({source:true,poster:true,allow:false});
  f.media.paused=false; f.media.readyState=0;
  f.portEvents.message({type:'start'});
  assert.equal(f.clicks,1); assert.equal(f.plays,0);
  await f.step(2000); assert.equal(f.clicks,2);
  f.media.error={code:2}; await f.step(2000); assert.equal(f.clicks,3);
});

test('late video progress still clears startup without performing late clicks', async () => {
  const f=fixture({source:true,poster:false,allow:false});
  f.media.paused=false;
  f.portEvents.message({type:'start',observeMs:44000});
  await f.step(31000);
  assert.equal(f.messages.length,0);
  f.media.readyState=4; f.media.videoWidth=1920; f.media.videoHeight=1080; f.media.currentTime=.5;
  await f.step(4000);
  assert.equal(f.messages.at(-1).state,'playing');
  assert.equal(f.plays,0); assert.equal(f.clicks,0);
});
test('native remaining observation budget is honored and new posters after30s are not clicked', async () => {
  const expired=fixture({allow:false});
  expired.portEvents.message({type:'start',observeMs:1000});
  await expired.step(1200);
  expired.media.paused=false; expired.media.readyState=4; expired.media.videoWidth=1920; expired.media.videoHeight=1080; expired.media.currentTime=.5;
  await expired.step(400);
  assert.equal(expired.messages.length,0);
  const late=fixture({video:false,poster:false});
  await late.step(31000);
  late.document.querySelector=selector=>selector==='#jwplayer.jwplayer.jw-state-idle .jw-icon-display' ? late.control : null;
  await late.step(400);
  assert.equal(late.clicks,0);
});
