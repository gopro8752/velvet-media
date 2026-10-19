sub main()
    m.failures = 0
    expect(VBackendUrl(" https://velvet.example/ ") = "https://velvet.example", "backend address trims surrounding whitespace and trailing slash")
    expect(VBackendUrl("http://192.0.2.10:8800") <> "", "LAN HTTP backend supported")
    expect(VBackendUrl("file:///etc/passwd") = "", "non-network schemes rejected")
    expect(VBackendUrl("https://name:password@velvet.example") = "", "embedded credentials rejected")
    expect(VBackendUrl("https://velvet.example?token=secret") = "", "query credentials rejected")
    expect(VBackendUrl("https://") = "", "missing host rejected")
    expect(VOrigin("https://Velvet.Example/path") = "https://velvet.example", "origin isolates normalized host")
    expect(VBackendMediaUrl("https://velvet.example", "/live/streams/session/index.m3u8") = "https://velvet.example/live/streams/session/index.m3u8", "relative backend media uses selected backend")
    expect(VBackendMediaUrl("https://velvet.example", "https://evil.example/private") = "", "arbitrary foreign URL cannot receive backend token")
    expect(VBackendMediaUrl("https://velvet.example", "//evil.example/private") = "", "protocol-relative foreign URL rejected")
    expect(VStreamId("https://velvet.example/stream/abc123?x=1") = "abc123", "stream identifier excludes query")
    expect(VStreamId("https://velvet.example/stream/abc123/admin") = "", "nested resource is not a stream ID")
    expect(VRegisteredStreamUrl("http://192.0.2.10:8800", "https://public.example/stream/abc_123-XYZ?temporary=1") = "http://192.0.2.10:8800/stream/abc_123-XYZ", "public resolver URL reuses its registered source on the selected LAN backend")
    expect(VRegisteredStreamUrl("https://velvet.example", "https://foreign.example/video.mp4") = "", "arbitrary source cannot become credential-bearing playback")
    expect(VRegisteredStreamUrl("https://velvet.example", "/stream/../admin") = "", "nested traversal is rejected")
    expect(VRegisteredStreamUrl("https://velvet.example", "/stream/%2e%2e") = "", "encoded path characters are rejected")
    expect(VRegisteredStreamUrl("https://velvet.example", "/stream/abc#fragment") = "", "fragment cannot be interpreted as part of a registered identifier")

    movie = {type: "movie", mediaId: 7, imdbId: "tt0007"}
    show = {type: "show", mediaId: 7, season: 2, episode: 6}
    expect(VMediaKey(movie) <> VMediaKey(show), "same numeric movie/show IDs remain distinct")
    expect(VStreamKey(movie) = "tt0007", "movie resolver uses known IMDb identity")
    expect(VStreamKey(show) = "tmdb:7:2:6", "episode resolver preserves exact season and episode")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
