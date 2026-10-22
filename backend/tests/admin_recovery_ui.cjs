#!/usr/bin/env node
'use strict';
// Optional browser regression check. Install Playwright outside the source tree,
// then set VELVET_PLAYWRIGHT_MODULE to its module path if it is not on NODE_PATH.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const os = require('node:os');
const { chromium } = require(process.env.VELVET_PLAYWRIGHT_MODULE || 'playwright');
const assets = path.resolve(__dirname, '../admin');
const output = process.env.VELVET_UI_TEST_OUTPUT || fs.mkdtempSync(path.join(os.tmpdir(), 'velvet-admin-ui-'));
const stamp = Date.UTC(2026, 9, 22, 18);
const sample = () => ({
  available: true, scope: 'beta', coverage:{droppedEvents:0,titleLimit:50,sessionLimit:200}, firstEventAt: stamp-86400000, lastEventAt: stamp,
  summary: {watches:4,watchedMs:7200000,providerRescuedArticles:24,providerRescuedBytes:12582912,par2Jobs:5,par2Succeeded:3,par2Failed:1,par2Cancelled:1,par2Pending:0,par2RecoveredBytes:8388608,repairDownloadBytes:1073741824,playbacksUsingRepairedBytes:1,playbacksUsingProviderRescue:3,preparedOnlyJobs:1,repairP50Ms:1800,repairP95Ms:12000,sourceSwitches:2,sourceSwitchAttempts:5,automaticSwitches:1,automaticSwitchAttempts:4,manualSwitches:1,manualSwitchAttempts:1,unclassifiedSwitches:0,avgSwitchesPerWatch:.5,zeroSwitchWatches:2,startupP50Ms:1200,startupP95Ms:7500,bufferedMs:6000,bufferRatioPct:.08,bufferEvents:2,rebufferedMs:4000,rebufferCount:1,deadlineMisses:0,failedViewerReads:1,aheadCompletedJobs:2,foregroundCompletedJobs:1},
  reasons:[{reason:'insufficient_parity',count:1}],
  daily:[{date:'2026-10-20',observed:false,providerRescuedArticles:0,par2Succeeded:0,par2Failed:0,sourceSwitches:0,watches:0},{date:'2026-10-21',providerRescuedArticles:12,par2Succeeded:2,par2Failed:0,sourceSwitches:1,watches:2},{date:'2026-10-22',providerRescuedArticles:12,par2Succeeded:1,par2Failed:1,sourceSwitches:1,watches:2}],
  titles:[{id:'show',title:'An ordinary episode',kind:'tv',season:1,episode:2,watches:3,playedMs:3600000,playbacksUsingRepairedBytes:1,providerRescuedArticles:20,par2Succeeded:3,par2Failed:1,sourceSwitches:2,automaticSwitches:1,manualSwitches:1,avgSwitchesPerWatch:2/3,bufferedMs:6000,bufferRatioPct:.1},{id:'movie',title:'A quiet movie',kind:'movie',watches:1,playedMs:3600000,playbacksUsingRepairedBytes:0,providerRescuedArticles:4,par2Succeeded:0,par2Failed:0,sourceSwitches:0,automaticSwitches:0,manualSwitches:0,avgSwitchesPerWatch:0,bufferedMs:0,bufferRatioPct:0}],
  sessions:[{id:'s1',title:'An ordinary episode',kind:'tv',profileName:'Test viewer',deviceName:'Test Shield',startedAt:stamp,playedMs:1200000,state:'ended',sourceSwitches:2,automaticSwitches:1,manualSwitches:1,providerRescuedArticles:20,par2Succeeded:3,par2Failed:1,usedRepairedBytes:true,bufferedMs:6000,startupMs:1200,events:[{id:'e1',timestamp:stamp+1000,type:'par2_succeeded',outcome:'success',bytes:8388608,durationMs:1800},{id:'e2',timestamp:stamp+2000,type:'repaired_bytes_served',outcome:'delivered',bytes:524288},{id:'e3',timestamp:stamp+3000,type:'par2_failed',outcome:'failed',reason:'insufficient_parity'},{id:'e4',timestamp:stamp+4000,type:'automatic_switch',outcome:'success'}]}]
});
const report = {coverage:{collectionStartedAt:stamp-86400000,playbackStartedAt:stamp-86400000,capacitySampleCount:200,retentionDays:90},range:{observedDays:2},summary:{},quality:{},titles:[],sessions:[],devices:[]};
let mode='sample', calls=[];
const server = http.createServer((req,res) => {
  const url=new URL(req.url,'http://localhost'); calls.push(url.pathname+url.search);
  const json = value => {res.setHeader('Content-Type','application/json');res.end(JSON.stringify(value));};
  if(url.pathname==='/admin/api/report') return json(report);
  if(url.pathname==='/admin/api/live') return json({capacity:{capacity:10,free:10,busy:0,idle:0,unused:10},activeSessions:[]});
  if(url.pathname==='/admin/api/recovery') {
    if(mode==='error'){res.statusCode=503;return json({error:'The beta backend is offline.'});}
    if(mode==='empty') return json({available:true,summary:{watches:0,providerRescuedArticles:0,par2Jobs:0,par2Succeeded:0,par2Failed:0,par2Cancelled:0,par2Pending:0,playbacksUsingRepairedBytes:0,sourceSwitches:0,avgSwitchesPerWatch:null},titles:[],sessions:[],daily:[],reasons:[]});
    if(mode==='unavailable') return json({available:false});
    const data=sample();
    if(mode==='missing'){delete data.summary.par2Failed;delete data.summary.playbacksUsingRepairedBytes;delete data.summary.sourceSwitches;}
    if(mode==='hostile'){data.titles[0].title='<img src=x onerror="window.injected=true">';data.reasons[0].reason='<script>window.injected=true</script>';data.sessions[0].events[0].reason='<img src=x onerror="window.injected=true">';}
    return json(data);
  }
  const name = {'/admin':'index.html','/admin/':'index.html','/admin/admin.js':'admin.js','/admin/admin.css':'admin.css'}[url.pathname];
  if(!name){res.statusCode=404;return res.end();}
  res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(path.join(assets,name)));
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const browser=await chromium.launch({headless:true,...(process.env.VELVET_CHROME_PATH?{executablePath:process.env.VELVET_CHROME_PATH}:{})});
  const page=await browser.newPage({viewport:{width:1440,height:1080}}), errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  const url=`http://127.0.0.1:${server.address().port}/admin#recovery`;
  let loadNumber=0;
  const load=async()=>{await page.goto(url.replace('#recovery',`?case=${++loadNumber}#recovery`));await page.locator('#report-content').waitFor({state:'visible'});};
  try {
    await load();await page.locator('.recovery-metrics').waitFor();
    assert.equal(await page.locator('.recovery-metrics .metric-value').nth(0).innerText(),'1');
    assert.equal(await page.locator('.recovery-metrics .metric-value').nth(1).innerText(),'3');
    assert.equal(await page.locator('.recovery-metrics .metric-value').nth(3).innerText(),'0.5');
    assert.match(await page.locator('.recovery-metrics').innerText(),/2 successful switches ÷ 4 watches/);
    assert.match(await page.locator('.recovery-step.parity').innerText(),/1 completed jobs have no observed delivery/);
    assert.match(await page.locator('.quality-list').innerText(),/4 automatic attempts/);
    assert.match(await page.locator('.quality-list').innerText(),/Started by look-ahead/);
    assert.match(await page.locator('.quality-list').innerText(),/does not establish when repair finished relative to the playhead/);
    assert.equal(await page.locator('svg[aria-label="Daily PAR2 recovery outcomes and source switches"]').getByText('Oct 20',{exact:true}).count(),0);
    await page.screenshot({path:path.join(output,'recovery-desktop.png'),fullPage:true});
    console.log('PASS distinct repair preparation, delivery, attempts, and watch denominator');
    await page.locator('#table-recovery-sessions [data-expand]').click();
    assert.equal(await page.locator('.recovery-timeline li:visible').count(),4);
    assert.match(await page.locator('.recovery-timeline').innerText(),/Not enough repair blocks/);
    await page.locator('#search-recovery-titles').fill('quiet');
    assert.equal(await page.locator('#table-recovery-titles tbody tr').count(),1);
    assert.match(await page.locator('#table-recovery-titles').innerText(),/A quiet movie/);
    await page.locator('#search-recovery-titles').fill('');
    await page.locator('[data-filter="recovery-titles"]').selectOption('tv');
    assert.equal(await page.locator('#table-recovery-titles tbody tr').count(),1);
    await page.locator('[data-filter="recovery-titles"]').selectOption('');
    await page.locator('[data-sort="recovery-titles"][data-key="sourceSwitches"]').click();
    assert.match(await page.locator('#table-recovery-titles tbody tr').first().innerText(),/A quiet movie/);
    console.log('PASS expandable event timeline and search/filter/sort');
    await page.locator('#range').selectOption('30');
    await page.waitForResponse(r=>r.url().includes('/api/recovery?days=30'));
    await page.locator('.recovery-metrics').waitFor();
    assert.match(await page.locator('.recovery-scope a').getAttribute('href'),/days=30/);
    console.log('PASS selected reporting range and CSV export link');
    mode='error';await page.locator('#refresh').click();await page.locator('[data-recovery-retry]').waitFor();
    assert.match(await page.locator('#report-content').innerText(),/Showing the last successful snapshot/);
    assert.equal(await page.locator('.recovery-metrics .metric-value').nth(0).innerText(),'1');
    await page.locator('[data-tab="capacity"]').click();await page.getByRole('heading',{name:'Know your headroom.'}).waitFor();
    console.log('PASS beta outage preserves last snapshot and stable reports');
    mode='missing';await load();await page.locator('.recovery-metrics').waitFor();
    assert.equal(await page.locator('.recovery-metrics .metric-value').nth(0).innerText(),'—');
    assert.equal(await page.locator('.recovery-metrics .metric-value').nth(2).innerText(),'—');
    console.log('PASS absent metrics stay unavailable, not zero');
    mode='empty';await load();await page.getByText('Ready for the next watch.',{exact:true}).waitFor();
    assert.equal(await page.locator('.recovery-metrics .metric-value').nth(3).innerText(),'—');
    assert.match(await page.locator('#table-recovery-sessions').innerText(),/No reported watches/);
    console.log('PASS empty history and zero denominator');
    mode='unavailable';await load();await page.getByText('Recovery reporting is not available yet',{exact:true}).waitFor();
    assert.equal(await page.locator('.recovery-metrics').count(),0);
    console.log('PASS unavailable endpoint does not invent statistics');
    mode='hostile';await load();await page.locator('.recovery-metrics').waitFor();
    assert.equal(await page.locator('#report-content img').count(),0);
    assert.equal(await page.evaluate(()=>window.injected),undefined);
    assert.match(await page.locator('#table-recovery-titles').innerText(),/<img/);
    console.log('PASS untrusted titles and reasons are escaped');
    mode='sample';await page.setViewportSize({width:390,height:844});await load();await page.locator('.recovery-metrics').waitFor();
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
    await page.screenshot({path:path.join(output,'recovery-mobile.png'),fullPage:true});
    assert.deepEqual(errors,[]);
    console.log('PASS mobile layout and no browser errors');
    console.log(`Screenshots: ${output}`);
  } finally {await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
