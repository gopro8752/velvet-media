sub main()
    m.failures = 0
    expect(VRokuAudioHint({title: "Movie.2160p.TrueHD.7.1.Atmos"}) = "truehd", "lossless source triggers capability check")
    expect(VRokuAudioHint({title: "Movie.DTS-HD.MA.5.1"}) = "dtshd", "DTS-HD is kept distinct from supported DTS core")
    expect(VRokuAudioHint({title: "Movie.DDP5.1"}) = "eac3", "native Dolby Digital Plus uses its actual codec")
    id = "abc123abc123abc123abc123abc123ab"
    expect(VRokuAudioSessionId(id) = id, "opaque session identifier is accepted")
    expect(VRokuAudioSessionId("../../other") = "" and VRokuAudioSessionId("http://external") = "", "untrusted session IDs cannot escape backend routes")
    expect(VRokuAudioTimeline(12.5, 125000, 300000) = 137.5, "native HLS time maps to original source time")
    expect(VRokuAudioTimeline(200, 125000, 300000) = 300, "source timeline clamps at original duration")
    expect(VRokuAudioNativeStart(137500, 125000) = 12, "initial seek accounts for preceding source keyframe")
    expect(VRokuAudioNativeStart(1, 9000) = 0, "invalid negative native offset cannot be sent")
    target = VRokuAudioNativeTarget(35000, 32115)
    expect(Abs(target - 2.885) < 0.0001, "native seek preserves fractional time after measured keyframe")
    expect(VRokuAudioStartupAction(target, false, "buffering", 0) = "wait", "converted seek waits for native playback readiness")
    expect(VRokuAudioStartupAction(target, false, "playing", 0.033) = "seek", "ignored playStart requires an explicit native seek")
    expect(VRokuAudioStartupAction(target, true, "playing", 0.033) = "wait", "keyframe preroll cannot release video or acknowledge handoff")
    expect(VRokuAudioStartupAction(target, true, "paused", 0.033) = "resume", "paused seek continues hidden preroll until requested position")
    expect(VRokuAudioStartupAction(target, true, "playing", 2.885) = "wait", "optimistic seek target notification cannot complete the gate")
    expect(VRokuAudioStartupAction(target, true, "paused", 2.885) = "resume", "optimistic paused target must not freeze undecoded preroll")
    expect(VRokuAudioStartupAction(target, true, "playing", 2.89, true) = "ready", "settled requested frame permits playback or paused intent to be restored")
    expect(VRokuAudioStartupAction(target, true, "paused", 2.89, true) = "ready", "an accurate settled seek can finish already paused")
    expect(VRokuAudioStartupAction(target, true, "playing", 30, true) = "wait", "live-edge clamping cannot masquerade as a successful resume")
    expect(VRokuAudioRenderedPosition({epoch: 0, clip_id: 4, video: 2.9}, 4) = 2.9, "matching rendered frame uses native stream-relative time")
    expect(VRokuAudioRenderedPosition({epoch: 0, clip_id: 3, video: 40}, 4) = -1, "previous clip rendered timestamp is discarded")
    expect(VRokuAudioRenderedPosition({epoch: 1, clip_id: 4, video: 1700000000}, 4) = -1, "UTC live timestamps cannot become relative seek positions")
    expect(VRokuAudioStartupAction(-1, false, "playing", 0) = "ready", "native sources have no converted startup gate")
    tracks = [{index: 1, codec: "truehd", channels: 8, language: "eng", title: "English Atmos"}, {index: 4, codec: "ac3", channels: 6, language: "spa", title: ""}]
    options = VRokuAudioTrackOptions(tracks, 4)
    expect(options.Count() = 2 and options[1].id = "rokuAudio:4" and options[1].selected, "track selection retains absolute ffprobe stream index")
    expect(options[1].label = "Spanish" and options[1].subtitle = "AC3 · 6 channels", "converted tracks retain useful labels")
    expect(VRokuPreferredAudioIndex(tracks, "Spanish") = 4, "saved audio choice picks original track index")
    expect(VRokuPreferredAudioIndex(tracks, "") = 1 and VRokuPreferredAudioIndex([], "") = -1, "default selects actual first track and empty metadata does not invent one")
    subtitles = [{index: 6, codec: "subrip", language: "spa"}, {index: 9, codec: "ass", language: "eng", title: "English SDH"}, {index: 11, codec: "hdmv_pgs_subtitle", language: "eng"}, {index: 9, codec: "ass", language: "eng"}]
    captionOptions = VRokuSubtitleTrackOptions(subtitles, 9, true)
    expect(captionOptions.Count() = 3 and captionOptions[2].id = "rokuSubtitle:9" and captionOptions[2].selected, "text captions preserve source indexes and exclude image/duplicate tracks")
    expect(VRokuSubtitleTrackOptions(subtitles, 9, false)[0].selected and not VRokuSubtitleTrackOptions(subtitles, 9, false)[2].selected, "carrying a subtitle in HLS does not turn captions on")
    expect(VRokuPreferredSubtitleIndex(subtitles, "Spanish") = 6 and VRokuPreferredSubtitleIndex(subtitles, "") = 9, "subtitle choice follows saved preference then English")
    expect(VRokuPreferredSubtitleIndex([], "") = -1, "missing text captions do not invent selectable tracks")
    expect(VRokuAudioPlaybackPath(id, "/roku/audio/" + id + "/master.m3u8"), "converted subtitle master playlist is accepted")
    expect(not VRokuAudioPlaybackPath(id, "/roku/audio/" + id + "/../index.m3u8") and not VRokuAudioPlaybackPath(id, "https://elsewhere/index.m3u8"), "converted manifests stay within the validated session")
    sources = [{title: "Movie.TrueHD.7.1", url: "/source"}, {title: "Movie.AAC.2.0", url: "/native"}]
    converted = VCompatibleStreams(sources, true, true, invalid, true)
    expect(converted.streams.Count() = 2 and converted.streams[0].url = "/source", "audio conversion keeps original compatible video source ordering")
    expect(VCompatibleStreams([{title: "Movie.AV1.TrueHD"}], true, true, invalid, true).streams.Count() = 0, "audio conversion cannot make unsupported video eligible")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
