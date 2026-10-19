(() => {
  // Isolated content script: standard player controls only. No media URL, cookie,
  // provider token or private player API is collected or sent to the app.
  const port = browser.runtime.connectNative('velvetSportsStartup');
  const samples = new WeakMap();
  const pending = new WeakSet();
  const registeredFrames = new Set();
  let stopped = false, started = false, attempts = 0, lastAttempt = -Infinity, deadline = 0;
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
      started = true; deadline = Date.now() + 30000;
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
    // The selected Golf document declares its visible direct wrapper; that accepted
    // wrapper may then declare its visible ingest player. Native code validates each hop.
    const golf = ['embed.st', 'embed.pk'].includes(location.hostname) && /^\/embed\/golf\/[^/]+\/[^/]+$/.test(location.pathname);
    const wrapper = location.hostname === 'rockylive.st' && /^\/source\/streamed1?\.php$/.test(location.pathname);
    if (golf || wrapper) {
      for (const frame of document.querySelectorAll('iframe[src]')) {
        if (registeredFrames.size >= 4 || !visible(frame)) continue;
        try {
          const url = new URL(frame.src);
          if (url.protocol !== 'https:' || url.port || url.username || url.password || registeredFrames.has(url.href)) continue;
          const candidate = golf
            ? !url.hash && url.hostname === 'rockylive.st' && /^\/source\/streamed1?\.php$/.test(url.pathname) && url.searchParams.getAll('id').length === 1 && url.searchParams.get('id') === location.pathname.split('/')[3] && url.searchParams.getAll('no').length === 1 && /^[1-9][0-9]{0,3}$/.test(url.searchParams.get('no'))
            : ['embed.st', 'embed.pk'].includes(url.hostname) && !url.search && (!url.hash || url.hash === '#player=clappr&autoplay=true') && /^\/embed\/ingest\/[A-Za-z0-9_-]{1,200}\/[1-9][0-9]{0,3}\/?$/.test(url.pathname);
          if (!candidate) continue;
          registeredFrames.add(url.href);
          const rect = frame.getBoundingClientRect();
          port.postMessage({ state: 'child', frame: url.href, width: Math.round(rect.width), height: Math.round(rect.height) });
        } catch (_) {}
      }
    }
    const video = Array.from(document.querySelectorAll('video')).filter(visible)
      .sort((a, b) => b.getBoundingClientRect().width * b.getBoundingClientRect().height - a.getBoundingClientRect().width * a.getBoundingClientRect().height)[0];
    const hasSource = video && (video.srcObject || video.getAttribute('src')?.trim() || Array.from(video.querySelectorAll('source[src]')).some(source => source.getAttribute('src')?.trim()));
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
      if (video.error) return;
      if (video.paused && !pending.has(video) && attempts < 8 && Date.now() - lastAttempt >= 2000) {
        attempts++; lastAttempt = Date.now(); pending.add(video);
        try { Promise.resolve(video.play()).catch(() => {}).finally(() => pending.delete(video)); }
        catch (_) { pending.delete(video); }
      }
    } else if (attempts < 8 && Date.now() - lastAttempt >= 2000) {
      // This exact Clappr poster invokes container.play. Never click generic text,
      // links, SVGs, ad overlays or arbitrary page coordinates.
      const poster = document.querySelector('[data-player] .player-poster[data-poster].clickable .play-wrapper[data-poster]') ||
        document.querySelector('.jwplayer.jw-state-idle .jw-icon-display');
      const player = poster?.closest('.player-poster') || poster?.closest('.jwplayer');
      if (poster && player && visible(player) && !poster.closest('a')) {
        attempts++; lastAttempt = Date.now(); poster.click();
      }
    }
  }
})();
