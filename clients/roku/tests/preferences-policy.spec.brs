sub main()
    m.failures = 0
    context = {epoch: 2, generation: 3, profileId: "a", playGeneration: 4}
    expect(VPreferencesContextCurrent(context, 2, 3, "a", 4), "current keyboard and preference scope is accepted")
    expect(not VPreferencesContextCurrent(context, 3, 3, "a", 4), "old backend keyboard cannot change the new server")
    expect(not VPreferencesContextCurrent(context, 2, 4, "a", 4), "dismissed page menu cannot apply stale choices")
    expect(not VPreferencesContextCurrent(context, 2, 3, "b", 4), "old profile menu cannot mutate the newly selected profile")
    expect(not VPreferencesContextCurrent(context, 2, 3, "a", 5), "handoff playback prevents a stale keyboard from restoring browse focus")
    expect(not VPreferencesContextCurrent(invalid, 2, 3, "a", 4), "missing scope fails closed")
    layouts = {"server-a|old": {hidden: ["continue"]}, "server-a|active": {}, "server-b|old": {}, "server-a|not-yet-synced": {}}
    pruned = VPruneDeletedProfileLayouts(layouts, "server-a", [{id: "old", deleted: true}, {id: "active", deleted: false}])
    expect(not pruned.DoesExist("server-a|old") and pruned.Count() = 3, "a deleted profile loses only its own local home layout")
    expect(pruned.DoesExist("server-b|old") and pruned.DoesExist("server-a|not-yet-synced"), "other backend and not-yet-synced layouts are preserved")
    expect(layouts.Count() = 4, "layout pruning does not mutate the original registry value")
    profiles = [{id: "a", name: "Alex", color: "#8B7CF6", createdAt: 20, updatedAt: 40, deleted: false}, {id: "b", name: "Taylor", color: "#46D369", createdAt: 30, updatedAt: 50, deleted: false}]
    expect(VProfileNameError(profiles, " aLeX ") <> "", "trimmed case-insensitive duplicate profile name is rejected")
    expect(VProfileNameError(profiles, "ALEX", "a") = "", "own name can be recased")
    expect(VProfileNameError(profiles, "  ") <> "", "empty profile cannot be created")
    expect(VNextProfileColor(profiles) = "#F5C76B", "new profile uses first unused palette color")
    deleted = VProfileTombstone(profiles, "a", 10)
    expect(VGet(deleted, "id") = "a" and VGet(deleted, "deleted") and VGet(deleted, "updatedAt") > 40, "deletion tombstones the selected profile with a winning timestamp")
    expect(not profiles[0].deleted and not profiles[1].deleted, "deletion helper cannot mutate other profiles or original sync data")
    expect(VGet(deleted, "createdAt") = 20 and VGet(deleted, "name") = "Alex", "profile tombstone retains identity and original creation date")
    expect(VProfileTombstone([profiles[0]], "a", 60) = invalid, "last profile cannot be deleted")
    expect(VProfileTombstone(profiles, "missing", 60) = invalid, "removed or unknown profile cannot be deleted")

    rows = [{id: "continue"}, {id: "mylist"}, {id: "halloween"}, {id: "popular"}]
    arranged = VOrderedHomeRows(rows, ["halloween", "continue", "halloween", "gone"], ["mylist"])
    expect(arranged.Count() = 3 and arranged[0].id = "halloween" and arranged[1].id = "continue" and arranged[2].id = "popular", "row customization removes duplicates and hidden rows while appending new content")
    moved = VMoveHomeRow(rows, [], "halloween", -1)
    expect(moved[0] = "continue" and moved[1] = "halloween" and moved[2] = "mylist", "moving one row preserves other relative positions")
    expect(VMoveHomeRow(rows, [], "continue", -1)[0] = "continue", "top row cannot move beyond the first position")
    expect(VPreferenceToggle(["mylist"], "mylist").Count() = 0, "showing hidden row restores it")
    expect(VPreferenceToggle([], "mylist")[0] = "mylist", "hiding row records its stable ID")

    streams = [{id: "uhd", title: "2160p"}, {id: "hd1", title: "1080p H.264"}, {id: "hd2", title: "1080p HEVC"}, {id: "low", title: "720p"}]
    preferred = VPreferredQualityStreams(streams, "1080p")
    expect(preferred.Count() = 4 and preferred[0].id = "hd1" and preferred[1].id = "hd2" and preferred[2].id = "uhd", "quality preference keeps stable source ranking and preserves fallback streams")
    expect(VPreferredQualityStreams(streams, "automatic")[0].id = "uhd", "unknown preference cannot discard streams")

    sync = {progress: [
        {profileId: "a", type: "show", mediaId: "100", updatedAt: 500, deleted: false},
        {profileId: "b", type: "show", mediaId: "100", updatedAt: 500, deleted: false},
        {profileId: "a", type: "movie", mediaId: "100", updatedAt: 500, deleted: false}
    ], watched: [
        {profileId: "a", mediaId: "100", season: 1, episode: 1, watchedAt: 400, updatedAt: 500, deleted: false},
        {profileId: "a", mediaId: "100", season: 1, episode: 2, watchedAt: 410, updatedAt: 500, deleted: false},
        {profileId: "b", mediaId: "100", season: 1, episode: 1, watchedAt: 400, updatedAt: 500, deleted: false}
    ]}
    history = VHistoryTombstones(sync, "a", {type: "show", mediaId: "100"}, 500)
    expect(history.progress.Count() = 1 and history.watched.Count() = 2, "clear history is scoped to the selected show and profile")
    expect(VGet(history.progress[0], "updatedAt") = 501 and VGet(history.watched[0], "updatedAt") = 501, "history deletion wins a same-time in-flight sync pull")
    expect(not sync.progress[0].deleted and not sync.watched[0].deleted, "history helper leaves source state untouched")
    history = VHistoryTombstones(sync, "a", {type: "show", mediaId: "100"}, 600, true)
    expect(history.progress.Count() = 1 and history.watched.Count() = 0, "remove from Continue Watching preserves watched episodes")
    history = VHistoryTombstones(sync, "a", {type: "movie", mediaId: "100"}, 600)
    expect(history.progress.Count() = 1 and history.watched.Count() = 0, "movie and show sharing TMDB ID cannot erase each other's history")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
