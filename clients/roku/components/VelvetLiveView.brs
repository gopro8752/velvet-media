sub init()
    m.rows = []
    m.channelIndex = 0
    m.programIndex = 0
    m.area = "channels"
    m.headerIndex = 0
    m.channelCells = []
    m.programCells = []
    for i = 0 to 4
        m.channelCells.Push(liveCell(m.top.FindNode("channels"), i * 132, 688, 122, true))
    end for
    for i = 0 to 2
        m.programCells.Push(liveCell(m.top.FindNode("programs"), i * 164, 1004, 152, false))
    end for
    m.top.FindNode("search").ObserveField("selected", "searchSelected")
    m.top.FindNode("refresh").ObserveField("selected", "refreshSelected")
    m.top.FindNode("watch").ObserveField("selected", "watchSelected")
    m.top.ObserveField("focusedChild", "liveFocusChanged")
    m.top.ObserveField("visible", "liveFocusChanged")
    m.observingSceneFocus = false
end sub

function liveLabel(parent as Object, y as Integer, width as Integer, size as Integer, color as String) as Object
    node = parent.CreateChild("Label")
    node.translation = [24, y]
    node.width = width - 48
    node.height = size + 12
    node.color = color
    font = CreateObject("roSGNode", "Font")
    font.uri = "pkg:/fonts/Inter-Regular.ttf"
    font.size = size
    node.font = font
    return node
end function

function liveCell(parent as Object, y as Integer, width as Integer, height as Integer, channel as Boolean) as Object
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
    if channel
        return {group: group, rim: rim, title: liveLabel(group, 12, width, 27, "0xF2F4F8FF"), line1: liveLabel(group, 49, width, 22, "0xC9C2E5FF"), line2: liveLabel(group, 80, width, 21, "0xA9B1C2FF")}
    end if
    return {group: group, rim: rim, title: liveLabel(group, 48, width, 28, "0xF2F4F8FF"), line1: liveLabel(group, 12, width, 22, "0xC9C2E5FF"), line2: liveLabel(group, 91, width, 23, "0xA9B1C2FF")}
end function

