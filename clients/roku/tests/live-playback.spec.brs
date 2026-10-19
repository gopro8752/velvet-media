sub main()
    m.failures = 0
    base = "https://velvet.example:8443"
    sid = String(48, "a")
    other = String(48, "b")
    clear = {sessionId: sid, playbackPath: "/live/streams/" + sid + "/index.m3u8", mimeType: "application/vnd.apple.mpegurl", channel: {id: "local-news"}}
    descriptor = VLivePlaybackDescriptor(base, clear, "local-news")
    expect(descriptor <> invalid, "existing clear HLS response remains supported")
    expect(descriptor.streamFormat = "hls" and descriptor.drmParams = invalid, "clear HLS does not initialize DRM")
    expect(descriptor.url = base + clear.playbackPath, "media stays on configured backend origin")
    expect(VLivePlaybackDescriptor(base, clear, "another-channel") = invalid, "requested station identity is verified")
    aliases = VCopy(clear)
    aliases.mimeType = "application/x-mpegURL"
    expect(VLivePlaybackDescriptor(base, aliases) <> invalid, "standard HLS MIME alias works")

    protected = VCopy(clear)
    protected.playbackPath = "/live/streams/" + sid + "/manifest.mpd"
    protected.mimeType = "application/dash+xml"
    protected.drm = {scheme: "widevine", licensePath: "/live/drm/" + sid, multiSession: true, headers: {Authorization: "private-provider-token"}}
    descriptor = VLivePlaybackDescriptor(base, protected, "local-news")
    expect(descriptor <> invalid and descriptor.streamFormat = "dash", "protected DASH uses Roku native DASH playback")
    expect(descriptor.drmParams.keySystem = "Widevine", "Roku native CDM scheme is explicit")
    expect(descriptor.drmParams.licenseServerURL = base + "/live/drm/" + sid, "native license URI is the backend session capability")
    expect(Instr(1, FormatJson(descriptor), "private-provider-token") = 0, "untrusted provider headers never reach Video or the license agent")
    expect(VGet(descriptor.drmParams, "multiSession") = invalid, "Android-specific session option is not a Roku DRM field")

    for each badPath in ["https://elsewhere.example/license", "//elsewhere.example/license", "/admin", "/live/drm/" + other, "/live/drm/" + sid + "?token=x", "/live/drm/" + sid + "#x", "/live/drm/../" + sid]
        bad = VCopy(protected)
        bad.drm.licensePath = badPath
        expect(VLivePlaybackDescriptor(base, bad) = invalid, "reject foreign, cross-session, or unscoped license capability")
    end for
    for each badPath in ["https://elsewhere.example/manifest.mpd", "/live/streams/" + other + "/manifest.mpd", "/live/streams/" + sid + "/../" + other + "/manifest.mpd", "/live/streams/" + sid + "/manifest.mpd?token=x", "/live/streams/" + sid + "/%2e%2e/manifest.mpd"]
        bad = VCopy(protected)
        bad.playbackPath = badPath
        expect(VLivePlaybackDescriptor(base, bad) = invalid, "reject cross-session or malformed media capability")
    end for
    for each scheme in ["playready", "fairplay", "clearkey", "", "Widevine", {}, []]
        bad = VCopy(protected)
        bad.drm.scheme = scheme
        expect(VLivePlaybackDescriptor(base, bad) = invalid, "only declared supported protection is accepted")
    end for
    bad = VCopy(protected)
    bad.drm.multiSession = "true"
    expect(VLivePlaybackDescriptor(base, bad) = invalid, "malformed rotation descriptor is rejected")
    bad = VCopy(protected)
    bad.drm = invalid
    expect(VLivePlaybackDescriptor(base, bad) = invalid, "unadvertised clear DASH is rejected")
    bad = VCopy(clear)
    bad.drm = protected.drm
    expect(VLivePlaybackDescriptor(base, bad) = invalid, "protected HLS is not advertised by this Roku implementation")
    expect(VLivePlaybackDescriptor("https://user:password@velvet.example", protected) = invalid, "credentials cannot appear in the backend origin")
    expect(VLiveSessionId("../../admin") = "" and VLiveSessionId(sid) = sid, "only safe returned session IDs can be released")
    headers = VLiveRequestHeaders("/live/tune")
    expect(headers["X-Velvet-Client"] = "roku", "native Roku identity is advertised in headers")
    expect(headers["X-Velvet-Playback-Capabilities"] = "hls-clear,dash-widevine", "capabilities distinguish protected native DASH from clear HLS remux")
    expect(VLiveRequestHeaders("/sports/tune").Count() = 0, "sports browser flow remains unchanged")
    expect(VLiveRequestHeaders("/live/channels").Count() = 0, "browsing does not request protected playback")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
