import XCTest
import Combine
@testable import Velvet

@MainActor
final class ReleaseGroupBlocksTests: XCTestCase {
    private func stream(_ group: String?, title: String = "Show.S01E01.1080p-WRONG", source: String = "Velvet Backend") -> StreamOption {
        StreamOption(url: URL(string: "https://stream.test/file")!, title: title, quality: "1080p",
                     sizeBytes: nil, sourceName: source, bingeGroup: group, headers: [:])
    }

    private func withSettings(_ body: (SettingsStore, UserDefaults) throws -> Void) rethrows {
        let suite = "tv.velvet.tests.release-groups." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(SettingsStore(defaults: defaults), defaults)
    }

    func testExactMetadataIdentifiesGroupAcrossEpisodes() throws {
        let group = try XCTUnwrap(stream("velvet-tsrg").releaseGroupForBlocking())
        XCTAssertEqual(group, ReleaseGroup(key: "velvet-tsrg", label: "tsrg"))
        XCTAssertTrue(stream("velvet-tsrg", title: "Show.S07E03.2160p-TSRG").isReleaseGroupBlocked([group]))
        XCTAssertFalse(stream("velvet-other").isReleaseGroupBlocked([group]))
    }

    func testCustomKeysRetainCasePunctuationAndNamespace() throws {
        let group = try XCTUnwrap(stream("  addon/Release:X|1080p  ").releaseGroupForBlocking())
        XCTAssertEqual(group.key, "addon/Release:X|1080p")
        XCTAssertEqual(group.label, group.key)
        XCTAssertTrue(stream("addon/Release:X|1080p").isReleaseGroupBlocked([group]))
        XCTAssertFalse(stream("addon/release:x|1080p").isReleaseGroupBlocked([group]))
        XCTAssertFalse(stream("other-addon/Release:X|1080p").isReleaseGroupBlocked([group]))
    }

    func testUnknownMetadataNeverGuessesFromSourceOrFilename() {
        XCTAssertNil(stream(nil, title: "Show.S01E01.1080p-TSRG", source: "TSRG").releaseGroupForBlocking())
        for key in [" ", "velvet-", "velvet-unknown", "velvet-rls", "velvet-mkv", "velvet-x265", "velvet-2160p"] {
            XCTAssertNil(stream(key).releaseGroupForBlocking(), key)
        }
        XCTAssertFalse(stream(nil).isReleaseGroupBlocked([ReleaseGroup(key: "velvet-tsrg", label: "tsrg")]))
    }

    func testUnsafeMetadataDoesNotBecomeAnActionOrPersistentKey() {
        XCTAssertNil(stream("group\nsecond line").releaseGroupForBlocking())
        XCTAssertNil(stream("group\u{0085}suffix").releaseGroupForBlocking())
        XCTAssertNil(stream(String(repeating: "x", count: 513)).releaseGroupForBlocking())
        XCTAssertNil(stream(String(repeating: "🍿", count: 257)).releaseGroupForBlocking()) // UTF-16 parity with Android
    }

    func testBlockSurvivesNewStoreAndStaysScopedToOneShow() throws {
        let group = try XCTUnwrap(stream("velvet-tsrg").releaseGroupForBlocking())
        withSettings { settings, defaults in
            XCTAssertTrue(settings.blockReleaseGroup(imdbId: " tt123 ", group: group))
            let restarted = SettingsStore(defaults: defaults)
            XCTAssertEqual(restarted.blockedGroups(imdbId: "tt123"), [group])
            XCTAssertTrue(stream("velvet-tsrg").isReleaseGroupBlocked(restarted.blockedGroups(imdbId: "tt123")))
            XCTAssertFalse(stream("velvet-tsrg").isReleaseGroupBlocked(restarted.blockedGroups(imdbId: "tt456")))
            XCTAssertEqual(restarted.blockedGroups(imdbId: nil), [])
        }
    }

