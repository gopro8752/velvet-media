' Scene-level controller for the standalone live guide. Playback stays in VelvetPlayback.
sub initLiveBrowser()
    m.liveView = m.top.FindNode("liveView")
    m.liveView.ObserveField("action", "onLiveBrowserAction")
    m.liveBrowser = {channels: [], guide: {}, query: "", loading: false, message: "", favoriteIds: [], favoritesOnly: false}
    m.liveLastRefresh = 0
    m.livePending = 0
    m.liveBrowserTimer = CreateObject("roSGNode", "Timer")
    m.liveBrowserTimer.duration = 30
    m.liveBrowserTimer.repeat = true
    m.liveBrowserTimer.ObserveField("fire", "onLiveBrowserTick")
    m.top.AppendChild(m.liveBrowserTimer)
end sub

sub openLiveBrowser()
    m.liveFavoriteKey = "liveFavorites:" + m.baseUrl + ":" + m.profileId
    storedFavorites = m.registry.Read(m.liveFavoriteKey)
    m.liveBrowser.favoriteIds = []
    if storedFavorites <> "" then m.liveBrowser.favoriteIds = VGuideFavoriteIds(ParseJson(storedFavorites))
    m.livePending = 0
    m.view.visible = true
    m.liveView.visible = true
    publishLiveBrowser()
    m.liveView.CallFunc("restoreFocus")
    m.liveBrowserTimer.control = "start"
    refreshLiveBrowser()
end sub

sub closeLiveBrowser()
    m.liveView.visible = false
    m.liveBrowserTimer.control = "stop"
end sub

sub restoreLiveBrowser()
    m.view.visible = true
    m.liveView.visible = true
    publishLiveBrowser()
    m.liveView.CallFunc("restoreFocus")
    m.liveBrowserTimer.control = "start"
end sub

sub publishLiveBrowser()
    m.liveView.model = VCopy(m.liveBrowser)
end sub

sub refreshLiveBrowser()
    if m.livePending > 0 then return
    m.liveBrowser.loading = true
    m.liveBrowser.message = ""
    m.livePending = 2
    m.liveLastRefresh = VNowMs()
    publishLiveBrowser()
    requestApi("liveChannels", "/live/channels")
    requestApi("liveGuide", "/live/guide")
end sub

function handleLiveBrowserResponse(kind as String, data as Dynamic) as Boolean
    if kind <> "liveChannels" and kind <> "liveGuide" then return false
    if kind = "liveChannels"
        m.liveBrowser.channels = VArray(VGet(data, "channels"))
    else
        m.liveBrowser.guide = VPrepareGuide(data)
    end if
    message = VStr(VGet(data, "message"))
    if message <> "" then m.liveBrowser.message = message
    if m.livePending > 0 then m.livePending -= 1
    m.liveBrowser.loading = m.livePending > 0
    publishLiveBrowser()
    return true
end function

function handleLiveBrowserError(kind as String, message as String) as Boolean
    if kind <> "liveChannels" and kind <> "liveGuide" then return false
    if m.livePending > 0 then m.livePending -= 1
    m.liveBrowser.loading = m.livePending > 0
    m.liveBrowser.message = message
    publishLiveBrowser()
    return true
end function

sub onLiveBrowserTick()
    if not m.liveView.visible then return
    dialog = m.top.dialog
    if dialog <> invalid
        if not dialog.close then return
    end if
    if VNowMs() - m.liveLastRefresh >= 300000
        refreshLiveBrowser()
    else
        publishLiveBrowser()
    end if
end sub

sub onLiveBrowserAction(event as Object)
    action = event.GetData()
    kind = VStr(VGet(action, "kind"))
    if kind = "liveTune"
        closeLiveBrowser()
        tuneChannel(VGet(action, "channel", {}))
    else if kind = "liveRefresh"
        refreshLiveBrowser()
    else if kind = "liveFilter"
        m.liveBrowser.favoritesOnly = VBool(VGet(action, "favoritesOnly"))
        publishLiveBrowser()
    else if kind = "liveFavorite"
        id = VStr(VGet(action, "channelId"))
        validChannel = false
        for each channel in m.liveBrowser.channels
            if VStr(VGet(channel, "id")) = id then validChannel = true
        end for
        if validChannel
            m.liveBrowser.favoriteIds = VGuideToggleFavorite(m.liveBrowser.favoriteIds, id)
            m.registry.Write(m.liveFavoriteKey, FormatJson(m.liveBrowser.favoriteIds))
            m.registry.Flush()
            publishLiveBrowser()
        end if
    else if kind = "liveSearch"
        dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
        dialog.title = "Search Live TV"
        dialog.textEditBox.maxTextLength = 120
        dialog.text = VStr(VGet(m.liveBrowser, "query"))
        dialog.buttons = ["Search", "Clear", "Cancel"]
        dialog.ObserveField("buttonSelected", "onLiveSearchSelected")
        m.top.dialog = dialog
    else if kind = "liveBack"
        openLiveDock()
    end if
end sub

sub onLiveSearchSelected(event as Object)
    dialog = event.GetRoSGNode()
    index = event.GetData()
    if index = 0 then m.liveBrowser.query = Left(dialog.text.Trim(), 120)
    if index = 1 then m.liveBrowser.query = ""
    dialog.close = true
    publishLiveBrowser()
    m.liveView.CallFunc("restoreFocus")
end sub
