sub initPlayback()
    m.video = m.top.FindNode("video")
    m.video.ObserveField("state", "onVideoState")
    m.video.ObserveField("position", "onVideoPosition")
    m.playbackTimer = m.top.FindNode("playbackTimer")
    m.playbackTimer.ObserveField("fire", "onPlaybackTick")
    m.playing = false
    m.playSessionActive = false
    m.playResolving = false
    m.playGeneration = 0
    m.playItem = {}
    m.streams = []
    m.sourceIndex = 0
    m.queue = []
    m.queueIndex = 0
    m.inQueue = false
    m.isLive = false
    m.liveSession = ""
    m.formatRetry = false
    m.lastPosition = 0
    m.lastDuration = 0
    m.lastProgressSaved = 0
    m.sourceStarted = 0
    m.lastAdvanced = 0
    m.lastPrewarm = 0
    m.reported = false
    m.sourceHasPlayed = false
    m.sourceHasAdvanced = false
    m.pendingSourceRetry = false
    device = CreateObject("roDeviceInfo")
    ' CanDecodeVideo takes codec/profile/level, not pixel dimensions. Incomplete
    ' requests can reject HEVC on 4K hardware before audio compatibility runs.
    ' Roku's UHD streaming example uses HEVC Main level 5.1 (4K at 60 fps).
    hevcCapability = device.CanDecodeVideo({codec: "hevc", profile: "main", level: "4.1"})
    uhdCapability = device.CanDecodeVideo({codec: "hevc", profile: "main", level: "5.1"})
    videoMode = device.GetVideoMode()
    modelType = device.GetModelType()
    hdcp22 = false
    if UCase(modelType) = "STB"
        hdmi = CreateObject("roHdmiStatus")
        if hdmi <> invalid then hdcp22 = hdmi.IsHdcpActive("2.2")
    end if
    decodesUhd = VBool(VGet(uhdCapability, "result"))
    m.supportsUhd = VUhdEligible(videoMode, modelType, decodesUhd, hdcp22)
    m.supportsHevc = decodesUhd or VBool(VGet(hevcCapability, "result"))
    print "[Velvet] video capabilities model="; device.GetModel(); " mode="; videoMode; " hdcp22="; hdcp22; " hevc="; m.supportsHevc; " uhd="; m.supportsUhd
    print "[Velvet] HEVC main/4.1="; FormatJson(hevcCapability); " main/5.1="; FormatJson(uhdCapability)
    initPlayerController()
    initTelemetry()
end sub

sub startPlayback(item as object, queuePlayback as boolean)
    prepareTelemetry()
    onHandoffClose()
    if m.playing then savePlaybackProgress()
    stopRokuAudio()
    m.playGeneration += 1
    m.playProfileId = m.profileId
    m.playSessionActive = false
    m.playing = false
    m.playResolving = true
    m.video.control = "stop"
    m.video.visible = false
    m.view.visible = false
    m.playbackTimer.control = "stop"
    m.inQueue = queuePlayback
    m.isLive = false
    m.playItem = VCopy(item)
    m.streams = []
    m.allStreams = []
    m.sourceIndex = 0
    m.formatRetry = false
    m.pendingSourceRetry = false
    m.lastPosition = 0
    m.lastDuration = 0
    m.lastProgressSaved = 0
    resetPlayerItem()
    m.model.busy = true
    m.model.message = "Finding a stream for your Roku…"
    publishModel()
    requestApi("playDetails", "/catalog/" + VStr(item.type) + "/" + VStr(item.mediaId) + "?date=" + localDate(), "GET", invalid, {playId: m.playGeneration, target: item})
end sub

