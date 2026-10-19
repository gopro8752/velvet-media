' Targeted v2 receiver. No external source URL is accepted and no resolver is
' involved in starting a handoff. The backend's presence lease expires in 12s.
sub initHandoff()
    device = CreateObject("roDeviceInfo")
    m.handoffDevice = device
    m.handoffDeviceId = m.registry.Read("handoffDeviceId")
    if not handoffUUID(m.handoffDeviceId)
        m.handoffDeviceId = device.GetRandomUUID()
        m.registry.Write("handoffDeviceId", m.handoffDeviceId)
    end if
    m.handoffSessionId = device.GetRandomUUID()
    m.handoffName = Left(device.GetFriendlyName(), 80)
    if m.handoffName.Trim() = "" then m.handoffName = "Velvet on Roku"
    m.handoffSequence = m.registry.Read("handoffSequence").ToInt()
    if m.handoffSequence < 0 then m.handoffSequence = 0
    reserveHandoffSequence()
    m.handoffEnabled = true
    m.handoffAdvertised = false
    m.handoffPresencePending = false
    m.handoffClaimPending = false
    m.handoffActive = invalid
    m.handoffCandidate = invalid
    m.pendingHandoffItem = invalid
    m.handoffStream = invalid
    m.handoffPlayId = -1
    m.handoffAckState = ""
    m.handoffAckPending = false
    m.handoffLastPresence = 0
    if m.handoffTimer = invalid then m.handoffTimer = m.top.CreateChild("Timer")
    m.handoffTimer.duration = 4
    m.handoffTimer.repeat = true
    m.handoffTimer.UnobserveField("fire")
    m.handoffTimer.ObserveField("fire", "onHandoffTick")
    m.handoffTimer.control = "start"
end sub

sub reserveHandoffSequence()
    ' Reserve a block before using it so relaunch never replays an old sequence;
    ' avoid a registry flush on every four-second heartbeat.
    m.handoffReserved = m.handoffSequence + 10000
    m.registry.Write("handoffSequence", m.handoffReserved.ToStr())
    m.registry.Flush()
end sub

function handoffUUID(value as String) as Boolean
    return CreateObject("roRegex", "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", "").IsMatch(value)
end function

function handoffEligible() as Boolean
    if m.handoffEnabled <> true or m.baseUrl = "" or m.profileId = "" then return false
    if not m.top.visible or not m.top.IsInFocusChain() then return false
    if VStr(VGet(activeProfile(), "id")) = "" then return false
    if m.top.HasField("exitRequested") and m.top.exitRequested then return false
    ' SceneGraph stops with the app. HDMI adds a useful disconnected-display
    ' check on STBs; Roku TVs do not implement the HDMI status interface.
    if m.handoffDevice.GetModelType() = "STB"
        hdmi = CreateObject("roHdmiStatus")
        if hdmi <> invalid and not hdmi.IsConnected() then return false
    end if
    return true
end function

function handoffContext() as Object
    return {sessionId: m.handoffSessionId, deviceId: m.handoffDeviceId}
end function

sub sendHandoffPresence(available as Boolean)
    if m.handoffSequence + 1 >= m.handoffReserved then reserveHandoffSequence()
    m.handoffSequence += 1
    body = {deviceId: m.handoffDeviceId, sessionId: m.handoffSessionId, name: m.handoffName, profileId: m.profileId, sequence: m.handoffSequence, available: available}
    context = handoffContext()
    context.available = available
    m.handoffPresencePending = true
    requestApi("handPresence", "/handoff/presence", "POST", body, context, 4500)
end sub

sub onHandoffTick()
    if m.handoffEnabled <> true then return
    if not handoffEligible()
        if m.handoffAdvertised and not m.handoffPresencePending then sendHandoffPresence(false)
        m.handoffAdvertised = false
        if m.handoffActive <> invalid and m.handoffAckState = "" then onHandoffFailure("The Roku is no longer active.")
        return
    end if
    if not m.handoffPresencePending then sendHandoffPresence(true)
    if m.handoffActive <> invalid
        if VNowMs() > VNum(VGet(m.handoffActive, "expiresAt")) + 12000
            onHandoffClose()
            return
        end if
        if m.handoffAckState = ""
            if VNowMs() >= VNum(VGet(m.handoffActive, "expiresAt")) then onHandoffFailure("The handoff expired before playback started.")
            onHandoffPlaying()
        else if not m.handoffAckPending
            sendHandoffAck(m.handoffAckState)
        end if
    end if
end sub

