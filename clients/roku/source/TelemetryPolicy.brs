' Playback accounting uses monotonic wall time. Position movement is only proof
' that native video is advancing; a seek can never turn into time watched.
function VTelemetryAccumulator() as object
    return {playedMs: 0#, bufferedMs: 0#, errorCount: 0, sourceSwitches: 0, startupMs: -1, lastSampleMs: 0#, lastState: "buffering", motionAtMs: 0#, motionPositionMs: 0#, motionState: "buffering"}
end function

function VTelemetrySample(value as object, nowMs as double, positionMs as double, state as string, observePosition as boolean) as object
    result = VCopy(value)
    elapsed = nowMs - VNum(VGet(result, "lastSampleMs"))
    previousState = VStr(VGet(result, "lastState"))
    ' A missing timer interval (app suspension, sleep) is not playback time.
    if elapsed > 0 and elapsed <= 2000 and state = "buffering" and previousState = "buffering"
        result.bufferedMs = VNum(VGet(result, "bufferedMs")) + elapsed
    end if
    if state = "error" and previousState <> "error" then result.errorCount = VNum(VGet(result, "errorCount")) + 1
    if observePosition and state = "playing"
        motionElapsed = nowMs - VNum(VGet(result, "motionAtMs"))
        motion = positionMs - VNum(VGet(result, "motionPositionMs"))
        continuous = VStr(VGet(result, "motionState")) = "playing"
        ' Small callback jitter is allowed; backwards or large position jumps
        ' establish a new baseline and contribute no watched time.
        if continuous and motionElapsed > 0 and motionElapsed <= 2000 and motion > 0 and motion <= motionElapsed * 1.5 + 750
            result.playedMs = VNum(VGet(result, "playedMs")) + motionElapsed
            if VNum(VGet(result, "startupMs"), -1) < 0 then result.startupMs = nowMs
        end if
        result.motionAtMs = nowMs
        result.motionPositionMs = positionMs
        result.motionState = state
    else if state <> "playing" or previousState <> "playing"
        result.motionAtMs = nowMs
        result.motionPositionMs = positionMs
        result.motionState = state
    end if
    result.lastSampleMs = nowMs
    result.lastState = state
    return result
end function

function VTelemetryKind(item as dynamic, isLive as boolean, channel as dynamic) as string
    if isLive
        if Type(VGet(channel, "sportsEvent")) = "roAssociativeArray" then return "live_sports"
        return "live_tv"
    end if
    if VStr(VGet(item, "type")) = "show" then return "tv"
    return "movie"
end function

function VTelemetryMilliseconds(value as dynamic) as longinteger
    result& = VNum(value)
    if result& < 0 then return 0&
    return result&
end function
