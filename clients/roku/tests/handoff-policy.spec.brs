sub main()
    m.failures = 0
    m.sync = {profiles: [{id: "me", deleted: false}, {id: "gone", deleted: true}]}
    payload = {id: "10000000-0000-0000-0000-000000000001", profileId: "me", mediaId: 1434, type: "show", season: 1, episode: 2, positionMs: 604800000, expiresAt: VNowMs() + 120000, sourceHint: {streamId: "0123456789abcdef", title: "Family.Guy.S01E02.mkv"}, playbackPath: "/stream/0123456789abcdef"}
    expect(validHandoff(payload), "exact episode stream accepted")
    changed = VCopy(payload)
    changed.playbackPath = "https://elsewhere.example/stream/0123456789abcdef"
    expect(not validHandoff(changed), "foreign host rejected")
    changed.playbackPath = "/stream/0123456789abcdef/../other"
    expect(not validHandoff(changed), "path suffix rejected")
    changed = VCopy(payload)
    changed.sourceHint.streamId = "0123456789abcdeF"
    expect(not validHandoff(changed), "noncanonical source ID rejected")
    changed = VCopy(payload)
    changed.profileId = "gone"
    expect(not validHandoff(changed), "deleted profile rejected")
    changed.profileId = "unknown"
    expect(not validHandoff(changed), "unknown profile rejected")
    changed = VCopy(payload)
    changed.expiresAt = VNowMs() - 1
    expect(not validHandoff(changed), "expired handoff rejected")
    changed = VCopy(payload)
    changed.episode = 0
    expect(not validHandoff(changed), "invalid episode rejected")
    changed = VCopy(payload)
    changed.positionMs = -1
    expect(not validHandoff(changed), "negative position rejected")
    expect(handoffUUID("10000000-0000-0000-0000-000000000001"), "UUID accepted")
    expect(not handoffUUID("bad"), "invalid UUID rejected")
    ' The handoff SID already identifies the exact registered episode. Sender
    ' display hints may omit episode coordinates; codec checks still apply.
    displayHint = {name: "Velvet Backend", title: "1080p H.264 AAC", behaviorHints: {filename: "1080p H.264 AAC"}}
    expect(VCompatibleStreams([displayHint], true, true).streams.Count() = 1, "exact handoff does not depend on filename episode matching")
    displayHint.title = "1080p TrueHD Atmos"
    expect(VCompatibleStreams([displayHint], true, true).streams.Count() = 0, "unsupported handoff audio rejected")
    displayHint.title = "2160p HEVC AAC"
    expect(VCompatibleStreams([displayHint], false, true).streams.Count() = 0, "unsupported handoff video rejected")
    expect(VCompatibleStreams([displayHint], true, false).streams.Count() = 0, "unsupported UHD handoff rejected")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub
sub expect(value as Boolean, message as String)
    if not value
        print "VELVET_TEST_FAIL " + message
        m.failures += 1
    end if
end sub