sub handlePlaybackResponse(kind as string, data as object, context as dynamic)
    if VNum(VGet(context, "playId"), -1) <> m.playGeneration then return
    if kind = "playDetails"
        target = VCopy(VGet(data, "item", m.playItem))
        original = VGet(context, "target", {})
        if target.type = "movie" and not VBool(VGet(data, "digitallyAvailable", true))
            playbackFailure("This movie has not reached streaming yet.")
            return
        end if
        m.playDetails = data
        if target.type = "show"
            progress = findProgress(target)
            season = VGet(original, "season")
            episode = VGet(original, "episode")
            if season = invalid or episode = invalid
                season = VGet(progress, "season")
                episode = VGet(progress, "episode")
            end if
            if season = invalid or episode = invalid
                seasons = VArray(VGet(data, "seasons"))
                if seasons.Count() = 0
                    playbackFailure("No episodes are available yet.")
                    return
                end if
                m.playItem = target
                requestApi("nextSeason", "/catalog/show/" + VStr(target.mediaId) + "/seasons/" + VStr(seasons[0].number), "GET", invalid, {playId: m.playGeneration, first: true})
                return
            end if
            target.season = season
            target.episode = episode
            target.episodeTitle = VGet(original, "episodeTitle", VGet(progress, "episodeTitle", ""))
        end if
        m.playItem = target
        if not m.inQueue and not VBool(VGet(original, "startFromBeginning"))
            progress = findProgress(target)
            same = target.type = "movie" or (VGet(progress, "season") = VGet(target, "season") and VGet(progress, "episode") = VGet(target, "episode"))
            if same and not VCompleted(VNum(VGet(progress, "positionMs")), VNum(VGet(progress, "durationMs"))) then m.lastPosition = VNum(VGet(progress, "positionMs")) / 1000#
        end if
        if applyHandoffExactStream() then return
        resolvePlayback()
    else if kind = "resolve"
        selected = VCompatibleStreams(VGet(data, "streams"), m.supportsHevc, m.supportsUhd, m.playItem, true)
        m.streams = []
        for each stream in selected.streams
            url = VRegisteredStreamUrl(m.baseUrl, VStr(VGet(stream, "url")))
            if url <> ""
                stream.url = url
                m.streams.Push(stream)
            end if
        end for
        if m.streams.Count() = 0
            if selected.incompatibleAudio > 0
                playbackFailure("The available releases use audio this Roku cannot play. Try another release or title; Roku audio conversion is not enabled yet.")
            else
                playbackFailure("No compatible streams are available for this Roku right now.")
            end if
            return
        end if
        m.streams = preferencesStreams(m.streams)
        m.allStreams = m.streams
        m.streams = VFilterBlockedStreams(m.allStreams, currentBlockedGroups())
        m.sourceIndex = 0
        m.formatRetry = false
        playCurrentStream()
    else if kind = "liveTune"
        live = VLivePlaybackDescriptor(m.baseUrl, data, VStr(VGet(m.playChannel, "id")))
        if live = invalid
            rejectedSession = VLiveSessionId(VGet(data, "sessionId"))
            if rejectedSession <> "" then requestApi("liveStop", "/live/sessions/" + VEncode(rejectedSession), "DELETE")
            playbackFailure("The live channel did not return a valid playback address.")
            return
        end if
        m.liveSession = live.sessionId
        m.streams = [{url: live.url, name: m.playItem.title, liveFormat: live.streamFormat, drmParams: live.drmParams}]
        m.sourceIndex = 0
        playCurrentStream()
    else if kind = "nextSeason"
        episodes = VArray(VGet(data, "episodes"))
        available = []
        today = localDate()
        for each episode in episodes
            aired = VStr(VGet(episode, "airDate"))
            if aired = "" or aired <= today then available.Push(episode)
        end for
        episodes = available
        requestedNumber = VNum(VGet(context, "after"), 0)
        direction = VNum(VGet(context, "direction"), 1)
        selectedEpisode = invalid
        if direction < 0
            for each episode in episodes
                if VNum(VGet(episode, "number")) < requestedNumber then selectedEpisode = episode
            end for
        else
            for each episode in episodes
                if selectedEpisode = invalid and VNum(VGet(episode, "number")) > requestedNumber then selectedEpisode = episode
            end for
        end if
        if selectedEpisode = invalid
            seasons = VArray(VGet(m.playDetails, "seasons"))
            currentSeason = VNum(VGet(data, "season"))
            nextSeason = invalid
            for each season in seasons
                number = VNum(VGet(season, "number"))
                if direction > 0 and number > currentSeason and nextSeason = invalid then nextSeason = number
                if direction < 0 and number < currentSeason then nextSeason = number
            end for
            if nextSeason = invalid
                closePlayback()
                return
            end if
            after = 0
            if direction < 0 then after = 100001
            requestApi("nextSeason", "/catalog/show/" + VStr(m.playItem.mediaId) + "/seasons/" + VStr(nextSeason), "GET", invalid, {playId: m.playGeneration, after: after, direction: direction})
            return
        end if
        m.playItem.season = selectedEpisode.season
        m.playItem.episode = selectedEpisode.number
        m.playItem.episodeTitle = selectedEpisode.title
        m.lastPosition = 0
        m.lastDuration = 0
        resolvePlayback()
    end if
