sub init()
    m.events = []
    m.sources = []
    m.eventIndex = 0
    m.sourceIndex = 0
    m.headerIndex = 0
    m.area = "events"
    m.eventCells = []
    m.sourceCells = []
    m.header = ["scopeLive", "scopeToday", "scopeAll", "search", "refresh"]
    for each id in m.header
        m.top.FindNode(id).ObserveField("selected", "sportsHeaderSelected")
    end for
    for i = 0 to 4
        m.eventCells.Push(sportsCell(m.top.FindNode("events"), i * 132, 874, 122))
    end for
    for i = 0 to 3
        m.sourceCells.Push(sportsCell(m.top.FindNode("sources"), i * 92, 814, 82))
    end for
    m.top.ObserveField("focusedChild", "sportsFocusChanged")
    m.top.ObserveField("visible", "sportsFocusChanged")
    m.observingSceneFocus = false
end sub

function sportsCell(parent as Object, y as Integer, width as Integer, height as Integer) as Object
    group = parent.CreateChild("Group")
    group.translation = [0, y]
    fill = group.CreateChild("Poster")
    fill.width = width
    fill.height = height
    fill.uri = "pkg:/images/card-well.9.png"
    rim = group.CreateChild("Poster")
    rim.width = width
    rim.height = height
    rim.uri = "pkg:/images/button-focus.9.png"
    rim.visible = false
    title = group.CreateChild("Label")
    title.translation = [24, 12]
    title.width = width - 48
    title.height = 38
    font = CreateObject("roSGNode", "Font")
    font.uri = "pkg:/fonts/Inter-Medium.ttf"
    font.size = 27
    title.font = font
    subtitle = group.CreateChild("Label")
    subtitle.translation = [24, 54]
    subtitle.width = width - 48
    subtitle.height = 30
    subtitle.color = "0xA9B1C2FF"
    font = CreateObject("roSGNode", "Font")
    font.uri = "pkg:/fonts/Inter-Regular.ttf"
    font.size = 22
    subtitle.font = font
    return {group:group, rim:rim, title:title, subtitle:subtitle}
end function

sub sportsModelChanged()
    previous = ""
    if m.eventIndex < m.events.Count() then previous = VStr(VGet(m.events[m.eventIndex], "id"))
    model = m.top.model
    m.events = []
    query = LCase(VStr(VGet(model, "query")).Trim())
    for each event in VArray(VGet(model, "events"))
        haystack = LCase(VStr(VGet(event, "title")) + " " + VStr(VGet(event, "sportName")))
        if query = "" or Instr(1, haystack, query) > 0 then m.events.Push(event)
    end for
    m.eventIndex = 0
    for i = 0 to m.events.Count() - 1
        if VStr(VGet(m.events[i], "id")) = previous then m.eventIndex = i
    end for
    if m.events.Count() = 0 then m.area = "header"
    m.sources = VArray(VGet(model, "streams"))
    if m.sourceIndex >= m.sources.Count() then m.sourceIndex = 0
    if m.area = "sources" and m.sources.Count() = 0 then m.area = "events"
    status = VStr(m.events.Count()) + " events"
    if m.events.Count() = 1 then status = "1 event"
    if VBool(VGet(model, "loading")) then status = "Loading events…"
    message = VStr(VGet(model, "message"))
    if message <> "" then status += " · " + message
    m.top.FindNode("status").text = status
    m.top.FindNode("search").label = "Search teams or sports"
    if query <> "" then m.top.FindNode("search").label = "Search: " + VStr(VGet(model, "query"))
    paintSports()
end sub

sub restoreFocus()
    if not m.observingSceneFocus
        scene = m.top.GetScene()
        if scene <> invalid
            scene.ObserveField("focusedChild", "sportsFocusChanged")
            m.observingSceneFocus = true
        end if
    end if
    focusSportsArea()
    paintSports()
end sub

' Release native button focus before returning keys to the custom event/source
' regions. Parent SetFocus(true) alone leaves its descendant as the key target.
sub focusSportsArea()
    target = m.top
    if m.area = "header" then target = m.top.FindNode(m.header[m.headerIndex])
    for each id in m.header
        control = m.top.FindNode(id)
        if not control.IsSameNode(target) and control.IsInFocusChain() then control.SetFocus(false)
    end for
    if not target.HasFocus() then target.SetFocus(true)
    sportsFocusChanged()
end sub

sub sportsFocusChanged()
    active = m.top.visible and m.top.IsInFocusChain()
    for i = 0 to m.header.Count() - 1
        m.top.FindNode(m.header[i]).focused = active and m.area = "header" and m.headerIndex = i
    end for
    for each cell in m.eventCells
        cell.rim.opacity = 0.15
        if active then cell.rim.opacity = 0.35
        if active and m.area = "events" then cell.rim.opacity = 1
    end for
    for each cell in m.sourceCells
        cell.rim.opacity = 0.15
        if active and m.area = "sources" then cell.rim.opacity = 1
    end for
