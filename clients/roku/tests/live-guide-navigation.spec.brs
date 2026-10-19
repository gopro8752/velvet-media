sub main()
    m.failures = 0
    now = VGuideEpoch("2026-10-19T12:15:00Z")
    start = VGuideWindowStart(now)
    expect(start = now - 900, "ruler aligns to half-hour boundary")
    programs = VGuidePrograms([
        {id:"current",title:"Morning News",startTime:"2026-10-19T11:00:00Z",endTime:"2026-10-19T12:30:00Z",isLive:true,rating:"TV-G"},
        {id:"next",title:"Film",episodeTitle:"The Great Escape",startTime:"2026-10-19T13:00:00Z",endTime:"2026-10-19T15:00:00Z"}
    ], now)
    segments = VGuideWindowSegments(programs, start)
    expect(segments.Count() = 3, "schedule fills actual program cells and one honest missing interval")
    expect(segments[0].startSeconds = start and segments[0].endSeconds = start + 1800, "current program is clipped to the shared timeline")
    expect(segments[1].program = invalid and segments[1].startSeconds = start + 1800 and segments[1].endSeconds = start + 3600, "gap contains no invented program")
    expect(segments[2].endSeconds = start + 7200, "long program clips at right viewport edge")
    expect(VGuideSegmentAt(segments, start + 1800) = 1, "vertical navigation uses half-open time boundaries")
    expect(VGuideSegmentAt(segments, start + 4000) = 2, "vertical navigation retains selected time across channels")
    expect(programs[0].isLive and programs[0].rating = "TV-G", "optional metadata survives normalization")
    empty = VGuideWindowSegments([], start)
    expect(empty.Count() = 1 and empty[0].program = invalid, "channel without schedule keeps one explicit gap cell")
    destination = VGuideNavigateTime(programs, start, now, now, start + 10800, 1)
    expect(destination.windowStart = start and destination.focusTime = start + 1801, "Right moves to the next interval without losing ruler alignment")
    destination = VGuideNavigateTime(programs, start, start + 4000, now, start + 10800, 1)
    expect(destination.windowStart = start + 3600 and destination.focusTime = start + 7201, "Right past the viewport advances one hour with context preserved")
    destination = VGuideNavigateTime(programs, start + 3600, start + 4000, now, start + 10800, -1)
    expect(destination.windowStart = start and destination.focusTime = start + 3599, "Left from later viewport restores earlier schedule")
    destination = VGuideNavigateTime(programs, start, now, now, start + 10800, -1)
    expect(destination.focusHeader and destination.windowStart = start, "Left at beginning provides a quick route to filters from any channel")
    destination = VGuideNavigateTime(programs, start, start + 4000, now, start + 7200, 1)
    expect(destination.windowStart = start and destination.focusTime = start + 4000, "guide does not scroll endlessly into missing future data")
    row = {channel:{id:"one",name:"News",number:"7"},programs:programs}
    expect(VGuideSearchTime(row, "great escape", now) = start + 3601, "program search lands on its actual future airing")
    expect(VGuideSearchTime(row, "News", now) = now, "channel search stays on what is airing now")
    favorites = VGuideFavoriteIds(["one", "one", "", "two"])
    expect(favorites.Count() = 2, "favorite storage removes duplicate and empty identities")
    favorites = VGuideToggleFavorite(favorites, "one")
    expect(not VGuideHasFavorite(favorites, "one") and VGuideHasFavorite(favorites, "two"), "toggle removes only selected channel")
    favorites = VGuideToggleFavorite(favorites, "one")
    expect(VGuideHasFavorite(favorites, "one"), "toggle adds selected channel")
    rows = VGuideFavoriteRows([row,{channel:{id:"other"},programs:[]}], favorites, true)
    expect(rows.Count() = 1 and rows[0].channel.id = "one", "favorite filter preserves guide rows")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub
sub expect(value as Boolean, message as String)
    if not value
        print "VELVET_TEST_FAIL " + message
        m.failures += 1
    end if
end sub
