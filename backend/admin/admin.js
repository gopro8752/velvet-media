(() => {
  'use strict';

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const finite = value => typeof value === 'number' && Number.isFinite(value);
  const numeric = value => finite(value) ? value : 0;
  const array = value => Array.isArray(value) ? value : [];
  const sum = (rows, key) => rows.reduce((total, row) => total + numeric(row[key]), 0);
  const fmt = new Intl.NumberFormat('en-US', {maximumFractionDigits: 1});
  const integer = new Intl.NumberFormat('en-US', {maximumFractionDigits: 0});
  const colors = {movie:'#b9a0ff',tv:'#82b9f5',live_tv:'#80d9bf',live_sports:'#ebc18b',unknown:'#8b91ad'};
  const labels = {movie:'Movies',tv:'TV shows',live_tv:'Live TV',live_sports:'Live sports',unknown:'Unclassified'};
  const kinds = ['movie','tv','live_tv','live_sports'];
  const iconPaths = {
    overview:'<rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/>',
    capacity:'<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01M13 6.5h4M13 17.5h4"/>',
    playback:'<rect x="3" y="4" width="18" height="16" rx="4"/><path d="m10 8 6 4-6 4Z"/>',
    profiles:'<circle cx="9" cy="7" r="3"/><path d="M3 21v-3a6 6 0 0 1 12 0v3M16 4a3 3 0 0 1 0 6M18 15a5 5 0 0 1 3 4v2"/>',
    recovery:'<path d="M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6Z"/><path d="m8 12 3 3 5-6"/>',
    health:'<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    calendar:'<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4M17 3v4M3 11h18"/>',
    refresh:'<path d="M20 7v5h-5M4 17v-5h5M6 6a8 8 0 0 1 13 3M18 18A8 8 0 0 1 5 15"/>',
    arrow:'<path d="M5 12h14m-6-6 6 6-6 6"/>',
    bandwidth:'<path d="M7 3v18m-4-4 4 4 4-4M17 21V3m-4 4 4-4 4 4"/>',
    info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
    check:'<path d="m5 12 4 4L19 6"/>',
    search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
    eye:'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
    cpu:'<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 3v3m6-3v3M9 18v3m6-3v3M3 9h3m-3 6h3m12-6h3m-3 6h3"/><rect x="9" y="9" width="6" height="6" rx="1"/>',
    disk:'<path d="m5 5-2 10v4a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-4L19 5a2 2 0 0 0-2-2H7a2 2 0 0 0-2 2Z"/><path d="M3 15h18M17 18h.01"/>',
    signal:'<path d="M5 20v-4m5 4V11m5 9V7m5 13V3"/>',
    warning:'<path d="m10.3 4-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.7-3l-8-14a2 2 0 0 0-3.4 0ZM12 9v5M12 17h.01"/>',
    spark:'<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z"/>',
    device:'<rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>'
  };
  const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${iconPaths[name] || iconPaths.info}</svg>`;
  const count = value => finite(value) ? integer.format(value) : '—';
  const number = value => finite(value) ? fmt.format(value) : '—';
  const percent = value => finite(value) ? `${fmt.format(value)}%` : '—';
  function duration(ms, compact = false) {
    if (!finite(ms)) return '—';
    if (ms === 0) return '0m';
    if (ms < 60000) return '<1m';
    const mins = Math.floor(ms / 60000), hours = Math.floor(mins / 60);
    if (compact && hours >= 100) return `${integer.format(hours)}h`;
    return hours ? `${integer.format(hours)}h${mins % 60 ? ` ${mins % 60}m` : ''}` : `${mins}m`;
  }
  const latency = ms => !finite(ms) ? '—' : ms < 1000 ? `${integer.format(ms)} ms` : `${fmt.format(ms / 1000)} s`;
  function bytes(value) {
    if (!finite(value)) return '—';
    if (value === 0) return '0 B';
    const unit = Math.max(0, Math.min(4, Math.floor(Math.log(Math.max(1, value)) / Math.log(1024))));
    return `${fmt.format(value / (1024 ** unit))} ${['B','KiB','MiB','GiB','TiB'][unit]}`;
  }
  const rate = value => finite(value) ? `${fmt.format(value * 8 / 1e6)} Mbps` : '—';
  const date = (value, withTime = false) => {
    if (!value) return 'Not yet';
    const parsed = new Date(value);
    if (!Number.isFinite(parsed.getTime())) return '—';
    return parsed.toLocaleString('en-US', {timeZone:'UTC',month:'short',day:'numeric', ...(withTime ? {hour:'numeric',minute:'2-digit'} : {})});
  };
  const relative = value => {
    if (!value) return 'Not yet';
    const delta = Math.max(0, Date.now() - value);
    if (delta < 60000) return 'Just now';
    if (delta < 3600000) return `${Math.floor(delta / 60000)}m ago`;
    if (delta < 86400000) return `${Math.floor(delta / 3600000)}h ago`;
    return `${Math.floor(delta / 86400000)}d ago`;
  };
  const initials = name => String(name || '?').trim().split(/\s+/).slice(0, 2).map(s => s[0]).join('').toUpperCase();
  const state = {tab:'overview', days:7, recovery:null, recoveryBusy:false, recoveryError:null, recoveryRequestId:0, report:null, live:null, authenticated:false, reportBusy:false, liveBusy:false, lastSuccess:0, liveSuccess:0, reportError:null, liveError:null, requestId:0, search:{}, sort:{}, filter:{}, expanded:new Set(), profile:null, toastTimer:null};
  const sections = {
    overview:{label:'Overview',eyebrow:'THE BIG PICTURE',title:'Room for everyone.',description:'A clear view of your viewers, streams, and server capacity.'},
    capacity:{label:'Capacity',eyebrow:'KEEP THE GOOD TIMES PLAYING',title:'Know your headroom.',description:'Understand connection demand before adding more server capacity.'},
    playback:{label:'Playback',eyebrow:'WHAT’S KEEPING EVERYONE WATCHING',title:'Every kind of evening.',description:'Movies, shows, live channels, and sports — in one clear picture.'},
    profiles:{label:'People & devices',eyebrow:'YOUR INNER CIRCLE',title:'Everyone has a place.',description:'Understand viewing across profiles, devices, and platforms.'},
    recovery:{label:'Recovery',eyebrow:'EVERY BYTE COUNTS',title:'Keep the story going.',description:'See what beta recovered, what it could not, and how each watch played out.'},
    health:{label:'Health & quality',eyebrow:'BEHIND THE SCENES',title:'A smoother experience.',description:'Spot playback friction, provider issues, and reporting gaps.'}
  };
  function empty(title, detail, symbol = 'signal', compact = false) {
    return `<div class="empty-state${compact ? ' compact' : ''}"><div class="empty-symbol">${icon(symbol)}</div><h3>${escape(title)}</h3><p>${escape(detail)}</p></div>`;
  }
  function metric(label, value, note, symbol, featured = false) {
    return `<article class="metric-card${featured ? ' featured' : ''}"><div class="metric-top"><span>${escape(label)}</span><span class="metric-icon">${icon(symbol)}</span></div><div class="metric-value">${value}</div><div class="metric-note">${note}</div></article>`;
  }
  function panelHeader(title, detail, action = '') {
    return `<div class="panel-header"><div><h2>${escape(title)}</h2>${detail ? `<p>${escape(detail)}</p>` : ''}</div>${action}</div>`;
  }
  function navAction(tab, label = 'View report') {
    return `<button class="panel-header-action" data-nav="${tab}">${escape(label)} <span aria-hidden="true">↗</span></button>`;
  }
  const activeSessions = () => array(state.live?.activeSessions);
  const hasPlayback = () => Boolean(state.report?.coverage?.playbackStartedAt);
  const playbackMetric = value => hasPlayback() ? value : null;
  const observedDays = () => numeric(state.report?.range?.observedDays);
  const dailyNote = () => observedDays() ? `Across ${number(observedDays())} observed UTC day${observedDays() === 1 ? '' : 's'}, including today` : 'Waiting for the first reported viewing';
  function coverageNotice() {
    const coverage = state.report?.coverage || {};
    const message = coverage.message || 'Watch time is recorded by compatible Velvet clients. Past playback cannot be reconstructed.';
    return `<aside class="notice">${icon('info')}<div><strong>${hasPlayback() ? 'A measured view of your server.' : 'Your reporting starts here.'}</strong> ${escape(message)}</div></aside>`;
  }
  function overview() {
    const r = state.report, s = r.summary || {}, live = state.live?.capacity || {};
    return `${coverageNotice()}<div class="metric-grid">
      ${metric('Average viewing / day',duration(playbackMetric(s.avgDailyPlayedMs)),escape(dailyNote()),'clock',true)}
      ${metric('Active sessions now',`<span data-live-value="watching">${state.live ? count(activeSessions().filter(s => s.state !== 'stale').length) : '—'}</span>`,`<strong>${count(playbackMetric(s.peakConcurrent))}</strong> peak simultaneous sessions`,'profiles')}
      ${metric('Average connections in use',`${number(s.avgBusyConnections)} <small>/ ${count(s.capacity)}</small>`,`${percent(s.avgUtilizationPct)} average utilization`,'capacity')}
      ${metric('Usenet data retrieved',bytes(s.downloadedBytes),`${rate(s.avgDownloadBps)} average · article payload`,'bandwidth')}
    </div><div class="dashboard-grid"><section class="panel">${panelHeader('Time well spent','Daily reported viewing, by kind',navAction('playback'))}${playbackChart(r.daily)}${breakdownLegend()}</section><section class="panel" data-live-panel="capacity">${capacityNow()}</section></div>
    <section class="panel section-space" data-live-panel="sessions">${livePanel()}</section>
    <div class="dashboard-grid"><section class="panel">${panelHeader('Connection demand','Sampled busy connections across the selected period',navAction('capacity'))}${capacityChart(r.capacityHistory)}<p class="chart-caption">Includes streaming, prefetching, warming, and source checks.</p></section><section class="panel">${panelHeader('Worth a look','Signals to help you plan with confidence')}${insights()}</section></div>
    <div class="two-col"><section class="panel">${panelHeader('Your viewers','Profiles with reported viewing',navAction('profiles'))}${profileLeaders()}</section><section class="panel">${panelHeader('When everyone tunes in','Viewing by day of week and hour · UTC')}${heatmap(r.hourlyHeatmap)}</section></div>`;
  }
  function capacityPage() {
    const s = state.report.summary || {}, live = state.live?.capacity || {};
    return `<div class="metric-grid">
      ${metric('Average busy connections',`${number(s.avgBusyConnections)} <small>/ ${count(s.capacity)}</small>`,`${percent(s.avgUtilizationPct)} average utilization`,'capacity',true)}
      ${metric('Busy connections · p95',number(s.p95BusyConnections),`95% of samples were at or below this demand`,'signal')}
      ${metric('Available right now',`<span data-live-value="free">${count(live.free)}</span>`,`Idle sockets plus unused configured slots`,'check')}
      ${metric('Time under pressure',duration(finite(s.saturatedSeconds) ? s.saturatedSeconds * 1000 : null),`${count(s.peakBusyConnections)} peak busy connections`,'clock')}
    </div><div class="dashboard-grid"><section class="panel">${panelHeader('Capacity over time','Demand, open connections, and your configured limit')}${capacityChart(state.report.capacityHistory,true)}<div class="chart-legend">${legend('Busy','#b9a0ff')}${legend('Open','#82b9f5')}${legend('Configured limit','#596077')}</div></section><section class="panel" data-live-panel="capacity">${capacityNow()}</section></div>
    <section class="panel section-space">${panelHeader('Your providers','Configured pools in fallback order — extra providers are not necessarily used in parallel')}<div class="provider-grid">${providerCards()}</div></section>
    <div class="two-col"><section class="panel">${panelHeader('Retrieval bandwidth','Usenet article payload, averaged per sample')}${lineChart(state.report.capacityHistory,'downloadBps','Bandwidth',rate,'#80d9bf')}<p class="chart-caption">These bytes are not an exact WAN bill and exclude direct live-sports traffic.</p></section><section class="panel">${panelHeader('Waiting for a connection','Average queued requests in each reporting bucket')}${lineChart(state.report.capacityHistory,'avgWaiters','Waiting requests',number,'#ebc18b')}<p class="chart-caption">Persistent queueing is a stronger capacity signal than open socket count.</p></section></div>
    <section class="panel section-space">${panelHeader('Provider performance','Counters accumulated inside the selected reporting window')}${providerTable()}</section>
    <section class="panel section-space">${panelHeader('A connection is not a viewer','One viewer can use several connections; background work uses them too.')}<dl class="definitions"><div><dt><i class="legend-dot" style="background:#b9a0ff"></i>Busy</dt><dd>Connections currently checked out for article requests or background work.</dd></div><div><dt><i class="legend-dot" style="background:#82b9f5"></i>Open</dt><dd>Established sockets, including busy sockets and idle sockets ready to reuse.</dd></div><div><dt><i class="legend-dot" style="background:#80d9bf"></i>Available / free</dt><dd>Configured capacity minus busy connections. Includes idle sockets and slots not yet opened.</dd></div><div><dt><i class="legend-dot" style="background:#596077"></i>Configured limit</dt><dd>The connection limit set for the provider in Velvet. Verify it matches the allowance on your plan.</dd></div></dl><p class="definition-note">Provider limits can be shared with other downloaders. This dashboard measures Velvet’s pools, not connections used by other apps. Providers are tried in order, so total configured capacity does not guarantee equivalent primary-provider throughput.</p></section>
    <section class="panel section-space">${panelHeader('Planning signals','Evidence first. No automatic upsell.')}${insights()}</section>`;
  }
  function playbackPage() {
    const s = state.report.summary || {}, q = state.report.quality || {};
    return `${coverageNotice()}<div class="metric-grid">${metric('Average viewing / day',duration(playbackMetric(s.avgDailyPlayedMs)),escape(dailyNote()),'clock',true)}${metric('Total viewing',duration(playbackMetric(s.playedMs)),`${count(playbackMetric(s.sessions))} reported sessions`,'playback')}${metric('Average session',duration(playbackMetric(s.avgSessionMs)),'Active viewing time, excluding pauses','profiles')}${metric('Typical startup',latency(q.startupP50Ms),`${latency(q.startupP95Ms)} at the 95th percentile`,'signal')}</div>
    <div class="dashboard-grid"><section class="panel">${panelHeader('The daily picture','Actual reported viewing time, not media duration')}${playbackChart(state.report.daily)}${breakdownLegend()}</section><section class="panel">${panelHeader('What’s playing','Viewing totals, daily averages, and sessions')}${breakdown()}</section></div>
    <div class="two-col"><section class="panel">${panelHeader('Busiest viewing hours','Time watched by day of week and hour · UTC')}${heatmap(state.report.hourlyHeatmap)}</section><section class="panel">${panelHeader('Playback quality','Reported by clients that support playback telemetry',navAction('health'))}${qualityRows()}</section></div>
    <section class="panel section-space">${panelHeader('On everyone’s screen','Up to 50 titles with the most reported viewing')}${tableToolbar('titles','Search titles',true)}<div id="table-titles">${titlesTable()}</div></section>
    <section class="panel section-space">${panelHeader('Recent sessions','The latest 200 sessions in this reporting period')}${tableToolbar('sessions','Search titles, profiles, or devices',true)}<div id="table-sessions">${sessionsTable()}</div></section>`;
  }
  function profilesPage() {
    const rows = array(state.report.profiles), devices = array(state.report.devices), s = state.report.summary || {};
    const search = state.search.profiles || '';
    const filtered = rows.filter(row => `${row.name} ${row.id}`.toLowerCase().includes(search.toLowerCase()));
    const cards = filtered.length ? `<div class="profile-grid">${filtered.map(profileCard).join('')}</div>` : `<section class="panel section-space">${empty(search ? 'No matching profiles' : 'Everyone starts somewhere',search ? 'Try a different name.' : 'Profiles appear when a compatible client reports playback.','profiles')}</section>`;
    const selected = rows.find(row => row.id === state.profile);
    return `${coverageNotice()}<div class="metric-grid">${metric('Profiles watching',count(playbackMetric(s.profiles)),'Distinct profiles with reported playback','profiles',true)}${metric('Devices used',count(playbackMetric(s.devices)),'Distinct devices reporting in this period','device')}${metric('Viewing per profile',duration(rows.length && finite(s.playedMs) ? s.playedMs / rows.length : null),'Reported viewing divided by active profiles','clock')}${metric('Peak simultaneous sessions',count(playbackMetric(s.peakConcurrent)),'Based on overlapping reported sessions','signal')}</div>
    <div class="section-title"><div><h2>Your people</h2><p>Choose a profile to see its recent sessions.</p></div><div class="search-field">${icon('search')}<input id="search-profiles" data-search="profiles" value="${escape(search)}" aria-label="Search profiles" placeholder="Find a profile…" type="search"></div></div>${cards}
    ${selected ? `<section class="panel section-space">${panelHeader(`${selected.name || 'Profile'}’s recent sessions`,'Only sessions in the selected period',`<button class="panel-header-action" data-clear-profile>Show everyone</button>`)}<div class="table-scroll">${sessionRows(sortedRows('profile-sessions',array(state.report.sessions).filter(row => row.profileId === selected.id || (!row.profileId && row.profileName === selected.name)),'startedAt'),'profile-sessions')}</div></section>` : ''}
    <section class="panel section-space">${panelHeader('Devices & platforms','The clients behind the viewing time')}${tableToolbar('devices','Search devices or platforms')}<div id="table-devices">${devicesTable()}</div></section>`;
  }
  function healthPage() {
    const q = state.report.quality || {}, host = state.live?.host || {};
    return `<div class="metric-grid">${metric('Typical startup',latency(q.startupP50Ms),`${latency(q.startupP95Ms)} p95 startup`,'playback',true)}${metric('Buffering share',percent(q.bufferRatioPct),`${duration(q.bufferedMs)} reported buffering`,'clock')}${metric('Sessions with an error',percent(q.sessionErrorRatePct),`${count(q.errorCount)} reported playback errors`,'warning')}${metric('Source changes',count(q.sourceSwitches),'Automatic or manual, as reported by clients','refresh')}</div>
    <div class="two-col"><section class="panel">${panelHeader('Playback experience','Client events within your selected period')}${qualityRows()}</section><section class="panel" data-live-panel="host">${hostPanel()}</section></div>
    <section class="panel section-space">${panelHeader('Usenet provider health','A missing article can be recovered through a fallback provider')}${providerTable()}</section>
    <div class="two-col"><section class="panel">${panelHeader('Reporting coverage','What these numbers can and cannot tell you')}${coveragePanel()}</section><section class="panel">${panelHeader('Worth a look','The signals that need your attention')}${insights()}</section></div>
    <section class="panel section-space"><div class="panel-pad account-row"><div><h2>Private by design.</h2><p>This dashboard requires your admin access key. Reporting retains up to 90 days of activity.</p></div><button class="button button-secondary" data-logout>Sign out</button></div></section>`;
  }
  const recoveryReasons = {
    file_budget:'Release exceeds repair size limit', cache_budget:'Repair storage limit reached', download_budget:'Repair download limit reached', no_parity:'No repair data in this release', insufficient_parity:'Not enough repair blocks', deadline:'Repair missed its deadline', deadline_exceeded:'Repair missed its deadline', timeout:'Repair timed out', byte_limit:'Repair size limit reached', disk_limit:'Repair storage limit reached', job_limit:'Repair job limit reached', connection_limit:'Connection limit reached', cap_exceeded:'Repair safety limit reached', cancelled:'Playback or repair was cancelled', canceled:'Playback or repair was cancelled', missing_data:'Required data was unavailable', unsupported:'Release cannot be repaired', invalid_parity:'Repair data failed validation', verification_failed:'Repaired bytes failed verification', provider_unavailable:'Providers were unavailable', unknown:'Other / unclassified'
  };
  const recoveryReason = reason => recoveryReasons[reason] || String(reason || 'Unknown reason').replace(/_/g,' ');
  const ratio = (part,total) => finite(part) && finite(total) && total > 0 ? part / total * 100 : null;
  const isoDate = value => finite(value) && Number.isFinite(new Date(value).getTime()) ? new Date(value).toISOString() : '';
  const exactNumber = value => finite(value) ? new Intl.NumberFormat('en-US',{maximumFractionDigits:2}).format(value) : '—';
  function recoveryPage() {
    const r = state.recovery;
    const scope = `<div class="recovery-scope"><div><span class="badge beta">VELVET BETA</span><p>Recovery events and viewing are measured separately, then linked by watch. Stable playback remains in the other reports.</p></div><div><a class="button button-secondary" href="/admin/api/recovery/export?days=${state.days}">Export sessions ↓</a><span class="recovery-export-note">CSV · latest 5,000 sessions</span></div></div>`;
    const warning = state.recoveryError ? `<aside class="notice notice-error">${icon('warning')}<div><strong>Beta reporting is temporarily unavailable.</strong> ${escape(state.recoveryError)} ${r ? 'Showing the last successful snapshot.' : 'Existing server reports are still available.'} <button data-recovery-retry>Try again</button></div></aside>` : '';
    if (!r || r.available === false) return `${scope}${warning}<section class="panel">${empty(state.recoveryBusy ? 'Getting your recovery report ready' : 'Recovery reporting is not available yet',state.recoveryBusy ? 'Checking the beta backend for measured repair and playback events.' : 'The beta backend has not returned compatible recovery telemetry. Earlier watches are not reconstructed.','recovery')}</section>`;
    const s = r.summary || {};
    const watched = finite(s.watches) && s.watches > 0;
    const jobs = finite(s.par2Jobs) && s.par2Jobs > 0;
    const completed = finite(s.par2Succeeded) && finite(s.par2Failed) ? s.par2Succeeded + s.par2Failed : null;
    const noActivity = !watched && !jobs && !numeric(s.providerRescuedArticles);
    const incomplete = numeric(r.coverage?.droppedEvents) > 0 ? `<aside class="notice notice-error">${icon('warning')}<div><strong>Some recovery events were not recorded.</strong> ${count(r.coverage.droppedEvents)} events were dropped since collection began. Repair totals and session timelines can be incomplete.</div></aside>` : '';
    return `${scope}${warning}${incomplete}${noActivity ? `<aside class="notice">${icon('info')}<div><strong>Ready for the next watch.</strong> Recovery reporting is connected. Results will appear as you watch with a reporting client; a title without damage may need no repairs at all.</div></aside>` : ''}
      <div class="metric-grid recovery-metrics">
        ${metric('Watches receiving repaired bytes',count(s.playbacksUsingRepairedBytes),`${count(s.watches)} measured movie or episode watches · delivery is not proof of uninterrupted playback`,'playback',true)}
        ${metric('PAR2 repairs completed',count(s.par2Succeeded),`${percent(ratio(s.par2Succeeded,completed))} of completed attempts · ${bytes(s.par2RecoveredBytes)} restored`,'check')}
        ${metric('Repairs unable to complete',count(s.par2Failed),`${count(s.par2Cancelled)} cancelled · ${count(s.par2Pending)} still in progress`,'warning')}
        ${metric('Source switches / watch',exactNumber(watched ? s.avgSwitchesPerWatch : null),`${count(s.sourceSwitches)} successful switches ÷ ${count(s.watches)} watches, including watches with none`,'refresh')}
      </div>
      <div class="dashboard-grid recovery-grid"><section class="panel recovery-path">${panelHeader('What the recovery engine did','Separate measurements for rescue, reconstruction, and delivery')}<div class="recovery-steps">
        ${recoveryStep('01','Another provider had the article',s.providerRescuedArticles,'articles rescued',`${bytes(s.providerRescuedBytes)} validated from a fallback provider. Rescued articles were delivered to ${count(s.playbacksUsingProviderRescue)} measured watches.`,'provider')}
        ${recoveryStep('02','PAR2 rebuilt the missing data',s.par2Succeeded,'jobs completed',`${count(s.preparedOnlyJobs)} completed jobs have no observed delivery to a watched session yet. ${bytes(s.repairDownloadBytes)} downloaded for repair jobs.`,'parity')}
        ${recoveryStep('03','Repaired bytes reached playback',s.playbacksUsingRepairedBytes,'watches received repaired bytes','The server delivered the verified bytes on the player’s active stream. Startup and buffering below show the observed experience.','delivered')}
      </div><div class="recovery-footnote">${icon('info')}<p>Prepared bytes, delivered bytes, and a smooth viewing experience are different measurements. A successful repair alone does not prove a stall or source switch was avoided.</p></div></section>
      <section class="panel">${panelHeader('Why a repair could not finish','Recorded failure reasons within this period')}${recoveryFailures(r.reasons,s)}</section></div>
      <div class="two-col"><section class="panel">${panelHeader('Recovery over time','Completed PAR2 jobs and source switches by UTC day')}${recoveryChart(r.daily)}</section><section class="panel">${panelHeader('The viewing experience','Observed for the selected clients; these are not causal estimates')}${recoveryQuality(s)}</section></div>
      <section class="panel section-space">${panelHeader('Which titles need help',`Up to ${count(r.coverage?.titleLimit || 50)} movie and episode titles, including watches with no switches`)}${tableToolbar('recovery-titles','Search titles',true,['movie','tv'])}<div id="table-recovery-titles">${recoveryTitlesTable()}</div></section>
      <section class="panel section-space">${panelHeader('Follow a session',`Latest ${count(r.coverage?.sessionLimit || 200)} sessions, including starts with no viewing. Expand for recovery events and playback measurements.`)}${tableToolbar('recovery-sessions','Search titles, profiles, or devices',true,['movie','tv'])}<div id="table-recovery-sessions">${recoverySessionsTable()}</div></section>
      <section class="panel section-space">${panelHeader('How to read this report','Useful comparisons start with a clear denominator')}<dl class="definitions recovery-definitions"><div><dt>One watch</dt><dd>A movie or episode session with reported viewing time. Source switches stay inside that watch. Live TV and sports do not enter the per-watch average.</dd></div><div><dt>Switches per watch</dt><dd>Successful replacement starts divided by all measured watches, including zero-switch watches. Attempts that never start are reported separately.</dd></div><div><dt>Repair attempts</dt><dd>Provider article rescues and PAR2 jobs have different units. A single PAR2 job may restore many articles, and prepared data may never be played.</dd></div><div><dt>Reporting coverage</dt><dd>${r.firstEventAt ? `First event ${escape(date(r.firstEventAt,true))} UTC. Last event ${escape(date(r.lastEventAt,true))} UTC.` : 'Waiting for the first recovery event.'} A dash means unavailable, not zero. No earlier repair history is reconstructed.</dd></div></dl></section>`;
  }
  function recoveryStep(index,title,value,unit,detail,kind) {
    return `<div class="recovery-step ${kind}"><span class="recovery-step-number">${index}</span><div><h3>${escape(title)}</h3><p>${escape(detail)}</p></div><div class="recovery-step-value"><strong>${count(value)}</strong><span>${escape(unit)}</span></div></div>`;
  }
  function recoveryFailures(rows,s) {
    const data = array(rows).filter(row => finite(row.count) && row.count > 0).sort((a,b) => b.count-a.count), total = sum(data,'count');
    if (!data.length) return empty(numeric(s.par2Failed) ? 'Reasons have not been reported' : 'No failed repairs reported',numeric(s.par2Failed) ? 'Failure totals are available, but these events did not include a reason.' : 'A failed repair will appear here with the reason it could not finish. Cancelled work is tracked separately.','check');
    return `<div class="recovery-reasons">${data.map(row => `<div><div class="recovery-reason-label"><span>${escape(recoveryReason(row.reason))}</span><strong>${count(row.count)}</strong></div><div class="recovery-reason-track"><span style="width:${Math.max(0,Math.min(100,row.count/total*100))}%"></span></div></div>`).join('')}</div><p class="chart-caption">${count(total)} classified outcomes. A limit can stop work safely before repair is attempted.</p>`;
  }
  function recoveryQuality(s) {
    const rows = [
      ['Automatic source switches',count(s.automaticSwitches),`${count(s.automaticSwitchAttempts)} automatic attempts. Counted as a switch once replacement playback starts.`],
      ['Manual source switches',count(s.manualSwitches),`${count(s.manualSwitchAttempts)} manual attempts · ${count(s.unclassifiedSwitches)} successful switches were unclassified.`],
      ['Source switch attempts',count(s.sourceSwitchAttempts),'Includes replacement sources that never began playing.'],
      ['Watches without a source switch',`${count(s.zeroSwitchWatches)} <small>${percent(ratio(s.zeroSwitchWatches,s.watches))}</small>`,'Zero switches does not necessarily mean zero buffering.'],
      ['Typical startup',latency(s.startupP50Ms),`${latency(s.startupP95Ms)} at the 95th percentile.`],
      ['Buffering after startup',latency(s.rebufferedMs),`${count(s.rebufferCount)} interruptions after playback began · ${percent(s.bufferRatioPct)} post-start buffering share.`],
      ['Typical repair duration',latency(s.repairP50Ms),`${latency(s.repairP95Ms)} p95 · ${count(s.deadlineMisses)} missed repair deadlines.`],
      ['Started by look-ahead',count(s.aheadCompletedJobs),'Successful jobs initiated by look-ahead. This does not establish when repair finished relative to the playhead.'],
      ['Started by playback request',count(s.foregroundCompletedJobs),'Successful jobs initiated when playback requested missing bytes.'],
      ['Viewer reads that failed',count(s.failedViewerReads),'The requested bytes could not be supplied after the recovery attempt.']
    ];
    return `<div class="quality-list">${rows.map(([title,value,detail]) => `<div class="quality-row"><div>${escape(title)}<small>${escape(detail)}</small></div><strong>${value}</strong></div>`).join('')}</div>`;
  }
  function recoveryChart(data) {
    const rows = array(data).filter(row => row.date && row.observed !== false), keys = [['par2Succeeded','PAR2 completed','#80d9bf'],['par2Failed','PAR2 unsuccessful','#ebc18b'],['sourceSwitches','Source switches','#b9a0ff']];
    if (!rows.some(row => keys.some(([key]) => finite(row[key]) && row[key] > 0))) return empty('The pattern will appear here','Days are counted only from received events. Start a beta watch to collect recovery and switching history.','recovery');
    const width = window.innerWidth <= 700 ? 420 : 660, height=250, left=35, right=14, top=24, bottom=38, plotH=height-top-bottom, plotW=width-left-right;
    const max=niceMax(Math.max(...rows.flatMap(row => keys.map(([key]) => numeric(row[key]))))), step=plotW/rows.length, barW=Math.min(10,step*.18);
    const grid=Array.from({length:5},(_,i) => {const value=max*i/4,y=top+plotH-i/4*plotH;return `<line class="gridline" x1="${left}" x2="${width-right}" y1="${y}" y2="${y}"/><text x="${left-9}" y="${y+3}" text-anchor="end">${number(value)}</text>`;}).join('');
    const bars=rows.map((row,i) => {const x=left+step*(i+.5),detail=`${date(`${row.date}T12:00:00Z`)}. ${keys.map(([key,label]) => `${label}: ${count(row[key])}`).join('. ')}`;return `<g tabindex="0" role="img" aria-label="${escape(detail)}"><title>${escape(detail)}</title>${keys.map(([key,,color],j) => {const value=row[key],h=numeric(value)/max*plotH;return finite(value)?`<rect x="${x+(j-1)*(barW+2)-barW/2}" y="${top+plotH-h}" width="${barW}" height="${h}" rx="2" fill="${color}"/>`:'';}).join('')}<rect class="chart-hit" x="${x-step/2}" y="${top}" width="${step}" height="${plotH}"/>${rows.length<=8||i%Math.ceil(rows.length/6)===0||i===rows.length-1?`<text x="${x}" y="${height-14}" text-anchor="middle">${escape(date(`${row.date}T12:00:00Z`))}</text>`:''}</g>`;}).join('');
    return `<div class="chart-wrap"><svg class="chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="Daily PAR2 recovery outcomes and source switches">${grid}${bars}</svg></div><div class="chart-legend">${keys.map(([,label,color]) => legend(label,color)).join('')}</div><p class="chart-caption">Job counts and source changes are separate events. Dates before collection are omitted when identified by the server.</p>`;
  }
  function recoveryTitlesTable() {
    const search=(state.search['recovery-titles']||'').toLowerCase(), filter=state.filter['recovery-titles'];
    const rows=sortedRows('recovery-titles',array(state.recovery?.titles).filter(row => (!filter||row.kind===filter)&&`${row.title} ${labels[row.kind]||''}`.toLowerCase().includes(search)),'sourceSwitches');
    return `<div class="table-scroll"><table class="data-table"><thead><tr>${sortHeader('recovery-titles','title','Title')}${sortHeader('recovery-titles','watches','Watches',true)}${sortHeader('recovery-titles','avgSwitchesPerWatch','Switches / watch',true)}${sortHeader('recovery-titles','sourceSwitches','Switches',true,'sourceSwitches')}${sortHeader('recovery-titles','playbacksUsingRepairedBytes','Received repairs',true)}${sortHeader('recovery-titles','par2Failed','PAR2 jobs',true)}${sortHeader('recovery-titles','providerRescuedArticles','Article rescues',true)}${sortHeader('recovery-titles','bufferRatioPct','Buffering',true)}</tr></thead><tbody>${rows.length?rows.map(row=>`<tr><td class="title-cell"><strong>${escape(row.title||'Untitled')}</strong><small>${escape(labels[row.kind]||row.kind||'Playback')}${row.season!=null&&row.episode!=null?` · S${escape(row.season)} E${escape(row.episode)}`:''}</small></td><td class="number">${count(row.watches)}</td><td class="number recovery-number">${exactNumber(row.watches>0?row.avgSwitchesPerWatch:null)}</td><td class="number">${count(row.sourceSwitches)}<small class="table-subline">${count(row.automaticSwitches)} auto · ${count(row.manualSwitches)} manual</small></td><td class="number">${count(row.playbacksUsingRepairedBytes)}<small class="table-subline">watches</small></td><td class="number">${count(row.par2Succeeded)} / ${count(row.par2Failed)}<small class="table-subline">completed / failed</small></td><td class="number">${count(row.providerRescuedArticles)}</td><td class="number">${percent(row.bufferRatioPct)}</td></tr>`).join(''):`<tr><td colspan="8" class="table-empty">${search||filter?'No titles match these filters.':'Movie and episode watches will appear as the beta app reports activity.'}</td></tr>`}</tbody></table></div>`;
  }
  function recoverySessionsTable() {
    const name='recovery-sessions', search=(state.search[name]||'').toLowerCase(), filter=state.filter[name];
    const rows=sortedRows(name,array(state.recovery?.sessions).filter(row=>(!filter||row.kind===filter)&&`${row.title} ${row.profileName} ${row.deviceName}`.toLowerCase().includes(search)),'startedAt');
    return `<div class="table-scroll"><table class="data-table"><thead><tr>${sortHeader(name,'title','Watch')}${sortHeader(name,'profileName','Profile / device')}${sortHeader(name,'startedAt','Started',false,'startedAt')}${sortHeader(name,'sourceSwitches','Switches',true)}<th>Repair delivery</th><th><span class="sr-only">Watch details</span></th></tr></thead><tbody>${rows.length?rows.map((row,i)=>{const id=`recovery:${row.id}`,expanded=state.expanded.has(id),detailId=`recovery-session-${i}`;return `<tr><td class="title-cell"><strong>${escape(row.title||'Untitled playback')}</strong><small>${duration(row.playedMs)} watched · ${escape(labels[row.kind]||row.kind||'Playback')}</small></td><td class="title-cell">${escape(row.profileName||'Unassigned')}<small>${escape(row.deviceName||'Unknown device')}</small></td><td>${escape(date(row.startedAt,true))}</td><td class="number">${count(row.sourceSwitches)}<small class="table-subline">${count(row.automaticSwitches)} auto · ${count(row.manualSwitches)} manual</small></td><td>${row.usedRepairedBytes===true?'<span class="badge live">Delivered</span>':row.usedRepairedBytes===false?'<span class="badge">None reported</span>':'<span class="subtle">Unavailable</span>'}</td><td><button class="text-button" data-expand="${escape(id)}" aria-expanded="${expanded}" aria-controls="${detailId}">${expanded?'Less −':'Details +'}</button></td></tr><tr id="${detailId}" class="detail-row"${expanded?'':' hidden'}><td colspan="6"><dl class="detail-grid">${[['Time watched',duration(row.playedMs)],['Startup',latency(row.startupMs)],['Buffering',latency(row.bufferedMs)],['Provider article rescues',count(row.providerRescuedArticles)],['PAR2 completed',count(row.par2Succeeded)],['PAR2 unsuccessful',count(row.par2Failed)]].map(([title,value])=>`<div><dt>${escape(title)}</dt><dd>${escape(value)}</dd></div>`).join('')}</dl>${recoveryTimeline(row.events)}</td></tr>`;}).join(''):'<tr><td colspan="6" class="table-empty">No reported watches match this view.</td></tr>'}</tbody></table></div>`;
  }
  function recoveryTimeline(events) {
    const rows=array(events).filter(row=>!['stream_session','repair_job_watch'].includes(row.type)).sort((a,b)=>numeric(a.timestamp)-numeric(b.timestamp));
    if (!rows.length) return '<p class="recovery-timeline-empty">No event timeline has been reported for this watch.</p>';
    const titles={stream_read_failed:'Playback read could not be recovered',repair_job_started:'PAR2 repair started',provider_rescue:'Article recovered from another provider',par2_started:'PAR2 repair started',par2_succeeded:'PAR2 repair completed',par2_failed:'PAR2 could not finish',par2_cancelled:'PAR2 repair cancelled',repaired_bytes_served:'Repaired bytes delivered to playback',source_switch:'Playback source changed',automatic_switch:'Automatic source switch',manual_switch:'Manual source switch',buffering:'Playback buffered',deadline_missed:'Repair deadline missed'};
    return `<div class="recovery-timeline-heading"><h3>Recovery events</h3><span>Times in UTC</span></div><ol class="recovery-timeline">${rows.map(row=>{const failed=['failed','error','timeout'].includes(row.outcome)||['par2_failed','deadline_missed','stream_read_failed'].includes(row.type),good=['succeeded','success','delivered'].includes(row.outcome)||['provider_rescue','par2_succeeded','repaired_bytes_served'].includes(row.type);const details=[row.reason?recoveryReason(row.reason):null,finite(row.bytes)&&row.bytes>0?bytes(row.bytes):null,finite(row.durationMs)?latency(row.durationMs):null,finite(row.positionMs)?`${duration(row.positionMs)} into playback`:null].filter(Boolean);return `<li class="${failed?'failed':good?'succeeded':''}"><span class="recovery-timeline-dot"></span><div><strong>${escape(titles[row.type]||String(row.type||'Recovery event').replace(/_/g,' '))}</strong>${details.length?`<p>${escape(details.join(' · '))}</p>`:''}</div><time datetime="${escape(isoDate(row.timestamp))}">${escape(date(row.timestamp,true))}</time></li>`;}).join('')}</ol>`;
  }
  function legend(label, color, value = '') {
    return `<span class="legend-item"><i class="legend-dot" style="background:${color}"></i>${escape(label)}${value ? `<span class="legend-value">${value}</span>` : ''}</span>`;
  }
  function breakdownLegend() {
    const breakdown = array(state.report.breakdown);
    return `<div class="chart-legend">${kinds.map(kind => legend(labels[kind],colors[kind],duration(breakdown.find(row => row.kind === kind)?.playedMs))).join('')}</div>`;
  }
  function breakdown() {
    const rows = array(state.report.breakdown), total = sum(rows,'playedMs');
    if (!total) return empty('No viewing reported yet','Your mix of movies, shows, live TV, and sports will appear here.','playback');
    return `<div class="breakdown-list">${kinds.map(kind => {
      const row = rows.find(row => row.kind === kind), value = numeric(row?.playedMs), pct = value / total * 100;
      return `<div><div class="breakdown-top"><span class="breakdown-label"><i class="legend-dot" style="background:${colors[kind]}"></i>${labels[kind]}</span><span class="breakdown-value">${duration(value)}<small>${percent(pct)}</small></span></div><div class="breakdown-track"><span style="width:${pct}%;background:${colors[kind]}"></span></div><div class="breakdown-meta"><span><strong>${duration(observedDays() > 0 ? value / observedDays() : null)}</strong> average / day</span><span>${count(row?.sessions)} sessions</span></div></div>`;
    }).join('')}</div><p class="chart-caption">Daily averages use ${number(observedDays())} observed UTC days, including today’s partial day and zero-use days.</p>`;
  }
  function playbackChart(data) {
    const rows = array(data);
    if (!hasPlayback() || !rows.some(row => row.playedMs > 0)) return empty('Your next watch starts the story','Daily viewing fills in as compatible clients report playback. No past activity is estimated.','playback');
    const width = window.innerWidth <= 700 ? 420 : 720, height = 232, left = 42, right = 10, top = 19, bottom = 34, plotH = height - top - bottom, plotW = width - left - right;
    const max = niceMax(Math.max(...rows.map(row => numeric(row.playedMs))) / 3600000);
    const step = plotW / rows.length, barW = Math.min(32,step * .58);
    const grid = Array.from({length:5},(_,i) => { const value = max * i / 4, y = top + plotH - i / 4 * plotH;return `<line class="gridline" x1="${left}" x2="${width-right}" y1="${y}" y2="${y}"/><text x="${left-10}" y="${y+3}" text-anchor="end">${number(value)}h</text>`;}).join('');
    const bars = rows.map((row,i) => {
      const x = left + step * i + step / 2;let y = top + plotH;
      const pieces = kinds.map(kind => { const ms = numeric(row.byKind?.[kind]), h = ms / 3600000 / max * plotH; y -= h;return `<rect class="bar-segment" x="${x-barW/2}" y="${y}" width="${barW}" height="${h}" fill="${colors[kind]}" rx="${Math.min(2,h/2)}"/>`; }).join('');
      const observed = row.observed !== false && finite(row.playedMs);
      const label = observed ? `${date(`${row.date}T12:00:00Z`)}: ${duration(row.playedMs)}. ${kinds.map(kind => `${labels[kind]} ${duration(numeric(row.byKind?.[kind]))}`).join(', ')}` : `${date(`${row.date}T12:00:00Z`)}: not monitored yet`;
      const gap = !observed ? `<line x1="${x-barW/2}" x2="${x+barW/2}" y1="${top+plotH}" y2="${top+plotH}" stroke="#62677a" stroke-dasharray="2 3"/>` : ''; 
      const showLabel = rows.length <= 8 || i % Math.ceil(rows.length / 7) === 0 || i === rows.length - 1;
      return `<g tabindex="0" role="img" aria-label="${escape(label)}" data-tooltip="${escape(label)}"><title>${escape(label)}</title>${observed ? pieces : gap}<rect class="chart-hit" x="${x-step/2}" y="${top}" width="${step}" height="${plotH}"/>${showLabel ? `<text x="${x}" y="${height-12}" text-anchor="middle">${escape(date(`${row.date}T12:00:00Z`))}</text>` : ''}</g>`;
    }).join('');
    return `<div class="chart-wrap chart-container"><svg class="chart" role="img" aria-label="Stacked chart of daily reported watch time" viewBox="0 0 ${width} ${height}">${grid}${bars}</svg></div>${rows.some(row => row.observed === false || !finite(row.playedMs)) ? '<p class="chart-caption">Dashed dates precede monitoring; they are not zero-use days.</p>' : ''}`;
  }
  function niceMax(value) {
    if (!finite(value) || value <= 0) return 1;
    const power = 10 ** Math.floor(Math.log10(value)), adjusted = value / power;
    return ([1,2,4,5,10].find(n => n >= adjusted) || 10) * power;
  }
  function chartTime(value, rows) {
    if (rows.length && rows[rows.length-1].timestamp - rows[0].timestamp < 86400000) return new Date(value).toLocaleTimeString('en-US',{timeZone:'UTC',hour:'numeric',minute:'2-digit'});
    return date(value);
  }
  function lineChart(data, key, title, formatter = number, color = '#b9a0ff', extraSeries = [], maxOverride = null) {
    const rows = array(data).filter(row => finite(row.timestamp) && finite(row[key]));
    if (!rows.length) return empty('Gathering capacity samples','The server samples its connection pools every 15 seconds. Trends appear as samples arrive.','capacity');
    const width = window.innerWidth <= 700 ? 440 : 720, height = 220, left = 54, right = 15, top = 18, bottom = 34, plotH = height-top-bottom, plotW = width-left-right;
    const series = [{key,title,color},...extraSeries], allValues = rows.flatMap(row => series.map(s => numeric(row[s.key])));
    const max = niceMax(maxOverride || Math.max(...allValues));
    const start = rows[0].timestamp, end = rows[rows.length-1].timestamp;
    const xpos = row => start === end ? left + plotW/2 : left + (row.timestamp-start)/(end-start)*plotW;
    const ypos = value => top + plotH - Math.max(0,value) / max * plotH;
    const grid = Array.from({length:5},(_,i) => {const value = max*i/4,y = ypos(value);return `<line class="gridline" x1="${left}" x2="${width-right}" y1="${y}" y2="${y}"/><text x="${left-9}" y="${y+3}" text-anchor="end">${escape(formatter(value))}</text>`;}).join('');
    const bucketMs = state.days <= 1 ? 300000 : state.days <= 7 ? 1800000 : state.days <= 30 ? 7200000 : 21600000;
    const chunks = seriesKey => rows.reduce((groups,row) => {
      const group = groups[groups.length-1];
      if (!finite(row[seriesKey])) { if (group?.length) groups.push([]); return groups; }
      if (!group || (group.length && row.timestamp - group[group.length-1].timestamp > bucketMs * 1.5)) groups.push([row]);
      else group.push(row);
      return groups;
    },[]).filter(group => group.length);
    const shade = chunks(key).map(group => `<polygon points="${xpos(group[0])},${ypos(0)} ${group.map(row => `${xpos(row)},${ypos(row[key])}`).join(' ')} ${xpos(group[group.length-1])},${ypos(0)}" fill="${color}" opacity=".055"/>`).join('');
    const paths = series.map(s => chunks(s.key).map(group => {const points = group.map(row => `${xpos(row)},${ypos(row[s.key])}`).join(' ');return `<polyline points="${points}" fill="none" stroke="${s.color}" stroke-width="${s.key === key ? 2 : 1.4}" stroke-linejoin="round" stroke-linecap="round" ${s.dash ? 'stroke-dasharray="5 5"' : ''}/>${group.length === 1 ? `<circle cx="${xpos(group[0])}" cy="${ypos(group[0][s.key])}" r="3" fill="${s.color}"/>` : ''}`;}).join('')).join('');
    const dots = rows.map((row,i) => {
      const label = `${date(row.timestamp,true)} UTC. ${series.map(s => `${s.title}: ${formatter(row[s.key])}`).join('. ')}`;
      return `<circle cx="${xpos(row)}" cy="${ypos(row[key])}" r="${rows.length === 1 ? 4 : 7}" fill="${rows.length === 1 ? color : 'transparent'}" tabindex="0" role="img" aria-label="${escape(label)}" data-tooltip="${escape(label)}"><title>${escape(label)}</title></circle>`;
    }).join('');
    const ticks = (rows.length <= 1 ? [0] : [...new Set([0,...Array.from({length:4},(_,i) => Math.round((i+1)*(rows.length-1)/4))])]).map(i => `<text x="${xpos(rows[i])}" y="${height-12}" text-anchor="middle">${escape(chartTime(rows[i].timestamp,rows))}</text>`).join('');
    return `<div class="chart-wrap chart-container"><svg class="chart" role="img" aria-label="${escape(title)} over time" viewBox="0 0 ${width} ${height}">${grid}${shade}${paths}${dots}${ticks}</svg></div>`;
  }
  function capacityChart(rows, detailed = false) {
    return lineChart(rows,'avgBusy','Busy connections',number,'#b9a0ff',detailed ? [{key:'avgOpen',title:'Open connections',color:'#82b9f5'},{key:'capacity',title:'Configured limit',color:'#596077',dash:true}] : []);
  }
  function capacityNow() {
    const c = state.live?.capacity;
    const header = panelHeader('Connections right now','A snapshot of your configured Usenet pools',`<span class="badge live"><i class="status-dot"></i>LIVE</span>`);
    if (!c) return header + empty('Connecting to the server','Live capacity will appear when the next snapshot is available.','capacity',true);
    const max = numeric(c.capacity), busy = numeric(c.busy), idle = numeric(c.idle), unused = numeric(c.unused), circumference = 326.73;
    const arc = (value,color,offset) => `<circle cx="60" cy="60" r="52" fill="none" stroke="${color}" stroke-width="7" stroke-dasharray="${max ? Math.max(0,value/max*circumference-2) : 0} ${circumference}" stroke-dashoffset="${-offset/max*circumference || 0}" stroke-linecap="round"/>`;
    return `${header}<div class="capacity-split"><div class="ring"><svg viewBox="0 0 120 120" role="img" aria-label="${count(busy)} busy, ${count(idle)} idle, ${count(unused)} unused of ${count(max)} configured connections"><circle cx="60" cy="60" r="52" fill="none" stroke="#ffffff08" stroke-width="7"/>${arc(busy,'#b9a0ff',0)}${arc(idle,'#82b9f5',busy)}${arc(unused,'#80d9bf',busy+idle)}</svg><div class="ring-label"><strong>${count(c.free)}</strong><span>available of ${count(c.capacity)}</span></div></div><div class="ring-legend">${[['Busy',busy,'#b9a0ff'],['Idle',idle,'#82b9f5'],['Unused',unused,'#80d9bf']].map(([label,value,color]) => `<div class="legend-item"><span><i class="legend-dot" style="background:${color}"></i>${label}</span><strong>${count(value)}</strong></div>`).join('')}</div></div><div class="capacity-foot"><div><span>Retrieving now</span><strong>${rate(c.downloadBps)}</strong></div><div><span>Waiting for a slot</span><strong>${count(c.waiters)} <small>requests</small></strong></div></div>`;
  }
  function livePanel() {
    const sessions = activeSessions();
    const active = sessions.filter(s => s.state !== 'stale');
    const header = panelHeader('Happening now','Reported activity from your connected clients',`<span class="badge live"><i class="status-dot"></i>${count(active.length)} ACTIVE</span>`);
    if (!state.live) return header + empty('Checking in with your server','Current reported sessions will appear here.','signal',true);
    if (!sessions.length) return header + empty('A quiet moment','No clients are reporting playback right now. Their next session will appear here.','playback',true);
    return `${header}<div class="live-list">${sessions.map(row => `<article class="live-card"><div class="live-card-head"><div class="person"><span class="avatar">${escape(initials(row.profileName))}</span><span class="person-text"><strong>${escape(row.profileName || 'Unassigned profile')}</strong><small>${escape(row.deviceName || row.platform || 'Unknown device')}</small></span></div>${sessionBadge(row.state)}</div><h3 class="live-title" title="${escape(row.title)}">${escape(row.title || 'Untitled playback')}</h3><p class="live-meta">${escape(labels[row.kind] || row.kind || 'Playback')}</p><div class="live-footer"><span>${duration(row.playedMs)} watched</span><span>Seen ${escape(relative(row.lastSeen))}</span></div></article>`).join('')}</div>`;
  }
  function sessionBadge(value) {
    const label = {playing:'Playing',paused:'Paused',buffering:'Buffering',starting:'Starting',ended:'Ended',stopped:'Stopped',error:'Error',stale:'Signal lost'}[value] || value || 'Reported';
    const cls = value === 'playing' ? 'live' : ['buffering','stale'].includes(value) ? 'warning' : value === 'error' ? 'bad' : '';
    return `<span class="badge ${cls}">${escape(label)}</span>`;
  }
  function insights() {
    const rows = array(state.report.insights);
    if (!rows.length) return empty('Let the evidence build','Capacity recommendations need a representative period of real viewing and connection samples.','spark',true);
    return `<div class="insight-list">${rows.map(row => `<article class="insight ${row.severity === 'watch' ? 'warning' : row.severity === 'action' ? 'bad' : ''}"><div class="insight-icon">${icon(row.severity === 'good' ? 'check' : row.severity === 'action' ? 'warning' : row.severity === 'watch' ? 'signal' : 'spark')}</div><div><h3>${escape(row.title)}</h3><p>${escape(row.detail)}</p></div></article>`).join('')}</div>`;
  }
  function profileLeaders() {
    const rows = array(state.report.profiles).filter(row => row.playedMs > 0).sort((a,b) => b.playedMs-a.playedMs).slice(0,5), total = sum(rows,'playedMs');
    if (!rows.length) return empty('Your people, in view','As profiles watch, you’ll see where the viewing time goes.','profiles',true);
    return `<div class="breakdown-list">${rows.map((row,i) => `<div><div class="breakdown-top"><button class="text-button profile-link" data-profile="${escape(row.id)}">${escape(row.name || 'Unnamed profile')}</button><span class="breakdown-value">${duration(row.playedMs)}<small>${count(row.sessions)} sessions</small></span></div><div class="breakdown-track"><span style="width:${row.playedMs/total*100}%;background:${['#b9a0ff','#82b9f5','#80d9bf','#ebc18b','#af9eba'][i]}"></span></div></div>`).join('')}</div>`;
  }
  function heatmap(data) {
    const rows = array(data), max = Math.max(0,...rows.map(row => numeric(row.playedMs)));
    if (!max) return empty('A rhythm will emerge','Reported viewing will reveal the days and hours your server is busiest.','calendar',true);
    const days = [1,2,3,4,5,6,0], names = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    const map = new Map(rows.map(row => [`${row.weekday}:${row.hour}`,numeric(row.playedMs)]));
    const cells = days.map(day => `<div class="heat-row"><span class="heat-row-label">${names[day]}</span>${Array.from({length:24},(_,hour) => {const value = map.get(`${day}:${hour}`) || 0, alpha = value ? .12 + value/max*.75 : .025, label = `${names[day]}, ${String(hour).padStart(2,'0')}:00 UTC: ${duration(value)} watched`;return `<span class="heat-cell" style="background:rgba(185,160,255,${alpha})" tabindex="0" role="img" aria-label="${escape(label)}" title="${escape(label)}"></span>`;}).join('')}</div>`).join('');
    const peak = rows.reduce((a,b) => a.playedMs > b.playedMs ? a : b);
    return `<div class="heatmap">${cells}<div class="heat-row heat-labels"><span></span>${Array.from({length:24},(_,i) => `<span>${i%6 === 0 || i === 23 ? String(i).padStart(2,'0') : ''}</span>`).join('')}</div></div><div class="heat-footer"><span>Peak: ${names[peak.weekday]} · ${String(peak.hour).padStart(2,'0')}:00 UTC</span><span class="heat-scale">Less ${[.08,.24,.42,.64,.9].map(a => `<i style="background:rgba(185,160,255,${a})"></i>`).join('')} More</span></div>`;
  }
  function providerCards() {
    const rows = array(state.report.providers);
    if (!rows.length) return empty('No provider samples yet','Configured Usenet providers appear after the server collects capacity samples.','capacity',true);
    return rows.map((row,i) => {
      const now = array(state.live?.capacity?.providers).find(p => p.id === row.id), capacity = numeric(row.capacity), busy = numeric(now?.busy), idle = numeric(now?.idle);
      return `<article class="provider-card"><div class="provider-head"><div><h3>${escape(row.name || `Provider ${i+1}`)}</h3><p>${i === 0 ? 'First in fallback order' : `Fallback position ${i+1}`}</p></div><span class="badge ${now?.waiters > 0 ? 'warning' : 'purple'}">${now ? `${count(now.free)} FREE NOW` : 'SAMPLED'}</span></div><div class="provider-capacity"><strong>${number(row.avgBusy)}</strong><span>average busy / ${count(row.capacity)} configured</span></div><div class="stacked-track" role="img" aria-label="Current busy ${count(now?.busy)}, idle ${count(now?.idle)}, configured ${count(row.capacity)}"><span style="width:${capacity ? Math.min(100,busy/capacity*100) : 0}%;background:#b9a0ff"></span><span style="width:${capacity ? Math.min(100,idle/capacity*100) : 0}%;background:#82b9f5"></span></div><div class="provider-stats"><div><span>P95 busy</span><strong>${number(row.p95Busy)}</strong></div><div><span>Peak busy</span><strong>${count(row.peakBusy)}</strong></div><div><span>Data retrieved</span><strong>${bytes(row.bytesDownloaded)}</strong></div></div></article>`;
    }).join('');
  }
  function providerTable() {
    const rows = array(state.report.providers);
    return `<div class="table-scroll"><table class="data-table"><thead><tr><th>Provider</th><th class="number">Articles found</th><th class="number">Missing</th><th class="number">Errors</th><th class="number">Fallback recoveries</th><th class="number">Avg queue wait</th><th class="number">Utilization</th></tr></thead><tbody>${rows.length ? rows.map(row => `<tr><td><strong>${escape(row.name)}</strong></td><td class="number">${count(row.found)}</td><td class="number">${count(row.missing)}</td><td class="number">${count(row.errors)}</td><td class="number">${count(row.fallbackSuccesses)}</td><td class="number">${latency(row.queueWaitMs)}</td><td class="number">${percent(row.utilizationPct)}</td></tr>`).join('') : '<tr><td colspan="7" class="table-empty">Provider samples are still being collected.</td></tr>'}</tbody></table></div>`;
  }
  function profileCard(row) {
    const total = numeric(row.playedMs), selected = state.profile === row.id;
    return `<article class="panel profile-card${selected ? ' selected' : ''}"><div class="person"><span class="avatar big">${escape(initials(row.name))}</span><span class="person-text"><strong>${escape(row.name || 'Unnamed profile')}</strong><small>Last seen ${escape(relative(row.lastSeen))}</small></span></div><div class="profile-duration">${duration(row.playedMs)}</div><div class="profile-label">${count(row.sessions)} sessions · ${count(row.devices)} devices</div><div class="stacked-track" role="img" aria-label="${escape(kinds.map(kind => `${labels[kind]}: ${duration(numeric(row.byKind?.[kind]))}`).join(', '))}">${kinds.map(kind => `<span style="width:${total ? numeric(row.byKind?.[kind])/total*100 : 0}%;background:${colors[kind]}"></span>`).join('')}</div><div class="profile-footer"><span>${duration(row.avgSessionMs)} / session</span><button class="text-button" data-profile="${escape(row.id)}" aria-pressed="${selected}">View sessions ↗</button></div></article>`;
  }
  function qualityRows() {
    const q = state.report.quality || {};
    return `<div class="quality-list">${[
      ['Median startup',latency(q.startupP50Ms),'Half of measured starts were at or below this time.'],
      ['Slow-end startup · p95',latency(q.startupP95Ms),'95% of measured starts were at or below this time.'],
      ['Buffering time',duration(q.bufferedMs),`${percent(q.bufferRatioPct)} of reported viewing plus buffering time.`],
      ['Playback errors',count(q.errorCount),`${percent(q.sessionErrorRatePct)} of reported sessions had at least one error.`],
      ['Source changes',count(q.sourceSwitches),'Includes manual changes and automatic recovery when clients report them.']
    ].map(([label,value,detail]) => `<div class="quality-row"><div>${label}<small>${escape(detail)}</small></div><strong>${value}</strong></div>`).join('')}</div>`;
  }
  function hostPanel() {
    const host = state.live?.host || {}, memoryPct = host.memoryLimitBytes ? numeric(host.rssBytes)/host.memoryLimitBytes*100 : null, diskPct = host.diskTotalBytes ? numeric(host.diskFreeBytes)/host.diskTotalBytes*100 : null;
    const containerCpu = host.cpuScope === 'container', containerMemory = host.memoryScope === 'container';
    const cpuDetail = `Normalized across available or limited cores (0–100%). ${containerCpu ? 'Container readings include transcode workers.' : 'Process fallback measures the backend itself.'}`;
    const memoryDetail = `${containerMemory ? 'Memory used by the backend container, including its workers.' : 'Resident backend process memory; container usage is unavailable.'} ${finite(memoryPct) ? `${percent(memoryPct)} of the reported memory limit.` : 'No memory limit was reported.'}`;
    return `${panelHeader('Server resources','Current backend runtime and data volume',`<span class="badge live"><i class="status-dot"></i>LIVE</span>`)}<div class="quality-list"><div class="quality-row"><div>${containerCpu ? 'Container CPU' : 'Backend CPU'}<small>${escape(cpuDetail)}</small></div><strong>${percent(host.cpuPercent)}</strong></div><div class="quality-row"><div>${containerMemory ? 'Container memory' : 'Backend process memory'}<small>${escape(memoryDetail)}</small></div><strong>${bytes(host.rssBytes)}</strong></div><div class="quality-row"><div>Free data-volume space<small>${finite(diskPct) ? `${percent(diskPct)} available of ${bytes(host.diskTotalBytes)} on the backend’s data volume.` : 'Free space on the volume containing the backend’s data, when reported.'}</small></div><strong>${bytes(host.diskFreeBytes)}</strong></div></div>`;
  }
  function coveragePanel() {
    const c = state.report.coverage || {};
    return `<div class="coverage-items">${[
      ['Capacity collection',c.collectionStartedAt ? `Since ${date(c.collectionStartedAt,true)} UTC · ${count(c.capacitySampleCount)} samples in this period.` : 'Waiting for the first server sample.',c.collectionStartedAt ? 'Collecting' : 'Pending'],
      ['Playback collection',c.playbackStartedAt ? `First report ${date(c.playbackStartedAt,true)} UTC. No older playback is reconstructed.` : 'Requires a compatible client. Existing watch progress is not a reliable measure of time watched.',c.playbackStartedAt ? 'Receiving' : 'Waiting'],
      ['Monitoring coverage', finite(c.expectedMs) && c.expectedMs > 0 ? `${percent(Math.min(100,numeric(c.sampledMs)/c.expectedMs*100))} of elapsed collection time in this period has capacity samples. Missing intervals are not counted as idle.` : 'The first complete sample interval is still being collected.', 'Sampled time'],
      ['Reporting devices',`${count(c.reportedDevices)} devices have sent playback activity since collection began. Devices with older clients may not report.`,`${count(c.reportedDevices)} devices`],
      ['Live sports coverage','Direct or embedded sports streams can bypass Usenet. Their bandwidth is not included in provider traffic.','Client-reported'],
      ['Daily averages',`Uses ${number(state.report.range?.observedDays)} observed UTC calendar days, including zero-use days and the current partial day.`,'Observed days'],
      ['Retention',`Activity is retained for ${count(c.retentionDays || 90)} days. Reports display the latest 200 sessions and up to 50 titles.`,'90 days']
    ].map(([title,detail,badge]) => `<div class="coverage-item"><div><strong>${escape(title)}</strong><p>${escape(detail)}</p></div><span class="badge">${escape(badge)}</span></div>`).join('')}</div>`;
  }
  function tableToolbar(name, placeholder, withKind = false, allowedKinds = kinds) {
    return `<div class="table-toolbar"><div class="search-field">${icon('search')}<input id="search-${name}" data-search="${name}" type="search" placeholder="${escape(placeholder)}…" aria-label="${escape(placeholder)}" value="${escape(state.search[name] || '')}"></div>${withKind ? `<select class="table-filter" data-filter="${name}" aria-label="Filter by playback kind"><option value="">All viewing</option>${allowedKinds.map(kind => `<option value="${kind}"${state.filter[name] === kind ? ' selected' : ''}>${labels[kind]}</option>`).join('')}</select>` : ''}<span class="table-count" id="count-${name}"></span></div>`;
  }
  function sortedRows(name, rows, defaultKey, defaultDirection = -1) {
    const sort = state.sort[name] || {key:defaultKey,direction:defaultDirection};
    return [...rows].sort((a,b) => {
      const x = a[sort.key], y = b[sort.key];
      return (typeof x === 'string' || typeof y === 'string' ? String(x ?? '').localeCompare(String(y ?? '')) : numeric(x)-numeric(y))*sort.direction;
    });
  }
  function sortHeader(name,key,label,isNumber = false,defaultKey = '') {
    const sorted = state.sort[name], active = sorted ? sorted.key === key : defaultKey === key, direction = sorted?.direction || -1;
    return `<th${isNumber ? ' class="number"' : ''} aria-sort="${active ? (direction === 1 ? 'ascending' : 'descending') : 'none'}"><button class="sort-button" data-sort="${name}" data-key="${key}" aria-pressed="${active}">${escape(label)}${active ? `<span aria-hidden="true">${direction === 1 ? '↑' : '↓'}</span>` : ''}</button></th>`;
  }
  function titlesTable() {
    const search = (state.search.titles || '').toLowerCase(), filter = state.filter.titles;
    const rows = sortedRows('titles',array(state.report.titles).filter(row => (!filter || row.kind === filter) && `${row.title} ${labels[row.kind] || ''}`.toLowerCase().includes(search)),'playedMs');
    return `<div class="table-scroll"><table class="data-table"><thead><tr>${sortHeader('titles','title','Title')}${sortHeader('titles','kind','Kind')}${sortHeader('titles','playedMs','Time watched',true,'playedMs')}${sortHeader('titles','sessions','Sessions',true)}${sortHeader('titles','profiles','Profiles',true)}</tr></thead><tbody>${rows.length ? rows.map(row => `<tr><td class="title-cell" title="${escape(row.title)}"><strong>${escape(row.title || 'Untitled')}</strong>${row.season != null && row.episode != null ? `<small>Season ${escape(row.season)} · Episode ${escape(row.episode)}</small>` : ''}</td><td>${escape(labels[row.kind] || row.kind || 'Unclassified')}</td><td class="number">${duration(row.playedMs)}</td><td class="number">${count(row.sessions)}</td><td class="number">${count(row.profiles)}</td></tr>`).join('') : `<tr><td colspan="5" class="table-empty">${search || filter ? 'No titles match these filters.' : 'Titles appear after clients report playback.'}</td></tr>`}</tbody></table></div>`;
  }
  function sessionsTable() {
    const search = (state.search.sessions || '').toLowerCase(), filter = state.filter.sessions;
    const rows = sortedRows('sessions',array(state.report.sessions).filter(row => (!filter || row.kind === filter) && `${row.title} ${row.profileName} ${row.deviceName} ${row.platform}`.toLowerCase().includes(search)),'startedAt');
    return `<div class="table-scroll">${sessionRows(rows,'sessions')}</div>`;
  }
  function sessionRows(rows, name) {
    return `<table class="data-table"><thead><tr>${sortHeader(name,'title','Title')}${sortHeader(name,'profileName','Profile / device')}${sortHeader(name,'startedAt','Started',false,'startedAt')}${sortHeader(name,'playedMs','Watched',true)}<th>Status</th><th><span class="sr-only">Session details</span></th></tr></thead><tbody>${rows.length ? rows.map((row,i) => {const expanded = state.expanded.has(String(row.id)), detailId = `${name}-detail-${i}`;return `<tr><td class="title-cell" title="${escape(row.title)}"><strong>${escape(row.title || 'Untitled playback')}</strong><small>${escape(labels[row.kind] || row.kind || 'Playback')}</small></td><td class="title-cell">${escape(row.profileName || 'Unassigned')}<small>${escape(row.deviceName || row.platform || 'Unknown device')}</small></td><td title="${escape(date(row.startedAt,true))} UTC">${escape(date(row.startedAt,true))}</td><td class="number">${duration(row.playedMs)}</td><td>${sessionBadge(row.state)}</td><td><button class="text-button" data-expand="${escape(row.id)}" aria-expanded="${expanded}" aria-controls="${detailId}">${expanded ? 'Less −' : 'Details +'}</button></td></tr><tr id="${detailId}" class="detail-row"${expanded ? '' : ' hidden'}><td colspan="6"><dl class="detail-grid">${[['Startup',latency(row.startupMs)],['Buffering',duration(row.bufferedMs)],['Errors',count(row.errorCount)],['Source changes',count(row.sourceSwitches)],['Last reported',`${date(row.lastSeen,true)} UTC`],['Platform',row.platform || 'Unknown']].map(([label,value]) => `<div><dt>${escape(label)}</dt><dd>${escape(value)}</dd></div>`).join('')}</dl></td></tr>`;}).join('') : '<tr><td colspan="6" class="table-empty">No reported sessions match this view.</td></tr>'}</tbody></table>`;
  }
  function devicesTable() {
    const search = (state.search.devices || '').toLowerCase();
    const rows = sortedRows('devices',array(state.report.devices).filter(row => `${row.name} ${row.platform} ${row.appVersion}`.toLowerCase().includes(search)),'playedMs');
    return `<div class="table-scroll"><table class="data-table"><thead><tr>${sortHeader('devices','name','Device')}${sortHeader('devices','platform','Platform')}<th>Version</th>${sortHeader('devices','playedMs','Time watched',true,'playedMs')}${sortHeader('devices','sessions','Sessions',true)}${sortHeader('devices','lastSeen','Last seen')}</tr></thead><tbody>${rows.length ? rows.map(row => `<tr><td><strong>${escape(row.name || 'Unnamed device')}</strong></td><td>${escape(row.platform || 'Unknown')}</td><td>${escape(row.appVersion || '—')}</td><td class="number">${duration(row.playedMs)}</td><td class="number">${count(row.sessions)}</td><td title="${escape(date(row.lastSeen,true))} UTC">${escape(relative(row.lastSeen))}</td></tr>`).join('') : '<tr><td colspan="6" class="table-empty">No reporting devices match this view.</td></tr>'}</tbody></table></div>`;
  }
  function render() {
    if (!state.report) return;
    const focused = document.activeElement, focusId = focused?.id, start = focused?.selectionStart, end = focused?.selectionEnd;
    const focusData = ['expand','profile','sort','key','nav'].filter(key => focused?.dataset?.[key]).map(key => [key,focused.dataset[key]]);
    const scrollPositions = $$('.table-scroll').map(el => el.scrollLeft);
    const renderers = {overview,capacity:capacityPage,playback:playbackPage,profiles:profilesPage,recovery:recoveryPage,health:healthPage};
    $('#report-content').innerHTML = renderers[state.tab]();
    $('#report-content').hidden = false;
    $('#report-loading').hidden = true;
    const nextFocus = focusId ? document.getElementById(focusId) : focusData.length ? $$('button', $('#report-content')).find(button => focusData.every(([key,value]) => button.dataset[key] === value)) : null;
    if (nextFocus) {nextFocus.focus({preventScroll:true});if (typeof nextFocus.setSelectionRange === 'function' && start != null) nextFocus.setSelectionRange(start,end);}
    $$('.table-scroll').forEach((el,i) => {el.scrollLeft = scrollPositions[i] || 0;});
    const coverage = state.report.coverage || {};
    $('#collection-label').textContent = coverage.collectionStartedAt ? 'Reporting online' : 'Starting collection';
    $('#collection-since').textContent = coverage.collectionStartedAt ? `Collecting since ${date(coverage.collectionStartedAt)} UTC` : 'Gathering your first samples';
    updateTableCounts();
    $('#coverage-footer').textContent = state.tab === 'recovery' ? 'Beta recovery covers reporting movie and episode watches only. No earlier repairs are reconstructed.' : `Playback covers reporting clients only. ${count(coverage.capacitySampleCount)} capacity samples · ${number(state.report.range?.observedDays)} observed days · ${count(coverage.retentionDays || 90)}-day retention.`;
  }
  function renderLive() {
    $$('[data-live-panel="capacity"]').forEach(el => {el.innerHTML = capacityNow();});
    $$('[data-live-panel="sessions"]').forEach(el => {el.innerHTML = livePanel();});
    $$('[data-live-panel="host"]').forEach(el => {el.innerHTML = hostPanel();});
    $$('[data-live-value="watching"]').forEach(el => {el.textContent = count(activeSessions().filter(s => s.state !== 'stale').length);});
    $$('[data-live-value="free"]').forEach(el => {el.textContent = count(state.live?.capacity?.free);});
  }
  function setTab(tab, scroll = true) {
    state.tab = sections[tab] ? tab : 'overview';
    const section = sections[state.tab];
    $('#breadcrumb-current').textContent = section.label;
    $('#page-eyebrow').textContent = section.eyebrow;
    $('#page-title').textContent = section.title;
    $('#page-description').textContent = section.description;
    document.title = `${section.label} · Velvet Admin`;
    $$('.nav-item').forEach(el => el.setAttribute('aria-current',el.dataset.tab === state.tab ? 'page' : 'false'));
    render();
    if (scroll) window.scrollTo({top:0,behavior:'instant'});
  }
  function showLogin(message = '') {
    state.authenticated = false;
    state.requestId++;
    $('#login').hidden = false;
    $('#app').hidden = true;
    $('#access-key').value = '';
    $('#login-error').textContent = message;
    $('#login-error').hidden = !message;
    if (message) $('#access-key').focus();
  }
  function showApp() {
    state.authenticated = true;
    $('#login').hidden = true;
    $('#app').hidden = false;
  }
  async function api(url, options = {}) {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(),20000);
    let response;
    try {response = await fetch(url,{...options,credentials:'same-origin',cache:'no-store',signal:controller.signal,headers:{Accept:'application/json',...options.headers}});} catch(error) {throw new Error(error.name === 'AbortError' ? 'The server took too long to respond.' : 'Could not reach the server. Check your connection.');} finally {clearTimeout(timer);}
    if (response.status === 401) {const err = new Error('Your admin session has ended. Sign in again.');err.status = 401;throw err;}
    if (!response.ok) {let message = 'The server could not complete this request.';try {const data = await response.json();if (typeof data.error === 'string') message = data.error;} catch (_) {}const err = new Error(message);err.status = response.status;throw err;}
    if (response.status === 204) return null;
    const type = response.headers.get('content-type') || '';
    return type.includes('application/json') ? response.json() : null;
  }
  async function fetchReport(initial = false) {
    if (state.reportBusy) return;
    state.reportBusy = true;
    const requestId = ++state.requestId, days = state.days;
    $('#refresh').classList.add('is-refreshing');
    if (!state.report) $('#report-loading').hidden = false;
    try {
      const report = await api(`/admin/api/report?days=${days}`);
      if (requestId !== state.requestId || days !== state.days) return;
      if (!report || typeof report !== 'object' || !report.coverage) throw new Error('The server returned an incomplete report.');
      state.report = report;
      state.lastSuccess = Date.now();
      state.reportError = null;
      showApp();
      render();
      updateStatus();
    } catch(error) {
      if (requestId !== state.requestId) return;
      if (error.status === 401) showLogin(initial ? '' : error.message);
      else {state.reportError = error.message;if (initial) showApp();updateStatus();if (!state.report) {$('#report-loading').hidden = true;$('#report-content').hidden = false;$('#report-content').innerHTML = `<section class="panel">${empty('Your report is temporarily unavailable','Use Refresh to try again. No data has been replaced.','warning')}</section>`;}}
    } finally {state.reportBusy = false;$('#refresh').classList.remove('is-refreshing');if (days !== state.days && state.authenticated) fetchReport();}
  }
  async function fetchRecovery() {
    if (state.recoveryBusy || !state.authenticated) return;
    state.recoveryBusy = true;
    const requestId = ++state.recoveryRequestId, days = state.days;
    if (state.tab === 'recovery') render();
    try {
      const recovery = await api(`/admin/api/recovery?days=${days}`);
      if (requestId !== state.recoveryRequestId || days !== state.days || !state.authenticated) return;
      if (!recovery || typeof recovery !== 'object' || (recovery.available !== false && !recovery.summary)) throw new Error('The beta backend returned an incomplete recovery report.');
      state.recovery = recovery;
      state.recoveryError = null;
    } catch (error) {
      if (requestId !== state.recoveryRequestId || days !== state.days) return;
      if (error.status === 401) showLogin(error.message);
      else state.recoveryError = error.message;
    } finally {
      state.recoveryBusy = false;
      if (state.tab === 'recovery') render();
      if (days !== state.days && state.authenticated) fetchRecovery();
    }
  }
  async function fetchLive() {
    if (state.liveBusy || !state.authenticated) return;
    state.liveBusy = true;
    try {const live = await api('/admin/api/live');if (!state.authenticated) return;if (!live || !live.capacity) throw new Error('Live capacity is temporarily unavailable.');state.live = live;state.liveSuccess = Date.now();state.liveError = null;renderLive();updateStatus();}
    catch(error) {if (error.status === 401) showLogin(error.message);else {state.liveError = error.message;updateStatus();}}
    finally {state.liveBusy = false;}
  }
  function updateStatus() {
    const stale = Boolean(state.reportError || state.liveError), banner = $('#error-banner');
    $('.topbar-status').classList.toggle('stale',stale);
    $('#refresh-status').textContent = stale ? `Connection interrupted${state.lastSuccess ? ` · saved ${relative(state.lastSuccess)}` : ''}` : state.lastSuccess ? `Updated ${relative(state.lastSuccess)}` : 'Connecting';
    banner.hidden = !stale;
    banner.innerHTML = stale ? `${icon('warning')}<div>${escape(state.reportError || state.liveError)} ${state.report ? 'Showing the last successful snapshot.' : ''} <button data-retry>Try again</button></div>` : '';
  }
  async function refresh() {
    await Promise.allSettled([fetchReport(),fetchLive(),fetchRecovery()]);
  }
  async function logout() {
    try {await api('/admin/api/logout',{method:'POST'});state.report = null;state.live = null;state.recovery = null;state.recoveryError = null;state.recoveryRequestId++;$('#report-content').innerHTML = '';state.lastSuccess = 0;state.liveSuccess = 0;state.reportError = null;state.liveError = null;showLogin();$('#access-key').focus();}
    catch(error) {if (error.status === 401) showLogin();else toast('Could not sign out. Please try again.');}
  }
  function toast(message) {clearTimeout(state.toastTimer);$('#toast').textContent = message;$('#toast').hidden = false;state.toastTimer = setTimeout(() => {$('#toast').hidden = true;},5000);}
  function updateTableCounts() {
    for (const name of ['titles','sessions','devices','recovery-titles','recovery-sessions']) {
      const table = $(`#table-${name}`), label = $(`#count-${name}`);
      if (table && label) label.textContent = `${table.querySelector('.table-empty') ? 0 : table.querySelectorAll('tbody > tr:not(.detail-row)').length} results`;
    }
  }
  function updateTable(name) {
    const renderer = {titles:titlesTable,sessions:sessionsTable,devices:devicesTable,'recovery-titles':recoveryTitlesTable,'recovery-sessions':recoverySessionsTable}[name];
    const target = $(`#table-${name}`);
    if (renderer && target) target.innerHTML = renderer();
    else render();
    updateTableCounts();
  }
  $('#navigation').innerHTML = Object.entries(sections).map(([key,section]) => `<a class="nav-item" href="#${key}" data-tab="${key}" title="${escape(section.label)}" aria-label="${escape(section.label)}">${icon(key)}<span class="nav-label">${escape(section.label)}</span></a>`).join('');
  $('#refresh').innerHTML = icon('refresh');
  $('#range-icon').innerHTML = icon('calendar');
  $('#show-key').innerHTML = icon('eye');
  $('#show-key').addEventListener('click',() => {const input = $('#access-key'), show = input.type === 'password';input.type = show ? 'text' : 'password';$('#show-key').setAttribute('aria-pressed',String(show));$('#show-key').setAttribute('aria-label',show ? 'Hide access key' : 'Show access key');});
  $('#login-form').addEventListener('submit',async event => {
    event.preventDefault();const token = $('#access-key').value.trim();if (!token) return;
    const button = $('#login-submit');button.disabled = true;button.textContent = 'Signing in…';$('#login-error').hidden = true;
    try {await api('/admin/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})});$('#access-key').value = '';$('#access-key').type = 'password';$('#show-key').setAttribute('aria-pressed','false');$('#show-key').setAttribute('aria-label','Show access key');showApp();await fetchReport();await Promise.allSettled([fetchLive(),fetchRecovery()]);}
    catch(error) {$('#login-error').textContent = error.status === 401 ? 'That access key wasn’t recognized. Please try again.' : error.message;$('#login-error').hidden = false;$('#access-key').focus();}
    finally {button.disabled = false;button.innerHTML = 'Open dashboard <span aria-hidden="true">↗</span>';}
  });
  $('#logout').addEventListener('click',logout);
  $('#refresh').addEventListener('click',refresh);
  $('#range').addEventListener('change',event => {
    state.days = Number(event.target.value);state.expanded.clear();state.report = null;state.recovery = null;state.recoveryError = null;
    $('#report-content').hidden = true;
    $('#report-loading').hidden = false;
    $('#export-playback').href = `/admin/api/export?days=${state.days}&type=playback`;
    $('#export-capacity').href = `/admin/api/export?days=${state.days}&type=capacity`;
    fetchReport();fetchRecovery();
  });
  window.addEventListener('hashchange',() => setTab(location.hash.slice(1)));
  document.addEventListener('click',event => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const nav = target.closest('[data-nav]');if (nav) location.hash = nav.dataset.nav;
    const expand = target.closest('[data-expand]');if (expand) {const id = expand.dataset.expand;if (state.expanded.has(id)) state.expanded.delete(id);else state.expanded.add(id);const row = document.getElementById(expand.getAttribute('aria-controls'));if (row) row.hidden = !state.expanded.has(id);expand.setAttribute('aria-expanded',String(state.expanded.has(id)));expand.textContent = state.expanded.has(id) ? 'Less −' : 'Details +';}
    const sort = target.closest('[data-sort]');if (sort) {const name = sort.dataset.sort, key = sort.dataset.key, previous = state.sort[name];state.sort[name] = {key,direction:previous?.key === key ? -previous.direction : sort.getAttribute('aria-pressed') === 'true' ? 1 : -1};updateTable(name);$(`[data-sort="${name}"][data-key="${key}"]`)?.focus({preventScroll:true});}
    const profile = target.closest('[data-profile]');if (profile) {state.profile = profile.dataset.profile;if (state.tab !== 'profiles') location.hash = 'profiles';else render();}
    if (target.closest('[data-clear-profile]')) {state.profile = null;render();}
    if (target.closest('[data-logout]')) logout();
    if (target.closest('[data-retry]')) refresh();
    if (target.closest('[data-recovery-retry]')) fetchRecovery();
    if (!target.closest('.export-menu')) $$('.export-menu[open]').forEach(el => {el.open = false;});
  });
  document.addEventListener('input',event => {const target = event.target;if (target instanceof HTMLInputElement && target.dataset.search) {state.search[target.dataset.search] = target.value;updateTable(target.dataset.search);}});
  document.addEventListener('change',event => {const target = event.target;if (target instanceof HTMLSelectElement && target.dataset.filter) {state.filter[target.dataset.filter] = target.value;updateTable(target.dataset.filter);}});
  document.addEventListener('keydown',event => {if (event.key === 'Escape') $$('.export-menu[open]').forEach(el => {el.open = false;});});
  document.addEventListener('visibilitychange',() => {if (!document.hidden && state.authenticated) refresh();});
  setInterval(() => {if (!document.hidden && state.authenticated) fetchLive();},15000);
  setInterval(() => {if (!document.hidden && state.authenticated) {fetchReport();fetchRecovery();}},60000);
  setInterval(() => {if (state.authenticated) updateStatus();},10000);
  let resizeTimer;
  let chartWidthMode = window.innerWidth <= 700;
  window.addEventListener('resize',() => {clearTimeout(resizeTimer);resizeTimer = setTimeout(() => {const next = window.innerWidth <= 700;if (next !== chartWidthMode) {chartWidthMode = next;render();}},150);});
  $('#app').hidden = false;
  setTab(location.hash.slice(1),false);
  fetchReport(true).then(() => {if (state.authenticated) {fetchLive();fetchRecovery();}});
})();
