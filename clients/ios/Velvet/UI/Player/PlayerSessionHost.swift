import SwiftUI
import AVFoundation
import UIKit

/// One landscape modal, many independent media identities. Each queue item
/// gets a fresh player and cache namespace before resolving a different show.
struct PlayerSessionHost: View {
    let target: PlayTarget
    @EnvironmentObject private var container: AppContainer
    @State private var cursor: CategoryQueueCursor?
    @State private var prefetched: CategoryQueuePrefetch?

    init(target: PlayTarget, queue: HomeCategory?) {
        self.target = target
        _cursor = State(initialValue: queue.map(CategoryQueueCursor.init))
    }

    var body: some View {
        Group {
            if let cursor, let entry = cursor.current {
                PlayerView(target: entry.target,
                           queuePlayback: CategoryQueuePlayback(title: cursor.title, index: cursor.index,
                               count: cursor.items.count, next: cursor.next,
                               canAutoSkipUnavailable: cursor.canAutoSkipUnavailable, previous: cursor.previous),
                           queuePrefetch: prefetched?.playbackID == cursor.id && prefetched?.target == entry.target ? prefetched : nil,
                           onAdvanceQueue: { reason in advance(id: cursor.id, index: cursor.index, reason: reason) },
                           onQueueHealthy: { self.cursor?.noteHealthy(expectedID: cursor.id, expectedIndex: cursor.index) })
                    .id(cursor.id)
            } else if cursor == nil {
                PlayerView(target: target)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            container.sync.setPlayerActive(true)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        .onDisappear {
            container.sync.setPlayerActive(false)
            UIApplication.shared.isIdleTimerDisabled = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        .task(id: cursor?.id) {
            guard let snapshot = cursor, let next = snapshot.next else { return }
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard !Task.isCancelled,
                  let details = try? await container.tmdb.details(id: next.mediaId, type: next.type) else { return }
            guard !Task.isCancelled else { return }
            if let season = next.season { _ = await container.tmdb.episodes(showId: next.mediaId, season: season) }
            guard !Task.isCancelled else { return }
            let imdb = details.item.imdbId ?? "tmdb:\(next.mediaId)"
            let streams = await container.streams.streams(imdbId: imdb, type: next.type,
                                                         season: next.season, episode: next.episode)
            guard !Task.isCancelled, cursor?.id == snapshot.id else { return }
            prefetched = CategoryQueuePrefetch(playbackID: snapshot.nextID, target: next.target,
                                               details: details, streams: streams)
        }
    }

    private func advance(id: UUID, index: Int, reason: CategoryQueueAdvance) {
        guard cursor?.advance(expectedID: id, expectedIndex: index, reason: reason) == true else { return }
        if prefetched?.playbackID != cursor?.id { prefetched = nil }
    }
}
