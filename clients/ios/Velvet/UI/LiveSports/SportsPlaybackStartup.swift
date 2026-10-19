import WebKit

/// Runs in an isolated WebKit world. Remote pages cannot call its native
/// handler; it reports only readiness and observed video progress.
enum SportsPlaybackStartup {
    static let world = WKContentWorld.world(name: "VelvetSportsStartup")
    static let handlerName = "sportsPlaybackState"
    static let cancelScript = "window.__velvetCancelStartup?.()"
    static let beginScript = "window.__velvetStartApprovedStartup?.()"

    static func makeScript(for embedURL: URL) -> String {
        var config = ["embedURL": embedURL.absoluteString]
        if let golf = golfIdentity(embedURL) { config["golfID"] = golf.id }
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return script.replacingOccurrences(of: "__VELVET_STARTUP_CONFIG__", with: String(decoding: data, as: UTF8.self))
    }

    static func accepts(frameURL: URL?, for embedURL: URL) -> Bool {
        frameURL == embedURL
    }

    static func isGolfWrapper(_ url: URL, for embedURL: URL) -> Bool {
        guard let golf = golfIdentity(embedURL), url.scheme == "https", url.host == "rockylive.st",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              ["/source/streamed.php", "/source/streamed1.php"].contains(url.path),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let numbers = query.filter { $0.name == "no" }.compactMap(\.value)
        let hd = query.filter { $0.name == "hd" }.compactMap(\.value)
        return query.allSatisfy { ["id", "no", "hd"].contains($0.name) && $0.value != nil }
            && query.filter { $0.name == "id" }.map(\.value) == [golf.id]
            && numbers.count == 1 && numbers[0].range(of: #"^[1-9][0-9]{0,2}$"#, options: .regularExpression) != nil
            && hd.count <= 1 && hd.allSatisfy { $0.range(of: #"^[0-9]{1,8}$"#, options: .regularExpression) != nil }
    }

    private static func golfIdentity(_ url: URL) -> (id: String, stream: String)? {
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[0] == "embed", parts[1] == "golf" else { return nil }
        return (String(parts[2]), String(parts[3]))
    }

    static func isIngestPlayer(_ url: URL) -> Bool {
        url.scheme == "https" && ["embed.st", "embed.pk"].contains(url.host ?? "")
            && url.port == nil && url.user == nil && url.password == nil
            && url.query == nil && (url.fragment == nil || url.fragment == "player=clappr&autoplay=true")
            && url.path.range(of: #"^/embed/ingest/[A-Za-z0-9][A-Za-z0-9_-]{0,199}/[1-9][0-9]{0,2}/?$"#,
                              options: .regularExpression) != nil
    }

    static func documentURL(_ url: URL) -> URL {
        guard isIngestPlayer(url), url.fragment != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // Fragments configure the intended player but are absent from the
        // frame's HTTP request URL. Only the validated options can be removed.
        parts.fragment = nil
        return parts.url ?? url
    }

    static let script = #"""
    (() => {
      const config = __VELVET_STARTUP_CONFIG__;
      const url = new URL(location.href);
      const exactEmbed = url.href === config.embedURL;
      const golfFrame = config.golfID && url.protocol === 'https:' && url.hostname === 'rockylive.st' &&
        !url.port && !url.username && !url.password && !url.hash &&
        ['/source/streamed.php', '/source/streamed1.php'].includes(url.pathname) &&
        Array.from(url.searchParams.keys()).every(key => ['id', 'no', 'hd'].includes(key)) &&
        url.searchParams.getAll('id').length === 1 && url.searchParams.get('id') === config.golfID &&
        url.searchParams.getAll('no').length === 1 && /^[1-9][0-9]{0,2}$/.test(url.searchParams.get('no')) &&
        url.searchParams.getAll('hd').length <= 1 && url.searchParams.getAll('hd').every(value => /^[0-9]{1,8}$/.test(value));
      const ingestCandidate = config.golfID && url.protocol === 'https:' &&
        ['embed.st', 'embed.pk'].includes(url.hostname) && !url.port && !url.username && !url.password &&
        !url.search && (!url.hash || url.hash === '#player=clappr&autoplay=true') &&
        /^\/embed\/ingest\/[A-Za-z0-9][A-Za-z0-9_-]{0,199}\/[1-9][0-9]{0,2}\/?$/.test(url.pathname);
      if (!exactEmbed && !golfFrame && !ingestCandidate) return;
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
        let hasSource = false;
        for (const video of videos) {
          if ((video.getAttribute('src') || '').trim() || video.srcObject ||
              Array.from(video.querySelectorAll('source')).some(source => (source.getAttribute('src') || '').trim())) {
            hasSource = true;
            if (video.paused && !video.ended) {
              try { const pending = video.play(); if (pending) pending.catch(() => {}); } catch (_) {}
            }
          }
        }
        if (hasSource) return;
        // These are the players' own initial Play controls, never links, ads,
        // arbitrary matching text, or coordinates. Native popup policy applies.
        const control = Array.from(document.querySelectorAll(
          '.jwplayer.jw-state-idle .jw-icon-display, ' +
          '[data-player] .player-poster[data-poster].clickable .play-wrapper[data-poster]'
        )).find(element => visible(element) && !element.closest('a, form') &&
          !element.hasAttribute('href'));
        if (control) control.click();
      };
      // A nested frame has to be approved from its native navigation lineage
      // before it can invoke even a standard Play control.
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
