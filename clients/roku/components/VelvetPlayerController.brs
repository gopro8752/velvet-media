sub initPlayerController()
    initRokuAudio()
    m.player = m.top.FindNode("player")
    m.player.ObserveField("action", "onPlayerAction")
    m.video.enableUI = false
    for each field in ["availableAudioTracks", "availableSubtitleTracks", "currentAudioTrack", "currentSubtitleTrack"]
        m.video.ObserveField(field, "onPlayerTracksChanged")
    end for
    m.playerMenu = invalid
    m.playerMenuPage = ""
    m.replayState = invalid
    m.savedCaptionMode = invalid
    m.desiredSubtitle = m.registry.Read("subtitleLabel")
    m.desiredAudio = m.registry.Read("audioLabel")
    m.audioPending = false
    m.subtitlePending = false
    m.acceptPlayerTracks = false
    m.seekShouldPause = false
    m.playerNotice = ""
    m.noticeUntil = 0
    m.intro = invalid
    m.introDismissed = false
    m.upNextDismissed = false
    m.playerAlternativesNeeded = false
    m.playerAlternativesPending = false
    m.pendingBlockCurrent = false
    m.seasonEpisodes = []
    m.allStreams = []
    m.blockedReleases = {}
    stored = m.registry.Read("blockedReleases")
    if stored <> ""
        parsed = ParseJson(stored)
        if Type(parsed) = "roAssociativeArray" then m.blockedReleases = parsed
    end if
end sub

sub captureCaptionPreference()
    if m.savedCaptionMode <> invalid then return
    m.savedCaptionMode = m.video.globalCaptionMode
    mode = m.registry.Read("captions")
    if mode = "" then mode = m.savedCaptionMode
    m.captionsDesired = LCase(mode) = "on"
    if m.captionsDesired then m.video.globalCaptionMode = "On" else m.video.globalCaptionMode = "Off"
end sub

sub finishReplay()
    if m.replayState = invalid then return
    m.video.subtitleTrack = VStr(VGet(m.replayState, "restoreTrack"))
    m.video.globalCaptionMode = VStr(VGet(m.replayState, "restoreMode"), "Off")
    print "[Velvet] replay restored captions="; m.video.globalCaptionMode
    m.replayState = invalid
end sub

sub resetPlayerItem()
    finishReplay()
    m.playerMenu = invalid
    m.playerMenuPage = ""
    m.playerNotice = ""
    m.intro = invalid
    m.introDismissed = false
    m.upNextDismissed = false
    m.playerAlternativesNeeded = false
    m.playerAlternativesPending = false
    m.pendingBlockCurrent = false
    m.seasonEpisodes = []
    captureCaptionPreference()
    m.player.visible = true
    m.view.visible = false
    publishPlayer()
    m.player.CallFunc("resetSession")
end sub

sub resetPlayerTracks()
    finishReplay()
    m.seekShouldPause = false
    m.subtitlePending = true
    m.audioPending = true
    if m.captionsDesired then m.video.globalCaptionMode = "On" else m.video.globalCaptionMode = "Off"
end sub

function playerHasPrevious() as boolean
    if m.isLive then return false
    if m.inQueue then return m.queueIndex > 0
    if VGet(m.playItem, "type") <> "show" then return false
    seasons = VArray(VGet(m.playDetails, "seasons"))
    if seasons.Count() = 0 then return VNum(VGet(m.playItem, "episode")) > 1
    return VNum(VGet(m.playItem, "season")) > VNum(VGet(seasons[0], "number")) or VNum(VGet(m.playItem, "episode")) > 1
end function

function playerHasNext() as boolean
    if m.isLive then return false
    if m.inQueue then return m.queue.Count() > 0
    if VGet(m.playItem, "type") <> "show" then return false
    for each season in VArray(VGet(m.playDetails, "seasons"))
        if VNum(VGet(season, "number")) > VNum(VGet(m.playItem, "season")) then return true
    end for
    if m.seasonEpisodes.Count() = 0 then return true
    for each episode in m.seasonEpisodes
        if VNum(VGet(episode, "number")) > VNum(VGet(m.playItem, "episode")) and VStr(VGet(episode, "airDate")) <= localDate() then return true
    end for
    return false
end function

