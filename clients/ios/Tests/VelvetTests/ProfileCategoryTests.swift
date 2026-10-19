import XCTest
import SwiftData
@testable import Velvet

@MainActor
final class ProfileCategoryTests: XCTestCase {
    private func halloween(_ title: String = "Monstober & Nick Halloween") -> HomeCategory {
        HomeCategory(id: PersonalHalloweenCategory.id, title: title, items: [HomeCategoryItem(
            mediaId: 10, type: .show, title: "Show", year: nil,
            posterUrl: nil, backdropUrl: nil, imdbId: nil, rating: nil,
            season: 1, episode: 2, episodeTitle: "Halloween", stillUrl: nil)])
    }

    private func fixture(profile: String, cached: HomeCategory? = nil) throws
        -> (HomeViewModel, SettingsStore, PendingHalloween, UserDefaults, String) {
        let suite = "tv.velvet.tests.halloween." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        if let cached { HomeCategoryCache.saveHalloween(cached, defaults: defaults) }
        let settings = SettingsStore(defaults: defaults)
        settings.activeProfileId = profile
        let container = try ModelContainer(for: WatchProgress.self, WatchedEpisode.self, MyListItem.self, Profile.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let playback = PlaybackStore(container: container)
        playback.activeProfileId = { settings.activeProfileId ?? "default" }
        let service = PendingHalloween()
        let model = HomeViewModel(tmdb: EmptyCategoryCatalog(), settings: settings, playback: playback,
                                  companion: service, categoryDefaults: defaults)
        return (model, settings, service, defaults, suite)
    }

    func testOriginalProfileKeepsCachedHalloweenAndCanPlay() async throws {
        let (model, _, service, defaults, suite) = try fixture(profile: "default", cached: halloween())
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(model.halloweenCategory(for: "default"), halloween())
        XCTAssertTrue(model.canPlayCategory(halloween()))
        XCTAssertFalse(model.halloweenLoading)
        await service.waitForRequests(1)
        service.complete(0, with: halloween("Refreshed"))
        await settleTasks()
        XCTAssertEqual(model.halloweenCategory(for: "default")?.title, "Refreshed")
    }

    func testOtherProfileCannotSeeOrFetchCachedHalloweenAndCacheIsPreserved() async throws {
        let (model, _, service, defaults, suite) = try fixture(profile: "craig", cached: halloween())
        defer { defaults.removePersistentDomain(forName: suite) }
        model.onHomeAppear()
        model.refreshHalloween(force: true)
        await settleTasks()
        XCTAssertNil(model.halloweenCategory)
        XCTAssertNil(model.halloweenCategory(for: "craig"))
        XCTAssertFalse(model.halloweenLoading)
        XCTAssertFalse(model.canPlayCategory(halloween()))
        XCTAssertEqual(service.requests, 0)
        XCTAssertEqual(HomeCategoryCache.halloween(defaults: defaults), halloween())
    }

    func testProfileSwitchHidesRowAndRejectsLateRefresh() async throws {
        let (model, settings, service, defaults, suite) = try fixture(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }
        await service.waitForRequests(1)
        XCTAssertTrue(model.halloweenLoading)
        settings.activeProfileId = "craig"
        XCTAssertNil(model.halloweenCategory)
        XCTAssertFalse(model.halloweenLoading)
        service.complete(0, with: halloween()) // Simulate an operation ignoring cancellation.
        await settleTasks()
        XCTAssertNil(model.halloweenCategory)
        XCTAssertFalse(model.halloweenLoading)
        XCTAssertNil(HomeCategoryCache.halloween(defaults: defaults))
        XCTAssertFalse(model.canPlayCategory(halloween()))
    }

    func testReturnToOriginalProfileIgnoresOldRequestCompletion() async throws {
        let (model, settings, service, defaults, suite) = try fixture(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }
        await service.waitForRequests(1)
        settings.activeProfileId = "craig"
        settings.activeProfileId = "default"
        await service.waitForRequests(2)
        service.complete(0, with: halloween("Old response"))
        await settleTasks()
        XCTAssertTrue(model.halloweenLoading, "Old request must not clear the new request's loading state")
        XCTAssertNil(model.halloweenCategory)
        service.complete(1, with: halloween("Current response"))
        await settleTasks()
        XCTAssertFalse(model.halloweenLoading)
        XCTAssertEqual(model.halloweenCategory(for: "default")?.title, "Current response")
        XCTAssertNil(model.halloweenCategory(for: "craig"))
        XCTAssertTrue(model.canPlayCategory(halloween()))
    }

    func testPersonalHalloweenRuleLeavesGeneratedCollectionsAlone() {
        let generated = HomeCategory(id: "ai-halloween", title: "My Halloween movies", items: [])
        XCTAssertTrue(PersonalHalloweenCategory.canPlay(generated, profile: "craig"))
        XCTAssertTrue(PersonalHalloweenCategory.canPlay(generated, profile: "default"))
        XCTAssertFalse(PersonalHalloweenCategory.canPlay(halloween(), profile: "craig"))
        XCTAssertTrue(PersonalHalloweenCategory.canPlay(halloween(), profile: "default"))
    }

    private func settleTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

@MainActor
private final class PendingHalloween: HomeCategoryService {
    var requests = 0
    var pending: [Int: CheckedContinuation<HomeCategory?, Never>] = [:]
    func halloweenCategory() async -> HomeCategory? {
        let index = requests
        requests += 1
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func generateCategory(prompt: String) async throws -> HomeCategory {
        throw URLError(.unsupportedURL)
    }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<100 where requests < count { await Task.yield() }
        XCTAssertEqual(requests, count)
    }
    func complete(_ index: Int, with category: HomeCategory) {
        pending.removeValue(forKey: index)?.resume(returning: category)
    }
}

private struct EmptyCategoryCatalog: TmdbRepository {
    var allRows: [RowSpec] { [] }
    func rowItems(rowId: String, page: Int) async -> [MediaItem] { [] }
    func details(id: Int, type: MediaType) async throws -> MediaDetails { throw URLError(.badURL) }
    func episodes(showId: Int, season: Int) async -> [Episode] { [] }
    func search(query: String) async -> [MediaItem] { [] }
}
