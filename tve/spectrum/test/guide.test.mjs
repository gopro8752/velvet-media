import test from 'node:test';
import assert from 'node:assert/strict';
import {createGuide, normalizePrograms} from '../src/guide.mjs';

const NOW = Date.parse('2026-10-19T10:15:00Z');
const HOUR = 3600000;
const program = (extra = {}) => ({tmsGuideId:'101', tmsProgramId:'EP123', title:'Morning news', startTimeSec:(NOW - 15 * 60000) / 1000, durationMinutes:60,
  shortDesc:'Today’s headlines.', metadata:{title:'Monday'}, imageUrl:'/imageserver/program/EP123', genres:['News & Weather'], icons:['Live','New'], rating:'TVG', ...extra});
const reply = (value, status = 200) => ({status,body:Buffer.from(JSON.stringify(value))});
const settle = () => new Promise(resolve => setImmediate(resolve));
function fixture(request) {
  let now = NOW;
  const calls = [];
  const provider = {
    auth:{accessToken:'private-token',deviceId:'private-device'},
    async token(){return this.auth;},
    async channels(){return [{guideId:'101',channel:{id:'exact-news'}},{guideId:'102',channel:{id:'exact-pbs'}}];},
    async refresh(){this.auth={...this.auth,accessToken:'rotated-private-token'};},
    async request(options){calls.push(options);return request(options,calls.length);},
  };
  const guide = createGuide(provider,{now:()=>now});
  return {guide,provider,calls,advance:ms=>{now+=ms;}};
}

test('native schedule maps exact feed IDs and keeps only bounded public program metadata', () => {
  const normalized = normalizePrograms([
    program(), program({tmsGuideId:'wrong-station'}), program({title:'',startTimeSec:NOW / 1000}),
    program({startTimeSec:NaN}), program({durationMinutes:-10}), program({durationMinutes:24 * 60 + 1}),
    program({startTimeSec:(NOW+2*HOUR)/1000,imageUrl:'https://evil.example/art?token=private',icons:[],metadata:{},genres:['Movies','Movies']}),
  ],'101',NOW-HOUR,NOW+24*HOUR);
  assert.equal(normalized.length,2);
  assert.deepEqual(normalized[0],{
    id:'spectrum:101:1792404000:EP123',title:'Morning news',startTime:'2026-10-19T10:00:00.000Z',endTime:'2026-10-19T11:00:00.000Z',
    description:'Today’s headlines.',episodeTitle:'Monday',imageUrl:'https://cdnimg.spectrum.net/imageserver/program/EP123',
    genres:['News & Weather'],rating:'TVG',isLive:true,isNew:true,
  });
  assert.equal(normalized[1].imageUrl,null);assert.deepEqual(normalized[1].genres,['Movies']);assert.equal(normalized[1].isLive,false);
});

test('guide request is singleflight, uses fixed provider origin and 24-hour window, and never allocates playback', async () => {
  let release;const wait=new Promise(resolve=>{release=resolve;});
  const f=fixture(async options=>{await wait;return reply({'101':[program()],'102':[program({tmsGuideId:'102',title:'Nature'})]});});
  const first=f.guide.snapshot('Spectrum'), second=f.guide.snapshot('Spectrum');await settle();release();
  const [a,b]=await Promise.all([first,second]);
  assert.equal(f.calls.length,1);assert.deepEqual(a,b);
  const u=new URL(f.calls[0].url);
  assert.equal(u.origin,'https://pi-lite.spectrum.net');assert.equal(u.pathname,'/epgs/api/smarttv/guide/v4/twctv/grid');
  assert.equal(u.searchParams.get('hours'),'24');assert.equal(u.searchParams.get('tmsIds'),'101,102');assert.equal(u.searchParams.get('startDateTime'),'1792404000');
  assert.equal(f.calls[0].headers.Authorization,'Bearer private-token');assert.equal(a.channels[1].channelId,'exact-pbs');assert.equal(a.message,null);
  assert.ok(!JSON.stringify(a).includes('private'));await f.guide.snapshot('Spectrum');assert.equal(f.calls.length,1);
});

test('failed refresh preserves unexpired listings without making browsing wait; retry is throttled', async () => {
  const f=fixture(async (_options,count)=>count===1?reply({'101':[program()],'102':[program({tmsGuideId:'102'})]}):reply({secret:'private-upstream-error'},503));
  await f.guide.snapshot('Spectrum');f.advance(16*60000);
  const stale=await f.guide.snapshot('Spectrum');assert.equal(stale.channels[0].programs.length,1);await settle();
  const failed=await f.guide.snapshot('Spectrum');assert.match(failed.message,/temporarily unavailable/);assert.equal(f.calls.length,2);
  f.advance(HOUR);const expired=await f.guide.snapshot('Spectrum');assert.equal(expired.channels[0].programs.length,0);await settle();
  assert.ok(!JSON.stringify(expired).includes('private'));
});

