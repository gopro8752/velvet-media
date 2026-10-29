import WebKit

/// Runs in an isolated WebKit world. Remote pages cannot call its native
/// handler; it reports only readiness and observed video progress.
enum SportsPlaybackStartup {
    static let world = WKContentWorld.world(name: "VelvetSportsStartup")
    static let handlerName = "sportsPlaybackState"
    static let cancelScript = "window.__velvetCancelStartup?.()"
    static let beginScript = "window.__velvetStartApprovedStartup?.()"

    static func makeScript(for embedURL: URL) -> String {
        let config = ["embedURL": embedURL.absoluteString]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return script.replacingOccurrences(of: "__VELVET_STARTUP_CONFIG__", with: String(decoding: data, as: UTF8.self))
    }

    static func accepts(frameURL: URL?, for embedURL: URL) -> Bool {
        frameURL == embedURL
    }

    static let script = #"""
    (() => {
      const config = __VELVET_STARTUP_CONFIG__;
      const url = new URL(location.href);
      const exactEmbed = url.href === config.embedURL;
      if (!exactEmbed) return;
      let stopped = false;
      let deadline = 0;
      let timer = null;
      const samples = new WeakMap();
      let observation = null;
      const observePlayback = video => {
        if (observation !== null) return;
        let previous = video.currentTime;
        observation = setInterval(() => {
          if (document.hidden || !video.isConnected) { clearInterval(observation); return; }
          const time = video.currentTime;
          const advanced = time > previous && time - previous < 3;
          previous = time;
          notify(video.ended ? 'ended' : video.paused ? 'paused' :
            (advanced && video.readyState >= 2 ? 'playing' : 'buffering'));
        }, 1000);
        window.addEventListener('pagehide', () => clearInterval(observation), {once: true});
      };
      let lastAttempt = -Infinity;
      const notify = state => window.webkit.messageHandlers.sportsPlaybackState.postMessage({state});
      const visible = element => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width >= 20 && rect.height >= 20 && rect.bottom > 0 && rect.right > 0 &&
          rect.top < innerHeight && rect.left < innerWidth && style.display !== 'none' &&
          style.visibility !== 'hidden' && Number(style.opacity) !== 0;
      };
      const stop = () => { stopped = true; clearInterval(timer); };
      window.__velvetCancelStartup = stop;
      const tick = () => {
        if (stopped) return;
        if (performance.now() >= deadline) { stop(); return; }
        // Ignore hidden advertising frames and documents that are away.
        if (innerWidth < 320 || innerHeight < 180 || document.hidden) return;
        const videos = Array.from(document.querySelectorAll('video')).filter(video => {
          const rect = video.getBoundingClientRect();
          return visible(video) && rect.width >= 320 && rect.height >= 180;
        });
        for (const video of videos) {
          const previous = samples.get(video);
          const time = video.currentTime;
          if (video.videoWidth > 0 && video.videoHeight > 0 && video.readyState >= 2 &&
              !video.paused && previous !== undefined && time > previous + 0.15) {
            stop(); observePlayback(video); notify('playing'); return;
          }
          if (Number.isFinite(time)) samples.set(video, time);
        }
        if (performance.now() - lastAttempt < 1500) return;
        lastAttempt = performance.now();
        // Let JWPlayer handle its own initial transition even when its video
        // already has a source. Never click generic buttons or advertising links.
        const control = Array.from(document.querySelectorAll(
          '#jwplayer.jwplayer.jw-state-idle .jw-icon-display'
        )).find(element => visible(element) && !element.closest('a, form') &&
          !element.hasAttribute('href'));
        if (control) {
          const rect = control.getBoundingClientRect();
          const event = {bubbles: true, cancelable: true, view: window,
            clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2,
            button: 0, buttons: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true};
          if (typeof PointerEvent === 'function') control.dispatchEvent(new PointerEvent('pointerdown', event));
          control.dispatchEvent(new MouseEvent('mousedown', event));
          if (typeof PointerEvent === 'function') control.dispatchEvent(new PointerEvent('pointerup', {...event, buttons: 0}));
          control.dispatchEvent(new MouseEvent('mouseup', {...event, buttons: 0}));
          control.dispatchEvent(new MouseEvent('click', {...event, buttons: 0, detail: 1}));
          return;
        }
        for (const video of videos) {
          if ((video.getAttribute('src') || '').trim() || video.srcObject ||
              Array.from(video.querySelectorAll('source')).some(source => (source.getAttribute('src') || '').trim())) {
            if (video.paused && !video.ended) {
              try { const pending = video.play(); if (pending) pending.catch(() => {}); } catch (_) {}
            }
          }
        }
      };
      // Only the selected StreamFree embed can receive native startup approval;
      // nested advertising documents never get play or click automation.
      window.__velvetStartApprovedStartup = () => {
        if (stopped || timer !== null) return;
        deadline = performance.now() + 45000;
        timer = setInterval(tick, 300);
        tick();
      };
      notify('ready');
    })();
    """#
}

@MainActor
final class SportsPlaybackStateHandler: NSObject, WKScriptMessageHandler {
    weak var owner: SportsWebPlayer?
    init(owner: SportsWebPlayer) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receivePlaybackState(message)
    }
}
