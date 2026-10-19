sub main()
    m.failures = 0
    now = VGuideEpoch("2026-10-18T16:30:00Z")
    expect(now > 0, "ISO guide timestamp parsed")
    expect(VGuideEpoch("2026-10-18T12:30:00-04:00") = now, "guide offsets normalize to UTC")
    expect(VGuideEpoch("garbage") = -1, "malformed guide time rejected")
    programs = [
        {id: "next", title: "Baseball", startTime: "2026-10-18T17:00:00Z", endTime: "2026-10-18T19:00:00Z", episodeTitle: "Cleveland at New York"},
        {id: "now", title: "SportsCenter", startTime: "2026-10-18T16:00:00Z", endTime: "2026-10-18T17:00:00Z"},
        {id: "old", title: "Expired", startTime: "2026-10-18T15:00:00Z", endTime: "2026-10-18T16:00:00Z"},
        {id: "next", title: "Duplicate", startTime: "2026-10-18T17:00:00Z", endTime: "2026-10-18T19:00:00Z"},
        {id: "bad", title: "Invalid", startTime: "bad", endTime: "2026-10-18T19:00:00Z"}
    ]
    rows = VLiveRows([{id:"espn", name:"ESPN", number:"31", group:"Sports"}, {id:"news", name:"News"}], {channels:[{channelId:"espn", programs:programs}]}, "", now)
    expect(rows.Count() = 2, "channels without guide remain available")
    expect(rows[0].programs.Count() = 2, "expired, duplicate, invalid programs filtered")
    expect(rows[0].current.id = "now", "Now selects current program from unsorted feed")
    expect(rows[0].upcoming.id = "next", "Next selects first future program")
    expect(rows[0].programs[0].id = "now", "schedule ordered by time")
    expect(rows[1].programs.Count() = 0 and rows[1].current = invalid, "missing guide stays empty")
    matches = VLiveRows([rows[0].channel, rows[1].channel], {channels:[{channelId:"espn", programs:programs}]}, " cLEveLand ", now)
    expect(matches.Count() = 1, "search finds upcoming episode title without case sensitivity")
    matches = VLiveRows([rows[0].channel], {}, "31", now)
    expect(matches.Count() = 1, "search matches channel number without schedule")
    matches = VLiveRows([rows[0].channel], {}, "unknown", now)
    expect(matches.Count() = 0, "search excludes unrelated channel")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub
sub expect(value as Boolean, message as String)
    if not value
        print "VELVET_TEST_FAIL " + message
        m.failures += 1
    end if
end sub