sub handleHandoffResponse(kind as String, data as Object, context as Dynamic)
    if VStr(VGet(context, "sessionId")) <> m.handoffSessionId then return
    if VNum(VGet(data, "protocolVersion")) <> 2
        onHandoffRequestFailed(kind, context)
        return
    end if
    if kind = "handPresence"
        m.handoffPresencePending = false
        available = VBool(VGet(context, "available"))
        m.handoffAdvertised = available and VBool(VGet(data, "accepted"))
        if not m.handoffAdvertised or not handoffEligible() then return
        m.handoffLastPresence = VNowMs()
        if not m.handoffClaimPending and m.handoffActive = invalid and m.handoffCandidate = invalid
            m.handoffClaimPending = true
            ' Claim is deny_unknown_fields: exactly these two identity fields.
            requestApi("handClaim", "/handoff/v2/claim", "POST", handoffContext(), handoffContext(), 4500)
        end if
    else if kind = "handClaim"
        m.handoffClaimPending = false
        candidate = VGet(data, "handoff")
        if Type(candidate) <> "roAssociativeArray" then return
        if not handoffEligible() or not validHandoff(candidate)
            rejectHandoff(candidate, "This handoff cannot be played on this Roku.")
            return
        end if
        m.handoffCandidate = candidate
        statusContext = handoffContext()
        statusContext.id = VStr(candidate.id)
        requestApi("handStatus", "/handoff/v2/status?id=" + VEncode(candidate.id), "GET", invalid, statusContext, 4500)
    else if kind = "handStatus"
        candidate = m.handoffCandidate
        if candidate = invalid then return
        if VStr(VGet(context, "id")) <> VStr(VGet(candidate, "id")) then return
        m.handoffCandidate = invalid
        if VStr(VGet(data, "id")) <> VStr(candidate.id) or VStr(VGet(data, "state")) <> "claimed" then return
        if not handoffEligible() or not validHandoff(candidate)
            rejectHandoff(candidate, "The Roku is no longer active.")
            return
        end if
        beginHandoff(candidate)
    else if kind = "handAck"
        if m.handoffActive = invalid then return
        if VStr(VGet(context, "id")) <> VStr(m.handoffActive.id) then return
        m.handoffAckPending = false
        status = VGet(data, "status", {})
        accepted = VBool(VGet(data, "accepted"))
        terminalState = VStr(VGet(status, "state"))
        stopCancelledPlayback = not accepted and terminalState <> "claimed" and terminalState <> "started" and m.handoffPlayId = m.playGeneration
        if accepted or terminalState <> "claimed"
            m.handoffActive = invalid
            m.pendingHandoffItem = invalid
            m.handoffStream = invalid
            m.handoffAckState = ""
            if stopCancelledPlayback then closePlayback()
            if accepted and m.playerMenuPage = "streams" then openSourcePicker(0)
        end if
    end if
end sub

sub onHandoffRequestFailed(kind as String, context as Dynamic)
    if VStr(VGet(context, "sessionId")) <> m.handoffSessionId then return
    if kind = "handPresence"
        m.handoffPresencePending = false
        m.handoffAdvertised = false
    else if kind = "handClaim"
        m.handoffClaimPending = false
    else if kind = "handStatus"
        if m.handoffCandidate <> invalid
            if VStr(VGet(context, "id")) <> VStr(VGet(m.handoffCandidate, "id")) then return
            rejectHandoff(m.handoffCandidate, "Could not verify the handoff.")
            m.handoffCandidate = invalid
        end if
    else if kind = "handAck"
        if m.handoffActive = invalid then return
        if VStr(VGet(context, "id")) <> VStr(VGet(m.handoffActive, "id")) then return
        m.handoffAckPending = false
    end if
end sub

function validHandoff(value as Object) as Boolean
    if not handoffUUID(VStr(VGet(value, "id"))) then return false
    hint = VGet(value, "sourceHint", {})
    sid = VStr(VGet(hint, "streamId"))
    if not CreateObject("roRegex", "^[0-9a-f]{16}$", "").IsMatch(sid) then return false
    if VStr(VGet(value, "playbackPath")) <> "/stream/" + sid then return false
    if VNum(VGet(value, "mediaId")) <= 0 then return false
    kind = VStr(VGet(value, "type"))
    if kind <> "movie" and kind <> "show" and kind <> "series" then return false
    if kind <> "movie"
        if VNum(VGet(value, "season"), -1) < 0 or VNum(VGet(value, "episode")) < 1 then return false
    end if
    if VNum(VGet(value, "positionMs"), -1) < 0 or VNum(VGet(value, "positionMs")) > 604800000 then return false
    if VNum(VGet(value, "expiresAt")) <= VNowMs() then return false
    profileId = VStr(VGet(value, "profileId"))
    for each profile in VArray(m.sync.profiles)
        if VStr(VGet(profile, "id")) = profileId and not VBool(VGet(profile, "deleted")) then return true
    end for
    return false
end function

sub rejectHandoff(value as Object, message as String)
    id = VStr(VGet(value, "id"))
    if not handoffUUID(id) then return
    body = handoffContext()
    body.id = id
    body.state = "failed"
    body.error = Left(message, 240)
    requestApi("handReject", "/handoff/v2/ack", "POST", body, handoffContext(), 4500)
end sub

