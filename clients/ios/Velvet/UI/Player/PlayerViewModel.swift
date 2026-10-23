import Foundation
import Combine
import UIKit
import VLCKitSPM

// MARK: - UI state types (1:1 with the Android PlayerViewModel.kt)

/// Which top-level UI the player screen shows.
enum PlayerPhase: Equatable {
    case loading
    case error
    case playing
}

/// Lightweight episode descriptor for the Up Next overlay.
struct NextEpisodeUi: Equatable {
    let season: Int
    let episode: Int
    let title: String
    let stillUrl: URL?
    var showTitle: String? = nil
}

/// One selectable entry in the subtitle/audio picker sheets.
/// `index` is the VLC track id; -1 is the "Off" entry (subtitles only).
struct TrackOption: Identifiable, Hashable {
    let index: Int
    let label: String
    let selected: Bool
    var id: Int { index }
}

enum UpNextUi: Equatable {
    case hidden
    /// Autoplay countdown card, bottom-right, ticking once a second.
    case countdown(next: NextEpisodeUi, secondsLeft: Int, totalSeconds: Int)
    /// Static end-of-episode choice card (autoplay off or "Watch credits" pressed).
    case endChoice(next: NextEpisodeUi)
}

/// Outcome pill for the Throw to TV action: quiet confirmation on success,
/// an equally quiet "couldn't reach it" note on failure — never an error screen.
enum ThrowToTvNotice: Equatable {
    case searching, starting(String), sent(String), failed(String), uncertain

    var isPending: Bool {
        switch self { case .searching, .starting: true; default: false }
    }
    var isSuccess: Bool { if case .sent = self { true } else { false } }
    var message: String {
        switch self {
        case .searching: "Finding an awake TV…"
        case .starting(let name): "Starting on \(name)…"
        case .sent(let name): "Playing on \(name)"
        case .failed(let message): message
        case .uncertain: "Couldn't confirm TV playback. Tap Play to continue here."
        }
    }
}

private struct PendingSeek {
    let positionMs: Int64
    let guardNearEnd: Bool
}

private struct SeasonEpisodeKey: Hashable {
    let season: Int
    let episode: Int
}

/// Retain every ranked stream so blocked groups can be restored by Unblock.
private struct PrefetchedStreams {
    let season: Int
    let episode: Int
    let all: [StreamOption]
    /// Stream url -> episode-title verdict for the NEXT episode's stream list
    /// (EpisodeMatch.swift). Empty for movies / missing episode data.
    let verdicts: [URL: EpisodeTitleVerdict]
}

/// Raised when a season-episode fetch is judged to have FAILED (vs. genuinely
/// empty). "fetch failed" must never read as "season empty" — see episodesFor.
private struct SeasonFetchError: Error {}

// MARK: - PlayerViewModel

/// Exact port of ~/velvet .../ui/player/PlayerViewModel.kt: resume rules,
/// 10s progress writes, watched at >=95%, next-episode resolution with the
/// never-skip-a-season guarantee, and the up-next machine with all its race
/// guards (never arm while swapping; ended-vs-swap dedupe; identity snapshots
/// for every persist).
@MainActor
final class PlayerViewModel: ObservableObject {

    // Thresholds — identical to the Android PlayerViewModel.
    private static let upNextTriggerMs: Int64 = 40_000
    private static let upNextReleaseMs: Int64 = 45_000
    private static let resumeMinMs: Int64 = 30_000
    private static let progressSaveEveryTicks = 20 // ticker runs every 500ms -> 10s
    /// Spec §3c: a systemic outage must not loop through sources forever.
    private static let maxAutoRetries = 4
    /// "What did they say?" — jump back this far with subtitles temporarily on.
    private static let replayBackMs: Int64 = 15_000
    let target: PlayTarget
    let engine = PlayerEngine()
    let isShow: Bool
    let queuePlayback: CategoryQueuePlayback?
    @Published private(set) var queueAdvanceRequested: CategoryQueueAdvance?
    @Published private(set) var queuePlaybackHealthy = false
    private var queuePrefetch: CategoryQueuePrefetch?
    private var queueTransitionStarted = false
    private var queueInitialRetryUsed = false
    @Published private var queueAutoAdvanceSuspended = false
    private var queueHealthyMilliseconds: Int64 = 0
    private var queuePreviousPositionMs: Int64 = 0
    private var queueErrorTask: Task<Void, Never>?

    private let tmdb: TmdbRepository
    private let streamRepo: StreamRepository
    private let settings: SettingsStore
    private lazy var telemetry = PlaybackTelemetry(settings: settings)
    private var telemetryIdentity: String?
    private let playback: PlaybackStore
    /// Skip-intro and acknowledged TV handoffs on the configured sync server.
    private let companion: CompanionApi

    // MARK: published UI state

    @Published private(set) var phase: PlayerPhase = .loading
    @Published private(set) var errorMessage: String?
    @Published private(set) var canChooseStream = false
    @Published private(set) var backdropUrl: URL?
    @Published private(set) var showTitle: String = ""
    /// "S2 E4 — Episode Title" for shows; nil for movies.
    @Published private(set) var episodeLabel: String?
    @Published private(set) var isPlaying = false
    /// The decoder can report buffering while preparation has paused playback.
    var isPreparingAudioForPlayback: Bool { audioPreparationTask != nil }
    /// Internal audio preparation pauses VLC but retains the user's Play intent.
    /// The control should still offer Pause while it waits for audible playback.
    var playbackButtonShowsPause: Bool {
        if audioPreparationTask != nil {
            return !queueAutoAdvanceSuspended && !handoffHoldsPlayback && !handoffProgressSuspended
        }
        return isPlaying
    }
    @Published private(set) var isBuffering = false
    @Published private(set) var positionMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var streams: [StreamOption] = []
    @Published private(set) var currentStreamUrl: URL?
    @Published private(set) var hasNext = false
    @Published private(set) var hasPrevious = false
    @Published private(set) var blockedGroups: [ReleaseGroup] = []
    @Published private(set) var groupActionError: String?
    /// Display name of the active embedded subtitle track; nil = subtitles off.
    @Published private(set) var subtitleLabel: String?
    @Published private(set) var subtitleAvailable = false
    /// "Off" + every embedded text track; empty when the stream has none.
    @Published private(set) var subtitleOptions: [TrackOption] = []
    /// Embedded audio tracks; empty until the player reports them.
    @Published private(set) var audioOptions: [TrackOption] = []
    @Published private(set) var upNext: UpNextUi = .hidden
    /// The screen should pop itself (movie finished, no next episode, ...).
    @Published private(set) var shouldDismiss = false
    /// "Trying another source…" — a brief, NON-blocking indicator shown while a
    /// dead stream is swapped for the next healthy candidate in place (spec
    /// §3c). Auto-clears the moment playback actually resumes.
    @Published private(set) var failoverNotice = false
    /// "What did they say?" is mid-flight: subs temporarily on, restore pending.
    @Published private(set) var replayActive = false
    /// Playback is inside a known intro — the Skip Intro pill should show.
    @Published private(set) var skipIntroVisible = false
    /// Pending handoff status or its briefly displayed outcome.
    @Published private(set) var throwToTvNotice: ThrowToTvNotice?
    @Published private(set) var tvReceivers: [TVHandoffReceiver] = []
    @Published private(set) var handoffInProgress = false

    // MARK: media identity

    private var details: MediaDetails?
    private var imdbId: String?
    private var curSeason: Int?
    private var curEpisode: Int?
    private var currentEpisodeMeta: Episode?
    private var episodesCache: [Int: [Episode]] = [:]
    /// Stream url -> episode-title verdict for the CURRENT episode's stream list
    /// (EpisodeMatch.swift): a release whose filename carries a DIFFERENT
    /// episode's title (off-by-one usenet numbering) is .mismatch and never
    /// auto-picked while a confirmed/unknown candidate exists. Empty for movies /
    /// missing episode data => every stream ranks UNKNOWN => zero behavior change.
    private var episodeVerdicts: [URL: EpisodeTitleVerdict] = [:]
    /// Consecutive failed re-judgments per season (see episodesFor): after the
    /// limit, [] is accepted as genuinely empty so binge advancement can skip
    /// the season (stale TMDB metadata) instead of stalling forever.
    private var seasonFetchFailures: [Int: Int] = [:]
    private static let seasonFetchFailureLimit = 3

    // MARK: playback bookkeeping

    private var currentStream: StreamOption?
    var playingStream: StreamOption? { currentStream }
    private var allResolvedStreams: [StreamOption] = []
    private var blockSubscription: AnyCancellable?
    private var hostStopped = false
    private var sourcePickerOpen = false
    /// Ranked alternatives, consumed head-first by bounded automatic failover.
    private var fallbackStreams: [StreamOption] = []
    private var lookaheadTask: Task<Void, Never>?
    private var lookaheadGeneration = 0
    /// URLs that failed to play this session — never handed back to the engine.
    private var failedStreamUrls = Set<URL>()
    /// Automatic failovers used this session (capped at maxAutoRetries).
    private var autoRetryCount = 0
    private var sourceEstablished = false
    private var preparedFallbackURL: URL?
    private var sameSourceRetryCount = 0
    private var sameSourceRetryUntilMs: Int64 = 0
    private var sameSourceRetryTask: Task<Void, Never>?
    private var sameSourceRetryID: UUID?
    private var healthyPlaybackMs: Int64 = 0
    private var healthySample: (time: Int64, position: Int64)?
    private var lastBingeGroup: String?
    private var pendingSeek: PendingSeek?
    private var lastKnownPositionMs: Int64 = 0
    private var lastKnownDurationMs: Int64 = 0
    private var markedWatched = false
    private var endedHandled = false
    /// Set when handleEnded definitively finished this title (movie ended, or
    /// the show's last episode ended) and REMOVED the Continue Watching row.
    /// Gates the dismiss-time saveProgressNow so it can't resurrect the row
    /// (VLC streams without a resolved length make the >=95% check unreachable).
    /// Cleared by play() — restarting/seeking out of ENDED resumes normal saves.
    private var sessionFinished = false
    /// After a user seek, the 500ms ticker must not overwrite `positionMs` with
    /// the engine's not-yet-updated position (VLC applies network-stream seeks
    /// asynchronously) — the scrubber would rubber-band back for up to ~1s.
    private var seekGrace: (deadline: Date, targetMs: Int64)?

    // MARK: up-next bookkeeping

    private var nextEpisode: Episode?
    private var nextResolved = false
    private var pendingNextEpisode: Episode?
    private var prefetchedStreams: PrefetchedStreams?
    private var upNextArming = false
    private var upNextCancelled = false
    private var upNextTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var swapping = false

    // MARK: tracks

    /// Name of the audio track the user picked this session; survives episode
    /// swaps (quality/language continuity while binging).
    private var sessionAudioLabel: String?
    private var audioPreparationTask: Task<Void, Never>?
    private var audioPreparationGeneration = 0
    private var audioPreparingTrackId: Int?
    private var compatibleAudioSlaves: [Int: Int] = [:]
    private var externalAudioTrackIds: Set<Int> = []
    /// Name of the subtitle track the user enabled; re-applied across swaps.
    /// nil = subtitles off (the default).
    private var subtitleDesiredLabel: String?

    // MARK: "What did they say?"

    /// Position playback must pass before the temporary subtitles turn back
    /// off; -1 = idle. Repeat presses keep the ORIGINAL restore point.
    private var replayRestoreAtMs: Int64 = -1
    /// Whether finishing the replay should switch subtitles back OFF (they
    /// were off when the replay started).
    private var replayTurnSubsOff = false

    // MARK: skip intro

    /// The current episode's intro marker from GET /segments; nil until known.
    private var introRange: ClosedRange<Int64>?
    /// The user tapped Skip (or the pill was dismissed) for THIS episode.
    private var introDismissed = false
    private var segmentsTask: Task<Void, Never>?
    private var throwNoticeTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var handoffClient: TVHandoffClient?
    private var handoffStreamBaseURL: String?
    private var handoffTarget: PlayTarget?
    private var handoffRequestID: String?
    private var handoffGeneration = 0
    private var handoffHoldsPlayback = false
    private var handoffProgressSuspended = false
    private var unresolvedHandoffCancellations: [String: TVHandoffClient] = [:]

    private var tornDown = false