sub modelChanged()
    oldId = ""
    if m.channelIndex < m.rows.Count() then oldId = VStr(VGet(m.rows[m.channelIndex].channel, "id"))
    model = m.top.model
    m.rows = VLiveRows(VGet(model, "channels"), VGet(model, "guide", {}), VStr(VGet(model, "query")), VNowMs() / 1000#)
    m.channelIndex = 0
    for i = 0 to m.rows.Count() - 1
        if VStr(VGet(m.rows[i].channel, "id")) = oldId then m.channelIndex = i
    end for
    search = m.top.FindNode("search")
    search.label = "Search channels and programs"
    query = VStr(VGet(model, "query"))
    if query <> "" then search.label = "Search: " + query
    status = VStr(m.rows.Count()) + " channels"
    if VBool(VGet(model, "loading")) then status = "Loading channels…"
    message = VStr(VGet(model, "message"))
    if message <> "" then status += " · " + message
    if m.rows.Count() = 0 and query <> "" then status = "No channels or programs match. Try another search."
    m.top.FindNode("status").text = status
    if m.rows.Count() = 0 then m.area = "header"
    paintLive()
end sub

sub restoreFocus()
    if not m.observingSceneFocus
        scene = m.top.GetScene()
        if scene <> invalid
            scene.ObserveField("focusedChild", "liveFocusChanged")
            m.observingSceneFocus = true
        end if
    end if
    focusLiveArea()
    paintLive()
end sub

' Focusing an ancestor does not release a focused button/paragraph on Roku.
' Keep the native key target aligned with the region whose rim we draw.
sub focusLiveArea()
    target = m.top
    if m.area = "header"
        if m.headerIndex = 0 then target = m.top.FindNode("search") else target = m.top.FindNode("refresh")
    else if m.area = "watch"
        target = m.top.FindNode("watch")
    else if m.area = "details"
        target = m.top.FindNode("programDescription")
    end if
    for each id in ["search", "refresh", "watch", "programDescription"]
        control = m.top.FindNode(id)
        if not control.IsSameNode(target) and control.IsInFocusChain() then control.SetFocus(false)
    end for
    if not target.HasFocus() then target.SetFocus(true)
    liveFocusChanged()
end sub

sub liveFocusChanged()
    active = m.top.visible and m.top.IsInFocusChain()
    m.top.FindNode("search").focused = active and m.area = "header" and m.headerIndex = 0
    m.top.FindNode("refresh").focused = active and m.area = "header" and m.headerIndex = 1
    m.top.FindNode("watch").focused = active and m.area = "watch"
    for each cell in m.channelCells
        cell.rim.opacity = 0.15
        if active then cell.rim.opacity = 0.35
        if active and m.area = "channels" then cell.rim.opacity = 1
    end for
    for each cell in m.programCells
        cell.rim.opacity = 0.15
        if active and m.area = "programs" then cell.rim.opacity = 1
    end for
end sub

sub paintLive()
    offset = Int(m.channelIndex / 5) * 5
    for i = 0 to m.channelCells.Count() - 1
        cell = m.channelCells[i]
        index = offset + i
        cell.group.visible = index < m.rows.Count()
        if cell.group.visible
            row = m.rows[index]
            number = VStr(VGet(row.channel, "number"))
            name = VStr(VGet(row.channel, "name"))
            if number <> "" then name = number + "  " + name
            cell.title.text = name
            cell.line1.text = "Now · " + VStr(VGet(row.current, "title"), "Guide unavailable")
            cell.line2.text = "Next · " + VStr(VGet(row.upcoming, "title"), "Guide unavailable")
            cell.rim.visible = index = m.channelIndex
            cell.rim.opacity = 0.35
            if m.area = "channels" then cell.rim.opacity = 1
        end if
    end for
    hasChannel = m.rows.Count() > 0
    m.top.FindNode("schedule").visible = hasChannel
    if hasChannel
        row = m.rows[m.channelIndex]
        m.top.FindNode("channelTitle").text = VStr(VGet(row.channel, "name"))
        programs = row.programs
        if m.programIndex >= programs.Count() then m.programIndex = 0
        programOffset = Int(m.programIndex / 3) * 3
        for i = 0 to m.programCells.Count() - 1
            cell = m.programCells[i]
            index = programOffset + i
            cell.group.visible = index < programs.Count()
            if cell.group.visible
                program = programs[index]
                cell.title.text = VStr(VGet(program, "title"))
                cell.line1.text = VGuideRange(program)
                if VBool(VGet(program, "isNow")) then cell.line1.text = "NOW · " + cell.line1.text
                cell.line2.text = VStr(VGet(program, "episodeTitle"), VStr(VGet(program, "description")))
                cell.rim.visible = m.area = "programs" and index = m.programIndex
            end if
        end for
        m.top.FindNode("footer").text = VStr(m.channelIndex + 1) + " of " + VStr(m.rows.Count()) + " channels · Right for schedule · Play to watch live"
        if m.area = "programs" then m.top.FindNode("footer").text = "Program " + VStr(m.programIndex + 1) + " of " + VStr(programs.Count()) + " · OK for full description · Left for channels"
        if programs.Count() = 0 then m.top.FindNode("footer").text = "No verified schedule for this channel. Watch live is still available."
    end if
    liveFocusChanged()
    if not m.top.visible or not m.top.IsInFocusChain() then return
    focusLiveArea()
end sub

sub searchSelected()
    m.top.action = {kind: "liveSearch"}
end sub
sub refreshSelected()
    m.top.action = {kind: "liveRefresh"}
end sub
sub watchSelected()
    if m.rows.Count() > 0 then m.top.action = {kind: "liveTune", channel: m.rows[m.channelIndex].channel}
end sub

sub showProgram()
    if m.rows.Count() = 0 then return
    programs = m.rows[m.channelIndex].programs
    if m.programIndex >= programs.Count() then return
    program = programs[m.programIndex]
    m.top.FindNode("programTitle").text = VStr(VGet(program, "title"))
    m.top.FindNode("programTime").text = VGuideRange(program)
    text = VStr(VGet(program, "episodeTitle"))
    description = VStr(VGet(program, "description"))
    if text <> "" and description <> "" then text += Chr(10) + Chr(10)
    text += description
    if text = "" then text = "No description is available for this program."
    m.top.FindNode("programDescription").text = text
    m.top.FindNode("details").visible = true
    m.area = "details"
    focusLiveArea()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "play"
        watchSelected()
        return true
    end if
    if m.area = "details"
        if key = "back" or key = "OK"
            m.area = "programs"
            focusLiveArea()
            m.top.FindNode("details").visible = false
            paintLive()
            return true
        end if
        return false
    end if
    if key = "back"
        if m.area = "programs" or m.area = "watch"
            m.area = "channels"
            paintLive()
        else
            m.top.action = {kind: "liveBack"}
        end if
        return true
    end if
    if m.area = "header"
        if key = "left" then m.headerIndex = 0
        if key = "right" then m.headerIndex = 1
        if key = "down" and m.rows.Count() > 0 then m.area = "channels"
    else if m.area = "channels"
        if key = "up"
            if m.channelIndex = 0 then m.area = "header" else m.channelIndex -= 1
            m.programIndex = 0
        else if key = "down"
            if m.channelIndex < m.rows.Count() - 1 then m.channelIndex += 1
            m.programIndex = 0
        else if key = "right" or key = "OK"
            m.area = "watch"
        else if key = "options"
            if m.rows[m.channelIndex].programs.Count() > 0 then m.area = "programs"
        end if
    else if m.area = "watch"
        if key = "left" then m.area = "channels"
        if key = "up" then m.area = "header"
        if key = "down" and m.rows[m.channelIndex].programs.Count() > 0 then m.area = "programs"
    else if m.area = "programs"
        if key = "left" then m.area = "channels"
        if key = "up"
            if m.programIndex = 0 then m.area = "watch" else m.programIndex -= 1
        end if
        if key = "down" and m.programIndex < m.rows[m.channelIndex].programs.Count() - 1 then m.programIndex += 1
        if key = "OK"
            showProgram()
            return true
        end if
    end if
    paintLive()
    return true
end function
