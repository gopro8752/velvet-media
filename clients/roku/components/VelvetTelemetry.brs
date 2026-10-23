' Dedicated low-priority reporting. These tasks never occupy resolver, sync or
' playback request slots, never block playback and never expose stream URLs.
sub initTelemetry()
    m.telemetry = invalid
    m.telemetryStartClock = invalid
    m.recoveryGeneration = 0
    m.recoveryLastHeartbeat = 0
    m.manualSourceSwitch = false
    m.telemetryTask = invalid
    m.telemetryPending = []
    m.telemetryDevice = CreateObject("roDeviceInfo")
    m.telemetryDeviceId = m.registry.Read("telemetryDeviceId")
    if m.telemetryDeviceId = ""
        m.telemetryDeviceId = m.telemetryDevice.GetRandomUUID()
        m.registry.Write("telemetryDeviceId", m.telemetryDeviceId)
        m.registry.Flush()
    end if
    app = CreateObject("roAppInfo")
    m.telemetryVersion = app.GetVersion()
    m.telemetryName = Left(m.telemetryDevice.GetFriendlyName(), 80)
    if m.telemetryName.Trim() = "" then m.telemetryName = "Velvet on Roku"
    m.telemetryTimer = m.top.CreateChild("Timer")
    m.telemetryTimer.duration = 1
    m.telemetryTimer.repeat = true
    m.telemetryTimer.ObserveField("fire", "onTelemetryTick")
    m.telemetryTimer.control = "start"
end sub

sub prepareTelemetry()
    endTelemetry("ended")
    m.telemetryStartClock = CreateObject("roTimespan")
    m.telemetryStartClock.Mark()
end sub

sub beginTelemetry()
    if m.telemetry <> invalid then return
    if m.baseUrl = "" or VStr(m.playProfileId) = "" then return
    clock = m.telemetryStartClock
    if clock = invalid
        clock = CreateObject("roTimespan")
        clock.Mark()
    end if
    m.telemetryStartClock = invalid
    m.telemetry = {
        id: m.telemetryDevice.GetRandomUUID(), sequence: 0, clock: clock,
        baseUrl: m.baseUrl, token: m.token, profileId: m.playProfileId,
        profileName: VStr(VGet(activeProfile(), "name")),
        accumulator: VTelemetryAccumulator(), lastSent: 0, source: "", lastSentState: ""
    }
    sendTelemetry("buffering")
end sub

function telemetryNativeState() as string
    if m.playResolving or m.rokuAudioPending or m.rokuAudioStartTarget >= 0 then return "buffering"
    state = m.video.state
    if state = "playing" and (not m.video.visible or m.seekShouldPause) then return "paused"
    if state = "playing" or state = "paused" or state = "buffering" or state = "error" then return state
    return "buffering"
end function