end sub

sub resolvePlayback()
    beginTelemetry()
    requestPlayerMetadata()
    kind = "movie"
    if m.playItem.type = "show" then kind = "series"
    requestApi("resolve", "/stream/" + kind + "/" + VEncode(VStreamKey(m.playItem)) + ".json", "GET", invalid, {playId: m.playGeneration}, 120000)
end sub

sub playCurrentStream()
    if m.sourceIndex >= m.streams.Count()
        playbackFailure("These streams could not play on your Roku. Try again or choose another title.")
        return
    end if
    stopRokuAudio()
    stream = m.streams[m.sourceIndex]
    if not m.isLive and rokuAudioNeedsProbe(stream)
        probeRokuAudio(stream)
        return
    end if
    playNativeStream(stream.url, "", Int(m.lastPosition))
end sub

sub playNativeStream(url as string, forcedFormat as string, startPosition as integer)
    telemetrySourceStarted()
    stream = m.streams[m.sourceIndex]
    content = CreateObject("roSGNode", "ContentNode")
    if m.telemetry <> invalid and not m.isLive then url = VAttributedMediaUrl(m.baseUrl, url, m.telemetry.id)
    content.url = url
    content.title = VStr(VGet(m.playItem, "title"))
    if VStr(VGet(m.playItem, "episodeTitle")) <> "" then content.title += " · " + m.playItem.episodeTitle
    content.streamFormat = VStreamFormat(stream)
    if m.formatRetry
        if content.streamFormat = "mp4" then content.streamFormat = "mkv" else content.streamFormat = "mp4"
    end if
    if m.isLive then content.streamFormat = VStr(VGet(stream, "liveFormat"), "hls")
    if forcedFormat <> "" then content.streamFormat = forcedFormat
    content.playStart = startPosition
    content.HttpCertificatesFile = "common:/certs/ca-bundle.crt"
    headers = []
    if m.token <> "" and not m.isLive then headers.Push("Authorization:Bearer " + m.token)
    content.HttpHeaders = headers
    ' A fresh DRM HTTP agent prevents provider/session headers carrying into a
    ' different title. The CDM posts its opaque challenge to the validated relay.
    drmAgent = CreateObject("roHttpAgent")
    drmAgent.SetCertificatesFile("common:/certs/ca-bundle.crt")
    drmAgent.AddHeader("Content-Type", "application/octet-stream")
    m.video.drmHttpAgent = drmAgent
    if m.isLive and VGet(stream, "drmParams") <> invalid then content.drmParams = stream.drmParams
    m.acceptPlayerTracks = false
    retainedPause = m.rokuAudioPaused
    retainedReplay = m.replayState
    resetPlayerTracks()
    if m.rokuAudioSession <> ""
        m.seekShouldPause = retainedPause
        m.replayState = retainedReplay
        if retainedReplay <> invalid and VBool(VGet(retainedReplay, "enableCaptions")) then m.video.globalCaptionMode = "On"
    end if
    m.video.control = "stop"
    m.video.content = content
    startSeeking = m.rokuAudioSession <> "" and m.rokuAudioStartTarget >= 0
    m.video.visible = not startSeeking
    m.video.mute = startSeeking
    if startSeeking then m.video.notificationInterval = 0.1 else m.video.notificationInterval = 0.5
    m.video.autoplayAfterSeek = true
    if m.video.HasField("seekMode")
        if m.rokuAudioSession <> "" then m.video.seekMode = "accurate" else m.video.seekMode = "default"
    end if
    m.view.visible = false
    m.player.visible = true
    m.player.CallFunc("restoreFocus")
    m.playing = true
    m.playSessionActive = true
    m.playResolving = false
    m.model.busy = false
    m.model.message = ""
    m.reported = false
    m.sourceHasPlayed = false
    m.sourceHasAdvanced = false
    m.pendingSourceRetry = false
    m.sourceStarted = VNowMs()
    m.lastAdvanced = m.sourceStarted
    m.lastObservedPosition = m.lastPosition
    print "[Velvet] source attempt "; m.sourceIndex + 1; " format="; content.streamFormat
    m.video.control = "play"
    m.playbackTimer.control = "start"
    publishPlayer()
