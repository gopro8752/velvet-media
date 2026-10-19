sub initSportsBrowser()
    m.sportsView = m.top.FindNode("sportsView")
    m.sportsView.ObserveField("action", "onSportsBrowserAction")
    m.sportsBrowser = {events:[], streams:[], event:{}, scope:"live", query:"", loading:false, streamsLoading:false, message:"", streamMessage:""}
end sub
sub openSportsBrowser()
    m.view.visible = true
    m.sportsView.visible = true
    publishSportsBrowser()
    m.sportsView.CallFunc("restoreFocus")
    refreshSportsBrowser()
end sub
sub closeSportsBrowser()
    m.sportsView.visible = false
end sub
sub restoreSportsBrowser()
    m.view.visible = true
    m.sportsView.visible = true
    publishSportsBrowser()
    m.sportsView.CallFunc("restoreFocus")
end sub
sub publishSportsBrowser()
    m.sportsView.model = VCopy(m.sportsBrowser)
end sub
sub refreshSportsBrowser()
    m.sportsBrowser.loading = true
    m.sportsBrowser.message = ""
    publishSportsBrowser()
    requestApi("sportsEvents", "/sports/events?scope=" + VEncode(m.sportsBrowser.scope), "GET", invalid, {scope:m.sportsBrowser.scope})
end sub
function handleSportsBrowserResponse(kind as String, data as Dynamic, context = invalid as Dynamic) as Boolean
    if kind = "sportsEvents"
        if VStr(VGet(context,"scope")) <> m.sportsBrowser.scope then return true
        m.sportsBrowser.loading = false
        m.sportsBrowser.events = VArray(VGet(data,"events"))
        m.sportsBrowser.message = VStr(VGet(data,"message"))
    else if kind = "sportsStreams"
        if VStr(VGet(data,"eventId")) <> VStr(VGet(m.sportsBrowser.event,"id")) then return true
        m.sportsBrowser.streamsLoading = false
        m.sportsBrowser.streams = VArray(VGet(data,"streams"))
        m.sportsBrowser.streamMessage = VStr(VGet(data,"message"))
    else
        return false
    end if
    publishSportsBrowser()
    return true
end function
function handleSportsBrowserError(kind as String, message as String, context = invalid as Dynamic) as Boolean
    if kind = "sportsEvents"
        if VStr(VGet(context,"scope")) <> m.sportsBrowser.scope then return true
        m.sportsBrowser.loading = false
        m.sportsBrowser.message = message
    else if kind = "sportsStreams"
        if VStr(VGet(context,"eventId")) <> VStr(VGet(m.sportsBrowser.event,"id")) then return true
        m.sportsBrowser.streamsLoading = false
        m.sportsBrowser.streamMessage = message
    else
        return false
    end if
    publishSportsBrowser()
    return true
end function
sub onSportsBrowserAction(event as Object)
    action = event.GetData()
    kind = VStr(VGet(action,"kind"))
    if kind = "sportsEvent"
        m.sportsBrowser.event = VGet(action,"event",{})
        m.sportsBrowser.streams = []
        m.sportsBrowser.streamsLoading = true
        m.sportsBrowser.streamMessage = ""
        publishSportsBrowser()
        id = VStr(VGet(m.sportsBrowser.event,"id"))
        requestApi("sportsStreams", "/sports/events/" + VEncode(id) + "/streams", "GET", invalid, {eventId:id})
    else if kind = "sportsTune"
        closeSportsBrowser()
        tuneSports(VGet(action,"event",{}),VGet(action,"stream",{}))
    else if kind = "sportsScope"
        m.sportsBrowser.scope = VStr(VGet(action,"scope"),"live")
        refreshSportsBrowser()
    else if kind = "sportsRefresh"
        refreshSportsBrowser()
    else if kind = "sportsSearch"
        dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
        dialog.title = "Search Live Sports"
        dialog.textEditBox.maxTextLength = 120
        dialog.text = m.sportsBrowser.query
        dialog.buttons = ["Search","Clear","Cancel"]
        dialog.ObserveField("buttonSelected","onSportsSearchSelected")
        m.top.dialog = dialog
    else if kind = "sportsBack"
        openSportsDock()
    end if
end sub
sub onSportsSearchSelected(event as Object)
    dialog = event.GetRoSGNode()
    index = event.GetData()
    if index = 0 then m.sportsBrowser.query = Left(dialog.text.Trim(),120)
    if index = 1 then m.sportsBrowser.query = ""
    dialog.close = true
    publishSportsBrowser()
    m.sportsView.CallFunc("restoreFocus")
end sub