sub sampleTelemetry(observePosition = false as boolean)
    if m.telemetry = invalid then return
    now = m.telemetry.clock.TotalMilliseconds()
    state = telemetryNativeState()
    m.telemetry.accumulator = VTelemetrySample(m.telemetry.accumulator, now, m.lastPosition * 1000#, state, observePosition)
    if state = "playing" and VNum(VGet(m.telemetry.accumulator, "startupMs"), -1) < 0 then state = "buffering"
    if state <> m.telemetry.lastSentState then sendTelemetry(state)
end sub

sub onTelemetryTick()
    if m.telemetry = invalid then return
    sampleTelemetry(false)
    if m.telemetry.clock.TotalMilliseconds() - m.telemetry.lastSent >= 15000 then sendTelemetry()
end sub

sub telemetrySourceStarted()
    if m.telemetry = invalid then beginTelemetry()
    if m.telemetry = invalid then return
    sampleTelemetry(false)
    source = VStr(VGet(m.streams[m.sourceIndex], "url"))
    if m.telemetry.source <> "" and source <> m.telemetry.source then recoveryHeartbeat(true)
    m.telemetry.accumulator = VRecoveryBeginSource(m.telemetry.accumulator, source, m.manualSourceSwitch)
    m.manualSourceSwitch = false
    m.recoveryGeneration += 1
    m.recoveryLastHeartbeat = 0
    m.telemetry.source = source
    ' Restart the motion baseline across source replacement or audio preroll.
    m.telemetry.accumulator.motionState = "buffering"
end sub

sub endTelemetry(state = "ended" as string)
    if m.telemetry = invalid then return
    sampleTelemetry(true)
    if state = "error" and VStr(VGet(m.telemetry.accumulator, "lastState")) <> "error"
        m.telemetry.accumulator.errorCount = VNum(VGet(m.telemetry.accumulator, "errorCount")) + 1
    end if
    sendTelemetry(state)
    recoveryHeartbeat(true)
    m.telemetry = invalid
end sub

sub sendTelemetry(state = "" as string)
    if m.telemetry = invalid then return
    if state = "" then state = telemetryNativeState()
    counters = m.telemetry.accumulator
    if state = "playing" and VNum(VGet(counters, "startupMs"), -1) < 0 then state = "buffering"
    kind = VTelemetryKind(m.playItem, m.isLive, m.playChannel)
    mediaId = VStr(VGet(m.playItem, "mediaId"))
    if kind = "live_tv" then mediaId = VStr(VGet(m.playChannel, "id"))
    if kind = "live_sports" then mediaId = VStr(VGet(VGet(m.playChannel, "sportsEvent"), "id"))
    m.telemetry.sequence += 1
    body = {
        sessionId: m.telemetry.id, sequence: m.telemetry.sequence,
        deviceId: m.telemetryDeviceId, deviceName: m.telemetryName,
        platform: "roku", appVersion: m.telemetryVersion,
        profileId: m.telemetry.profileId, profileName: m.telemetry.profileName,
        kind: kind, mediaId: mediaId, title: VStr(VGet(m.playItem, "title")),
        state: state, playedMs: VTelemetryMilliseconds(VGet(counters, "playedMs")),
        bufferedMs: VTelemetryMilliseconds(VGet(counters, "bufferedMs")),
        errorCount: VNum(VGet(counters, "errorCount")), sourceSwitches: VNum(VGet(counters, "sourceSwitches")),
        positionMs: VMediaMilliseconds(m.lastPosition)
    }
    if kind = "tv"
        body.season = VNum(VGet(m.playItem, "season"))
        body.episode = VNum(VGet(m.playItem, "episode"))
    end if
    if not m.isLive
        body.telemetryVersion = 2
        body.buildChannel = "stable"
        body.sourceSwitchAttempts = counters.automaticSwitchAttempts + counters.manualSwitchAttempts
        body.successfulSourceSwitches = counters.sourceSwitches
        for each key in ["automaticSwitchAttempts", "manualSwitchAttempts", "automaticSourceSwitches", "manualSourceSwitches", "rebufferCount", "seekCount"]
            body.AddReplace(key, VNum(VGet(counters, key)))
        end for
        for each key in ["rebufferedMs", "maxRebufferMs"]
            body.AddReplace(key, VTelemetryMilliseconds(VGet(counters, key)))
        end for
    end if
    if VNum(VGet(counters, "startupMs"), -1) >= 0 then body.startupMs = VTelemetryMilliseconds(VGet(counters, "startupMs"))
    request = {id: m.telemetry.id + ":" + m.telemetry.sequence.ToStr(), baseUrl: m.telemetry.baseUrl, token: m.telemetry.token, path: "/telemetry/playback", method: "POST", body: body, timeout: 5000}
    ' Keep only the newest cumulative payload for each pending session.
    for i = m.telemetryPending.Count() - 1 to 0 step -1
        if VStr(VGet(m.telemetryPending[i].body, "sessionId")) = m.telemetry.id then m.telemetryPending.Delete(i)
    end for
    m.telemetryPending.Push(request)
    while m.telemetryPending.Count() > 8
        m.telemetryPending.Shift()
    end while
    m.telemetry.lastSent = m.telemetry.clock.TotalMilliseconds()
    m.telemetry.lastSentState = state
    drainTelemetry()
end sub

sub drainTelemetry()
    if m.telemetryTask <> invalid or m.telemetryPending.Count() = 0 then return
    request = m.telemetryPending.Shift()
    ' Backend changes must never forward a retained token to another server.
    if request.baseUrl <> m.baseUrl
        drainTelemetry()
        return
    end if
    m.telemetryTask = CreateObject("roSGNode", "ApiTask")
    m.telemetryTask.request = request
    m.telemetryTask.ObserveField("result", "onTelemetryResult")
    m.telemetryTask.control = "RUN"
end sub

sub onTelemetryResult(event as object)
    if m.telemetryTask = invalid then return
    if VStr(VGet(event.GetData(), "id")) <> VStr(VGet(m.telemetryTask.request, "id")) then return
    m.telemetryTask.UnobserveField("result")
    m.telemetryTask = invalid
    ' No UI error, retry storm, or playback failure on an older/offline backend.
    ' The next cumulative heartbeat repairs an ordinary transient loss.
    drainTelemetry()
end sub

sub resetTelemetryBackend()
    endTelemetry("ended")
    if m.telemetryTask <> invalid
        m.telemetryTask.UnobserveField("result")
        m.telemetryTask.control = "STOP"
        m.telemetryTask = invalid
    end if
    m.telemetryPending = []
end sub

' Position heartbeats bind the watch to verified read-ahead and exact repair.
' No speculative buffer-time estimate is sent when Roku cannot expose one.
sub recoveryHeartbeat(stopped = false as boolean)
    if m.telemetry = invalid or m.isLive then return
    source = m.telemetry.source
    if VOrigin(source) <> VOrigin(m.telemetry.baseUrl) then return
    sid = VStreamId(source)
    if sid = "" then return
    now = m.telemetry.clock.TotalMilliseconds()
    if not stopped and now - m.recoveryLastHeartbeat < 3000 then return
    m.recoveryLastHeartbeat = now
    body = {sessionId: m.telemetry.id, generation: m.recoveryGeneration,
        positionMs: VMediaMilliseconds(m.lastPosition), durationMs: VMediaMilliseconds(m.lastDuration),
        bufferedPositionMs: 0, playing: m.playing and m.video.state <> "paused" and not m.seekShouldPause, stopped: stopped}
    requestApi("recoveryPlayback", "/stream/" + VEncode(sid) + "/playback", "POST", body, {}, 5000)
end sub