end sub

sub onVideoPosition()
    if not m.playing then return
    position = m.video.position
    if m.rokuAudioSession <> ""
        starting = m.rokuAudioStartTarget >= 0
        if advanceRokuAudioStartup() then return
        if starting then onVideoState()
        ' Fresh HLS content can briefly report zero before playStart. Do not
        ' turn that into a false source-time advance or overwrite the seek.
        if position <= 0 and not m.sourceHasAdvanced and m.lastPosition > m.rokuAudioOffsetMs / 1000# then return
        position = VRokuAudioTimeline(position, m.rokuAudioOffsetMs, m.rokuAudioDurationMs)
    end if
    if Abs(position - m.lastObservedPosition) > 0.1
        m.sourceHasAdvanced = true
        m.lastAdvanced = VNowMs()
        m.lastObservedPosition = position
    end if
    ' A freshly switched player can briefly report zero before playStart is applied.
    if position > 0 then m.lastPosition = position
    if m.rokuAudioSession = "" and m.video.duration > 0 then m.lastDuration = m.video.duration
    if m.rokuAudioSession <> "" and m.rokuAudioDurationMs > 0 then m.lastDuration = m.rokuAudioDurationMs / 1000#
    if m.replayState <> invalid
        m.replayState = VReplayAdvance(m.replayState, position)
        if VBool(VGet(m.replayState, "readyToRestore")) then finishReplay()
    end if
    sampleTelemetry(true)
    onHandoffPlaying()
    publishPlayer()
end sub

sub onVideoState()
    if not m.playing then return
    sampleTelemetry(false)
    state = m.video.state
    if m.rokuAudioSession = "" and m.video.duration > 0 then m.lastDuration = m.video.duration
    print "[Velvet] video "; state; " code="; m.video.errorCode
    if (state = "playing" or state = "paused" or state = "buffering") and m.rokuAudioStartTarget >= 0
        if advanceRokuAudioStartup()
            publishPlayer()
            return
        end if
    end if
    if state = "error"
        ' Let Roku finish its error/finished transition before reusing Video.
        m.pendingSourceRetry = true
    else if state = "finished"
        if m.pendingSourceRetry or not m.sourceHasPlayed then return
        if not VReachedPlaybackEnd(m.lastPosition, m.lastDuration)
            m.pendingSourceRetry = true
            return
        end if
        m.lastPosition = m.lastDuration
        savePlaybackProgress()
        advanceEpisode(1)
    else if state = "playing"
        if m.rokuAudioSession = "" and not m.isLive and m.video.audioFormat = "none" and not m.rokuAudioNativeProbed
            probeRokuAudio(m.streams[m.sourceIndex], true)
            return
        end if
        ' Some native Matroska decoders ignore autoplayAfterSeek. Reapply the
        ' explicit paused intent until the user presses Play.
        if m.seekShouldPause
            m.video.control = "pause"
        end if
        m.sourceHasPlayed = true
        m.acceptPlayerTracks = true
        onPlayerTracksChanged()
        onHandoffPlaying()
        ' State changes alone do not prove the stream is moving. Only position
        ' changes and intentional pauses refresh the stall watchdog.
        if not m.reported and not m.isLive
            m.reported = true
            imdb = VStr(VGet(m.playItem, "imdbId"))
            if imdb = "" then imdb = "tmdb:" + VStr(m.playItem.mediaId)
            requestApi("report", "/report_play", "POST", {imdbId: imdb, season: VNum(VGet(m.playItem, "season")), episode: VNum(VGet(m.playItem, "episode")), url: m.streams[m.sourceIndex].url})
        end if
    end if
    publishPlayer()
end sub