end sub

sub paintSports()
    offset = Int(m.eventIndex / 5) * 5
    for i = 0 to 4
        index = offset + i
        cell = m.eventCells[i]
        cell.group.visible = index < m.events.Count()
        if cell.group.visible
            event = m.events[index]
            cell.title.text = VStr(VGet(event, "title"))
            tag = VGuideTime(VGet(event, "startTime"))
            if VBool(VGet(event, "isLive")) then tag = "LIVE"
            cell.subtitle.text = tag + " · " + VStr(VGet(event, "sportName"))
            cell.rim.visible = index = m.eventIndex
            cell.rim.opacity = 0.35
            if m.area = "events" then cell.rim.opacity = 1
        end if
    end for
    m.top.FindNode("detail").visible = m.events.Count() > 0
    if m.events.Count() > 0
        event = m.events[m.eventIndex]
        m.top.FindNode("eventTitle").text = VStr(VGet(event, "title"))
        m.top.FindNode("eventInfo").text = VStr(VGet(event, "sportName")) + " · " + VGuideTime(VGet(event, "startTime"))
        selected = VStr(VGet(VGet(m.top.model, "event"), "id")) = VStr(VGet(event, "id"))
        hint = "Press OK to see available sources."
        if selected
            hint = VStr(m.sources.Count()) + " sources · Right to choose and play"
            if m.sources.Count() = 1 then hint = "1 source · Right to choose and play"
            if m.sources.Count() = 0 then hint = VStr(VGet(m.top.model, "streamMessage"), "No sources are available yet. Press OK to retry.")
            if VBool(VGet(m.top.model, "streamsLoading")) then hint = "Finding available sources…"
        end if
        m.top.FindNode("sourceHint").text = hint
        offset = Int(m.sourceIndex / 4) * 4
        for i = 0 to 3
            cell = m.sourceCells[i]
            index = offset + i
            cell.group.visible = selected and index < m.sources.Count()
            if cell.group.visible
                stream = m.sources[index]
                quality = "SD"
                if VBool(VGet(stream, "hd")) then quality = "HD"
                cell.title.text = VStr(VGet(stream, "source")) + " · " + VStr(VGet(stream, "streamNo")) + " · " + quality + " · " + VStr(VGet(stream, "language"))
                cell.subtitle.text = ""
                cell.rim.visible = m.area = "sources" and index = m.sourceIndex
            end if
        end for
    end if
    m.top.FindNode("footer").text = "OK for sources · Right to choose a source · Back for navigation"
    if m.area = "sources" then m.top.FindNode("footer").text = "Source " + VStr(m.sourceIndex + 1) + " of " + VStr(m.sources.Count()) + " · OK to watch · Left for events"
    sportsFocusChanged()
    if not m.top.visible or not m.top.IsInFocusChain() then return
    focusSportsArea()
end sub

sub sportsHeaderSelected(event as Object)
    id = event.GetRoSGNode().id
    if id = "scopeLive" then m.top.action = {kind:"sportsScope", scope:"live"}
    if id = "scopeToday" then m.top.action = {kind:"sportsScope", scope:"today"}
    if id = "scopeAll" then m.top.action = {kind:"sportsScope", scope:"all"}
    if id = "search" then m.top.action = {kind:"sportsSearch"}
    if id = "refresh" then m.top.action = {kind:"sportsRefresh"}
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "back"
        if m.area = "sources"
            m.area = "events"
            paintSports()
        else
            m.top.action = {kind:"sportsBack"}
        end if
        return true
    end if
    if m.area = "header"
        if key = "left" and m.headerIndex > 0 then m.headerIndex -= 1
        if key = "right" and m.headerIndex < 4 then m.headerIndex += 1
        if key = "down" and m.events.Count() > 0 then m.area = "events"
    else if m.area = "events"
        if key = "up"
            if m.eventIndex = 0 then m.area = "header" else m.eventIndex -= 1
            m.sourceIndex = 0
        end if
        if key = "down" and m.eventIndex < m.events.Count() - 1 then m.eventIndex += 1
        if key = "OK" and m.events.Count() > 0
            m.top.action = {kind:"sportsEvent", event:m.events[m.eventIndex]}
        else if key = "right" and m.sources.Count() > 0
            if VStr(VGet(VGet(m.top.model,"event"),"id")) = VStr(VGet(m.events[m.eventIndex],"id")) then m.area = "sources"
        end if
    else if m.area = "sources"
        if key = "left" then m.area = "events"
        if key = "up" and m.sourceIndex > 0 then m.sourceIndex -= 1
        if key = "down" and m.sourceIndex < m.sources.Count() - 1 then m.sourceIndex += 1
        if key = "OK" or key = "play" then m.top.action = {kind:"sportsTune", event:m.events[m.eventIndex], stream:m.sources[m.sourceIndex]}
    end if
    paintSports()
    return true
end function
