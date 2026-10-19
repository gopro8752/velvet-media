sub main()
    m.failures = 0
    state = VTelemetryAccumulator()
    state = VTelemetrySample(state, 1000, 0, "buffering", false)
    expect(state.bufferedMs = 1000 and state.playedMs = 0, "loading time is separate from watched time")
    state = VTelemetrySample(state, 1500, 10000, "playing", false)
    expect(state.playedMs = 0 and state.startupMs = -1, "playing signal alone cannot prove advancing playback")
    state = VTelemetrySample(state, 2000, 10500, "playing", true)
    expect(state.playedMs = 500 and state.startupMs = 2000, "confirmed native movement accounts wall time and first startup")
    state = VTelemetrySample(state, 2250, 10500, "playing", false)
    state = VTelemetrySample(state, 2500, 11000, "playing", true)
    expect(state.playedMs = 1000, "heartbeat samples cannot consume the position clock or double count")
    state = VTelemetrySample(state, 3000, 411000, "playing", true)
    expect(state.playedMs = 1000, "forward seeks cannot create watched time")
    state = VTelemetrySample(state, 3500, 401000, "playing", true)
    expect(state.playedMs = 1000, "backward seeks cannot create watched time")
    state = VTelemetrySample(state, 4000, 401500, "playing", true)
    expect(state.playedMs = 1500, "playback resumes accounting after the new seek baseline")
    state = VTelemetrySample(state, 4500, 401500, "paused", false)
    state = VTelemetrySample(state, 6000, 401500, "paused", false)
    expect(state.playedMs = 1500 and state.bufferedMs = 1000, "pause contributes to neither watching nor buffering")
    state = VTelemetrySample(state, 6500, 401500, "playing", false)
    state = VTelemetrySample(state, 9500, 404500, "playing", true)
    expect(state.playedMs = 1500, "suspension gap over two seconds is discarded")
    state = VTelemetrySample(state, 10000, 405000, "playing", true)
    expect(state.playedMs = 2000, "normal sampling resumes after suspension")
    state = VTelemetrySample(state, 10500, 405000, "playing", true)
    expect(state.playedMs = 2000, "unchanged video position cannot accumulate watched time")
    state = VTelemetrySample(state, 11000, 405000, "error", false)
    state = VTelemetrySample(state, 11500, 405000, "error", false)
    expect(state.errorCount = 1, "one native error transition counts once")
    state = VTelemetrySample(state, 12000, 405000, "buffering", false)
    state = VTelemetrySample(state, 12500, 405000, "buffering", false)
    expect(state.bufferedMs = 1500, "source recovery is separately measured as buffering")
    state = VTelemetrySample(state, 13000, 405000, "error", false)
    expect(state.errorCount = 2, "a new recovery failure is a distinct error")
    expect(VTelemetryKind({type: "movie"}, false, {}) = "movie", "movies are their own metric kind")
    expect(VTelemetryKind({type: "show"}, false, {}) = "tv", "episode queues remain TV viewing")
    expect(VTelemetryKind({type: "live"}, true, {id: "fs1"}) = "live_tv", "channels are live TV")
    expect(VTelemetryKind({type: "live"}, true, {sportsEvent: {id: "match"}}) = "live_sports", "sports events are distinct from channels")
    expect(VTelemetryMilliseconds(1234.56#) = 1234, "wire counters are whole milliseconds")
    expect(VTelemetryMilliseconds(-1) = 0, "negative counters cannot go over the wire")
    expect(VTelemetryMilliseconds(3000000000#) = 3000000000#, "long live sessions do not overflow 32-bit milliseconds")
    body = {sessionid: "test", deviceid: "install", devicename: "Roku", appversion: "0.3.0", profileid: "casey", profilename: "Casey", playedms: VTelemetryMilliseconds(3000000000#), bufferedms: 0, errorcount: 0, sourceswitches: 1, startupms: 2000}
    wire = FormatJson(VWireValue(body))
    expect(Instr(1, wire, Chr(34) + "playedMs" + Chr(34) + ":3000000000") > 0, "native lowercase keys become contract camelCase and integer JSON")
    for each key in ["deviceName", "appVersion", "profileName", "bufferedMs", "errorCount", "sourceSwitches", "startupMs"]
        expect(Instr(1, wire, Chr(34) + key + Chr(34)) > 0, "wire name retained: " + key)
    end for
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(value as boolean, message as string)
    if value then return
    m.failures += 1
    print "VELVET_TEST_FAIL "; message
end sub
