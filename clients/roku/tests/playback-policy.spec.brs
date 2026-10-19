sub main()
    m.failures = 0
    streams = [
        {id: "avc", title: "Example.1080p.H264.AAC", url: "https://backend/stream/1"},
        {id: "hevc", title: "Example.1080p.HEVC.DDP5.1", url: "https://backend/stream/2"},
        {id: "uhd", title: "Example.2160p.HEVC.DDP5.1", url: "https://backend/stream/3"},
        {id: "truehd", title: "Example.1080p.TrueHD.Atmos", url: "https://backend/stream/4"},
        {id: "dtshd", title: "Example.1080p.DTS-HD.MA", url: "https://backend/stream/5"},
        {id: "av1", title: "Example.1080p.AV1.AAC", url: "https://backend/stream/6"},
        {id: "3d", title: "Example.1080p.3D.HSBS.AAC", url: "https://backend/stream/7"}
    ]
    capable = VCompatibleStreams(streams, true, true)
    expect(capable.streams.Count() = 3, "capable Roku keeps three compatible sources")
    expect(capable.incompatibleAudio = 2, "unsupported lossless sources are counted separately")
    expect(capable.streams[0].id = "avc" and capable.streams[1].id = "hevc" and capable.streams[2].id = "uhd", "server ranking remains stable")
    expect(capable.streams[2].url = streams[2].url, "filter does not substitute another stream")
    limited = VCompatibleStreams(streams, false, false)
    expect(limited.streams.Count() = 1 and limited.streams[0].id = "avc", "legacy device excludes unsupported video")
    expect(VUhdEligible("2160p60", "STB", true, true), "UHD decoder and compliant active HDMI output allow 4K")
    expect(VUhdEligible("2160p30b10", "TV", true, false), "integrated 4K TV does not require external HDMI status")
    expect(not VUhdEligible("1080p60b10", "STB", true, true), "UHD decoder on 1080p output cannot select 4K")
    expect(not VUhdEligible("2160p60", "STB", true, false), "4K STB output requires active HDCP 2.2")
    expect(not VUhdEligible("2160p60", "TV", false, true), "4K output cannot substitute for UHD decoding support")
    expect(not VUhdEligible("", "STB", true, true), "unknown output mode cannot promise 4K playback")
    hdOutput = VUhdEligible("1080p60b10", "STB", true, false)
    displayLimited = VCompatibleStreams(streams, true, hdOutput, invalid, true)
    expect(displayLimited.streams.Count() = 4, "1080p output retains HEVC and lossless audio conversion sources")
    expect(displayLimited.streams[1].id = "hevc" and displayLimited.streams[2].id = "truehd", "display guard does not disable 1080p HEVC or TrueHD")
    expect(VCompatibleStreams([streams[2]], true, hdOutput, invalid, true).streams.Count() = 0, "exact 4K handoff uses the same display guard")
    expect(VCompatibleStreams(invalid, true, true).streams.Count() = 0, "empty resolution stays empty")
    expect(VStreamFormat({behaviorHints: {filename: "episode.mp4"}}) = "mp4", "explicit MP4 retains its native container")
    expect(VStreamFormat({behaviorHints: {filename: "episode.mkv"}}) = "mkv", "explicit MKV uses Matroska")
    expect(VStreamFormat({title: "Release.1080p.H264"}) = "mkv", "extensionless resolver release defaults to tested Roku container")
    expect(VStreamFormat({url: "http://backend/live/stream/index.m3u8"}) = "hls", "live HLS stays HLS")

    losslessTags = ["DTS.HD.MA", "DTS HD", "DTS_HD", "DTS:X", "DTS-X", "TRUE.HD", "True HD", "True-HD"]
    for each tag in losslessTags
        result = VCompatibleStreams([
            {title: "Example.1080p.H264.AAC", url: "https://backend/stream/aac"},
            {title: "Example.1080p.H264", behaviorHints: {filename: "Example." + tag + ".mkv"}, url: "https://backend/stream/lossless"}
        ], true, true)
        expect(result.streams.Count() = 1 and result.incompatibleAudio = 1, "punctuation variant is excluded: " + tag)
        expect(result.streams[0].url = "https://backend/stream/aac", "compatible audio remains available for " + tag)
    end for

    expect(VQueueNext(2, 3, 1) = 0, "category loops indefinitely after last item")
    expect(VQueueNext(0, 1, 1) = 0, "single-item category repeats")
    expect(VQueueNext(0, 3, -1) = -1, "previous at first item has no invented target")
    expect(VQueueNext(2, 3, -1) = 1, "previous uses preceding queue item")
    expect(VQueueNext(0, 0, 1) = -1, "empty category cannot be played")

    expect(VShouldSaveProgress(120000, 1200000, false, false), "ordinary VOD saves progress")
    expect(not VShouldSaveProgress(120000, 1200000, true, false), "category playback never enters Continue Watching")
    expect(not VShouldSaveProgress(120000, 1200000, false, true), "live playback never enters Continue Watching")
    expect(not VShouldSaveProgress(0, 1200000, false, false), "unstarted content is not saved")
    expect(not VShouldSaveProgress(120000, 0, false, false), "unknown duration is not treated as progress")
    expect(not VCompleted(180000, 1200000), "mid-episode progress remains resumable")
    expect(VCompleted(1140000, 1200000), "95 percent marks completion")
    expect(not VCompleted(0, 0), "missing duration is not completion")

    expect(VMediaMilliseconds(12.3456#) = 12345, "fractional player seconds become truncated whole milliseconds")
    expect(Type(VMediaMilliseconds(12.3456#)) = "Integer", "sync progress is serialized from an integer")
    expect(VMediaMilliseconds(-2.5) = 0, "negative player timestamps are clamped")
    expect(VMediaMilliseconds(invalid) = 0, "unknown player timestamp is zero")
    expect(VMediaMilliseconds(3000000#) = 2147483647, "extreme player timestamp cannot overflow integer progress")
    requestContext = {season: 1, playId: 3}
    expect(VNum(VGet(requestContext, "season")) = 1, "boxed request season retains its identity")
    expect(VNum(VGet(requestContext, "playId"), -1) = 3, "boxed playback generation passes the stale-response gate")
    expect(VStr(VGet(requestContext, "season")) = "1", "boxed season produces a valid catalog path")
    expect(not VReachedPlaybackEnd(0, 1200), "unstarted episode cannot count as completed")
    expect(not VReachedPlaybackEnd(600, 1200), "premature EOF must retry the same episode")
    expect(VReachedPlaybackEnd(1196, 1200), "natural finish within five seconds advances the queue")

    episode = {type: "show", title: "Family Guy", year: 1999, season: 1, episode: 1}
    expect(not VExactEpisodeRelease({behaviorHints: {filename: "Guys.Ultimate.Family.Cruise.2025.1080p.DSCP.WEB-DL.DDP2.0.H.264-FUZEER"}}, episode), "unrelated indexer hit cannot play as Family Guy")
    expect(VExactEpisodeRelease({behaviorHints: {filename: "Family.Guy.S01E01.Death.Has.a.Shadow.1080p.DSNP.WEB-DL.AAC2.0.H.264-PHOENiX"}}, episode), "correct title and exact episode survives")
    expect(VExactEpisodeRelease({behaviorHints: {filename: "Family Guy (1999) - 1x01 - Death Has a Shadow.mkv"}}, episode), "year and alternate coordinate notation match")
    for each wrong in ["Family.Guy.S01E10.mkv", "Family.Guy.S02E01.mkv", "Family.Guy.S01.Complete.mkv", "Family.Guy.S01E01E02.mkv", "Family.Guy.S01E01-E02.mkv", "Family.Guy.S01E01-02.mkv", "Family.Guy.S01E01+E02.mkv", "Family.Guy.S01E01&S01E02.mkv", "Family.Guy.S01E01/E02.mkv", "Family.Guy.S01E01+02.mkv", "Not.Family.Guy.S01E01.mkv"]
        expect(not VExactEpisodeRelease({behaviorHints: {filename: wrong}}, episode), "wrong episode, pack or unrelated show rejected: " + wrong)
    end for
    office = {type: "show", title: "The Office", year: 2005, season: 1, episode: 1}
    expect(not VExactEpisodeRelease({behaviorHints: {filename: "The.Office.UK.S01E01.mkv"}}, office), "unverified country suffix cannot substitute another series")
    expect(VExactEpisodeRelease({behaviorHints: {filename: "The.Office.2005.S01E01.mkv"}}, office), "canonical title and year remain valid")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
