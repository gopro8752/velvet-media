import Foundation

/// Episode coordinates belong to the card, so an episode category never resumes
/// an unrelated episode from Continue Watching.
struct HomeCategoryItem: Codable, Identifiable, Hashable {
    let mediaId: Int
    let type: MediaType
    let title: String
    let year: String?
    let posterUrl: URL?
    let backdropUrl: URL?
    let imdbId: String?
    let rating: Double?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let stillUrl: URL?

    var id: String { "\(type.rawValue):\(mediaId):\(season ?? -1):\(episode ?? -1)" }
    var target: PlayTarget {
        PlayTarget(mediaId: mediaId, type: type, season: season, episode: episode)
    }
    var item: MediaItem {
        MediaItem(id: mediaId, type: type, title: title, year: year,
                  posterUrl: posterUrl, backdropUrl: backdropUrl, rating: rating, imdbId: imdbId)
    }
    var episodeLabel: String? {
        guard let season, let episode else { return nil }
        let label = "S\(season) E\(episode)"
        return episodeTitle.map { "\(label) · \($0)" } ?? label
    }
}

struct HomeCategory: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    var items: [HomeCategoryItem]

    /// Reject broken identities and dedupe episode cards without merging
    /// different episodes of the same show.
    var validated: HomeCategory {
        var seen = Set<String>()
        var copy = self
        copy.items = items.filter {
            let validEpisode = ($0.season == nil && $0.episode == nil)
                || ($0.type == .show && ($0.season ?? -1) >= 0 && ($0.episode ?? 0) > 0)
            return $0.mediaId > 0 && !$0.title.isEmpty && validEpisode && seen.insert($0.id).inserted
        }
        return copy
    }
}

/// Both playback modes send the selected episode coordinates intact. The
/// backend expands only whole-show seeds (nil season/episode); toggling Shuffle
/// must not widen an episode category into the shows' entire catalogs.
struct CategoryQueueRequest: Encodable {
    struct Seed: Encodable {
        let mediaId: Int
        let type: MediaType
        let season: Int?
        let episode: Int?
    }
    let title: String
    let items: [Seed]
    let shuffle: Bool

    init(category: HomeCategory, shuffle: Bool) {
        title = category.title
        items = category.items.map {
            Seed(mediaId: $0.mediaId, type: $0.type, season: $0.season, episode: $0.episode)
        }
        self.shuffle = shuffle
    }
}

@MainActor
protocol HomeCategoryService {
    func halloweenCategory() async -> HomeCategory?
    func generateCategory(prompt: String) async throws -> HomeCategory
}

/// This original curated row belongs to the original viewer. Its metadata may
/// be cached globally, but other profiles must not display or launch the row.
enum PersonalHalloweenCategory {
    static let id = "halloween-nostalgia"
    static func isVisible(profile: String) -> Bool { profile == "default" }
    static func canPlay(_ category: HomeCategory, profile: String) -> Bool {
        category.id != id || isVisible(profile: profile)
    }
}

/// Local cache contains catalog metadata only, never subscription credentials.
/// Generated rows belong to the profile that requested them, even if the active
/// profile changes while the server is resolving titles.
enum HomeCategoryCache {
    private static let halloweenKey = "home_halloween_category_v1"
    private static func key(_ profile: String) -> String { "home_generated_categories_v1_" + profile }

    static func halloween(defaults: UserDefaults = .standard) -> HomeCategory? {
        guard let data = defaults.data(forKey: halloweenKey) else { return nil }
        return (try? JSONDecoder().decode(HomeCategory.self, from: data))?.validated
    }
    static func saveHalloween(_ category: HomeCategory, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(category) else { return }
        defaults.set(data, forKey: halloweenKey)
    }
    static func categories(profile: String) -> [HomeCategory] {
        guard let data = UserDefaults.standard.data(forKey: key(profile)) else { return [] }
        return ((try? JSONDecoder().decode([HomeCategory].self, from: data)) ?? [])
            .map(\.validated).filter { !$0.items.isEmpty }
    }
    static func save(_ categories: [HomeCategory], profile: String) {
        guard let data = try? JSONEncoder().encode(Array(categories.prefix(12))) else { return }
        UserDefaults.standard.set(data, forKey: key(profile))
    }
}

/// A continuously repeating category. Each entry has its own playback identity,
/// including after wraparound, so old ENDED/healthy callbacks cannot affect a
/// later visit to the same index. The precomputed next ID also owns its prefetch.
struct CategoryQueueCursor {
    private(set) var id = UUID()
    private(set) var nextID = UUID()
    let title: String
    let items: [HomeCategoryItem]
    private(set) var index = 0
    private(set) var consecutiveFailures = 0

    init(category: HomeCategory) {
        title = category.title
        items = category.validated.items.filter {
            $0.type == .movie || ($0.season != nil && $0.episode != nil)
        }
    }
    var current: HomeCategoryItem? { items.indices.contains(index) ? items[index] : nil }
    var next: HomeCategoryItem? { items.isEmpty ? nil : items[(index + 1) % items.count] }
    var previous: HomeCategoryItem? { index > 0 && items.indices.contains(index - 1) ? items[index - 1] : nil }
    var canAutoSkipUnavailable: Bool { consecutiveFailures < 2 }

    @discardableResult
    mutating func advance(expectedID: UUID, expectedIndex: Int, reason: CategoryQueueAdvance) -> Bool {
        if reason == .previous { return previous(expectedID: expectedID, expectedIndex: expectedIndex) }
        guard expectedID == id, expectedIndex == index, current != nil else { return false }
        if reason == .unavailable {
            guard canAutoSkipUnavailable else { return false }
            consecutiveFailures += 1
        } else {
            consecutiveFailures = 0
        }
        index = (index + 1) % items.count
        id = nextID
        nextID = UUID()
        return true
    }
    /// Previous follows the exact saved order, including a shuffled queue.
    /// A new identity prevents callbacks from either old visit from advancing
    /// this visit, and invalidates the old forward prefetch.
    @discardableResult
    mutating func previous(expectedID: UUID, expectedIndex: Int) -> Bool {
        guard expectedID == id, expectedIndex == index, previous != nil else { return false }
        index -= 1
        id = UUID()
        nextID = UUID()
        consecutiveFailures = 0
        return true
    }
    mutating func noteHealthy(expectedID: UUID, expectedIndex: Int) {
        if expectedID == id, expectedIndex == index { consecutiveFailures = 0 }
    }
}

enum CategoryQueueAdvance: Equatable { case completed, manual, unavailable, previous }

struct CategoryQueuePlayback {
    let title: String
    let index: Int
    let count: Int
    let next: HomeCategoryItem?
    let canAutoSkipUnavailable: Bool
    let previous: HomeCategoryItem?

    init(title: String, index: Int, count: Int, next: HomeCategoryItem?,
         canAutoSkipUnavailable: Bool, previous: HomeCategoryItem? = nil) {
        self.title = title
        self.index = index
        self.count = count
        self.next = next
        self.canAutoSkipUnavailable = canAutoSkipUnavailable
        self.previous = previous
    }
}

/// Full media identity travels with a prefetch across child player lifetimes.
struct CategoryQueuePrefetch {
    let playbackID: UUID
    let target: PlayTarget
    let details: MediaDetails
    let streams: [StreamOption]
}