sub publishPlayer()
    if m.player = invalid then return
    subtitle = ""
    if VGet(m.playItem, "type") = "show"
        subtitle = "S" + VStr(VGet(m.playItem, "season")) + " E" + VStr(VGet(m.playItem, "episode"))
        if VStr(VGet(m.playItem, "episodeTitle")) <> "" then subtitle += " — " + m.playItem.episodeTitle
    else if m.isLive
        subtitle = "LIVE"
    end if
    startSeeking = m.rokuAudioStartTarget >= 0
    busy = m.playResolving or m.video.state = "buffering" or m.pendingSourceRetry or m.rokuAudioPending or startSeeking
    status = ""
    if busy
        status = "Loading…"
        if m.playResolving then status = "Finding your stream…"
        if m.sourceIndex > 0 or m.formatRetry then status = "Trying another source…"
        if m.rokuAudioPending then status = "Preparing compatible audio…"
    else if m.noticeUntil > VNowMs()
        status = m.playerNotice
    end if
    streamLabel = ""
    if m.sourceIndex < m.streams.Count() then streamLabel = VStreamDisplay(m.streams[m.sourceIndex], m.sourceIndex).label
    skip = false
    if m.intro <> invalid and not m.introDismissed
        skip = m.lastPosition >= VNum(VGet(m.intro, "startMs")) / 1000# and m.lastPosition < VNum(VGet(m.intro, "endMs")) / 1000#
    end if
    upNext = invalid
    if not m.upNextDismissed and playerHasNext() and m.lastDuration > 0 and m.lastPosition >= m.lastDuration - 25
        label = "Next episode"
        if m.inQueue then label = "Next in your playlist"
        upNext = {label: label, seconds: Int(m.lastDuration - m.lastPosition)}
    end if
    m.player.model = {
        title: VStr(VGet(m.playItem, "title")), subtitle: subtitle,
        position: m.lastPosition, duration: m.lastDuration, buffered: m.lastPosition,
        playing: m.video.state = "playing" and not startSeeking, busy: busy, status: status,
        isLive: m.isLive, episodic: m.inQueue or VGet(m.playItem, "type") = "show",
        hasPrevious: playerHasPrevious(), hasNext: playerHasNext(),
        replayActive: m.replayState <> invalid, captionsEnabled: LCase(m.video.globalCaptionMode) = "on",
        streamLabel: streamLabel, menu: m.playerMenu, backdropUrl: VStr(VGet(m.playItem, "backdropUrl")),
        showBackdrop: m.playResolving or startSeeking, skipIntro: skip, upNext: upNext
    }
end sub

sub playerNotice(message as string)
    m.playerNotice = message
    m.noticeUntil = VNowMs() + 4500
    publishPlayer()
end sub

