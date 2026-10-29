(() => {
  // Isolated content script: standard player controls only. No media URL, cookie,
  // provider token or private player API is collected or sent to the app.
  const port = browser.runtime.connectNative('velvetSportsStartup');
  const samples = new WeakMap();
  const pending = new WeakSet();
  let stopped = false, started = false, attempts = 0, lastAttempt = -Infinity, deadline = 0, actionDeadline = 0, lastDiagnostic = -Infinity;
  let timer, observation;
  function observePlayback(video) {
    if (observation) return;
    let previous = video.currentTime;
    observation = setInterval(() => {
      if (document.hidden || !video.isConnected) { clearInterval(observation); return; }
      const time = video.currentTime;
      const advanced = time > previous && time - previous < 3;
      previous = time;
      const state = video.ended ? 'ended' : video.paused ? 'paused' :
        (advanced && video.readyState >= 2 ? 'playing' : 'buffering');
      port.postMessage({state: 'observation', playbackState: state});
    }, 1000);
  }
  function stop() { stopped = true; clearInterval(timer); }
  port.onMessage.addListener(message => {
    if (message?.type === 'stop') stop();
    if (message?.type === 'start' && !started && !stopped) {
      started = true;
      // Native owns the overall load timeout. Keep observing actual playback
      // after the bounded click window, so a slow provider cannot play beneath
      // the startup overlay without ever notifying the app.
      const observeMs = Number.isFinite(message.observeMs) ? Math.max(0, Math.min(45000, message.observeMs)) : 45000;
      deadline = Date.now() + observeMs;
      actionDeadline = Date.now() + Math.min(30000, observeMs);
      timer = setInterval(tick, 400); tick();
    }
  });
  port.onDisconnect.addListener(() => { stop(); clearInterval(observation); });
  window.addEventListener('pagehide', stop, { once: true });
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
  function visible(element) {
    const rect = element.getBoundingClientRect();
    if (rect.width < 320 || rect.height < 180 || rect.bottom <= 0 || rect.right <= 0 || rect.top >= window.innerHeight || rect.left >= window.innerWidth) return false;
    for (let node = element; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
    }
    return true;
  }
  function tick() {
    if (stopped) return;
    if (Date.now() >= deadline || document.hidden) { stop(); return; }
    if (window.innerWidth < 320 || window.innerHeight < 180) return;
    const video = Array.from(document.querySelectorAll('video')).filter(visible)
      .sort((a, b) => b.getBoundingClientRect().width * b.getBoundingClientRect().height - a.getBoundingClientRect().width * a.getBoundingClientRect().height)[0];
    const hasSource = video && (video.srcObject || video.getAttribute('src')?.trim() || Array.from(video.querySelectorAll('source[src]')).some(source => source.getAttribute('src')?.trim()));
    if (Date.now() - lastDiagnostic >= 2000) {
      lastDiagnostic = Date.now();
      const candidate = video || document.querySelector('video');
      const control = document.querySelector('#jwplayer.jwplayer.jw-state-idle .jw-icon-display');
      const player = document.querySelector('#jwplayer');
      port.postMessage({ state: 'startup', attempts, video: !!candidate, visibleVideo: !!video,
        source: !!hasSource, idleControl: !!control, player: !!player,
        readyState: candidate?.readyState ?? 0, paused: candidate?.paused ?? true,
        networkState: candidate?.networkState ?? 0, errorCode: candidate?.error?.code ?? 0 });
    }
    if (video && hasSource) {
      const frames = video.getVideoPlaybackQuality?.().totalVideoFrames || 0;
      let before = samples.get(video);
      if (!before) { before = { time: video.currentTime, frames }; samples.set(video, before); }
      const advanced = Math.abs(video.currentTime - before.time) > .15 || frames > before.frames;
      if (!video.paused && video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0 && advanced) {
        stop();
        observePlayback(video);
        port.postMessage({ state: 'playing', width: video.videoWidth, height: video.videoHeight,
          viewportWidth: window.innerWidth, viewportHeight: window.innerHeight, readyState: video.readyState, advanced: true });
        return;
      }
    }
    if (attempts < 8 && Date.now() < actionDeadline && Date.now() - lastAttempt >= 2000) {
      // StreamFree uses this JWPlayer display control. Never click generic text,
      // links, ad overlays or arbitrary page coordinates.
      const poster = document.querySelector('#jwplayer.jwplayer.jw-state-idle .jw-icon-display');
      const player = poster?.closest('#jwplayer.jwplayer');
      if (poster && player && visible(player) && !poster.closest('a')) {
        attempts++; lastAttempt = Date.now(); poster.click();
      } else if (video && hasSource && video.paused && !video.error && !pending.has(video)) {
        attempts++; lastAttempt = Date.now(); pending.add(video);
        try { Promise.resolve(video.play()).catch(() => {}).finally(() => pending.delete(video)); }
        catch (_) { pending.delete(video); }
      }
    }
  }
})();