    func testBlockClearsOnlyConflictingStickyPreferenceBeforePublishing() throws {
        let group = try XCTUnwrap(stream("velvet-tsrg").releaseGroupForBlocking())
        withSettings { settings, defaults in
            settings.setStickyReleaseGroup(imdbId: "tt1", bingeGroup: group.key)
            settings.setStickyReleaseGroup(imdbId: "tt2", bingeGroup: group.key)
            var published = false
            let observer = settings.$blockedReleaseGroups.dropFirst().sink { value in
                published = true
                XCTAssertEqual(value["tt1"], [group])
                XCTAssertNil(settings.stickyReleaseGroup(imdbId: "tt1"))
                XCTAssertEqual(settings.stickyReleaseGroup(imdbId: "tt2"), group.key)
            }
            XCTAssertTrue(settings.blockReleaseGroup(imdbId: "tt1", group: group))
            XCTAssertTrue(published)
            observer.cancel()
            settings.setStickyReleaseGroup(imdbId: "tt1", bingeGroup: group.key)
            XCTAssertNil(settings.stickyReleaseGroup(imdbId: "tt1"))
            let restarted = SettingsStore(defaults: defaults)
            XCTAssertNil(restarted.stickyReleaseGroup(imdbId: "tt1"))
            XCTAssertEqual(restarted.stickyReleaseGroup(imdbId: "tt2"), group.key)
        }
    }

    func testUnrelatedStickyPreferenceIsRetainedAndRepeatBlockIsIdempotent() throws {
        let group = try XCTUnwrap(stream("velvet-tsrg").releaseGroupForBlocking())
        withSettings { settings, _ in
            settings.setStickyReleaseGroup(imdbId: "tt1", bingeGroup: "velvet-better")
            XCTAssertTrue(settings.blockReleaseGroup(imdbId: "tt1", group: group))
            XCTAssertTrue(settings.blockReleaseGroup(imdbId: "tt1", group: group))
            XCTAssertEqual(settings.blockedGroups(imdbId: "tt1"), [group])
            XCTAssertEqual(settings.stickyReleaseGroup(imdbId: "tt1"), "velvet-better")
            XCTAssertFalse(settings.blockReleaseGroup(imdbId: " ", group: group))
            XCTAssertFalse(settings.blockReleaseGroup(imdbId: "tt1", group: ReleaseGroup(key: "", label: "made up")))
            XCTAssertEqual(settings.blockedGroups(imdbId: "tt1"), [group])
        }
    }

    func testUnblockPersistsAndOnlyRemovesChosenShowAndGroup() throws {
        let first = try XCTUnwrap(stream("velvet-first").releaseGroupForBlocking())
        let second = try XCTUnwrap(stream("custom-Second").releaseGroupForBlocking())
        withSettings { settings, defaults in
            settings.setStickyReleaseGroup(imdbId: "tt1", bingeGroup: first.key)
            settings.blockReleaseGroup(imdbId: "tt1", group: first)
            settings.blockReleaseGroup(imdbId: "tt1", group: second)
            settings.blockReleaseGroup(imdbId: "tt2", group: first)
            XCTAssertTrue(settings.unblockReleaseGroup(imdbId: "tt1", groupKey: first.key))
            XCTAssertEqual(SettingsStore(defaults: defaults).blockedGroups(imdbId: "tt1"), [second])
            XCTAssertNil(settings.stickyReleaseGroup(imdbId: "tt1")) // Unblock does not silently select it.
            XCTAssertTrue(settings.unblockReleaseGroup(imdbId: "tt1", groupKey: second.key))
            XCTAssertNil(settings.blockedReleaseGroups["tt1"])
            XCTAssertEqual(settings.blockedGroups(imdbId: "tt2"), [first])
            XCTAssertTrue(settings.unblockReleaseGroup(imdbId: "tt2", groupKey: first.key))
            XCTAssertTrue(SettingsStore(defaults: defaults).blockedReleaseGroups.isEmpty)
        }
    }

    func testCorruptBlockDataDoesNotPreventSettingsOrNewBlocks() throws {
        let group = try XCTUnwrap(stream("velvet-first").releaseGroupForBlocking())
        withSettings { _, defaults in
            defaults.set(Data("not-json".utf8), forKey: "blocked_release_groups_by_show_json")
            let settings = SettingsStore(defaults: defaults)
            XCTAssertTrue(settings.blockedReleaseGroups.isEmpty)
            XCTAssertTrue(settings.blockReleaseGroup(imdbId: "tt1", group: group))
            XCTAssertEqual(SettingsStore(defaults: defaults).blockedGroups(imdbId: "tt1"), [group])
        }
    }
}