sub onPlaybackTick()
    keepRokuAudioAlive()
    if not m.playing then return
    recoveryHeartbeat()
    if m.pendingSourceRetry
        m.pendingSourceRetry = false
        failoverStream()
        return
    end if
    now = VNowMs()
    publishPlayer()
    if m.video.state = "paused" and m.rokuAudioStartTarget < 0
        m.lastAdvanced = now
        return
    end if
    stallBudget = 10000
    if m.sourceHasAdvanced then stallBudget = 15000
    ' Rolling HLS needs its initial playback window; ordinary file candidates
    ' keep the short deadline, and every stream returns to it once advancing.
    if (m.isLive or m.rokuAudioSession <> "") and not m.sourceHasAdvanced then stallBudget = 45000
    if now - m.lastAdvanced > stallBudget
        failoverStream()
        return
    end if
    if now - m.lastProgressSaved >= 15000
        savePlaybackProgress()
        m.lastProgressSaved = now
    end if
    if not m.isLive and m.lastDuration > 0 and now - m.lastPrewarm > 20000 and m.sourceIndex + 1 < m.streams.Count()
        sid = VStreamId(m.streams[m.sourceIndex].url)
        if sid <> ""
            fraction = (m.lastPosition + 20) / m.lastDuration
            if fraction > 0.999 then fraction = 0.999
            requestApi("prepare", "/stream/" + VEncode(sid) + "/prepare", "POST", {fraction: fraction})
            m.lastPrewarm = now
        end if
    end if
end sub

sub failoverStream()
    converted = m.rokuAudioSession <> "" or m.rokuAudioFailed
    stopRokuAudio()
    if m.isLive
        playbackFailure("This live channel stopped. Please reopen it to reconnect.")
        return
    end if
    ' The resolver filename may name a release, not the actual media container.
    ' Try both supported containers once before moving to another release.
    if not m.formatRetry and not converted
        m.formatRetry = true
        playCurrentStream()
        return
    end if
    if handoffRequiresExactSource()
        onHandoffFailure()
        playbackFailure("The stream from your phone could not play on this Roku. Choose another stream on your phone and send it again.")
        return
    end if
    m.formatRetry = false
    m.sourceIndex += 1
    playCurrentStream()
end sub

sub savePlaybackProgress()
    if not m.playSessionActive then return
    position = VMediaMilliseconds(m.lastPosition)
    duration = VMediaMilliseconds(m.lastDuration)
    if not VShouldSaveProgress(position, duration, m.inQueue, m.isLive) then return
    record = VCopy(m.playItem)
    record.profileId = m.playProfileId
    record.positionMs = position
    record.durationMs = duration
    record.updatedAt = VNowMs()
    record.deleted = VCompleted(position, duration)
    upsertSync("progress", record)
    body = {progress: [record]}
    if record.deleted and VGet(record, "type") = "show"
        watched = {profileId: m.playProfileId, mediaId: record.mediaId, season: record.season, episode: record.episode, watchedAt: record.updatedAt, updatedAt: record.updatedAt, deleted: false}
        upsertSync("watched", watched)
        body.watched = [watched]
    end if
    requestApi("push", "/push", "POST", body)
end sub

sub closePlayback()
    endTelemetry("ended")
    onHandoffClose()
    savePlaybackProgress()
    stopRokuAudio()
    m.playSessionActive = false
    m.playGeneration += 1
    m.playing = false
    m.playResolving = false
    m.playbackTimer.control = "stop"
    m.video.control = "stop"
    m.video.visible = false
    m.player.CallFunc("resetSession")
    m.player.visible = false
    m.playerMenu = invalid
    m.playerMenuPage = ""
    finishReplay()
    if m.savedCaptionMode <> invalid then m.video.globalCaptionMode = m.savedCaptionMode
    m.savedCaptionMode = invalid
    m.view.visible = true
    if m.liveSession <> "" then requestApi("liveStop", "/live/sessions/" + VEncode(m.liveSession), "DELETE")
    m.liveSession = ""
    m.model.busy = false
    m.model.message = ""
    if m.model.page = "home" then composeHome() else publishModel()
    restoreBrowsePage()
end sub