sub beginHandoff(value as Object)
    onHandoffClose()
    m.model.Delete("choice")
    closeCategoryComposer(false)
    dismissScopedKeyboard()
    profileId = VStr(value.profileId)
    if m.profileId <> profileId
        m.profileId = profileId
        m.generation += 1
        m.history = []
        m.categories = []
        m.registry.Write("profileId", profileId)
        m.registry.Flush()
        m.model = {page: "home", busy: false, message: "", rows: []}
        composeHome()
        requestApi("savedCategories", "/categories/saved?profileId=" + VEncode(profileId), "GET", invalid, {profileId: profileId})
    end if
    kind = VStr(value.type)
    if kind = "series" then kind = "show"
    item = {mediaId: value.mediaId, type: kind, title: VStr(VGet(value, "title")), positionMs: VNum(value.positionMs)}
    if kind = "show"
        item.season = value.season
        item.episode = value.episode
    end if
    startPlayback(item, false)
    m.handoffActive = value
    m.pendingHandoffItem = item
    m.handoffPlayId = m.playGeneration
    m.handoffAckState = ""
    m.handoffAckPending = false
    hint = value.sourceHint
    m.handoffStream = {url: m.baseUrl + value.playbackPath, name: VStr(VGet(hint, "sourceName"), "Velvet"), title: VStr(VGet(hint, "title")), behaviorHints: {filename: VStr(VGet(hint, "title")), bingeGroup: VStr(VGet(hint, "bingeGroup"))}}
end sub

' Invoke once playDetails has enriched playItem, immediately before its normal
' resolvePlayback(). This replaces only the resolver step, retaining episode UI.
function applyHandoffExactStream() as Boolean
    if m.handoffActive = invalid or m.handoffPlayId <> m.playGeneration or m.handoffStream = invalid then return false
    if not handoffEligible() or not validHandoff(m.handoffActive)
        onHandoffFailure("The handoff is no longer available.")
        playbackFailure("The handoff is no longer available. Send it again from your phone.")
        return true
    end if
    compatible = VCompatibleStreams([m.handoffStream], m.supportsHevc, m.supportsUhd, invalid, true)
    if VArray(VGet(compatible, "streams")).Count() = 0
        message = "The stream from your phone uses video this Roku cannot play. Choose a compatible stream on your phone and send it again."
        if VNum(VGet(compatible, "incompatibleAudio")) > 0 then message = "The stream from your phone uses audio this Roku cannot decode. Choose a compatible stream on your phone and send it again."
        onHandoffFailure(message)
        playbackFailure(message)
        return true
    end if
    m.lastPosition = VNum(m.handoffActive.positionMs) / 1000#
    m.streams = [m.handoffStream]
    m.allStreams = m.streams
    m.sourceIndex = 0
    m.formatRetry = false
    m.inQueue = false
    m.playerAlternativesNeeded = true
    requestPlayerMetadata()
    playCurrentStream()
    return true
end function

function handoffRequiresExactSource() as Boolean
    return m.handoffActive <> invalid and m.handoffPlayId = m.playGeneration and m.handoffAckState = ""
end function

' Called after native state/position events. A mere buffering/playing transition
' is not success until the exact source has actually reached the sent position.
sub onHandoffPlaying()
    if not handoffRequiresExactSource() then return
    if m.video.state <> "playing" then return
    target = VNum(m.handoffActive.positionMs) / 1000#
    position = VNum(m.lastPosition)
    if position < maxHandoffZero(target - 2) or position > target + 15 then return
    if not m.sourceHasAdvanced then return
    sendHandoffAck("started")
end sub

function maxHandoffZero(value as Double) as Double
    if value < 0 then return 0
    return value
end function

sub sendHandoffAck(state as String)
    if m.handoffActive = invalid or m.handoffAckPending then return
    body = handoffContext()
    body.id = m.handoffActive.id
    body.state = state
    if state = "failed" then body.error = "The exact stream could not start on this Roku."
    context = handoffContext()
    context.id = body.id
    m.handoffAckState = state
    m.handoffAckPending = true
    requestApi("handAck", "/handoff/v2/ack", "POST", body, context, 4500)
end sub

sub onHandoffFailure(message = "The exact stream could not start on this Roku." as String)
    if not handoffRequiresExactSource() then return
    sendHandoffAck("failed")
end sub

sub onHandoffClose()
    if m.handoffActive <> invalid and m.handoffAckState = "" then rejectHandoff(m.handoffActive, "Playback was closed before the handoff completed.")
    if m.handoffCandidate <> invalid then rejectHandoff(m.handoffCandidate, "Playback changed before the handoff completed.")
    m.handoffActive = invalid
    m.handoffCandidate = invalid
    m.pendingHandoffItem = invalid
    m.handoffStream = invalid
    m.handoffPlayId = -1
    m.handoffAckState = ""
    m.handoffAckPending = false
end sub

sub deactivateHandoff()
    if m.handoffEnabled <> true then return
    onHandoffClose()
    if m.profileId <> "" then sendHandoffPresence(false)
    m.handoffEnabled = false
    m.handoffAdvertised = false
    if m.handoffTimer <> invalid then m.handoffTimer.control = "stop"
end sub