sub onPlayerAction()
    if not m.player.visible then return
    action = m.player.action
    kind = VStr(VGet(action, "kind"))
    if kind = "back"
        closePlayback()
    else if kind = "menuClose"
        if m.playerMenuPage = "audio" or m.playerMenuPage = "subtitles"
            openPlayerOptions()
        else if not m.playing and not m.playResolving
            closePlayback()
        else
            closePlayerMenu()
        end if
    else if kind = "menuSelect"
        handlePlayerMenu(VStr(VGet(action, "id")))
    else if kind = "options"
        openPlayerOptions()
    else if kind = "streams"
        openSourcePicker(0)
    else if kind = "previous"
        if playerHasPrevious() and not m.playResolving then advanceEpisode(-1)
    else if kind = "next"
        if playerHasNext() and not m.playResolving then advanceEpisode(1)
    else if kind = "playPause"
        if m.rokuAudioStartTarget < 0 then m.seekShouldPause = false
        if m.rokuAudioStartTarget >= 0
            ' Apply this choice after the requested frame is reached, rather
            ' than pausing the hidden keyframe preroll before its seek completes.
            m.rokuAudioPaused = not m.rokuAudioPaused
            m.seekShouldPause = m.rokuAudioPaused
        else if m.video.state = "paused"
            m.rokuAudioPaused = false
            m.video.control = "resume"
        else if m.video.state = "playing"
            m.rokuAudioPaused = true
            m.video.control = "pause"
        else if m.rokuAudioPending
            m.rokuAudioPaused = false
        end if
    else if kind = "seek"
        finishReplay()
        seekPlayer(VNum(VGet(action, "position")))
    else if kind = "replay"
        if not m.isLive and m.lastDuration > 0
            m.replayState = VReplayBegin(m.lastPosition, m.video.globalCaptionMode, m.video.currentSubtitleTrack, m.video.availableSubtitleTracks, m.replayState)
            print "[Velvet] replay target="; m.replayState.target; " restore="; m.replayState.restoreAt
            if m.replayState.enableCaptions
                m.video.subtitleTrack = m.replayState.trackId
                m.video.globalCaptionMode = "On"
            else
                playerNotice("Replaying 10 seconds. This source has no available captions.")
            end if
            seekPlayer(m.replayState.target)
        end if
    else if kind = "skipIntro"
        if m.intro <> invalid
            m.introDismissed = true
            seekPlayer(VNum(VGet(m.intro, "endMs")) / 1000#)
        end if
    else if kind = "dismissUpNext"
        m.upNextDismissed = true
    end if
    publishPlayer()
end sub

sub seekPlayer(position as dynamic)
    if (not m.playing and not m.rokuAudioPending) or m.isLive or m.lastDuration <= 0 then return
    position = Int(position)
    if position < 0 then position = 0
    if position >= m.lastDuration then position = Int(m.lastDuration - 1)
    m.lastAdvanced = VNowMs()
    ' Preserve paused intent even if another seek is still buffering.
    m.seekShouldPause = m.seekShouldPause or m.video.state = "paused"
    if m.rokuAudioSession <> "" or m.rokuAudioPending
        reopenRokuAudio(position, m.rokuAudioTrack)
        return
    end if
    m.video.autoplayAfterSeek = not m.seekShouldPause
    m.video.seek = position
    m.lastPosition = position
    publishPlayer()
end sub

sub closePlayerMenu()
    m.playerMenu = invalid
    m.playerMenuPage = ""
    publishPlayer()
    m.player.CallFunc("restoreFocus")
end sub

sub openPlayerOptions()
    audio = "Default"
    for each option in playerAudioOptions()
        if option.selected then audio = option.label
    end for
    captions = "Off"
    for each option in playerSubtitleOptions()
        if option.selected then captions = option.label
    end for
    items = [
        {id: "options:audio", label: "Audio", subtitle: audio, enabled: true, icon: "audio"},
        {id: "options:subtitles", label: "Subtitles", subtitle: captions, enabled: true, icon: "captions"}
    ]
    if VGet(m.playItem, "type") = "show"
        if m.sourceIndex < m.streams.Count()
            if VReleaseGroupFromStream(m.streams[m.sourceIndex]) <> invalid then items.Push({id: "options:block", label: "Block this release", subtitle: "For this show only", enabled: true, icon: "block"})
        end if
        if currentBlockedGroups().Count() > 0 then items.Push({id: "options:reset", label: "Reset blocked releases", subtitle: "For this show only", enabled: true, icon: "replay"})
    end if
    m.playerMenuPage = "options"
    m.playerMenu = {title: "Playback options", items: items}
    publishPlayer()
end sub

sub openPlayerTracks(kind as string)
    if kind = "audio"
        items = playerAudioOptions()
        title = "Audio"
        detail = "Choose a soundtrack"
        empty = "This source has not exposed selectable audio tracks yet."
    else
        items = playerSubtitleOptions()
        title = "Subtitles"
        detail = "Choose a language, or turn captions off"
        empty = "This source has no available captions."
        if items.Count() = 1 then detail = empty
    end if
    m.playerMenuPage = kind
    m.playerMenu = {title: title, subtitle: detail, items: items, emptyMessage: empty}
    publishPlayer()
end sub

sub openSourcePicker(page as integer)
    requestPlayerAlternatives()
    items = []
    for i = 0 to m.streams.Count() - 1
        display = VStreamDisplay(m.streams[i], i)
        items.Push({id: "source:" + VStr(i), label: display.label, subtitle: display.subtitle, selected: i = m.sourceIndex, enabled: true})
    end for
    m.playerMenuPage = "streams"
    subtitle = VStr(items.Count()) + " available · switches at your current position"
    if m.playerAlternativesPending then subtitle = "Finding more streams… Your current stream keeps playing."
    m.playerMenu = {title: "Streams", subtitle: subtitle, items: items, emptyMessage: "No compatible streams are available."}
    publishPlayer()
end sub

sub requestPlayerAlternatives()
    if not m.playerAlternativesNeeded or m.playerAlternativesPending then return
    if m.handoffActive <> invalid then return
    kind = "movie"
    if VGet(m.playItem, "type") = "show" then kind = "series"
    m.playerAlternativesPending = true
    requestApi("playerSources", "/stream/" + kind + "/" + VEncode(VStreamKey(m.playItem)) + ".json", "GET", invalid, {playId: m.playGeneration}, 45000)
end sub

sub handlePlayerAlternatives(data as object)
    m.playerAlternativesPending = false
    m.playerAlternativesNeeded = false
    ' Keep the transferred source selected and playing while filling the picker.
    sources = []
    currentUrl = ""
    if m.sourceIndex < m.streams.Count()
        sources.Push(m.streams[m.sourceIndex])
        currentUrl = VStr(VGet(m.streams[m.sourceIndex], "url"))
    end if
    selected = VCompatibleStreams(VGet(data, "streams"), m.supportsHevc, m.supportsUhd, m.playItem, true)
    for each stream in preferencesStreams(selected.streams)
        url = VRegisteredStreamUrl(m.baseUrl, VStr(VGet(stream, "url")))
        if url <> "" and url <> currentUrl
            stream.url = url
            sources.Push(stream)
        end if
    end for
    m.allStreams = sources
    ' A pre-existing block must not change the identity of the source already
    ' playing after a handoff. Apply it to alternatives until an explicit switch.
    m.streams = []
    if currentUrl <> "" then m.streams.Push(sources[0])
    for each stream in VFilterBlockedStreams(sources, currentBlockedGroups())
        if VStr(VGet(stream, "url")) <> currentUrl then m.streams.Push(stream)
    end for
    m.sourceIndex = 0
    if m.pendingBlockCurrent
        m.pendingBlockCurrent = false
        blockCurrentRelease()
    else if m.playerMenuPage = "streams"
        openSourcePicker(0)
    end if
end sub

sub playerAlternativesFailed()
    m.playerAlternativesPending = false
    m.pendingBlockCurrent = false
    if m.playerMenuPage = "streams"
        m.playerMenu.subtitle = "Could not load other streams. Reopen Streams to retry."
    end if
    playerNotice("Could not load other streams. Your current stream keeps playing.")
end sub

sub handlePlayerMenu(id as string)
    if id = "error:back"
        closePlayback()
    else if id = "error:retry"
        closePlayerMenu()
        m.sourceIndex = 0
        m.formatRetry = false
        if m.isLive
            if VGet(m.playChannel, "sportsEvent") <> invalid
                tuneSports(m.playChannel.sportsEvent, m.playChannel.sportsStream)
            else
                tuneChannel(m.playChannel)
            end if
        else if m.streams.Count() > 0
            playCurrentStream()
        else
            startPlayback(m.playItem, m.inQueue)
        end if
    else if id = "error:streams"
        openSourcePicker(0)
    else if id = "error:options"
        openPlayerOptions()
    else if id = "options:audio"
        openPlayerTracks("audio")
    else if id = "options:subtitles"
        openPlayerTracks("subtitles")
    else if id = "options:block"
        blockCurrentRelease()
    else if id = "options:reset"
        m.blockedReleases.Delete(releaseBlockKey())
        saveBlockedGroups()
        rebuildUnblockedStreams()
        if not m.playing and m.streams.Count() > 0
            closePlayerMenu()
            m.formatRetry = false
            playCurrentStream()
        else
            openPlayerOptions()
        end if
    else if Left(id, 10) = "rokuAudio:"
        for each option in playerAudioOptions()
            if option.id = id
                m.desiredAudio = option.label
                m.registry.Write("audioLabel", m.desiredAudio)
                m.registry.Flush()
                closePlayerMenu()
                reopenRokuAudio(m.lastPosition, Int(Val(option.nativeId)))
                return
            end if
        end for
    else if Left(id, 6) = "audio:"
        for each option in VTrackOptions(m.video.availableAudioTracks, "audio", m.video.currentAudioTrack)
            if option.id = id
                m.video.audioTrack = option.nativeId
                m.desiredAudio = option.label
                m.registry.Write("audioLabel", m.desiredAudio)
                m.registry.Flush()
                print "[Velvet] audio track selected"
            end if
        end for
        openPlayerOptions()
    else if Left(id, 13) = "rokuSubtitle:"
        m.replayState = invalid
        for each option in playerSubtitleOptions()
            if option.id = id
                m.captionsDesired = id <> "rokuSubtitle:off"
                if m.captionsDesired
                    selected = Int(Val(option.nativeId))
                    changed = selected <> m.rokuSubtitleTrack
                    m.rokuSubtitleTrack = selected
                    m.desiredSubtitle = option.label
                    m.video.globalCaptionMode = "On"
                    m.registry.Write("captions", "On")
                else
                    changed = false
                    m.video.globalCaptionMode = "Off"
                    m.registry.Write("captions", "Off")
                end if
                m.registry.Write("subtitleLabel", m.desiredSubtitle)
                m.registry.Flush()
                if changed
                    closePlayerMenu()
                    reopenRokuAudio(m.lastPosition, m.rokuAudioTrack)
                else
                    openPlayerOptions()
                end if
                return
            end if
        end for
    else if Left(id, 9) = "subtitle:"
        m.replayState = invalid
        for each option in VTrackOptions(m.video.availableSubtitleTracks, "subtitle", m.video.currentSubtitleTrack, m.video.globalCaptionMode)
            if option.id = id
                m.captionsDesired = id <> "subtitle:off"
                if m.captionsDesired
                    m.video.subtitleTrack = option.nativeId
                    m.desiredSubtitle = option.label
                    m.video.globalCaptionMode = "On"
                    m.registry.Write("captions", "On")
                else
                    m.video.globalCaptionMode = "Off"
                    m.registry.Write("captions", "Off")
                end if
                m.registry.Write("subtitleLabel", m.desiredSubtitle)
                m.registry.Flush()
                print "[Velvet] captions enabled="; m.captionsDesired
            end if
        end for
        openPlayerOptions()
    else if Left(id, 7) = "source:"
        index = Int(Val(Mid(id, 8)))
        if index < 0 or index >= m.streams.Count() then return
        closePlayerMenu()
        m.sourceIndex = index
        m.formatRetry = false
        playCurrentStream()
    end if
end sub

sub onPlayerTracksChanged()
    if not m.playing or not m.acceptPlayerTracks then return
    if m.video.state <> "playing" and m.video.state <> "paused" then return
    if m.audioPending and VArray(m.video.availableAudioTracks).Count() > 0
        m.audioPending = false
        for each option in VTrackOptions(m.video.availableAudioTracks, "audio")
            if option.label = m.desiredAudio then m.video.audioTrack = option.nativeId
        end for
    end if
    if m.subtitlePending and VArray(m.video.availableSubtitleTracks).Count() > 0
        m.subtitlePending = false
        selected = VPreferredSubtitleTrack(m.video.availableSubtitleTracks)
        for each option in VTrackOptions(m.video.availableSubtitleTracks, "subtitle")
            if option.label = m.desiredSubtitle then selected = option.nativeId
        end for
        if selected <> "" then m.video.subtitleTrack = selected
        enableCaptions = m.captionsDesired
        if m.replayState <> invalid then enableCaptions = enableCaptions or VBool(VGet(m.replayState, "enableCaptions"))
        if enableCaptions then m.video.globalCaptionMode = "On" else m.video.globalCaptionMode = "Off"
        print "[Velvet] available subtitles="; VArray(m.video.availableSubtitleTracks).Count(); " audio="; VArray(m.video.availableAudioTracks).Count()
    end if
    if m.playerMenuPage = "audio" or m.playerMenuPage = "subtitles"
        openPlayerTracks(m.playerMenuPage)
    else
        publishPlayer()
    end if
end sub

function releaseBlockKey() as string
    return m.baseUrl + "|" + m.profileId + "|" + VMediaKey(m.playItem)
end function

function currentBlockedGroups() as object
    return VArray(m.blockedReleases.Lookup(releaseBlockKey()))
end function

sub saveBlockedGroups()
    m.registry.Write("blockedReleases", FormatJson(m.blockedReleases))
    m.registry.Flush()
end sub

sub rebuildUnblockedStreams()
    currentUrl = ""
    if m.sourceIndex < m.streams.Count() then currentUrl = m.streams[m.sourceIndex].url
    m.streams = VFilterBlockedStreams(m.allStreams, currentBlockedGroups())
    m.sourceIndex = 0
    for i = 0 to m.streams.Count() - 1
        if m.streams[i].url = currentUrl then m.sourceIndex = i
    end for
end sub

sub blockCurrentRelease()
    if m.sourceIndex >= m.streams.Count() then return
    if m.playerAlternativesNeeded
        if m.handoffActive <> invalid
            playerNotice("Wait for playback to start before blocking this release.")
            return
        end if
        m.pendingBlockCurrent = true
        requestPlayerAlternatives()
        playerNotice("Finding other releases…")
        return
    end if
    group = VReleaseGroupFromStream(m.streams[m.sourceIndex])
    if group = invalid then return
    groups = currentBlockedGroups()
    groups.Push(group)
    m.blockedReleases[releaseBlockKey()] = groups
    saveBlockedGroups()
    rebuildUnblockedStreams()
    closePlayerMenu()
    m.formatRetry = false
    if m.streams.Count() = 0
        playbackFailure("This show's remaining releases are blocked or unavailable. Reset blocked releases in playback options to try them again.")
    else
        playCurrentStream()
        playerNotice("Release blocked for this show")
    end if
end sub

sub requestPlayerMetadata()
    if VGet(m.playItem, "type") <> "show" then return
    context = {playId: m.playGeneration}
    requestApi("playerEpisodes", "/catalog/show/" + VEncode(m.playItem.mediaId) + "/seasons/" + VEncode(m.playItem.season), "GET", invalid, context)
    imdb = VStr(VGet(m.playItem, "imdbId"))
    if imdb <> "" then requestApi("segments", "/segments?imdb=" + VEncode(imdb) + "&season=" + VEncode(m.playItem.season), "GET", invalid, context)
end sub

sub handlePlayerMetadata(kind as string, data as object)
    if kind = "playerEpisodes"
        m.seasonEpisodes = VArray(VGet(data, "episodes"))
        for each episode in m.seasonEpisodes
            if VNum(VGet(episode, "number")) = VNum(VGet(m.playItem, "episode")) then m.playItem.episodeTitle = VStr(VGet(episode, "title"))
        end for
    else if kind = "segments"
        m.intro = VGet(VGet(data, "episodes", {}), VStr(VGet(m.playItem, "episode")))
    end if
    publishPlayer()
end sub

' Audio-only compatibility sessions keep the original registered source identity.
' The backend copies video and converts one audio track; every seek gets a fresh
' short rolling HLS session so a native seek cannot fall outside its window.
sub initRokuAudio()
    m.rokuAudioSession = ""
    m.rokuAudioSid = ""
    m.rokuAudioGeneration = 0
    m.rokuAudioPending = false
    m.rokuAudioFailed = false
    m.rokuAudioNativeProbed = false
    m.rokuAudioForce = false
    m.rokuAudioPaused = false
    m.rokuAudioOffsetMs = 0
    m.rokuAudioDurationMs = 0
    m.rokuAudioTrack = -1
    m.rokuAudioTracks = []
    m.rokuSubtitleTrack = -1
    m.rokuSubtitleTracks = []
    m.rokuAudioLastKeep = 0
    m.rokuAudioKeepPending = false
    resetRokuAudioStartup()
end sub

sub resetRokuAudioStartup()
    m.rokuAudioStartTarget = -1#
    m.rokuAudioStartSeekIssued = false
    m.rokuAudioStartBufferSeen = false
    m.rokuAudioStartSettled = false
    m.rokuAudioStartIssuedAt = 0
    m.rokuAudioStartRenderedBefore = -1#
    m.video.mute = false
    m.video.notificationInterval = 0.5
end sub

function advanceRokuAudioStartup() as boolean
    if m.rokuAudioStartTarget < 0 then return false
    state = m.video.state
    rendered = VRokuAudioRenderedPosition(m.video.positionInfo, m.video.clipId)
    if m.rokuAudioStartSeekIssued
        if state = "buffering" then m.rokuAudioStartBufferSeen = true
        if state = "playing" and m.rokuAudioStartBufferSeen then m.rokuAudioStartSettled = true
        ' In-buffer seeks may skip a buffering state. Only actual rendered frame
        ' progress after settling can substitute for that state transition.
        if rendered >= 0
            if m.rokuAudioStartRenderedBefore < 0 or rendered < m.rokuAudioStartRenderedBefore then m.rokuAudioStartRenderedBefore = rendered
            if state = "playing" and VNowMs() - m.rokuAudioStartIssuedAt >= 300 and rendered > m.rokuAudioStartRenderedBefore + 0.03 then m.rokuAudioStartSettled = true
        end if
    end if
    position = m.video.position
    if rendered >= 0 then position = rendered
    action = VRokuAudioStartupAction(m.rokuAudioStartTarget, m.rokuAudioStartSeekIssued, state, position, m.rokuAudioStartSettled)
    if action = "seek"
        m.rokuAudioStartSeekIssued = true
        m.rokuAudioStartBufferSeen = false
        m.rokuAudioStartSettled = false
        m.rokuAudioStartIssuedAt = VNowMs()
        m.rokuAudioStartRenderedBefore = rendered
        m.video.autoplayAfterSeek = true
        m.video.seek = m.rokuAudioStartTarget
        print "[Velvet] converted start seek="; m.rokuAudioStartTarget
    else if action = "resume"
        m.video.control = "resume"
    else if action = "ready"
        print "[Velvet] converted start reached="; position; " native="; m.video.position; " rendered="; rendered; " paused="; m.seekShouldPause
        resetRokuAudioStartup()
        m.video.visible = true
        m.video.autoplayAfterSeek = not m.seekShouldPause
        m.sourceHasPlayed = true
        m.acceptPlayerTracks = true
        onPlayerTracksChanged()
        if m.seekShouldPause then m.video.control = "pause"
        if not m.seekShouldPause and m.video.state = "paused" then m.video.control = "resume"
        return false
    end if
    return true
end function

sub stopRokuAudio()
    if m.rokuAudioSession = invalid then return
    old = m.rokuAudioSession
    m.rokuAudioGeneration += 1
    m.rokuAudioSession = ""
    m.rokuAudioSid = ""
    m.rokuAudioPending = false
    m.rokuAudioFailed = false
    m.rokuAudioNativeProbed = false
    m.rokuAudioPaused = false
    m.rokuAudioTracks = []
    m.rokuAudioTrack = -1
    m.rokuSubtitleTrack = -1
    m.rokuSubtitleTracks = []
    m.rokuAudioOffsetMs = 0
    m.rokuAudioDurationMs = 0
    m.rokuAudioKeepPending = false
    resetRokuAudioStartup()
    if VRokuAudioSessionId(old) <> "" then requestApi("rokuAudioStop", "/roku/audio/" + VEncode(old), "DELETE")
end sub

function rokuAudioCodecSupported(codec as string, channels = 0 as integer) as boolean
    codec = LCase(codec)
    if codec = "truehd" or codec = "dtshd" then return false
    if codec = "" then return true
    device = CreateObject("roDeviceInfo")
    format = {codec: codec}
    if channels > 0 then format.channels = channels
    result = device.CanDecodeAudio(format)
    if VBool(VGet(result, "result")) then return true
    ' A connected receiver may play a format that the Roku cannot decode itself.
    format.passthru = 1
    return VBool(VGet(device.CanDecodeAudio(format), "result"))
end function

function rokuAudioNeedsProbe(stream as object) as boolean
    codec = VRokuAudioHint(stream)
    return codec <> "" and not rokuAudioCodecSupported(codec)
end function

function rokuAudioContext() as object
    return {playId: m.playGeneration, audioGeneration: m.rokuAudioGeneration, sid: m.rokuAudioSid, sessionId: m.rokuAudioSession}
end function

function rokuAudioContextCurrent(context as dynamic) as boolean
    return VNum(VGet(context, "playId"), -1) = m.playGeneration and VNum(VGet(context, "audioGeneration"), -1) = m.rokuAudioGeneration and VStr(VGet(context, "sid")) = m.rokuAudioSid
end function

sub probeRokuAudio(stream as object, force = false as boolean)
    sid = VStreamId(VStr(VGet(stream, "url")))
    if sid = "" then return
    m.rokuAudioGeneration += 1
    m.rokuAudioSid = sid
    m.rokuAudioNativeProbed = true
    m.rokuAudioForce = force
    m.rokuAudioPending = true
    m.rokuAudioPaused = m.seekShouldPause or m.video.state = "paused"
    m.playing = false
    m.playResolving = true
    m.acceptPlayerTracks = false
    m.video.control = "stop"
    m.video.visible = false
    m.player.visible = true
    m.player.CallFunc("restoreFocus")
    publishPlayer()
    requestApi("rokuAudioMetadata", "/stream/" + VEncode(sid) + "/audio", "GET", invalid, rokuAudioContext(), 30000)
end sub

sub reopenRokuAudio(position as double, track as integer)
    if m.rokuAudioSid = "" or m.isLive then return
    paused = m.rokuAudioPaused or m.seekShouldPause or m.video.state = "paused"
    old = m.rokuAudioSession
    m.rokuAudioGeneration += 1
    m.rokuAudioSession = ""
    m.rokuAudioPending = true
    m.rokuAudioKeepPending = false
    m.rokuAudioPaused = paused
    resetRokuAudioStartup()
    m.rokuAudioTrack = track
    m.playing = false
    m.playResolving = true
    m.acceptPlayerTracks = false
    m.lastPosition = position
    m.video.control = "stop"
    m.video.visible = false
    if VRokuAudioSessionId(old) <> "" then requestApi("rokuAudioStop", "/roku/audio/" + VEncode(old), "DELETE")
    body = {positionMs: VMediaMilliseconds(position)}
    if track >= 0 then body.AddReplace("audioTrack", track)
    if m.rokuSubtitleTrack >= 0 then body.AddReplace("subtitleTrack", m.rokuSubtitleTrack)
    requestApi("rokuAudioStart", "/stream/" + VEncode(m.rokuAudioSid) + "/roku/session", "POST", body, rokuAudioContext(), 70000)
    publishPlayer()
end sub

sub handleRokuAudioResponse(kind as string, data as object, context as dynamic)
    if kind = "rokuAudioStop" then return
    if not rokuAudioContextCurrent(context)
        if kind = "rokuAudioStart"
            abandoned = VRokuAudioSessionId(VGet(data, "sessionId"))
            if abandoned <> "" then requestApi("rokuAudioStop", "/roku/audio/" + abandoned, "DELETE")
        end if
        return
    end if
    if kind = "rokuAudioKeep"
        if VStr(VGet(context, "sessionId")) = m.rokuAudioSession then m.rokuAudioKeepPending = false
        return
    end if
    if kind = "rokuAudioMetadata"
        m.rokuAudioTracks = VArray(VGet(data, "audioTracks"))
        m.rokuSubtitleTracks = VArray(VGet(data, "subtitleTracks"))
        m.rokuSubtitleTrack = VRokuPreferredSubtitleIndex(m.rokuSubtitleTracks, m.desiredSubtitle)
        m.rokuAudioDurationMs = VNum(VGet(data, "durationMs"))
        if m.rokuAudioDurationMs > 0 then m.lastDuration = m.rokuAudioDurationMs / 1000#
        selected = VRokuPreferredAudioIndex(m.rokuAudioTracks, m.desiredAudio)
        if selected < 0
            onRokuAudioRequestFailed(kind, context)
            return
        end if
        needsConversion = m.rokuAudioForce
        for each track in m.rokuAudioTracks
            if VNum(VGet(track, "index"), -1) = selected
                codec = VStr(VGet(track, "codec"))
                needsConversion = needsConversion or not rokuAudioCodecSupported(codec, VNum(VGet(track, "channels")))
                if codec = "dts" and VRokuAudioHint(m.streams[m.sourceIndex]) = "dtshd" then needsConversion = true
            end if
        end for
        if needsConversion
            reopenRokuAudio(m.lastPosition, selected)
        else
            m.rokuAudioPending = false
            m.playResolving = false
            playNativeStream(m.streams[m.sourceIndex].url, "", Int(m.lastPosition))
        end if
    else if kind = "rokuAudioStart"
        session = VRokuAudioSessionId(VGet(data, "sessionId"))
        path = VStr(VGet(data, "playbackPath"))
        offset = VNum(VGet(data, "sourceOffsetMs"), -1)
        requested = VNum(VGet(data, "requestedPositionMs"), -1)
        if not VRokuAudioPlaybackPath(session, path) or offset < 0 or requested < offset
            if session <> "" then requestApi("rokuAudioStop", "/roku/audio/" + session, "DELETE")
            onRokuAudioRequestFailed(kind, context)
            return
        end if
        m.rokuAudioSession = session
        m.rokuAudioOffsetMs = offset
        m.rokuAudioDurationMs = VNum(VGet(data, "durationMs"))
        m.rokuAudioTrack = VNum(VGet(data, "audioTrack"), m.rokuAudioTrack)
        m.rokuAudioTracks = VArray(VGet(data, "audioTracks", m.rokuAudioTracks))
        m.rokuSubtitleTracks = VArray(VGet(data, "subtitleTracks", m.rokuSubtitleTracks))
        m.rokuSubtitleTrack = VNum(VGet(data, "subtitleTrack"), -1)
        m.rokuAudioPending = false
        m.rokuAudioFailed = false
        m.rokuAudioLastKeep = VNowMs()
        if m.rokuAudioDurationMs > 0 then m.lastDuration = m.rokuAudioDurationMs / 1000#
        m.lastPosition = requested / 1000#
        target = VRokuAudioNativeTarget(requested, offset)
        m.rokuAudioStartSeekIssued = false
        if target > 0.03 then m.rokuAudioStartTarget = target else m.rokuAudioStartTarget = -1#
        playNativeStream(m.baseUrl + path, "hls", VRokuAudioNativeStart(requested, offset))
        playerNotice("Compatible audio · original video quality")
    end if
end sub

sub onRokuAudioRequestFailed(kind as string, context as dynamic)
    if kind = "rokuAudioStop" then return
    if not rokuAudioContextCurrent(context) then return
    if kind = "rokuAudioKeep"
        m.rokuAudioKeepPending = false
        return
    end if
    m.rokuAudioPending = false
    m.rokuAudioFailed = true
    m.playResolving = false
    failoverStream()
end sub

sub keepRokuAudioAlive()
    if m.rokuAudioSession = "" or m.rokuAudioKeepPending then return
    now = VNowMs()
    if now - m.rokuAudioLastKeep < 20000 then return
    m.rokuAudioLastKeep = now
    m.rokuAudioKeepPending = true
    requestApi("rokuAudioKeep", "/roku/audio/" + m.rokuAudioSession, "GET", invalid, rokuAudioContext(), 8000)
end sub

function playerAudioOptions() as object
    if m.rokuAudioSession <> "" or m.rokuAudioPending
        return VRokuAudioTrackOptions(m.rokuAudioTracks, m.rokuAudioTrack)
    end if
    return VTrackOptions(m.video.availableAudioTracks, "audio", m.video.currentAudioTrack)
end function

function playerSubtitleOptions() as object
    if (m.rokuAudioSession <> "" or m.rokuAudioPending) and m.rokuSubtitleTracks.Count() > 0
        ' The master carries the selected text track even while captions are off,
        ' so Replay can turn it on without a separate subtitle scan.
        return VRokuSubtitleTrackOptions(m.rokuSubtitleTracks, m.rokuSubtitleTrack, LCase(m.video.globalCaptionMode) = "on")
    end if
    return VTrackOptions(m.video.availableSubtitleTracks, "subtitle", m.video.currentSubtitleTrack, m.video.globalCaptionMode)
end function
