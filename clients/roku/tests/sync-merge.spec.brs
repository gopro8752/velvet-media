sub main()
    m.failures = 0
    local = {
        profiles: [{id: "a", name: "Alice", updatedAt: 30, deleted: false}],
        progress: [
            {profileId: "a", type: "show", mediaId: 7, season: 2, episode: 3, positionMs: 500000, updatedAt: 40},
            {profileId: "b", type: "show", mediaId: 7, season: 1, episode: 1, positionMs: 100000, updatedAt: 20}
        ],
        mylist: [{profileId: "a", type: "movie", mediaId: 9, deleted: true, updatedAt: 50}],
        watched: [{profileId: "a", mediaId: 7, season: 2, episode: 2, deleted: false, updatedAt: 20}]
    }
    remote = {
        profiles: [{id: "b", name: "Bob", updatedAt: 25, deleted: false}],
        progress: [
            {profileId: "a", type: "show", mediaId: 7, season: 1, episode: 1, positionMs: 10000, updatedAt: 35},
            {profileId: "a", type: "movie", mediaId: 7, positionMs: 200000, updatedAt: 45},
            {profileId: "b", type: "show", mediaId: 7, season: 1, episode: 2, positionMs: 120000, updatedAt: 50}
        ],
        mylist: [{profileId: "a", type: "movie", mediaId: 9, deleted: false, updatedAt: 45}],
        watched: [{profileId: "a", mediaId: 7, season: 2, episode: 3, deleted: false, updatedAt: 45}]
    }
    merged = VMergeSync(local, remote)
    expect(merged.profiles.Count() = 2, "profiles from both snapshots survive")
    expect(merged.progress.Count() = 3, "movie/show/profile progress identities remain distinct")
    for each item in merged.progress
        if item.profileId = "a" and item.type = "show" then expect(item.positionMs = 500000 and item.episode = 3, "older pull cannot rewind fresh local progress")
        if item.profileId = "b" then expect(item.episode = 2, "newer remote progress replaces same profile identity")
    end for
    expect(merged.mylist[0].deleted, "older remote state cannot resurrect a local removal")
    expect(merged.watched.Count() = 2, "watched episodes merge by season/episode without a media type field")
    newer = VMergeSync(merged, {mylist: [{profileId: "a", type: "movie", mediaId: 9, deleted: false, updatedAt: 55}]})
    expect(not newer.mylist[0].deleted, "a genuinely newer add restores an item")
    expect(VIsoMs("2026-10-18T12:00:00Z") = 1792324800000#, "guide RFC3339 timestamp converts to milliseconds")
    expect(VIsoMs("") = 0, "missing guide time is ignored")
    recent = VNewestFirst([{id: "old", updatedAt: 10}, {id: "new", updatedAt: 30}, {id: "middle", updatedAt: 20}], "updatedAt")
    expect(recent[0].id = "new" and recent[1].id = "middle" and recent[2].id = "old", "continue watching remains newest-first after sync merges")
    wire = FormatJson(VWireValue({progress: [{profileid: "qa", mediaid: 7, positionms: 1234, durationms: 5000, updatedat: 1792324800000#}], channelid: "a"}))
    expect(Instr(1, wire, "profileId") > 0 and Instr(1, wire, "positionMs") > 0 and Instr(1, wire, "updatedAt") > 0 and Instr(1, wire, "channelId") > 0, "native lowercase keys serialize to the shared backend contract recursively")
    wire = FormatJson(VWireValue({progress: [{profileid: "qa", mediaid: 1434, positionms: 12345, durationms: 1200000, updatedat: 1792324800000#}], channelid: "test-channel"}))
    expect(Instr(1, wire, Chr(34) + "profileId" + Chr(34)) > 0, "nested sync identity uses backend camelCase")
    expect(Instr(1, wire, Chr(34) + "positionMs" + Chr(34)) > 0, "nested progress uses backend camelCase")
    expect(Instr(1, wire, Chr(34) + "channelId" + Chr(34)) > 0, "live tune uses backend camelCase")
    expect(Instr(1, wire, Chr(34) + "profileid" + Chr(34)) = 0, "lowercase native literal key is not serialized")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
