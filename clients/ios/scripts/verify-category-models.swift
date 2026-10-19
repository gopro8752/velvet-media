import Foundation

/// Run with swiftc together with Models.swift, HomeCategories.swift,
/// StreamLookahead.swift, TmdbRows.swift and SettingsStore.swift. Regression checks for exact episode playback identity
/// and for refusing a backup from another configured streaming source.
@main
struct CategoryContractChecks {
    @MainActor static func main() throws {
        let json = #"""
        {"id":"halloween-nostalgia","title":"Monstober & Nick Halloween","items":[
          {"mediaId":5371,"type":"show","title":"iCarly","season":1,"episode":7,"episodeTitle":"iScream on Halloween"},
          {"mediaId":5371,"type":"show","title":"iCarly","season":1,"episode":7},
          {"mediaId":5371,"type":"show","title":"iCarly","season":6,"episode":3},
          {"mediaId":5371,"type":"show","title":"iCarly","season":1},
          {"mediaId":1,"type":"movie","title":"Invalid movie episode","season":1,"episode":1},
          {"mediaId":0,"type":"show","title":"Invalid show"}
        ]}
        """#
        let rail = try JSONDecoder().decode(HomeCategory.self, from: Data(json.utf8)).validated
        precondition(rail.items.count == 2, "Keep distinct episodes and reject partial/wrong identities")
        precondition(rail.items[0].target.season == 1 && rail.items[0].target.episode == 7)
        precondition(rail.items[0].target.id != rail.items[1].target.id)
        let roundTrip = try JSONDecoder().decode(HomeCategory.self, from: JSONEncoder().encode(rail))
        precondition(roundTrip == rail, "Offline cache must retain episode coordinates")
        let generated = #"{"id":"retro","title":"Cartoons","items":[{"mediaId":1,"type":"show","title":"Example","season":null,"episode":null}]}"#
        let showRail = try JSONDecoder().decode(HomeCategory.self, from: Data(generated.utf8)).validated
        precondition(showRail.items[0].target.season == nil && showRail.items[0].episodeLabel == nil)
        let episodeCategoryJSON = #"""
        {"id":"ai-holidays","title":"Disney Halloween episodes","items":[
          {"mediaId":34573,"type":"show","title":"A.N.T. Farm","season":3,"episode":12,"episodeTitle":"mutANT farm 3.0"},
          {"mediaId":34573,"type":"show","title":"A.N.T. Farm","season":1,"episode":14,"episodeTitle":"mutANT Farm"},
          {"mediaId":5371,"type":"show","title":"iCarly","season":1,"episode":7,"episodeTitle":"iScream on Halloween"}
        ]}
        """#
        let selectedEpisodes = try JSONDecoder().decode(HomeCategory.self,
            from: Data(episodeCategoryJSON.utf8)).validated
        precondition(selectedEpisodes.items.count == 3 && selectedEpisodes.items.allSatisfy { $0.year == nil },
                     "Generated episode categories do not require years or collapse episodes by show")
        let cachedEpisodes = try JSONDecoder().decode([HomeCategory].self,
            from: JSONEncoder().encode([selectedEpisodes]))[0]
        precondition(cachedEpisodes == selectedEpisodes,
                     "Generated category persistence retains selected episode names, coordinates and order")
        let playRequest = CategoryQueueRequest(category: cachedEpisodes, shuffle: false)
        let shuffleRequest = CategoryQueueRequest(category: cachedEpisodes, shuffle: true)
        let playJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(playRequest)) as! [String: Any]
        let shuffleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shuffleRequest)) as! [String: Any]
        let playSeeds = playJSON["items"] as! [[String: Any]]
        let shuffleSeeds = shuffleJSON["items"] as! [[String: Any]]
        precondition(playSeeds.count == 3 && shuffleSeeds.count == 3)
        for (index, entry) in cachedEpisodes.items.enumerated() {
            precondition(playSeeds[index]["mediaId"] as? Int == entry.mediaId
                && playSeeds[index]["season"] as? Int == entry.season
                && playSeeds[index]["episode"] as? Int == entry.episode,
                "Play all must send the exact selected list in its original order")
            precondition(shuffleSeeds[index]["mediaId"] as? Int == entry.mediaId
                && shuffleSeeds[index]["season"] as? Int == entry.season
                && shuffleSeeds[index]["episode"] as? Int == entry.episode,
                "Shuffle changes order on the backend without expanding selected episodes to whole shows")
        }
        precondition(playJSON["shuffle"] as? Bool == false && shuffleJSON["shuffle"] as? Bool == true)
        var episodePass = CategoryQueueCursor(category: cachedEpisodes)
        for (index, entry) in cachedEpisodes.items.enumerated() {
            precondition(episodePass.current?.target == entry.target)
            precondition(episodePass.advance(expectedID: episodePass.id, expectedIndex: index, reason: .completed))
        }
        precondition(episodePass.current?.target == cachedEpisodes.items.first?.target,
                     "Episode categories wrap to their first exact selection")
        let active = URL(string: "https://example.test/token/stream/abc?auth=example")!
        precondition(StreamLookahead.streamId(active) == "abc")
        precondition(StreamLookahead.streamId(URL(string: "https://example.test/stream/series/tt001.json")!) == nil)
        precondition(StreamLookahead.isSibling(URL(string: "https://example.test/token/stream/backup")!, of: active))
        precondition(!StreamLookahead.isSibling(URL(string: "https://other.test/token/stream/backup")!, of: active))
        precondition(!StreamLookahead.isSibling(URL(string: "https://example.test/other/stream/backup")!, of: active))
        precondition(!StreamLookahead.isSibling(URL(string: "http://example.test/token/stream/backup")!, of: active))
        let queueJSON = #"""
        {"id":"shuffled","title":"Halloween pass","items":[
          {"mediaId":5371,"type":"show","title":"iCarly","season":1,"episode":7},
          {"mediaId":34573,"type":"show","title":"A.N.T. Farm","season":1,"episode":7},
          {"mediaId":5371,"type":"show","title":"iCarly","season":6,"episode":3},
          {"mediaId":9,"type":"movie","title":"Movie"},
          {"mediaId":5371,"type":"show","title":"iCarly","season":1,"episode":7},
          {"mediaId":100,"type":"show","title":"Unresolved show"}
        ]}
        """#
        let queue = try JSONDecoder().decode(HomeCategory.self, from: Data(queueJSON.utf8))
        var cursor = CategoryQueueCursor(category: queue)
        precondition(cursor.items.count == 4, "No repeats or guessed episode targets in a pass")
        precondition(cursor.current?.mediaId == 5371 && cursor.next?.mediaId == 34573)
        precondition(cursor.advance(expectedID: cursor.id, expectedIndex: 0, reason: .completed))
        precondition(cursor.current?.mediaId == 34573 && cursor.current?.episode == 7,
                     "Cross-show episodes with identical S/E must retain the next show's identity")
        precondition(!cursor.advance(expectedID: cursor.id, expectedIndex: 0, reason: .completed),
                     "A late ENDED must not consume the next queue item")
        precondition(cursor.advance(expectedID: cursor.id, expectedIndex: 1, reason: .manual))
        precondition(cursor.current?.mediaId == 5371 && cursor.current?.season == 6)
        precondition(cursor.advance(expectedID: cursor.id, expectedIndex: 2, reason: .completed))
        precondition(cursor.current?.type == .movie && cursor.next?.target == cursor.items.first?.target)
        precondition(cursor.advance(expectedID: cursor.id, expectedIndex: 3, reason: .completed))
        precondition(cursor.index == 0 && cursor.current?.target == cursor.items.first?.target,
                     "A completed category starts its next pass")
        precondition(!cursor.advance(expectedID: cursor.id, expectedIndex: 4, reason: .completed))
        var failed = CategoryQueueCursor(category: queue)
        precondition(failed.advance(expectedID: failed.id, expectedIndex: 0, reason: .unavailable))
        precondition(failed.advance(expectedID: failed.id, expectedIndex: 1, reason: .unavailable))
        precondition(!failed.canAutoSkipUnavailable && !failed.advance(expectedID: failed.id, expectedIndex: 2, reason: .unavailable),
                     "The third consecutive unavailable item must stop visibly")
        failed.noteHealthy(expectedID: failed.id, expectedIndex: 1)
        precondition(!failed.canAutoSkipUnavailable, "A late old-player callback cannot reset the outage limit")
        failed.noteHealthy(expectedID: failed.id, expectedIndex: 2)
        precondition(failed.canAutoSkipUnavailable && failed.advance(expectedID: failed.id, expectedIndex: 2, reason: .unavailable))
        let sameShowShuffle = HomeCategory(id: "same-show", title: "Same show shuffle", items: [queue.items[2], queue.items[0]])
        var shuffled = CategoryQueueCursor(category: sameShowShuffle)
        precondition(shuffled.current?.episode == 3)
        precondition(shuffled.advance(expectedID: shuffled.id, expectedIndex: 0, reason: .completed))
        precondition(shuffled.current?.season == 1 && shuffled.current?.episode == 7,
                     "Preserve the server's shuffle order instead of promoting the chronological successor")
        // Story order intentionally differs from release year and numeric ID.
        let movieJSON = #"""
        {"id":"ai-story-order","title":"Movies in story order","items":[
          {"mediaId":30,"type":"movie","title":"Story chapter one","year":"1999"},
          {"mediaId":10,"type":"movie","title":"Story chapter two","year":"2005"},
          {"mediaId":20,"type":"movie","title":"Story chapter three","year":"1977"}
        ]}
        """#
        let movieList = try JSONDecoder().decode(HomeCategory.self, from: Data(movieJSON.utf8)).validated
        let cachedMovies = try JSONDecoder().decode([HomeCategory].self,
            from: JSONEncoder().encode([movieList]))[0]
        let storyOrder = [30, 10, 20]
        precondition(cachedMovies.items.map(\.mediaId) == storyOrder,
                     "Saving a requested movie story order must not sort by release date or ID")
        let movieRequest = CategoryQueueRequest(category: cachedMovies, shuffle: false)
        let moviePayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(movieRequest)) as! [String: Any]
        let movieSeeds = moviePayload["items"] as! [[String: Any]]
        precondition(moviePayload["shuffle"] as? Bool == false
            && movieSeeds.compactMap { $0["mediaId"] as? Int } == storyOrder,
            "Play all must retain the requested story order in its backend request")
        precondition(movieSeeds.allSatisfy {
            $0["type"] as? String == "movie" && $0["season"] == nil && $0["episode"] == nil
        }, "Movie queues must not invent TV episode coordinates")
        var movieCursor = CategoryQueueCursor(category: cachedMovies)
        for step in 0..<(storyOrder.count * 3) {
            let index = step % storyOrder.count
            let id = storyOrder[index]
            precondition(movieCursor.current?.target == PlayTarget(mediaId: id, type: .movie))
            precondition(movieCursor.next?.mediaId == storyOrder[(index + 1) % storyOrder.count])
            precondition(movieCursor.advance(expectedID: movieCursor.id, expectedIndex: index, reason: .completed),
                         "A completed movie must advance to the next movie in the same playlist")
        }
        precondition(movieCursor.index == 0 && movieCursor.current?.mediaId == storyOrder.first,
                     "Multiple complete passes retain requested movie story order")
        precondition(movieCursor.previous == nil
            && !movieCursor.advance(expectedID: movieCursor.id, expectedIndex: 0, reason: .previous),
            "Previous never wraps backward into the previous pass")
        let originalFirstID = movieCursor.id
        precondition(movieCursor.advance(expectedID: movieCursor.id, expectedIndex: 0, reason: .manual))
        let originalSecondID = movieCursor.id
        let originalPrefetchID = movieCursor.nextID
        precondition(movieCursor.previous?.mediaId == storyOrder[0])
        precondition(movieCursor.advance(expectedID: movieCursor.id, expectedIndex: 1, reason: .previous))
        precondition(movieCursor.current?.mediaId == storyOrder[0]
            && movieCursor.id != originalFirstID && movieCursor.id != originalSecondID
            && movieCursor.nextID != originalPrefetchID,
            "Previous keeps story order with a fresh playback and prefetch identity")
        precondition(!movieCursor.advance(expectedID: originalFirstID, expectedIndex: 0, reason: .completed),
                     "A callback from the first visit cannot advance its later backward visit")

        let singleMovie = HomeCategory(id: "one", title: "One movie", items: [cachedMovies.items[0]])
        var repeating = CategoryQueueCursor(category: singleMovie)
        let firstID = repeating.id
        let prefetchedID = repeating.nextID
        let prefetchedTarget = repeating.next?.target
        precondition(prefetchedID == repeating.nextID && prefetchedTarget == repeating.current?.target,
                     "A single movie plans a stable next playback identity before wrap")
        precondition(repeating.advance(expectedID: firstID, expectedIndex: 0, reason: .completed))
        precondition(repeating.id == prefetchedID && repeating.id != firstID
            && repeating.current?.target == prefetchedTarget && repeating.index == 0,
            "A single movie restarts with exactly its prefetched playback identity")
        precondition(!repeating.advance(expectedID: firstID, expectedIndex: 0, reason: .completed),
                     "An old ENDED callback cannot advance a later visit to the same index")
        precondition(repeating.advance(expectedID: repeating.id, expectedIndex: 0, reason: .unavailable))
        repeating.noteHealthy(expectedID: firstID, expectedIndex: 0)
        precondition(repeating.consecutiveFailures == 1,
                     "An old healthy callback cannot reset failures after wrap")
        precondition(repeating.advance(expectedID: repeating.id, expectedIndex: 0, reason: .unavailable))
        precondition(!repeating.canAutoSkipUnavailable
            && !repeating.advance(expectedID: repeating.id, expectedIndex: 0, reason: .unavailable),
            "Three consecutive unavailable attempts stop even in a single-item loop")
        repeating.noteHealthy(expectedID: repeating.id, expectedIndex: 0)
        precondition(repeating.canAutoSkipUnavailable)

        var empty = CategoryQueueCursor(category: HomeCategory(id: "empty", title: "Empty", items: []))
        precondition(empty.next == nil && empty.current == nil
            && !empty.advance(expectedID: empty.id, expectedIndex: 0, reason: .completed))

        let suite = "VelvetCategoryRegression-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy marker", forKey: "doze_marker_json")
        defaults.set(false, forKey: "autoplay_next")
        defaults.set(17, forKey: "autoplay_countdown")
        defaults.set("1080p", forKey: "preferred_quality")
        defaults.set("profile-a", forKey: "active_profile_id")
        defaults.set(["custom_row"], forKey: "row_order")
        defaults.set("keep me", forKey: "unrelated_setting")
        var expected = defaults.persistentDomain(forName: suite)!
        expected.removeValue(forKey: "doze_marker_json")
        let settings = SettingsStore(defaults: defaults)
        precondition(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: expected),
                     "Retiring the idle prompt deletes only its legacy marker")
        precondition(!settings.autoplayNext && settings.autoplayCountdownSecs == 17
            && settings.preferredQuality == "1080p" && settings.activeProfileId == "profile-a")
        print("Category contracts, continuous queues, stale callback guards, outage limits, settings migration and backup-source boundaries passed")
    }
}