    // One deadline owns both startup and mid-playback recovery; no stacked
    // reconnects to the same stalled release before trying another candidate.
    private var failoverWatchdog = StreamFailoverWatchdog()
    private var mediaGeneration: UInt64 = 0
    private var monotonicMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }
    private func resetStallDeadline() {
        failoverWatchdog.reset(nowMs: monotonicMs, generation: mediaGeneration,
            positionMs: engine.positionMs, durationMs: engine.durationMs, established: sourceEstablished)
    }

    // MARK: - Init

    init(target: PlayTarget,
         tmdb: TmdbRepository,
         streamRepo: StreamRepository,
         settings: SettingsStore,
         playback: PlaybackStore,
         companion: CompanionApi,
         queuePlayback: CategoryQueuePlayback? = nil,
         queuePrefetch: CategoryQueuePrefetch? = nil) {
        self.target = target
        self.tmdb = tmdb
        self.streamRepo = streamRepo
        self.settings = settings
        self.playback = playback
        self.companion = companion
        self.queuePlayback = queuePlayback
        self.queuePrefetch = queuePrefetch?.target == target ? queuePrefetch : nil
        if let prefetch = self.queuePrefetch { self.details = prefetch.details }
        self.hasNext = queuePlayback?.next != nil
        self.hasPrevious = queuePlayback?.previous != nil
        self.isShow = target.type == .show
        self.curSeason = target.season
        self.curEpisode = target.episode

        engine.onStateChanged = { [weak self] state in
            self?.handleEngineState(state)
        }
        engine.onTimeChanged = { [weak self] in
            self?.handleTimeChanged()
        }

        blockSubscription = settings.$blockedReleaseGroups.sink { [weak self] stored in
            guard let self, self.isShow, let id = self.imdbId else { return }
            self.applyBlockedGroups(stored[id] ?? [])
        }

        startTicker()
        load()
    }

    deinit {
        tickerTask?.cancel()
        upNextTask?.cancel()
        loadTask?.cancel()
        segmentsTask?.cancel()
        throwNoticeTask?.cancel()
        handoffTask?.cancel()
        lookaheadTask?.cancel()
        queueErrorTask?.cancel()
    }

    // =====================================================================================
    // Pipeline: identity -> streams -> play
    // =====================================================================================

    private func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.runLoad()
        }
    }

    private func runLoad() async {
        phase = .loading
        errorMessage = nil
        do {
            let d: MediaDetails
            if let existing = details {
                d = existing
            } else {
                d = try await tmdb.details(id: target.mediaId, type: target.type)
                details = d
            }
            // Stream key: the imdb id when TMDB knows it, else a `tmdb:<id>`
            // pseudo-id the backend resolves by TITLE. Day-one titles (Monster:
            // The Lizzie Borden Story aired 2 days before this was written) often
            // have NO imdb mapping anywhere yet — bailing here made them
            // unwatchable exactly during the week everyone wants them. The same
            // key flows to sticky-release-group, report_play, and intro segments,
            // so all per-title state stays consistent for these titles.
            if let realImdb = d.item.imdbId, !realImdb.isEmpty {
                imdbId = realImdb
            } else {
                imdbId = "tmdb:\(target.mediaId)"
            }
            backdropUrl = d.item.backdropUrl ?? d.item.posterUrl
            showTitle = d.item.title
            // Spec §2 (player side): settle the launch/foreground pull BEFORE
            // anything reads watch state — the episode resolution below scans
            // the watched set, so waiting only for computeResume() would still
            // pick the next-unwatched episode from a stale snapshot (the other
            // device just finished S2E4 → this one replays S2E4, and
            // computeResume then discards the freshly synced S2E5 row because
            // the identity no longer matches). Bounded wait; a no-op when sync
            // is off or already settled.
            if queuePlayback == nil { await playback.awaitSyncSettled() }
            guard !tornDown else { return }
            if target.type == .show {
                applyBlockedGroups(settings.blockedGroups(imdbId: imdbId))
                let (s, e) = await resolveEpisodeTarget(d)
                curSeason = s
                curEpisode = e
                let eps = (try? await episodesFor(season: s)) ?? []
                let ep = eps.first { $0.number == e }
                currentEpisodeMeta = ep
                episodeLabel = Self.formatEpisodeLabel(season: s, episode: e, title: ep?.title)
            }
            guard !tornDown else { return }
            pendingSeek = computeResume()
            startTelemetry()
            await startStreamsAndPlay()
            resolveNextEagerly()
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession surfaces task cancellation as URLError(.cancelled), not
            // CancellationError — a teardown-time cancel must not flash the
            // error UI (same handling as DetailsViewModel.load()).
            return
        } catch {
            showError("Couldn't load this title. Check your connection and try again.",
                      canChoose: !streams.isEmpty)
        }
    }

    /// For shows launched without a season/episode: first episode (scanning
    /// seasons in order, skipping season 0 specials) that is not in the watched
    /// set. Defaults to S1E1.
    private func resolveEpisodeTarget(_ d: MediaDetails) async -> (Int, Int) {
        let ts = target.season
        let te = target.episode
        if let ts, let te { return (ts, te) }
        let watched = Set(
            playback.watchedEpisodes(mediaId: target.mediaId)
                .map { SeasonEpisodeKey(season: $0.season, episode: $0.episode) }
        )
        var seasonNumbers = d.seasons.map(\.number).filter { $0 > 0 }.sorted()
        if let ts { seasonNumbers = seasonNumbers.filter { $0 == ts } }
        for sn in seasonNumbers {
            let eps = (try? await episodesFor(season: sn)) ?? []
            let hit = eps.sorted { $0.number < $1.number }
                .first { !watched.contains(SeasonEpisodeKey(season: sn, episode: $0.number)) }
            if let hit { return (sn, hit.number) }
        }
        return (ts ?? 1, te ?? 1)
    }

    private func computeResume() -> PendingSeek? {
        guard queuePlayback == nil else { return nil }
        guard let row = playback.progress(mediaId: target.mediaId, typeKey: target.type.rawValue) else {
            return nil
        }
        if target.type == .show && (row.season != curSeason || row.episode != curEpisode) {
            return nil
        }
        if row.positionMs < Self.resumeMinMs { return nil }
        if row.durationMs > 0 && row.positionMs >= row.durationMs * 95 / 100 { return nil }
        return PendingSeek(positionMs: row.positionMs, guardNearEnd: true)
    }

    /// Episode-title cross-check (EpisodeMatch.swift): classify every stream and
    /// stable-reorder — CONFIRMED first, UNKNOWN middle (incoming order
    /// preserved), MISMATCH last. Movies / missing episode data => input
    /// unchanged, empty map. Feed it the QUALITY-SORTED list so the verdict
    /// re-rank is applied on top of the quality order (quality sort first,
    /// verdict re-rank second — same contract as Android).
    private func applyEpisodeVerdicts(
        _ streams: [StreamOption], season: Int?, episode: Int?
    ) async -> ([StreamOption], [URL: EpisodeTitleVerdict]) {
        guard target.type == .show, let season, let episode else { return (streams, [:]) }
        let eps = ((try? await episodesFor(season: season)) ?? [])
            .map { EpisodeMatch.SeasonEpisodeRef(number: $0.number, title: $0.title) }
        guard !eps.isEmpty else { return (streams, [:]) }
        var verdicts: [URL: EpisodeTitleVerdict] = [:]
        for stream in streams {
            verdicts[stream.url] = EpisodeMatch.classify(
                filenameOrTitle: stream.title, requestedSeason: season,
                requestedEpisode: episode, seasonEpisodes: eps)
        }
        let ranked = streams.enumerated()
            .sorted { lhs, rhs in
                let l = verdicts[lhs.element.url]?.sortRank == 2 ? 1 : 0
                let r = verdicts[rhs.element.url]?.sortRank == 2 ? 1 : 0
                if l != r { return l < r }
                return lhs.offset < rhs.offset // stable, like StreamClient.sortStreams
            }
            .map(\.element)
        return (ranked, verdicts)
    }

    private func isMismatch(_ stream: StreamOption) -> Bool {
        if case .mismatch = episodeVerdicts[stream.url] { return true }
        return false
    }

    private func startStreamsAndPlay() async {
        guard let id = imdbId, !id.isEmpty else {
            showError("No stream source for this title.", canChoose: false)
            return
        }
        let season = curSeason
        let episode = curEpisode
        let found: [StreamOption]
        if let prefetch = queuePrefetch, prefetch.target == target, !prefetch.streams.isEmpty {
            found = prefetch.streams
            queuePrefetch = nil
        } else {
            found = await streamRepo.streams(imdbId: id, type: target.type,
                                            season: season, episode: episode)
        }
        // The screen may have been dismissed while the fetch was in flight —
        // starting playback now would stream audio with no UI.
        guard !tornDown, !Task.isCancelled, curSeason == season, curEpisode == episode else { return }
        if found.isEmpty {
            showError("No streams found from your sources. Check Settings → Stream Sources.",
                      canChoose: false)
            return
        }
        let prepared = await streamRepo.refreshStartupReadiness(found, waitForReady: true)
        let sorted = streamRepo.sortStreams(prepared, preferredQuality: settings.preferredQuality)
        let (ranked, verdicts) = await applyEpisodeVerdicts(sorted, season: season, episode: episode)
        guard !tornDown, !Task.isCancelled, curSeason == season, curEpisode == episode else { return }
        episodeVerdicts = verdicts
        allResolvedStreams = ranked
        streams = ranked.filter { !isBlocked($0) }
        playBest(from: streams)
    }

    /// Readiness/quality order with explicit release-group continuity.
    private func playBest(from candidates: [StreamOption], remainder: [StreamOption] = []) {
        let usable = candidates.filter { !failedStreamUrls.contains($0.url) && !isBlocked($0)
            && $0.startupReadiness?.status != "unavailable" }
        // Never auto-pick a release whose filename carries the WRONG episode's
        // title while any confirmed/unknown candidate exists. autoPick re-sorts
        // by quality (ordering alone can't demote a mismatch), so the MISMATCH
        // pool is filtered OUT of autoPick's input here. Mismatches stay in the
        // failover queue below — a wrong-titled file that plays still beats an
        // error screen — and this keeps bingeGroup continuity off the off-by-one
        // release chain (autoPick only ever sees the safe pool).
        let safe = usable.filter { !isMismatch($0) }
        let pool = streamRepo.sortStreams(safe.isEmpty ? usable : safe, preferredQuality: settings.preferredQuality)
        // Sticky release group (owner rule): a MANUAL pick in the stream picker
        // pinned this show to that release group. Honor the pin within the best
        // verified resolution so continuity never chooses a dead or lower-quality
        // release over a working one. `pool` is best-first. No match (episode missing
        // from the group, or its releases all failed) → fall through
        // SILENTLY to the session-continuity autoPick and best-quality: quality
        // beats loyalty for an episode the group can't serve, and the failover
        // below keeps walking the sorted list either way.
        let stickyPick: StreamOption? = {
            guard isShow, let id = imdbId,
                  let group = settings.stickyReleaseGroup(imdbId: id) else { return nil }
            let bestRank = pool.first?.startupReadiness?.rank ?? 1
            return pool.first { $0.bingeGroup == group && $0.quality == pool.first?.quality
                && ($0.startupReadiness?.rank ?? 1) == bestRank }
        }()
        guard let pick = stickyPick
            ?? streamRepo.autoPick(pool, preferredQuality: settings.preferredQuality,
                                   previousBingeGroup: lastBingeGroup)
            ?? pool.first else {
            showError("No playable streams are available. Try another stream or reset blocked releases in playback options.",
                      canChoose: true)
            return
        }
        var queue = usable.filter { $0.url != pick.url }
        var queued = Set(queue.map(\.url))
        queued.insert(pick.url)
        for candidate in remainder where !queued.contains(candidate.url)
            && !failedStreamUrls.contains(candidate.url) && !isBlocked(candidate)
            && candidate.startupReadiness?.status != "unavailable" {
            queued.insert(candidate.url)
            queue.append(candidate)
        }
        fallbackStreams = queue
        play(stream: pick)
    }

    private func play(stream: StreamOption, startPlaying: Bool? = nil, automatic: Bool = true) {
        // Never (re)start playback on a dismissed/replaced queue item.
        guard !tornDown, !queueTransitionStarted, !isBlocked(stream) else { return }
        handoffProgressSuspended = false
        cancelTvHandoff()
        sameSourceRetryTask?.cancel()
        sameSourceRetryTask = nil
        sameSourceRetryID = nil
        if currentStream?.url != stream.url {
            sourceEstablished = false; sameSourceRetryCount = 0; sameSourceRetryUntilMs = 0
        }
        healthyPlaybackMs = 0
        healthySample = nil
        mediaGeneration &+= 1
        queueErrorTask?.cancel()
        queueErrorTask = nil
        cancelAudioPreparation()
        compatibleAudioSlaves = [:]
        externalAudioTrackIds = []
        telemetry.sourcePrepared(stream.url, automatic: automatic)
        currentStream = stream
        if let group = stream.bingeGroup { lastBingeGroup = group }
        // Skip intro: tell the fingerprint worker what actually plays and start
        // watching for this episode's marker. Every play() path re-reports —
        // failover/stream-switch included — the worker keys per episode and
        // takes the latest URL (same as Android).
        if isShow { reportPlayAndWatchForIntro(stream) }
        let mediaURL = StreamLookahead.attributedMediaURL(stream.url, backend: settings.syncUrl, sessionId: telemetry.sessionId)
        engine.setMedia(url: mediaURL, headers: stream.headers,
                        hardwareDecoding: settings.hardwareDecoding)
        // Only now can the OLD item no longer emit ENDED — re-arming any earlier
        // (e.g. at the top of swapToEpisode) lets a late ENDED corrupt the new
        // episode's watched-state while streams are still being fetched.
        endedHandled = false
        sessionFinished = false
        seekGrace = nil
        let shouldStart = (startPlaying ?? !queueAutoAdvanceSuspended) && !hostStopped
        queueAutoAdvanceSuspended = !shouldStart
        if shouldStart { engine.play() }
        phase = .playing
        errorMessage = nil
        canChooseStream = false
        currentStreamUrl = stream.url
        resetStallDeadline()
        isBuffering = true
        subtitleAvailable = false
        subtitleLabel = nil
        subtitleOptions = []
        audioOptions = []
        startStreamLookahead(stream)
    }

    /// Keep a replacement release ready at the current time before the decoder
    /// reaches a missing article. Generation + exact URL/episode checks prevent
    /// a delayed health response from changing a manually selected/new episode.
    private func startStreamLookahead(_ stream: StreamOption) {
        preparedFallbackURL = nil
        sameSourceRetryTask?.cancel()
        sameSourceRetryTask = nil
        sameSourceRetryID = nil
        lookaheadTask?.cancel()
        lookaheadGeneration &+= 1
        guard StreamLookahead.belongsToBackend(stream.url, base: settings.syncUrl),
              let playbackSessionId = telemetry.sessionId else { return }
        let generation = lookaheadGeneration
        let season = curSeason
        let episode = curEpisode
        lookaheadTask = Task { [weak self] in
            var lastPrepareAt: TimeInterval = 0
            var requestedFraction: Double?
            var prepareTask: Task<Void, Never>?
            defer {
                prepareTask?.cancel()
                Task { await StreamLookahead.playback(stream, value: .init(sessionId: playbackSessionId,
                    generation: generation, positionMs: 0, durationMs: 0, playing: false, stopped: true)) }
            }
            while !Task.isCancelled {
                guard let self, !self.tornDown, self.lookaheadGeneration == generation,
                      self.currentStream?.url == stream.url,
                      self.curSeason == season, self.curEpisode == episode else { return }
                await StreamLookahead.playback(stream, value: .init(sessionId: playbackSessionId,
                    generation: generation, positionMs: max(self.pendingSeek?.positionMs ?? self.seekGrace?.targetMs ?? self.engine.positionMs, 0),
                    durationMs: max(self.engine.durationMs, 0),
                    playing: !self.queueAutoAdvanceSuspended && !self.hostStopped && !self.handoffHoldsPlayback
                        && !self.handoffProgressSuspended && !self.swapping && !self.queueTransitionStarted,
                    stopped: false))
                guard !Task.isCancelled, self.lookaheadGeneration == generation else { return }
                if self.phase == .playing, !self.queueAutoAdvanceSuspended, !self.hostStopped,
                   !self.swapping, !self.queueTransitionStarted, self.audioPreparationTask == nil,
                   !self.handoffHoldsPlayback, !self.handoffProgressSuspended,
                   self.pendingSeek == nil, self.seekGrace == nil {
                    let position = max(self.engine.positionMs, 0)
                    let duration = self.engine.durationMs
                    if duration > 0 && position < duration - 10_000 {
                        let now = ProcessInfo.processInfo.systemUptime
                        if requestedFraction == nil || now - lastPrepareAt >= 30 {
                            let fraction = min(max(Double(position) / Double(duration), 0), 0.999)
                            requestedFraction = fraction
                            lastPrepareAt = now
                            prepareTask?.cancel()
                            prepareTask = Task { await StreamLookahead.prepare(stream, fraction: fraction) }
                        }
                        // Preparation never blocks polling. A matching position rejects
                        // readiness from an older seek while its new request is in flight.
                        let health = await StreamLookahead.health(stream, sessionId: playbackSessionId)
                        guard !Task.isCancelled, !self.tornDown,
                              self.lookaheadGeneration == generation,
                              self.currentStream?.url == stream.url,
                              self.curSeason == season, self.curEpisode == episode else { return }
                        self.preparedFallbackURL = nil
                        if let recovery = health?.recovery, recovery.status == "ready",
                           let streamId = recovery.streamId,
                           let prepared = recovery.preparedFraction, prepared.isFinite,
                           let requestedFraction, abs(prepared - requestedFraction) < 0.002,
                           let candidate = self.streams.first(where: {
                               StreamLookahead.streamId($0.url) == streamId
                                   && StreamLookahead.isSibling($0.url, of: stream.url)
                                   && $0.url != stream.url && !self.failedStreamUrls.contains($0.url)
                                   && !self.isBlocked($0) && !self.isMismatch($0)
                           }) {
                            self.preparedFallbackURL = candidate.url
                            self.fallbackStreams.removeAll { $0.url == candidate.url }
                            self.fallbackStreams.insert(candidate, at: 0)
                            if health?.status == "incomplete", health?.exactRecovery?.holdsProactiveFallback != true, !self.queueAutoAdvanceSuspended,
                               !self.hostStopped, !self.handoffHoldsPlayback, !self.handoffProgressSuspended,
                               self.audioPreparationTask == nil, !self.swapping, !self.queueTransitionStarted,
                               self.pendingSeek == nil, self.seekGrace == nil,
                               self.autoRetryCount < Self.maxAutoRetries {
                                self.handlePlayerError()
                                return
                            }
                        }
                    }
                }
                do { try await Task.sleep(nanoseconds: self.isBuffering ? 1_000_000_000 : 3_000_000_000) }
                catch { return }
            }
        }
    }

    private func applyPendingSeekIfReady() {
        guard let seek = pendingSeek else { return }
        let dur = engine.durationMs
        guard dur > 0, engine.isPlayingNow else { return }
        pendingSeek = nil
        if seek.guardNearEnd && seek.positionMs >= dur * 95 / 100 { return }
        engine.seek(toMs: max(seek.positionMs, 0), durationMs: dur)
        telemetry.seekDispatched()
        positionMs = max(seek.positionMs, 0)
        beginSeekGrace(targetMs: positionMs)
    }

    /// Trust the requested position in the UI until the engine catches up
    /// (or ~1.5s passes) — VLC applies network-stream seeks asynchronously.
    private func beginSeekGrace(targetMs: Int64) {
        seekGrace = (deadline: Date().addingTimeInterval(1.5), targetMs: targetMs)
        resetStallDeadline()
        if let stream = currentStream { startStreamLookahead(stream) }
    }

    private func showError(_ message: String, canChoose: Bool) {
        guard !tornDown, !queueTransitionStarted else { return }
        upNextTask?.cancel()
        sameSourceRetryTask?.cancel()
        sameSourceRetryTask = nil
        sameSourceRetryID = nil
        lookaheadTask?.cancel()
        lookaheadGeneration &+= 1
        cancelAudioPreparation()
        engine.stopPlayback()
        resetStallDeadline()
        phase = .error
        errorMessage = message
        // Block management remains available even when a fresh source lookup
        // returns nothing; an outage must not hide the user's saved exclusions.
        canChooseStream = (canChoose && !streams.isEmpty) || !blockedGroups.isEmpty
        isBuffering = false
        upNext = .hidden
        scheduleUnavailableQueueItem()
    }

    /// Give a transient lookup failure a second attempt; decoder errors already
    /// walked the normal fallback budget. Stop visibly on the third unavailable
    /// queue item instead of turning a service outage into an endless loop.
    private func scheduleUnavailableQueueItem() {
        guard let queuePlayback, queueErrorTask == nil, !queueTransitionStarted,
              !queueAutoAdvanceSuspended, !sourcePickerOpen else { return }
        if currentStream == nil && !queueInitialRetryUsed {
            queueInitialRetryUsed = true
            errorMessage = "Couldn't load this item. Retrying…"
            queueErrorTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, !self.tornDown else { return }
                self.queueErrorTask = nil
                self.load()
            }
            return
        }
        guard queuePlayback.next != nil else { return }
        guard queuePlayback.canAutoSkipUnavailable || queuePlaybackHealthy else {
            errorMessage = "Three items in a row couldn't play. Retry this item or skip to the next one."
            return
        }
        errorMessage = "This item couldn't play. Skipping to the next item…"
        queueErrorTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, !self.tornDown, self.phase == .error else { return }
            self.queueErrorTask = nil
            self.advanceQueue(.unavailable)
        }
    }

    private func advanceQueue(_ reason: CategoryQueueAdvance) {
        guard queuePlayback != nil, !queueTransitionStarted, !tornDown else { return }
        queueTransitionStarted = true
        endedHandled = true
        queueErrorTask?.cancel()
        upNextTask?.cancel()
        // Category playback is a separate channel, never a watch-history write.
        engine.pause()
        queueAdvanceRequested = reason
    }

    /// VLC `.error` — spec §3c. Blacklist the dead URL and continue in THIS
    /// player session on the next healthy candidate, resuming at the last known
    /// position (same identity, same profile, no navigation, no re-resolution).
    /// The error screen appears only once the fallback list is exhausted or the
    /// established-playback recovery burst is exhausted. Unstarted candidates
    /// do not consume that budget; each distinct URL is tried at most once.
    private func handlePlayerError(allowInPlaceRetry: Bool = true) {
        guard !tornDown, !queueTransitionStarted, !hostStopped,
              !handoffHoldsPlayback, !handoffProgressSuspended else { return }
        // A late `.error` from the OLD media while swapToEpisode is in flight
        // (fallbackStreams already cleared, new streams still resolving) would
        // otherwise take the terminal branch and flash the error screen over the
        // swap. Same guard as handleEnded — the incoming episode's own
        // startStreamsAndPlay owns the outcome for this window.
        if swapping { return }
        if sameSourceRetryTask != nil { return }
        // VLC does not expose reliable HTTP status codes. Probe the original
        // backend resource before giving an established stream a bounded retry.
        // Known missing data still advances directly to another release.
        if allowInPlaceRetry, sourceEstablished, sameSourceRetryCount < 2,
           let stream = currentStream, StreamLookahead.belongsToBackend(stream.url, base: settings.syncUrl),
           sameSourceRetryUntilMs == 0 || monotonicMs < sameSourceRetryUntilMs {
            if sameSourceRetryUntilMs == 0 { sameSourceRetryUntilMs = monotonicMs + 15_000 }
            sameSourceRetryCount += 1
            let attempt = sameSourceRetryCount
            let retryID = UUID()
            sameSourceRetryID = retryID
            let generation = mediaGeneration
            let position = pendingSeek?.positionMs ?? seekGrace?.targetMs ?? max(engine.positionMs, lastKnownPositionMs)
            sameSourceRetryTask = Task { [weak self] in
                let health = await StreamLookahead.health(stream)
                try? await Task.sleep(nanoseconds: attempt == 1 ? 250_000_000 : 750_000_000)
                guard let self, self.sameSourceRetryID == retryID else { return }
                self.sameSourceRetryTask = nil
                self.sameSourceRetryID = nil
                guard !Task.isCancelled, !self.tornDown, self.mediaGeneration == generation,
                      self.currentStream?.url == stream.url, !self.hostStopped, !self.queueTransitionStarted else { return }
                guard health?.status != "incomplete", self.monotonicMs < self.sameSourceRetryUntilMs else {
                    self.handlePlayerError(allowInPlaceRetry: false); return
                }
                if position > 1_000 { self.pendingSeek = PendingSeek(positionMs: position, guardNearEnd: false) }
                self.play(stream: stream, startPlaying: !self.queueAutoAdvanceSuspended)
            }
            return
        }
        telemetry.error()
        let preparedURL = sourceEstablished ? preparedFallbackURL : nil
        let pos = pendingSeek?.positionMs ?? seekGrace?.targetMs ?? engine.positionMs
        if pos > 0 { lastKnownPositionMs = pos }
        if let failed = currentStream {
            failedStreamUrls.insert(failed.url)
            fallbackStreams.removeAll { $0.url == failed.url }
        }
        // Revisit the full manual list: a source that was temporarily unavailable
        // at startup may now be ready. Actual failed URLs remain blacklisted.
        var seen = Set<URL>()
        fallbackStreams = (allResolvedStreams + fallbackStreams).filter {
            !failedStreamUrls.contains($0.url) && !isBlocked($0) && seen.insert($0.url).inserted
        }
        if StreamStartupSelection.canAdvance(established: sourceEstablished, attempts: autoRetryCount,
                                             remaining: fallbackStreams.count, maximum: Self.maxAutoRetries) {
            if sourceEstablished { autoRetryCount += 1 }
            failoverNotice = true
            let generation = mediaGeneration
            let retryID = UUID()
            sameSourceRetryID = retryID
            let candidates = fallbackStreams
            sameSourceRetryTask = Task { [weak self] in
                guard let self else { return }
                let refreshed = await self.streamRepo.refreshStartupReadiness(candidates, waitForReady: false)
                guard self.sameSourceRetryID == retryID else { return }
                self.sameSourceRetryTask = nil
                self.sameSourceRetryID = nil
                guard !Task.isCancelled, !self.tornDown, self.mediaGeneration == generation,
                      !self.hostStopped, !self.queueTransitionStarted, !self.handoffHoldsPlayback,
                      !self.handoffProgressSuspended else { return }
                let sorted = self.streamRepo.sortStreams(refreshed, preferredQuality: self.settings.preferredQuality)
                let safe = sorted.filter { !self.isMismatch($0) }
                self.fallbackStreams = (safe + sorted.filter { self.isMismatch($0) }).filter {
                    !self.failedStreamUrls.contains($0.url) && !self.isBlocked($0)
                        && $0.startupReadiness?.status != "unavailable"
                }
                // A current-position lookahead preparation is stronger than a
                // generic head/tail startup hint during an established stream.
                if let preparedURL, let index = self.fallbackStreams.firstIndex(where: {
                    $0.url == preparedURL && !self.isMismatch($0)
                }) {
                    let prepared = self.fallbackStreams.remove(at: index)
                    self.fallbackStreams.insert(prepared, at: 0)
                }
                guard !self.fallbackStreams.isEmpty else { self.showExhaustedStreamsError(); return }
                let next = self.fallbackStreams.removeFirst()
                if self.lastKnownPositionMs > 1_000 {
                    self.pendingSeek = PendingSeek(positionMs: self.lastKnownPositionMs, guardNearEnd: false)
                }
                self.endedHandled = false
                self.play(stream: next, startPlaying: !self.queueAutoAdvanceSuspended)
            }
            return
        }
        showExhaustedStreamsError()
    }

    private func showExhaustedStreamsError() {
        failoverNotice = false
        showError("This stream wouldn't play. Try again or choose a different stream.",
                  canChoose: true)
        let dur = lastKnownDurationMs
        let p = lastKnownPositionMs
        let season = curSeason
        let episode = curEpisode
        let meta = currentEpisodeMeta
        // Strong capture on purpose: like the Android persistScope, the final
        // write must land even if the screen (and thus the VM's last external
        // reference) goes away first. The task ends, then releases self.
        Task {
            await self.persistProgress(positionMs: p, durationMs: dur,
                                       season: season, episode: episode, episodeMeta: meta)
        }
    }

    // =====================================================================================
    // Engine events
    // =====================================================================================

    private func handleEngineState(_ state: VLCMediaPlayerState) {
        defer { telemetry.observe() }
        switch state {
        case .opening, .buffering:
            isBuffering = true
        case .playing:
            isBuffering = false
            isPlaying = true
            // Playback resumed — the failover indicator has done its job.
            if failoverNotice { failoverNotice = false }
            // Position advancement, rather than a VLC state claim, proves the
            // stream is healthy; repeated state events cannot extend its deadline.
            applyPendingSeekIfReady()
            refreshTracks()
        case .paused:
            isPlaying = false
            isBuffering = audioPreparationTask != nil
            resetStallDeadline()
        case .stopped:
            isPlaying = false
            // Defensive terminal handling: a stop while we think we're playing
            // (server killed the stream) must not strand the buffering spinner.
            isBuffering = false
        case .ended:
            isBuffering = false
            isPlaying = false
            handleEnded()
        case .error:
            handlePlayerError()
        case .esAdded:
            refreshTracks()
        @unknown default:
            break
        }
    }

    private func handleTimeChanged() {
        guard phase == .playing else { return }
        // Time advancing is the definitive "buffering is over" signal in VLC 3.x
        // (the buffering state has no explicit "done" counterpart event).
        if isBuffering { isBuffering = false }
        if failoverNotice { failoverNotice = false }
        if !isPlaying && engine.isPlayingNow { isPlaying = true }
        // Real advancement is the proof the input is alive; it clears any wedge
        // bookkeeping and feeds the reconnect target position.
        if queuePlayback != nil && !queuePlaybackHealthy {
            let current = engine.positionMs
            let delta = current - queuePreviousPositionMs
            queuePreviousPositionMs = current
            if engine.isPlayingNow && delta > 0 && delta <= 2_000 { queueHealthyMilliseconds += delta }
            if queueHealthyMilliseconds >= 5_000 { queuePlaybackHealthy = true }
        }
        applyPendingSeekIfReady()
    }

    // =====================================================================================
    // Public controls API
    // =====================================================================================

    func togglePlayPause() {
        hostStopped = false
        handoffProgressSuspended = false
        cancelTvHandoff()
        if audioPreparationTask != nil {
            // A Play/Pause tap while sound is being prepared changes intent;
            // do not resume the silent decoder while the request is pending.
            queueAutoAdvanceSuspended.toggle()
            if queueAutoAdvanceSuspended { engine.pause() }
            return
        }
        if engine.isPlayingNow {
            pause()
        } else {
            queueAutoAdvanceSuspended = false
            resetStallDeadline()
            if let stream = currentStream { startStreamLookahead(stream) }
            engine.play()
        }
    }

    func pause() {
        cancelTvHandoff()
        queueAutoAdvanceSuspended = true
        queueErrorTask?.cancel()
        queueErrorTask = nil
        engine.pause()
        resetStallDeadline()
        saveProgressNow()
    }

    func seek(toMs requested: Int64) {
        handoffProgressSuspended = false
        cancelTvHandoff()
        let state = engine.stateNow
        // .ended AND .stopped are both dead states VLC cannot seek (a stream
        // stopped server-side, or an ENDED coalesced into stopped): engine.seek
        // would silently no-op on the input-less player while the scrubber
        // showed a seek that never happened.
        let isDead = state == .ended || state == .stopped
        let dur: Int64? = durationMs > 0 ? durationMs : nil
        let clamped = min(max(requested, 0), dur ?? Int64.max)
        telemetry.seek(to: clamped)
        if isDead {
            // VLC cannot seek a stopped/ended item — restart the current stream
            // at the target position (play() resets endedHandled).
            guard let stream = currentStream else { return }
            pendingSeek = PendingSeek(positionMs: clamped, guardNearEnd: false)
            if case .endChoice = upNext { upNext = .hidden }
            play(stream: stream)
            positionMs = clamped
            beginSeekGrace(targetMs: clamped)
            return
        }
        engine.seek(toMs: clamped, durationMs: durationMs)
        telemetry.seekDispatched()
        // Seeking out of the credits zone: let the episode end "again" later,
        // and drop a stale EndChoice card.
        if let dur, clamped < dur * 95 / 100 {
            endedHandled = false
            if case .endChoice = upNext { upNext = .hidden }
        }
        positionMs = clamped
        beginSeekGrace(targetMs: clamped)
    }

    func seekBy(_ deltaMs: Int64) {
        // Use the published, seek-grace-aware position, not the engine's raw one:
        // during VLC's async seek window engine.positionMs is stale, so two quick
        // +10s taps would land at +10 instead of +20. `positionMs` compounds.
        seek(toMs: positionMs + deltaMs)
    }

    /// "What did they say?" — jump back 15s with subtitles temporarily on; they
    /// turn back off on their own once playback passes the point where the
    /// button was pressed. Pressing again mid-replay rewinds further but keeps
    /// the ORIGINAL restore point. If subtitles were already on, this is just a
    /// 15s replay.
    func replayWithSubtitles() {
        let pos = positionMs
        if replayRestoreAtMs < 0 { replayTurnSubsOff = subtitleDesiredLabel == nil }
        replayRestoreAtMs = max(replayRestoreAtMs, pos)
        let subs = engine.subtitleTracks
        if subtitleDesiredLabel == nil, !subs.isEmpty {
            // Prefer the first track whose name suggests English, else the first
            // — the same auto-pick the Android replay makes. Deliberately NOT
            // the public selectSubtitleTrack(id:): that path cancels the very
            // auto-restore this replay depends on.
            let pick = subs.first { Self.looksEnglish($0.name) } ?? subs[0]
            subtitleDesiredLabel = pick.name
            engine.selectSubtitleTrack(id: pick.id)
            subtitleLabel = pick.name
            rebuildTrackOptions()
        }
        replayActive = true
        seek(toMs: max(pos - Self.replayBackMs, 0))
    }

    /// Skip Intro pill pressed: land just past the intro's end.
    func skipIntro() {
        guard let intro = introRange else { return }
        introDismissed = true
        skipIntroVisible = false
        seek(toMs: intro.upperBound)
    }

    /// Category queues retain their no-history semantics and stay local.
    var canThrowToTv: Bool { queuePlayback == nil && companion.isEnabled && currentStream != nil && phase == .playing }

    private var handoffIdentity: PlayTarget {
        PlayTarget(mediaId: target.mediaId, type: target.type, season: curSeason, episode: curEpisode)
    }

    func throwToTv() {
        guard canThrowToTv, !handoffInProgress, let client = companion.handoffClient() else { return }
        cancelTvHandoff()
        let generation = handoffGeneration
        let identity = handoffIdentity
        handoffTarget = identity
        handoffClient = client
        handoffInProgress = true
        showThrowNotice(.searching)
        handoffTask = Task { [weak self] in
            do {
                let discovery = try await client.discover()
                guard let self, !self.tornDown, self.handoffGeneration == generation else { return }
                guard self.handoffIdentity == identity, self.phase == .playing,
                      !self.swapping, !self.endedHandled else {
                    self.cancelTvHandoff()
                    return
                }
                // Media and companion APIs can use the same server through
                // different public/LAN addresses. Trust only the canonical
                // media base published by this captured backend.
                guard let stream = self.currentStream,
                      TVHandoffSource.streamId(url: stream.url, backendURL: client.baseURL,
                        advertisedStreamBaseURL: discovery.streamBaseURL, headers: stream.headers) != nil else {
                    throw TVHandoffError.exactSourceUnsupported
                }
                self.handoffStreamBaseURL = discovery.streamBaseURL
                let receivers = discovery.available
                if receivers.isEmpty { throw TVHandoffError.noReceiver }
                if receivers.count == 1 { self.sendToTv(receivers[0]) }
                else {
                    self.tvReceivers = receivers
                    self.throwToTvNotice = nil
                }
            } catch {
                guard let self, !Task.isCancelled, self.handoffGeneration == generation else { return }
                self.finishHandoff(.failed(error.localizedDescription))
            }
        }
    }

    func sendToTv(_ receiver: TVHandoffReceiver) {
        guard handoffInProgress, let client = handoffClient, !tornDown,
              let stream = currentStream else { return }
        // ENDED can advance episode identity before async resolution replaces
        // the old media. A picker opened for that old episode must not combine
        // its stream/position with the new episode's metadata.
        guard handoffTarget == handoffIdentity, phase == .playing, !swapping, !endedHandled else {
            cancelTvHandoff()
            return
        }
        guard let streamId = TVHandoffSource.streamId(url: stream.url, backendURL: client.baseURL,
            advertisedStreamBaseURL: handoffStreamBaseURL, headers: stream.headers) else {
            finishHandoff(.failed(TVHandoffError.exactSourceUnsupported.localizedDescription))
            return
        }
        tvReceivers = []
        let generation = handoffGeneration
        let identity = handoffIdentity
        // Sound preparation pauses the engine internally while preserving the
        // user's Play intent. A failed transfer must restore that intent too.
        let wasPlaying = engine.isPlayingNow || isPlaying
            || (audioPreparationTask != nil && !queueAutoAdvanceSuspended)
        let previousProgressSuspended = handoffProgressSuspended
        // Freeze before any network await. This exact position is authoritative
        // on the TV, including positions under 30 seconds and near the credits.
        let frozenPosition = max(0, seekGrace?.targetMs ?? pendingSeek?.positionMs
            ?? (engine.positionMs >= 0 ? engine.positionMs : lastKnownPositionMs))
        handoffHoldsPlayback = true
        upNextTask?.cancel()
        upNextArming = false
        upNext = .hidden
        engine.pause()
        resetStallDeadline()
        // Persist one synchronous snapshot, without near-end promotion. Later
        // phone saves must not overwrite progress owned by the receiving TV.
        handoffProgressSuspended = false
        upsertRow(season: identity.season, episode: identity.episode,
            episodeTitle: currentEpisodeMeta?.title, positionMs: frozenPosition,
            durationMs: max(engine.durationMs, lastKnownDurationMs), still: currentEpisodeMeta?.stillUrl)
        playback.flushSyncNow()
        handoffProgressSuspended = true
        let requestID = UUID().uuidString
        handoffRequestID = requestID
        let request = TVHandoffRequest(requestId: requestID,
            targetDeviceId: receiver.deviceId, targetSessionId: receiver.sessionId,
            profileId: playback.activeProfileId(), mediaId: identity.mediaId,
            type: identity.type.rawValue, season: identity.season, episode: identity.episode,
            positionMs: frozenPosition, title: String(showTitle.prefix(500)),
            sourceHint: .init(streamId: streamId, title: String(stream.title.prefix(500)),
                sourceName: String(stream.sourceName.prefix(100)),
                bingeGroup: stream.bingeGroup.map { String($0.prefix(100)) }))
        showThrowNotice(.starting(receiver.name))
        handoffTask = Task { [weak self] in
            let terminal = try? await client.deliver(request)
            guard let self, !Task.isCancelled, !self.tornDown,
                  self.handoffGeneration == generation, self.handoffIdentity == identity else { return }
            if terminal?.state == .started {
                self.finishHandoff(.sent(terminal?.targetName ?? receiver.name))
            } else if let terminal, terminal.isTerminal {
                self.handoffProgressSuspended = previousProgressSuspended
                let reason = terminal.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = reason?.isEmpty == false ? String(reason!.prefix(300)) : "Couldn't start on \(receiver.name)."
                self.finishHandoff(.failed(message + " " + (wasPlaying ? "Continuing here." : "Your phone is still paused.")))
                // If sound is still being prepared, clearing the handoff hold
                // lets that task resume only once audio is ready.
                if wasPlaying && UIApplication.shared.applicationState == .active,
                   self.phase == .playing, self.currentStream?.url == stream.url,
                   self.audioPreparationTask == nil {
                    self.resetStallDeadline()
                    self.engine.play()
                }
            } else {
                // Do not pretend a lost acknowledgement means the TV never
                // started. A deliberate Play tap can continue locally.
                self.finishHandoff(.uncertain)
            }
        }
    }

    func cancelTvHandoff() {
        handoffHoldsPlayback = false
        handoffGeneration += 1
        handoffTask?.cancel()
        handoffTask = nil
        if let id = handoffRequestID, let client = handoffClient {
            unresolvedHandoffCancellations[id] = client
        }
        for (id, client) in unresolvedHandoffCancellations {
            Task { [weak self] in
                if let result = try? await client.cancel(id: id), result.isTerminal {
                    self?.unresolvedHandoffCancellations.removeValue(forKey: id)
                }
            }
        }
        handoffRequestID = nil
        handoffClient = nil
        handoffStreamBaseURL = nil
        handoffTarget = nil
        handoffInProgress = false
        tvReceivers = []
        if throwToTvNotice?.isPending == true { throwToTvNotice = nil }
    }

    private func finishHandoff(_ notice: ThrowToTvNotice) {
        if case .failed = notice { handoffHoldsPlayback = false }
        handoffTask = nil
        if notice != .uncertain {
            handoffClient = nil
            handoffStreamBaseURL = nil
            handoffTarget = nil
            handoffRequestID = nil
        }
        handoffInProgress = false
        tvReceivers = []
        showThrowNotice(notice)
    }

    private func showThrowNotice(_ notice: ThrowToTvNotice) {
        throwNoticeTask?.cancel()
        throwToTvNotice = notice
        guard !notice.isPending else { return }
        throwNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: notice.isSuccess ? 4_000_000_000 : 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.throwToTvNotice = nil
        }
    }

    /// User-driven retry: re-arm the automatic failover budget (the cap exists
    /// to stop silent loops, not to punish a deliberate retry) and replay the
    /// stream that failed — if it fails again the failover takes over.
    func retry() {
        hostStopped = false
        queueAutoAdvanceSuspended = false
        queueErrorTask?.cancel()
        queueErrorTask = nil
        queueInitialRetryUsed = false
        endedHandled = false
        autoRetryCount = 0
        sameSourceRetryCount = 0; sameSourceRetryUntilMs = 0
        failoverNotice = false
        if let stream = currentStream, !isBlocked(stream) {
            failedStreamUrls.remove(stream.url)
            if lastKnownPositionMs > 1_000 {
                pendingSeek = PendingSeek(positionMs: lastKnownPositionMs, guardNearEnd: false)
            }
            play(stream: stream)
        } else {
            load()
        }
    }

    /// Switch streams, preserving the current position.
    func switchStream(_ option: StreamOption) {
        guard !isBlocked(option) else { return }
        hostStopped = false
        prefetchedStreams = nil
        if option.url == currentStream?.url && phase == .playing { return }
        // A MANUAL pick from the stream picker is a verdict on the release
        // chain, not just this file — the autopicked group had issues, so pin
        // this show to the picked group for every later episode (playBest reads
        // it back). Series only: movies have no "next episode" to stay loyal
        // for. A pick with no bingeGroup pins nothing — there is no group to
        // stay with, and clearing the previous pin would forget a valid verdict.
        if isShow, let id = imdbId, let group = option.bingeGroup,
           !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.setStickyReleaseGroup(imdbId: id, bingeGroup: group)
        }
        let cur = engine.positionMs
        let pos = cur > 0 ? cur : lastKnownPositionMs
        if pos > 1_000 {
            pendingSeek = PendingSeek(positionMs: pos, guardNearEnd: false)
        }
        // An explicit pick supersedes the automatic queue: don't hand the same
        // stream back as a "fallback", and restore the retry budget.
        fallbackStreams.removeAll { $0.url == option.url }
        failedStreamUrls.remove(option.url)
        autoRetryCount = 0
        failoverNotice = false
        endedHandled = false
        play(stream: option, automatic: false)
    }

    private func isBlocked(_ stream: StreamOption) -> Bool {
        isShow && stream.isReleaseGroupBlocked(blockedGroups)
    }

    private func applyBlockedGroups(_ groups: [ReleaseGroup]) {
        if groups != blockedGroups { prefetchedStreams = nil }
        blockedGroups = groups
        streams = allResolvedStreams.filter { !isBlocked($0) }
        fallbackStreams.removeAll { isBlocked($0) }
    }

    func blockReleaseGroup(_ option: StreamOption) {
        guard isShow, let id = imdbId, let group = option.releaseGroupForBlocking() else { return }
        guard settings.blockReleaseGroup(imdbId: id, group: group) else {
            groupActionError = "Couldn't save the blocked group. Try again."
            return
        }
        applyBlockedGroups(settings.blockedGroups(imdbId: id))
        groupActionError = nil
        if lastBingeGroup == group.key { lastBingeGroup = nil }
        guard let currentStream, isBlocked(currentStream) else { return }
        let position = pendingSeek?.positionMs ?? seekGrace?.targetMs
            ?? (engine.positionMs > 0 ? engine.positionMs : lastKnownPositionMs)
        if position > 1_000 { pendingSeek = PendingSeek(positionMs: position, guardNearEnd: false) }
        let allowed = streams.filter { !failedStreamUrls.contains($0.url) }
        guard let next = allowed.first else {
            saveProgressNow()
            showError("This release is blocked for this show. Choose another stream or reset blocked releases in playback options.", canChoose: true)
            return
        }
        fallbackStreams = allowed.filter { $0.url != next.url }
        failoverNotice = true
        play(stream: next, startPlaying: !queueAutoAdvanceSuspended)
    }

    func unblockReleaseGroup(_ key: String) {
        guard isShow, let id = imdbId else { return }
        guard settings.unblockReleaseGroup(imdbId: id, groupKey: key) else {
            groupActionError = "Couldn't unblock that group. Try again."
            return
        }
        applyBlockedGroups(settings.blockedGroups(imdbId: id))
        fallbackStreams = streams.filter { $0.url != currentStream?.url && !failedStreamUrls.contains($0.url) }
        groupActionError = nil
    }

    func setSourcePickerOpen(_ open: Bool) {
        sourcePickerOpen = open
        if open { queueErrorTask?.cancel(); queueErrorTask = nil }
    }

    private func resolvePreviousEpisode() async -> Episode? {
        guard isShow, let season = curSeason, let episode = curEpisode else { return nil }
        return try? await findPreviousEpisode(season: season, episode: episode,
            seasonNumbers: details?.seasons.map(\.number) ?? [],
            episodesFor: { try await self.episodesFor(season: $0) })
    }

    func playPreviousEpisode() {
        guard !tornDown, !swapping, !queueTransitionStarted else { return }
        upNextTask?.cancel()
        upNextCancelled = true
        upNextArming = false
        upNext = .hidden
        handoffProgressSuspended = false
        cancelTvHandoff()
        if queuePlayback != nil {
            if hasPrevious { advanceQueue(.previous) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let season = self.curSeason, episode = self.curEpisode
            guard let previous = await self.resolvePreviousEpisode(), !self.tornDown,
                  self.curSeason == season, self.curEpisode == episode else { return }
            await self.swapToEpisode(previous, markCurrentWatched: false)
        }
    }

    /// Apply a subtitle pick from the picker sheet. `id` is the VLC track id;
    /// -1 = off.
    func selectSubtitleTrack(id: Int) {
        // An explicit pick outlives any pending "What did they say?" auto-restore.
        cancelReplay()
        if id < 0 {
            subtitleDesiredLabel = nil
            engine.selectSubtitleTrack(id: -1)
            subtitleLabel = nil
        } else if let track = engine.subtitleTracks.first(where: { $0.id == id }) {
            subtitleDesiredLabel = track.name
            engine.selectSubtitleTrack(id: id)
            subtitleLabel = track.name
        }
        rebuildTrackOptions()
    }

    /// Apply an audio pick: select the track now, and remember its name for the
    /// rest of the session so the choice survives episode swaps (where VLC track
    /// ids no longer match).
    func selectAudioTrack(id: Int) {
        guard let track = engine.audioTracks.first(where: { $0.id == id }) else { return }
        sessionAudioLabel = track.name
        if engine.hasCompatibleAudio, let stream = currentStream {
            // Replacing the same media also removes VLC's previous slave input,
            // so a different/native soundtrack does not keep decoding old audio
            // in the background. Keep the original release and exact position.
            let shouldResume = !queueAutoAdvanceSuspended && !handoffHoldsPlayback && !handoffProgressSuspended
            let position = seekGrace?.targetMs ?? pendingSeek?.positionMs
                ?? (engine.positionMs >= 0 ? engine.positionMs : lastKnownPositionMs)
            pendingSeek = PendingSeek(positionMs: position, guardNearEnd: false)
            play(stream: stream, startPlaying: shouldResume)
        } else {
            selectPlayableAudio(track)
        }
        rebuildTrackOptions()
    }

    /// Play the next episode now (controls button, Up Next "Play now", countdown end).
    func playNextEpisode() {
        handoffProgressSuspended = false
        cancelTvHandoff()
        if queuePlayback != nil {
            guard hasNext else { return }
            advanceQueue(.manual)
            return
        }
        Task { [weak self] in
            guard let self, !self.tornDown else { return }
            let next: Episode
            if let pending = self.pendingNextEpisode {
                next = pending
            } else if let resolved = await self.awaitNextEpisode() {
                next = resolved
            } else {
                return
            }
            await self.swapToEpisode(next)
        }
    }

    /// "Watch credits": cancel the countdown; the choice card returns at ENDED.
    func watchCredits() {
        upNextTask?.cancel()
        upNextCancelled = true
        upNextArming = false
        upNext = .hidden
    }

    /// Pause + persist when the scene goes to the background. Flushes the push
    /// immediately — this is the write the TV is about to read (spec §2).
    func onHostResume() {
        hostStopped = false
        resetStallDeadline()
    }

    func onHostStop() {
        hostStopped = true
        telemetry.observe(force: true)
        sameSourceRetryTask?.cancel()
        sameSourceRetryTask = nil
        sameSourceRetryID = nil
        lookaheadTask?.cancel()
        lookaheadGeneration &+= 1
        cancelTvHandoff()
        queueAutoAdvanceSuspended = true
        queueErrorTask?.cancel()
        queueErrorTask = nil
        engine.pause()
        // Keep the EARLIEST pause timestamp so pause -> background -> long wait
        // -> resume still measures the full pause and reconnects proactively.
        resetStallDeadline()
        saveProgressNow(flushSync: true)
    }

    /// Snapshot position AND episode identity synchronously, persist async —
    /// a concurrent swapToEpisode must never re-attribute the old episode's
    /// position to the new episode. Safe to call anytime.
    ///
    /// `flushSync` (dismiss / exit / background) pushes the row the moment it
    /// lands instead of waiting out the 1.5s debounce: that write is the one
    /// the cross-device hand-off depends on, and iOS may suspend us right after.
    func saveProgressNow(flushSync: Bool = false) {
        // Queues must not add, update, remove or sync normal Continue Watching.
        guard queuePlayback == nil, !handoffProgressSuspended else { return }
        // handleEnded already finished this title and REMOVED the Continue
        // Watching row — a dismiss-time save here would upsert it right back
        // (durations VLC never resolved make the >=95% check unreachable).
        guard !sessionFinished else {
            // The tombstone still needs to reach the server promptly.
            if flushSync { playback.flushSyncNow() }
            return
        }
        let cur = engine.positionMs
        let pos = cur > 0 ? cur : lastKnownPositionMs
        let curDur = engine.durationMs
        let dur = curDur > 0 ? curDur : lastKnownDurationMs
        let season = curSeason
        let episode = curEpisode
        let meta = currentEpisodeMeta
        // Take the background-task assertion SYNCHRONOUSLY, here — not inside
        // flushNow() at the end. persistProgress suspends (a >=95% show save
        // round-trips TMDB for the next episode), and on the scenePhase →
        // background path iOS can suspend us during that await: without the
        // assertion neither the local row nor the push lands, which is exactly
        // the phone → TV hand-off failure spec §2 exists to prevent.
        let flushToken = flushSync ? playback.beginSyncFlushWindow() : nil
        // Strong capture on purpose (the Android persistScope survives
        // onCleared for the same reason): the dismiss-time write must land even
        // after the screen drops its reference. The task ends, releases self.
        Task {
            await self.persistProgress(positionMs: pos, durationMs: dur,
                                       season: season, episode: episode, episodeMeta: meta)
            if flushSync {
                self.playback.flushSyncNow()
                // flushNow() has taken its own reference by now, so releasing
                // ours can never drop the assertion out from under the push.
                self.playback.endSyncFlushWindow(flushToken)
            }
        }
    }

    /// Final save + stop everything. Idempotent; called from the view's
    /// onDisappear so the last progress write always lands.
    func teardown() {
        guard !tornDown else { return }
        telemetry.end()
        tornDown = true
        cancelAudioPreparation()
        cancelTvHandoff()
        queueErrorTask?.cancel()
        sameSourceRetryTask?.cancel()
        sameSourceRetryTask = nil
        sameSourceRetryID = nil
        lookaheadTask?.cancel()
        lookaheadGeneration &+= 1
        resetStallDeadline()
        saveProgressNow(flushSync: true)
        tickerTask?.cancel()
        upNextTask?.cancel()
        loadTask?.cancel()
        segmentsTask?.cancel()
        throwNoticeTask?.cancel()
        engine.teardown()
    }

    // =====================================================================================
    // Ticker: position state, periodic saves, up-next trigger
    // =====================================================================================

    private func startTelemetry() {
        let identity = "\(target.mediaId):\(curSeason ?? -1):\(curEpisode ?? -1)"
        guard telemetryIdentity != identity else { return }
        telemetryIdentity = identity
        telemetry.start(kind: isShow ? "tv" : "movie", mediaId: String(target.mediaId), title: showTitle,
                        season: curSeason, episode: curEpisode, profileId: playback.activeProfileId()) { [weak self] in
            guard let self else { return .init(state: "ended") }
            let status: String
            if self.hostStopped { status = "paused" }
            else if self.phase == .error { status = "error" }
            else if self.engine.isPlayingNow && !self.isBuffering { status = "playing" }
            else if self.isBuffering || self.phase == .loading || self.currentStream == nil { status = "buffering" }
            else { status = "paused" }
            return .init(state: status, positionMs: self.engine.positionMs, source: self.currentStream?.url)
        }
    }

    private func startTicker() {
        tickerTask = Task { [weak self] in
            var saveTick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                saveTick = self.tick(saveTick: saveTick)
            }
        }
    }

    private func tick(saveTick: Int) -> Int {
        guard phase == .playing else { return saveTick }
        let pos = max(engine.positionMs, 0)
        let rawDur = engine.durationMs
        let dur = rawDur > 0 ? rawDur : 0
        if pos > 0, pendingSeek == nil, seekGrace == nil { lastKnownPositionMs = pos }
        if dur > 0 { lastKnownDurationMs = dur }
        if let grace = seekGrace {
            // Post-seek grace: keep showing the requested position until the
            // engine reports something near it (seek landed) or the window
            // lapses — otherwise the scrubber snaps back, then jumps forward.
            if Date() >= grace.deadline || abs(pos - grace.targetMs) < 2_000 {
                seekGrace = nil
                positionMs = pos
            } else {
                positionMs = grace.targetMs
            }
        } else {
            positionMs = pos
        }
        durationMs = dur
        if isPlaying != engine.isPlayingNow { isPlaying = engine.isPlayingNow }
        applyPendingSeekIfReady()
        let sampleTime = monotonicMs
        let healthy = engine.isPlayingNow && !queueAutoAdvanceSuspended && !hostStopped
            && pendingSeek == nil && seekGrace == nil && !handoffHoldsPlayback && !handoffProgressSuspended
        if healthy, let previous = healthySample {
            let elapsed = sampleTime - previous.time
            let advanced = pos - previous.position
            if elapsed > 0 && elapsed <= 2_000 && advanced > 0 && advanced <= elapsed * 2 + 750 {
                healthyPlaybackMs += min(elapsed, advanced)
                if healthyPlaybackMs >= 1_000 { sourceEstablished = true }
                if healthyPlaybackMs >= 30_000 {
                    autoRetryCount = 0; sameSourceRetryCount = 0; sameSourceRetryUntilMs = 0
                }
            } else { healthyPlaybackMs = 0 }
        } else { healthyPlaybackMs = 0 }
        healthySample = healthy ? (sampleTime, pos) : nil
        if failoverWatchdog.shouldFailover(
            nowMs: monotonicMs, generation: mediaGeneration, positionMs: pos,
            bufferedPositionMs: 0, durationMs: dur, buffering: true,
            isPlaying: engine.isPlayingNow, playWhenReady: !queueAutoAdvanceSuspended,
            suppressed: audioPreparationTask != nil || handoffHoldsPlayback || handoffProgressSuspended,
            eligible: !tornDown && !hostStopped && !swapping && !queueTransitionStarted
                && !endedHandled && !sessionFinished && engine.stateNow != .ended
        ) {
            handlePlayerError()
            return 0
        }
        maybeTriggerUpNext(pos: pos, dur: dur)
        // Both checks read the seek-grace-aware `positionMs`, not the raw engine
        // position: VLC applies network seeks asynchronously, so right after the
        // replay's -15s jump the engine still reports the OLD position (>= the
        // restore point) — the raw value would end the replay instantly.
        if replayRestoreAtMs >= 0 && positionMs >= replayRestoreAtMs { finishReplay() }
        updateSkipIntroVisibility(pos: positionMs)
        var nextTick = saveTick + 1
        if nextTick >= Self.progressSaveEveryTicks {
            nextTick = 0
            if engine.isPlayingNow && queuePlayback == nil {
                let season = curSeason
                let episode = curEpisode
                let meta = currentEpisodeMeta
                Task {
                    await self.persistProgress(positionMs: pos, durationMs: dur,
                                               season: season, episode: episode, episodeMeta: meta)
                }
            }
        }
        return nextTick
    }

    // =====================================================================================
    // Progress persistence
    // =====================================================================================

    /// Writes the resume row. At >=95%: mark episode watched (shows) and advance
    /// the row to the next episode, or remove the row entirely (movies /
    /// definitively-last episode). Identity (season/episode/meta) is passed in,
    /// snapshotted at the same moment as the position — this function suspends
    /// (awaitNextEpisode) and may race an episode swap.
    private func persistProgress(positionMs: Int64, durationMs: Int64,
                                 season: Int?, episode: Int?, episodeMeta: Episode?) async {
        guard queuePlayback == nil, !handoffProgressSuspended else { return }
        guard details != nil else { return }
        guard positionMs >= 5_000 else { return }
        if durationMs > 0 && positionMs >= durationMs * 95 / 100 {
            if target.type == .show {
                // An episode swap can advance the live identity while this save
                // was pending. Acting on the stale snapshot would mark the old
                // episode watched AGAIN (poisoning `markedWatched`, which the
                // swap just reset for the NEW episode) and resolve "next"
                // against the advanced episode — writing the Continue Watching
                // row to episode+2. The swap already wrote the correct row.
                guard season == curSeason, episode == curEpisode else { return }
                markWatched(season: season, episode: episode)
                let next = await awaitNextEpisode()
                // Re-check: identity or ownership may change during resolution.
                guard season == curSeason, episode == curEpisode, !handoffProgressSuspended else { return }
                if let next {
                    upsertRow(season: next.season, episode: next.number, episodeTitle: next.title,
                              positionMs: 0, durationMs: runtimeMs(next), still: next.stillUrl)
                } else if nextResolved {
                    // Definitively the last episode — the show is finished.
                    playback.removeProgress(mediaId: target.mediaId, typeKey: target.type.rawValue)
                } else {
                    // Resolution FAILED (network blip) — keep the row pointed at
                    // the current episode instead of deleting Continue Watching.
                    upsertRow(season: season, episode: episode, episodeTitle: episodeMeta?.title,
                              positionMs: positionMs, durationMs: durationMs,
                              still: episodeMeta?.stillUrl)
                }
            } else {
                playback.removeProgress(mediaId: target.mediaId, typeKey: target.type.rawValue)
            }
        } else {
            upsertRow(season: season, episode: episode, episodeTitle: episodeMeta?.title,
                      positionMs: positionMs, durationMs: durationMs,
                      still: episodeMeta?.stillUrl)
        }
    }

    private func upsertRow(season: Int?, episode: Int?, episodeTitle: String?,
                           positionMs: Int64, durationMs: Int64, still: URL?) {
        guard queuePlayback == nil, !handoffProgressSuspended else { return }
        let item = details?.item
        playback.upsertProgress(
            mediaId: target.mediaId,
            typeKey: target.type.rawValue,
            imdbId: imdbId,
            title: item?.title ?? showTitle,
            posterUrl: item?.posterUrl?.absoluteString,
            backdropUrl: (still ?? item?.backdropUrl)?.absoluteString,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            positionMs: positionMs,
            durationMs: durationMs,
            year: item?.year,
            rating: item?.rating
        )
    }

    /// Explicit (season, episode) — callers snapshot the identity at the call site.
    private func markWatched(season: Int?, episode: Int?) {
        guard queuePlayback == nil, !handoffProgressSuspended else { return }
        if markedWatched { return }
        guard let s = season, let e = episode else { return }
        guard target.type == .show else { return }
        markedWatched = true
        playback.markWatched(mediaId: target.mediaId, season: s, episode: e)
    }

    private func runtimeMs(_ ep: Episode) -> Int64 {
        Int64(ep.runtimeMinutes ?? 0) * 60_000
    }

    // =====================================================================================
    // Next-episode resolution + Up Next
    // =====================================================================================

    /// Episodes for a season, cached. THROWS when the fetch is judged to have
    /// failed: the repo contract returns [] for both "season empty" and "fetch
    /// failed", so when TMDB metadata says the season has episodes, [] must mean
    /// failure — a TMDB blip at a season boundary must never silently skip a
    /// whole season (or end the show).
    private func episodesFor(season: Int) async throws -> [Episode] {
        if let cached = episodesCache[season] { return cached }
        let eps = await tmdb.episodes(showId: target.mediaId, season: season)
        if eps.isEmpty {
            let meta = details?.seasons.first { $0.number == season }
            if let meta, meta.episodeCount > 0 {
                let failures = (seasonFetchFailures[season] ?? 0) + 1
                seasonFetchFailures[season] = failures
                if failures < Self.seasonFetchFailureLimit {
                    throw SeasonFetchError() // not cached — a later call retries
                }
                // Repeatedly judged "failed" yet the endpoint keeps answering
                // with no positive-numbered episodes: TMDB's show metadata is
                // stale (episodeCount > 0 for a genuinely empty season). Accept
                // [] and cache it so findNextEpisode can skip past this season
                // like Android does, instead of stalling binge advancement.
            }
        } else {
            seasonFetchFailures[season] = nil
        }
        episodesCache[season] = eps
        return eps
    }

    /// Next episode, or nil when the show is definitively over. THROWS when a
    /// season fetch fails — never advance PAST a season we couldn't read.
    private func findNextEpisode() async throws -> Episode? {
        guard target.type == .show else { return nil }
        guard let s = curSeason, let e = curEpisode else { return nil }
        let inSeason = try await episodesFor(season: s)
            .filter { $0.number > e }
            .min { $0.number < $1.number }
        if let inSeason { return inSeason }
        guard let d = details else { return nil }
        let laterSeasons = d.seasons.map(\.number).filter { $0 > s }.sorted()
        for ns in laterSeasons {
            // A failed fetch propagates: never advance past a season we couldn't read.
            if let first = try await episodesFor(season: ns).min(by: { $0.number < $1.number }) {
                return first
            }
        }
        return nil
    }

    /// Cached next-episode resolution. Returns nil both when there is no next
    /// episode AND when resolution failed — distinguish via `nextResolved`:
    /// failures leave it false so a later call retries instead of poisoning
    /// the session.
    private func awaitNextEpisode() async -> Episode? {
        if nextResolved { return nextEpisode }
        let season = curSeason, episode = curEpisode
        let resolved: Episode?
        do {
            resolved = try await findNextEpisode()
        } catch {
            return nil // unknown — leave nextResolved = false
        }
        guard !tornDown, curSeason == season, curEpisode == episode else { return nil }
        nextEpisode = resolved
        nextResolved = true
        hasNext = resolved != nil
        return resolved
    }

    private func resolveNextEagerly() {
        if let queuePlayback {
            hasNext = queuePlayback.next != nil
            hasPrevious = queuePlayback.previous != nil
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let season = self.curSeason, episode = self.curEpisode
            let previous = await self.resolvePreviousEpisode()
            guard !self.tornDown, self.curSeason == season, self.curEpisode == episode else { return }
            self.hasPrevious = previous != nil
        }
        Task { [weak self] in
            guard let self else { return }
            let next = await self.awaitNextEpisode()
            // Skip-intro prefetch: hand the worker next episode's URL now, not
            // at play time, so its marker is ready before that episode starts.
            if let next, !self.tornDown { await self.reportNextEpisodeUrl(next) }
        }
    }

    private func maybeTriggerUpNext(pos: Int64, dur: Int64) {
        guard !handoffHoldsPlayback, !handoffProgressSuspended else { return }
        if let queuePlayback {
            guard !queueTransitionStarted, phase == .playing, dur > 0,
                  let next = queuePlayback.next else { return }
            let remaining = dur - pos
            if remaining > Self.upNextReleaseMs { upNext = .hidden; upNextCancelled = false; return }
            guard remaining > 0, remaining <= Self.upNextTriggerMs, !upNextCancelled else { return }
            // Follow media time, so pausing pauses this countdown too. The queue
            // advances only at true ENDED or an explicit Play now/Next action.
            upNext = .countdown(next: NextEpisodeUi(season: next.season ?? 0, episode: next.episode ?? 0,
                title: next.episodeTitle ?? next.title, stillUrl: next.stillUrl ?? next.backdropUrl,
                showTitle: next.type == .show ? next.title : nil), secondsLeft: max(1, Int(ceil(Double(remaining) / 1_000))), totalSeconds: 40)
            return
        }
        // Mid-swap, pos/dur can still belong to the OLD item while identity and
        // the up-next flags already belong to the NEW one — arming in that window
        // starts a countdown ~at episode start and SKIPS the episode.
        if swapping { return }
        guard isShow, dur > 0, phase == .playing else { return }
        let remaining = dur - pos
        if upNext != .hidden && remaining > Self.upNextReleaseMs {
            // User scrubbed back out of the credits window — hide (Countdown AND
            // a stale EndChoice left over from a post-ENDED rewind) and re-arm.
            upNextTask?.cancel()
            upNextArming = false
            upNext = .hidden
            return
        }
        if remaining <= Self.upNextTriggerMs,
           upNext == .hidden,
           !upNextCancelled,
           !upNextArming,
           settings.autoplayNext {
            armUpNext()
        }
    }

    private func armUpNext() {
        let season = curSeason, episode = curEpisode
        upNextArming = true
        Task { [weak self] in
            guard let self else { return }
            // Any exit that doesn't reach startCountdown must clear the arming
            // flag, or maybeTriggerUpNext blocks the overlay for the rest of the
            // episode.
            var countdownStarted = false
            defer { if !countdownStarted { self.upNextArming = false } }
            guard !self.tornDown else { return }
            guard let next = await self.awaitNextEpisode() else { return }
            guard !self.tornDown, self.curSeason == season, self.curEpisode == episode else { return }
            self.pendingNextEpisode = next
            await self.prefetchNextStreams(next)
            // Conditions may have changed while prefetching (dismissed,
            // cancelled, errored, a swap started, or ENDED already swapped us
            // onto this very episode). teardown() never changes `phase`, so the
            // tornDown check is what stops a post-dismiss countdown.
            if self.curSeason != season || self.curEpisode != episode || self.tornDown || self.swapping || self.upNextCancelled || self.handoffHoldsPlayback || self.handoffProgressSuspended || self.phase != .playing {
                return
            }
            if self.curSeason == next.season && self.curEpisode == next.number { return }
            self.startCountdown(next)
            countdownStarted = true
        }
    }

    private func prefetchNextStreams(_ ep: Episode) async {
        guard let id = imdbId else { return }
        if let cached = prefetchedStreams, cached.season == ep.season, cached.episode == ep.number {
            return
        }
        let list = await streamRepo.streams(imdbId: id, type: .show,
                                            season: ep.season, episode: ep.number)
        guard !list.isEmpty else {
            prefetchedStreams = nil
            return
        }
        let sorted = streamRepo.sortStreams(list, preferredQuality: settings.preferredQuality)
        let (ranked, verdicts) = await applyEpisodeVerdicts(sorted, season: ep.season, episode: ep.number)
        guard !Task.isCancelled, !tornDown else { return }
        prefetchedStreams = PrefetchedStreams(season: ep.season, episode: ep.number,
                                               all: ranked, verdicts: verdicts)
    }

    private func startCountdown(_ next: Episode) {
        guard !tornDown, !handoffHoldsPlayback, !handoffProgressSuspended else { return }
        upNextTask?.cancel()
        let total = max(settings.autoplayCountdownSecs, 1)
        let ui = Self.toUi(next)
        upNextTask = Task { [weak self] in
            for secs in stride(from: total, through: 1, by: -1) {
                guard let self, !self.tornDown else { return }
                self.upNext = .countdown(next: ui, secondsLeft: secs, totalSeconds: total)
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return // cancelled mid-tick ("Watch credits")
                }
            }
            // A last-instant "Watch credits" can land after the final sleep
            // resumes: honor a post-resume cancel, and the upNextCancelled gate
            // covers playNextEpisode escaping into its own task.
            guard let self, !Task.isCancelled, !self.tornDown else { return }
            if !self.upNextCancelled { self.playNextEpisode() }
        }
    }

    private func handleEnded() {
        // A late ENDED from the OLD item while swapToEpisode is in flight
        // (identity already advanced, media not yet set) must be ignored —
        // handling it would mark the not-yet-played episode watched and advance
        // progress to ep+2.
        if swapping || tornDown || queueTransitionStarted || handoffHoldsPlayback || handoffProgressSuspended { return }
        if endedHandled { return }
        endedHandled = true
        if let queuePlayback {
            if queueAutoAdvanceSuspended, let next = queuePlayback.next {
                upNext = .endChoice(next: NextEpisodeUi(season: next.season ?? 0,
                    episode: next.episode ?? 0, title: next.episodeTitle ?? next.title,
                    stillUrl: next.stillUrl ?? next.backdropUrl, showTitle: next.type == .show ? next.title : nil))
            } else { advanceQueue(.completed) }
            return
        }
        // Snapshot identity before any suspension point.
        let endedSeason = curSeason
        let endedEpisode = curEpisode
        Task { [weak self] in
            guard let self, !self.tornDown else { return }
            if self.target.type == .movie {
                // Finished for good: block the dismiss-time saveProgressNow from
                // resurrecting the row (play() clears the flag on a restart).
                self.sessionFinished = true
                self.playback.removeProgress(mediaId: self.target.mediaId,
                                             typeKey: self.target.type.rawValue)
                self.shouldDismiss = true
                return
            }
            self.markWatched(season: endedSeason, episode: endedEpisode)
            let next = await self.awaitNextEpisode()
            // The screen may have been dismissed while resolving — no swaps, no
            // DB writes after teardown or a manual episode change.
            guard !self.tornDown, self.curSeason == endedSeason, self.curEpisode == endedEpisode else { return }
            if let next {
                if self.settings.autoplayNext && !self.upNextCancelled {
                    self.upNextTask?.cancel()
                    await self.swapToEpisode(next)
                } else {
                    self.pendingNextEpisode = next
                    self.upsertRow(season: next.season, episode: next.number,
                                   episodeTitle: next.title, positionMs: 0,
                                   durationMs: self.runtimeMs(next), still: next.stillUrl)
                    self.upNext = .endChoice(next: Self.toUi(next))
                }
            } else {
                // Only clear Continue Watching when "no next" is definitive; on a
                // resolution failure keep the row and just return to Details.
                if self.nextResolved {
                    self.sessionFinished = true
                    self.playback.removeProgress(mediaId: self.target.mediaId,
                                                 typeKey: self.target.type.rawValue)
                }
                self.shouldDismiss = true
            }
        }
    }

    /// The flagship: swap to the next episode inside the SAME screen.
    private func swapToEpisode(_ ep: Episode, markCurrentWatched: Bool = true) async {
        // Dismissed mid-flight (countdown completion, ENDED handler, "Play
        // next" — all hold self strongly): no watched marks, no Continue
        // Watching rewrite, no stream fetch, no playback after teardown.
        if tornDown { return }
        if swapping { return }
        if curSeason == ep.season && curEpisode == ep.number
            && phase == .playing && !endedHandled {
            return
        }
        swapping = true
        cancelAudioPreparation()
        sameSourceRetryTask?.cancel()
        sameSourceRetryTask = nil
        sameSourceRetryID = nil
        lookaheadTask?.cancel()
        lookaheadGeneration &+= 1
        defer { swapping = false }

        upNextTask?.cancel()
        let oldSeason = curSeason, oldEpisode = curEpisode
        let oldPosition = pendingSeek?.positionMs ?? seekGrace?.targetMs ?? max(engine.positionMs, lastKnownPositionMs)
        let oldDuration = max(engine.durationMs, lastKnownDurationMs)
        engine.stopPlayback()
        if markCurrentWatched {
            markWatched(season: oldSeason, episode: oldEpisode)
        } else {
            await persistProgress(positionMs: oldPosition, durationMs: oldDuration,
                                  season: oldSeason, episode: oldEpisode, episodeMeta: currentEpisodeMeta)
        }
        guard !tornDown else { return }
        resetReplayForSwap()

        curSeason = ep.season
        curEpisode = ep.number
        currentEpisodeMeta = ep
        currentStream = nil
        startTelemetry()
        markedWatched = false
        // endedHandled is reset inside play() — only once the old media item is
        // replaced and can no longer emit a late ENDED.
        upNextCancelled = false
        upNextArming = false
        nextEpisode = nil
        nextResolved = false
        pendingNextEpisode = nil
        pendingSeek = nil
        seekGrace = nil
        lastKnownPositionMs = 0
        lastKnownDurationMs = 0
        // The budget belongs to one episode attempt, not the entire evening.
        autoRetryCount = 0
        fallbackStreams = []
        allResolvedStreams = []
        streams = []
        failoverNotice = false

        upNext = .hidden
        episodeLabel = Self.formatEpisodeLabel(season: ep.season, episode: ep.number, title: ep.title)
        hasNext = false
        hasPrevious = false
        positionMs = 0
        durationMs = 0

        // Continue Watching should point at the new episode immediately.
        upsertRow(season: ep.season, episode: ep.number, episodeTitle: ep.title,
                  positionMs: 0, durationMs: runtimeMs(ep), still: ep.stillUrl)

        var pre: PrefetchedStreams?
        if let cached = prefetchedStreams, cached.season == ep.season, cached.episode == ep.number {
            pre = cached
        }
        prefetchedStreams = nil
        if let pre, !pre.all.isEmpty {
            // Adopt the prefetch's episode-title verdicts alongside its streams so
            // isMismatch keeps demoting off-by-one releases for the new episode.
            episodeVerdicts = pre.verdicts
            let refreshed = await streamRepo.refreshStartupReadiness(pre.all, waitForReady: true)
            guard !tornDown, !Task.isCancelled, curSeason == ep.season, curEpisode == ep.number else { return }
            allResolvedStreams = streamRepo.sortStreams(refreshed, preferredQuality: settings.preferredQuality)
            streams = allResolvedStreams.filter { !isBlocked($0) }
            playBest(from: streams)
        } else {
            // Resolve/rank the new episode using cached backend startup checks.
            phase = .loading
            errorMessage = nil
            await startStreamsAndPlay()
        }
        resolveNextEagerly()
    }

    private static func toUi(_ ep: Episode) -> NextEpisodeUi {
        NextEpisodeUi(season: ep.season, episode: ep.number, title: ep.title, stillUrl: ep.stillUrl)
    }

    private static func formatEpisodeLabel(season: Int, episode: Int, title: String?) -> String {
        var label = "S\(season) E\(episode)"
        if let title, !title.isEmpty { label += " — \(title)" }
        return label
    }

    // =====================================================================================
    // "What did they say?" internals
    // =====================================================================================

    /// Playback passed the replay's return point — restore the previous
    /// subtitle state (only when the replay had turned them on).
    private func finishReplay() {
        if replayTurnSubsOff {
            subtitleDesiredLabel = nil
            engine.selectSubtitleTrack(id: -1)
            subtitleLabel = nil
            rebuildTrackOptions()
        }
        cancelReplay()
    }

    /// Drop replay bookkeeping without touching the player (a manual pick has
    /// already applied the user's explicit choice).
    private func cancelReplay() {
        replayRestoreAtMs = -1
        replayTurnSubsOff = false
        if replayActive { replayActive = false }
    }

    /// Episode swap mid-replay: the temporary subtitles must not leak into the
    /// next episode. Clearing the desired label is enough — refreshTracks
    /// applies it (off) once the new stream's tracks register.
    private func resetReplayForSwap() {
        if replayTurnSubsOff {
            subtitleDesiredLabel = nil
            subtitleLabel = nil
        }
        cancelReplay()
    }

    // =====================================================================================
    // Skip intro (velvet-sync /report_play + /segments, velvet-intro worker)
    // =====================================================================================

    /// Report the URL this episode plays from (the worker fingerprints exactly
    /// what we watch) and start polling for its intro marker. Failover and
    /// stream-switch re-report the replacement URL — the worker keys per
    /// episode and takes the latest.
    private func reportPlayAndWatchForIntro(_ stream: StreamOption) {
        guard let id = imdbId, let season = curSeason, let episode = curEpisode else { return }
        let url = stream.url.absoluteString
        Task { [weak self] in
            await self?.companion.reportPlay(imdbId: id, season: season, episode: episode, url: url)
        }
        startSegmentsPolling(imdbId: id, season: season, episode: episode)
    }

    /// Fetch the intro marker: once at start, then slow retries while the
    /// worker may still be crunching the first episodes of a season. Gives up
    /// quietly — no marker just means no pill. Restarting (every play()) also
    /// resets the per-episode intro state.
    private func startSegmentsPolling(imdbId: String, season: Int, episode: Int) {
        segmentsTask?.cancel()
        introRange = nil
        introDismissed = false
        skipIntroVisible = false
        segmentsTask = Task { [weak self] in
            for attempt in 0..<6 {
                guard let self, !self.tornDown, !Task.isCancelled else { return }
                let range = await self.companion.introSegments(imdbId: imdbId, season: season)[episode]
                guard !Task.isCancelled else { return }
                if let range {
                    self.introRange = range
                    return
                }
                try? await Task.sleep(nanoseconds: attempt == 0 ? 20_000_000_000 : 45_000_000_000)
            }
        }
    }

    /// Pill window: inside the marker with margins (1.5s past the start so it
    /// never flashes on a boundary seek, gone 4s before the end where skipping
    /// stops being worth it), unless dismissed for this episode.
    private func updateSkipIntroVisibility(pos: Int64) {
        let show: Bool
        if let intro = introRange, !introDismissed {
            show = pos >= intro.lowerBound + 1_500 && pos < intro.upperBound - 4_000
        } else {
            show = false
        }
        if show != skipIntroVisible { skipIntroVisible = show }
    }

    /// At episode start, also resolve the NEXT episode's streams and report the
    /// would-be autopick URL (respecting bingeGroup continuity; no health
    /// probing — the fingerprint worker only needs a representative file), so
    /// the worker has its fingerprint ready BEFORE that episode plays.
    private func reportNextEpisodeUrl(_ next: Episode) async {
        guard let id = imdbId, companion.isEnabled else { return }
        let list = await streamRepo.streams(imdbId: id, type: .show,
                                            season: next.season, episode: next.number)
        guard !list.isEmpty else { return }
        let sorted = streamRepo.sortStreams(list.filter { !isBlocked($0) }, preferredQuality: settings.preferredQuality)
        guard !tornDown, !Task.isCancelled,
              let pick = lastBingeGroup.flatMap({ group in sorted.first { $0.bingeGroup == group } })
                ?? sorted.first else { return }
        await companion.reportPlay(imdbId: id, season: next.season, episode: next.number,
                                   url: pick.url.absoluteString)
    }

    // =====================================================================================
    // Tracks (subtitles + audio)
    // =====================================================================================

    /// Called whenever VLC reports new track info (.playing / .esAdded).
    private func refreshTracks() {
        guard phase == .playing, !swapping, !tornDown else { return }
        externalAudioTrackIds.formUnion(engine.compatibleAudioTrackIds)
        let subs = engine.subtitleTracks
        let audios = engine.audioTracks
        subtitleAvailable = !subs.isEmpty

        // Metadata can arrive after the track IDs. Re-evaluate codec/language
        // on every track event instead of permanently accepting the first list.
        let nativeAudios = audios.filter { !externalAudioTrackIds.contains($0.id) }
        if audioPreparationTask == nil,
           let preferred = MobileAudioSelection.preferred(in: nativeAudios,
                currentId: engine.currentAudioTrackId, manualName: sessionAudioLabel) {
            selectPlayableAudio(preferred)
        }

        // Subtitles default OFF; re-apply the session choice across episode
        // swaps so subtitles stay on while binging.
        if !subs.isEmpty {
            let currentId = engine.currentSubtitleTrackId
            if let desired = subtitleDesiredLabel {
                if currentId < 0 || !subs.contains(where: { $0.id == currentId }) {
                    let match = subs.first { $0.name == desired } ?? subs.first
                    if let match { engine.selectSubtitleTrack(id: match.id) }
                }
            } else if currentId >= 0 {
                // We never asked for subtitles: some containers default-enable
                // an embedded track — force off (Android disables TEXT by default).
                engine.selectSubtitleTrack(id: -1)
            }
        }
        subtitleLabel = subs.first { $0.id == engine.currentSubtitleTrackId }?.name
        rebuildTrackOptions()
    }

    private func cancelAudioPreparation() {
        audioPreparationGeneration &+= 1
        audioPreparationTask?.cancel()
        audioPreparationTask = nil
        audioPreparingTrackId = nil
    }

    private func selectPlayableAudio(_ track: PlayerTrack) {
        guard phase == .playing, !swapping, !tornDown else { return }
        if let slaveId = compatibleAudioSlaves[track.id] {
            let wasPreparing = audioPreparationTask != nil
            cancelAudioPreparation()
            if engine.currentAudioTrackId != slaveId { engine.selectAudioTrack(id: slaveId) }
            if wasPreparing, !queueAutoAdvanceSuspended, !handoffHoldsPlayback, !handoffProgressSuspended { engine.play() }
            return
        }
        guard track.needsAudioCompatibility else {
            let wasPreparing = audioPreparationTask != nil
            cancelAudioPreparation()
            if engine.currentAudioTrackId != track.id { engine.selectAudioTrack(id: track.id) }
            if wasPreparing, !queueAutoAdvanceSuspended, !handoffHoldsPlayback, !handoffProgressSuspended {
                engine.play()
            }
            return
        }
        guard let stream = currentStream, !tornDown else { return }
        if audioPreparingTrackId == track.id, audioPreparationTask != nil { return }
        cancelAudioPreparation()
        let generation = audioPreparationGeneration
        let identity = (curSeason, curEpisode)
        audioPreparingTrackId = track.id
        // Decode only this source's soundtrack on the server. Pause the video
        // while it is prepared, so none of the movie silently passes by.
        engine.pause()
        resetStallDeadline()
        isBuffering = true
        audioPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.audioPreparationGeneration == generation {
                    self.audioPreparationTask = nil
                    self.audioPreparingTrackId = nil
                    self.isBuffering = false
                }
            }
            do {
                let url = try await AudioCompatibility.prepare(stream: stream, track: track)
                try Task.checkCancellation()
                guard !self.tornDown, self.audioPreparationGeneration == generation,
                      self.phase == .playing, !self.swapping, self.curSeason == identity.0, self.curEpisode == identity.1,
                      self.currentStream?.url == stream.url else { return }
                let previousIds = Set(self.engine.audioTracks.map(\.id))
                let audioURL = StreamLookahead.attributedMediaURL(url, backend: self.settings.syncUrl, sessionId: self.telemetry.sessionId)
                guard self.engine.addCompatibleAudio(url: audioURL) else { throw AudioCompatibility.Failure.unavailable }
                let deadline = Date().addingTimeInterval(45)
                var added: Int?
                while Date() < deadline {
                    try Task.checkCancellation()
                    guard !self.tornDown, self.audioPreparationGeneration == generation,
                          self.phase == .playing, !self.swapping, self.curSeason == identity.0, self.curEpisode == identity.1,
                          self.currentStream?.url == stream.url else { return }
                    if let candidate = self.engine.audioTracks.first(where: {
                        !previousIds.contains($0.id) && ["s16l", "araw"].contains($0.codec ?? "")
                    }) { added = candidate.id; break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard let added else { throw AudioCompatibility.Failure.unavailable }
                self.compatibleAudioSlaves[track.id] = added
                self.externalAudioTrackIds.insert(added)
                self.engine.selectAudioTrack(id: added)
                self.rebuildTrackOptions()
                // A late sound-preparation response must not resume a phone
                // paused by the user, backgrounding, or a Send to TV transfer.
                if !self.queueAutoAdvanceSuspended, !self.handoffHoldsPlayback,
                   !self.handoffProgressSuspended {
                    self.engine.play()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !self.tornDown, self.audioPreparationGeneration == generation,
                      self.phase == .playing, !self.swapping, self.curSeason == identity.0, self.curEpisode == identity.1,
                      self.currentStream?.url == stream.url else { return }
                self.showError(AudioCompatibility.Failure.unavailable.localizedDescription, canChoose: true)
            }
        }
    }

    /// Rebuild the picker option lists from the player's current tracks.
    private func rebuildTrackOptions() {
        let subs = engine.subtitleTracks
        if subs.isEmpty {
            subtitleOptions = []
        } else {
            let currentSub = engine.currentSubtitleTrackId
            var options = [TrackOption(index: -1, label: "Off",
                                       selected: !subs.contains { $0.id == currentSub })]
            options += subs.map {
                TrackOption(index: $0.id, label: $0.name, selected: $0.id == currentSub)
            }
            subtitleOptions = options
        }
        let currentAudio = engine.currentAudioTrackId
        audioOptions = engine.audioTracks.filter { !externalAudioTrackIds.contains($0.id) }.map {
            TrackOption(index: $0.id, label: $0.name,
                selected: $0.id == currentAudio || compatibleAudioSlaves[$0.id] == currentAudio)
        }
    }

    /// VLC track names usually include the language ("Track 1 - [English]").
    private static func looksEnglish(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("english") { return true }
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.contains("en") || tokens.contains("eng")
    }
}
