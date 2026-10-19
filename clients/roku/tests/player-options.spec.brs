sub main()
    m.failures = 0
    audios = [{Language: "eng", Name: "English 5.1", Track: "audio/3"}, {Language: "spa", Name: "", Track: "audio/9"}]
    options = VTrackOptions(audios, "audio", "audio/9")
    expect(options.Count() = 2 and options[1].id = "audio:audio/9", "audio IDs remain opaque strings")
    expect(options[1].nativeId = "audio/9" and options[1].selected, "actual audio track is selected")
    expect(options[1].label = "Spanish", "missing description falls back to readable language")
    expect(options[0].subtitle = "", "language is not repeated beside descriptive name")
    expect(VCleanTrackText("#uniq:English(1)") = "English", "native MKV uniqueness wrapper is never shown to viewers")
    expect(VCleanTrackText("#uniq:English (Commentary)(2)") = "English (Commentary)", "audio label cleanup preserves real descriptive parentheses")
    subs = [{Description: "Español", Language: "spa", TrackName: "sub/10"}, {Description: "English SDH", Language: "eng", TrackName: "sub/20"}]
    options = VTrackOptions(subs, "subtitle", "sub/20", "Off")
    expect(options.Count() = 3 and options[0].selected and not options[2].selected, "caption Off remains separate from selected native track")
    options = VTrackOptions(subs, "subtitle", "sub/20", "On")
    expect(options[2].selected and options[2].id = "subtitle:sub/20", "caption selection preserves exact native ID")
    expect(VPreferredSubtitleTrack(subs) = "sub/20", "replay chooses English ahead of first language")
    expect(VPreferredSubtitleTrack([{TrackName: "es", Language: "spa"}]) = "es", "replay falls back to first available track")
    expect(VTrackOptions([{Track: "a"}, {Track: "a"}, {}], "audio").Count() = 1, "duplicate or unselectable tracks are omitted")
    expect(VTrackOptions([{Track: "TrackA"}, {Track: "tracka"}], "audio").Count() = 2, "native IDs differing only by case remain distinct")
    expect(VPreferredSubtitleTrack([]) = "", "missing subtitles do not invent a track")

    expect(VReleaseGroup(" velvet-PHOENiX ").key = "velvet-PHOENiX", "group retains source-provided exact key")
    expect(VReleaseGroup("velvet-PHOENiX").label = "PHOENiX", "namespace is stripped only for display")
    for each invalidKey in ["", "velvet-", "velvet-unknown", "velvet-1080p", "velvet-DL", "abc" + Chr(10) + "def"]
        expect(VReleaseGroup(invalidKey) = invalid, "fallback/control key cannot be blocked: " + invalidKey)
    end for
    expect(VReleaseGroup("Custom:MiXeD").key = "Custom:MiXeD", "custom addon identity remains case sensitive")
    expect(VReleaseGroup(1234) = invalid, "numeric metadata cannot masquerade as an opaque group key")
    expect(VReleaseGroupFromStream({title: "Show.S01E01-Group.mkv"}) = invalid, "filename never invents a blockable release group")
    sources = [{id: 1, behaviorHints: {bingeGroup: "velvet-Group"}}, {id: 2, behaviorHints: {bingeGroup: "velvet-group"}}, {id: 3, title: "Show-Group"}]
    filtered = VFilterBlockedStreams(sources, [{key: "velvet-Group"}])
    expect(filtered.Count() = 2 and filtered[0].id = 2 and filtered[1].id = 3, "block applies only to exact known group identity")

    display = VStreamDisplay({title: "Show.S01E01.1080p.DSNP.WEB-DL.DDP5.1.H.264-SECRET", behaviorHints: {videoSize: 1610612736#}}, 4)
    expect(display.label = "1080p", "stream title uses readable quality")
    expect(display.subtitle = "H.264 · Dolby Digital Plus 5.1 · 1.5 GB", "stream detail includes useful format and size")
    expect(Instr(1, FormatJson(display), "SECRET") = 0 and Instr(1, FormatJson(display), "Show") = 0, "stream cards hide filename and group")
    expect(VStreamDisplay({title: "Movie.2160p.DV.HEVC.TrueHD.7.1.Atmos"}).label = "4K · Dolby Vision", "premium quality badges remain readable")
    expect(VStreamDisplay({}, 2).label = "Stream 3", "unknown stream remains selectable with clean fallback")

    replay = VReplayBegin(100, "Off", "", subs)
    expect(replay.target = 90 and replay.restoreAt = 100 and replay.trackId = "sub/20", "replay jumps ten seconds and picks English")
    expect(replay.enableCaptions and replay.restoreMode = "Off", "temporary captions preserve original mode")
    replay = VReplayAdvance(replay, 100)
    expect(not replay.readyToRestore, "stale pre-seek timestamp cannot end temporary captions")
    replay = VReplayAdvance(replay, 90)
    expect(replay.seekConfirmed and not replay.readyToRestore, "observed rewind arms automatic restore")
    replay = VReplayBegin(92, "On", "sub/20", subs, replay)
    expect(replay.target = 82 and replay.restoreAt = 100 and replay.restoreMode = "Off", "repeated replay preserves original restore state and time")
    replay = VReplayAdvance(VReplayAdvance(replay, 82), 100)
    expect(replay.readyToRestore, "captions restore once replay catches up")
    replay = VReplayBegin(5, "On", "sub/10", subs)
    expect(replay.target = 0 and replay.restoreTrack = "sub/10" and replay.restoreMode = "On", "replay clamps start and preserves explicitly enabled captions")
    expect(not VReplayBegin(12, "Off", "", []).enableCaptions, "no subtitle track does not change caption mode")
    expect(VReplayBegin(12, "Off", "sub/10", subs).trackId = "sub/20", "disabled retained track does not override replay English preference")
    nativeState = CreateObject("roAssociativeArray")
    nativeState.SetModeCaseSensitive()
    nativeState.AddReplace("restoreAt", 100)
    nativeState.AddReplace("restoreMode", "Off")
    nativeState.AddReplace("seekConfirmed", false)
    nativeState.seekConfirmed = true
    nativeState.readyToRestore = true
    expect(VBool(VGet(nativeState, "seekConfirmed")), "native case-sensitive JSON honors the newer dot-written value")
    expect(VBool(VGet(nativeState, "readyToRestore")), "native lowercased replay completion key is readable")
    expect(VNum(VGet(nativeState, "restoreAt")) = 100, "native case-sensitive JSON also reads untouched wire spelling")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