sub playbackFailure(message as string)
    endTelemetry("error")
    onHandoffFailure(message)
    savePlaybackProgress()
    stopRokuAudio()
    m.playGeneration += 1
    m.playSessionActive = false
    m.playing = false
    m.playResolving = false
    m.playbackTimer.control = "stop"
    m.video.control = "stop"
    m.video.visible = false
    m.view.visible = false
    m.player.visible = true
    m.playerNotice = ""
    m.pendingSourceRetry = false
    items = [{id: "error:retry", label: "Try again", enabled: true}]
    if m.streams.Count() > 0 then items.Push({id: "error:streams", label: "Choose stream", enabled: true})
    if not m.isLive then items.Push({id: "error:options", label: "Playback options", enabled: true})
    items.Push({id: "error:back", label: "Back to browsing", enabled: true})
    m.playerMenuPage = "error"
    m.playerMenu = {title: "Playback unavailable", subtitle: message, items: items}
    publishPlayer()
    m.player.CallFunc("restoreFocus")
end sub

sub advanceEpisode(direction as integer)
    if m.isLive then return
    savePlaybackProgress()
    if m.inQueue
        index = VQueueNext(m.queueIndex, m.queue.Count(), direction)
        if index < 0 then return
        m.queueIndex = index
        startPlayback(m.queue[index], true)
    else if VGet(m.playItem, "type") = "show"
        prepareTelemetry()
        onHandoffClose()
        stopRokuAudio()
        m.playGeneration += 1
        m.playSessionActive = false
        m.playing = false
        m.playResolving = true
        m.video.control = "stop"
        m.playbackTimer.control = "stop"
        m.streams = []
        m.allStreams = []
        m.sourceIndex = 0
        m.formatRetry = false
        m.pendingSourceRetry = false
        m.lastPosition = 0
        m.lastDuration = 0
        m.model.busy = true
        m.model.message = "Finding the next episode…"
        m.video.visible = false
        resetPlayerItem()
        publishModel()
        requestApi("nextSeason", "/catalog/show/" + VStr(m.playItem.mediaId) + "/seasons/" + VStr(m.playItem.season), "GET", invalid, {playId: m.playGeneration, after: m.playItem.episode, direction: direction})
    else
        closePlayback()
    end if
end sub

sub tuneChannel(channel as object)
    closePlayback()
    prepareTelemetry()
    m.playChannel = VCopy(channel)
    m.playGeneration += 1
    m.playProfileId = m.profileId
    m.formatRetry = false
    m.isLive = true
    m.inQueue = false
    m.playResolving = true
    m.playItem = {title: VStr(VGet(channel, "name")), type: "live"}
    beginTelemetry()
    m.streams = []
    m.allStreams = []
    m.sourceIndex = 0
    m.pendingSourceRetry = false
    m.lastPosition = 0
    m.lastDuration = 0
    resetPlayerItem()
    m.model.busy = true
    m.model.message = "Opening " + m.playItem.title + "…"
    publishModel()
    requestApi("liveTune", "/live/tune", "POST", {channelId: channel.id, client: "roku"}, {playId: m.playGeneration}, 85000)
end sub

sub tuneSports(event as object, stream as object)
    closePlayback()
    prepareTelemetry()
    m.playChannel = {sportsEvent: VCopy(event), sportsStream: VCopy(stream), name: VStr(VGet(event, "title"), "Live sports")}
    m.playGeneration += 1
    m.playProfileId = m.profileId
    m.formatRetry = false
    m.isLive = true
    m.inQueue = false
    m.playResolving = true
    m.playItem = {title: m.playChannel.name, type: "live"}
    beginTelemetry()
    m.streams = []
    m.allStreams = []
    m.sourceIndex = 0
    m.pendingSourceRetry = false
    m.lastPosition = 0
    m.lastDuration = 0
    resetPlayerItem()
    m.model.busy = true
    m.model.message = "Opening " + m.playItem.title + "…"
    publishModel()
    body = {}
    body.AddReplace("eventId", VGet(event, "id"))
    body.AddReplace("streamId", VGet(stream, "id"))
    body.AddReplace("source", VGet(stream, "source"))
    body.AddReplace("streamNo", VGet(stream, "streamNo"))
    body.AddReplace("client", "roku")
    requestApi("liveTune", "/sports/tune", "POST", body, {playId: m.playGeneration}, 130000)
end sub