test('provider 401 refreshes and retries once; malformed schedules never replace a good cache', async () => {
  const f=fixture(async (_options,count)=>count===1?reply({},401):count===2?reply({'101':[program()]}):reply([]));
  const a=await f.guide.snapshot('Spectrum');assert.equal(a.channels[0].programs.length,1);assert.equal(f.calls[1].headers.Authorization,'Bearer rotated-private-token');
  f.advance(16*60000);await f.guide.snapshot('Spectrum');await settle();
  const b=await f.guide.snapshot('Spectrum');assert.equal(b.channels[0].programs.length,1);assert.match(b.message,/temporarily unavailable/);
});

test('unknown provider feeds and expired programs cannot populate an entitled channel', async () => {
  const f=fixture(async()=>reply({'999':[program({tmsGuideId:'999'})],'101':[program({durationMinutes:1,startTimeSec:(NOW-HOUR)/1000})]}));
  const a=await f.guide.snapshot('Spectrum');assert.equal(a.channels.length,2);assert.ok(a.channels.every(c=>c.programs.length===0));
  assert.throws(()=>normalizePrograms(new Array(1001).fill(program()),'101',NOW-HOUR,NOW+HOUR));
});

test('reused channel IDs never inherit a prior station schedule, including failed and in-flight refreshes', async () => {
  const f=fixture(async (_options,count)=>count===1?reply({'101':[program()],'102':[program({tmsGuideId:'102',title:'Nature'})]}):reply({},503));
  await f.guide.snapshot('Spectrum');
  f.provider.channels=async()=>[{guideId:'999',channel:{id:'exact-news'}},{guideId:'102',channel:{id:'renamed-pbs'}}];
  const immediately=await f.guide.snapshot('Spectrum');
  assert.deepEqual(immediately.channels[0].programs,[]);
  assert.equal(immediately.channels[1].programs[0].title,'Nature');
  assert.equal(f.calls.length,1,'catalog churn cannot bypass the retry limit');
  f.advance(60001);
  assert.deepEqual((await f.guide.snapshot('Spectrum')).channels[0].programs,[]);await settle();
  assert.deepEqual((await f.guide.snapshot('Spectrum')).channels[0].programs,[]);
  assert.equal(f.calls.length,2);
  // Even a catalog change while the first request waits cannot attach its old
  // station result to the new mapping when the next snapshot is requested.
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const g=fixture(async()=>{await pending;return reply({'101':[program()]});});
  const first=g.guide.snapshot('Spectrum');await settle();
  g.provider.channels=async()=>[{guideId:'999',channel:{id:'exact-news'}}];
  release();await first;
  assert.deepEqual((await g.guide.snapshot('Spectrum')).channels[0].programs,[]);
});

test('non-ASCII metadata respects Rust UTF-8 byte limits without splitting code points', () => {
  const p=normalizePrograms([program({title:'😀'.repeat(110),shortDesc:'é'.repeat(2100),metadata:{title:'漢'.repeat(140)},genres:['界'.repeat(30)],rating:'★'.repeat(12),tmsProgramId:'é'.repeat(60)})],'101',NOW-HOUR,NOW+HOUR)[0];
  assert.equal(Buffer.byteLength(p.title),400);assert.equal(p.title,'😀'.repeat(100));
  assert.equal(Buffer.byteLength(p.description),4000);assert.equal(Buffer.byteLength(p.episodeTitle),399);
  assert.equal(Buffer.byteLength(p.genres[0]),78);assert.equal(Buffer.byteLength(p.rating),30);
  assert.ok(Buffer.byteLength(p.id)<=256);assert.ok(!JSON.stringify(p).includes('�'));
  const controls=normalizePrograms([program({title:'News\u0085now\ud800'})],'101',NOW-HOUR,NOW+HOUR)[0];
  assert.equal(controls.title,'News now�');
});

test('artwork is public and query-free even when the provider supplies same-host tokens', () => {
  const p=normalizePrograms([program({imageUrl:'https://cdnimg.spectrum.net/imageserver/program/EP123?access_token=synthetic-private-token&width=400#private-fragment'})],'101',NOW-HOUR,NOW+HOUR)[0];
  assert.equal(p.imageUrl,'https://cdnimg.spectrum.net/imageserver/program/EP123');
  assert.ok(!JSON.stringify(p).includes('synthetic-private-token'));assert.ok(!JSON.stringify(p).includes('private-fragment'));
});
