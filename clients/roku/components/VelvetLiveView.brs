sub init()
    m.rows = []
    m.channelIndex = 0
    m.rowOffset = 0
    m.area = "grid"
    m.headerIndex = 0
    m.headerIds = ["all", "favorites", "search", "now", "refresh"]
    m.now = VNowMs() / 1000#
    m.windowStart = VGuideWindowStart(m.now)
    m.focusTime = m.now
    m.followNow = true
    m.favoriteIds = []
    m.query = ""
    m.gridRows = []
    m.rulerLabels = []
    for i = 0 to 3
        label = guideLabel(m.top.FindNode("ruler"), [i * 352, 0], 340, 34, 22, "0xA9A2B9FF")
        m.rulerLabels.Push(label)
    end for
    for i = 0 to 5
        m.gridRows.Push(createGuideRow(i))
    end for
    m.top.FindNode("all").ObserveField("selected", "allSelected")
    m.top.FindNode("favorites").ObserveField("selected", "favoritesSelected")
    m.top.FindNode("search").ObserveField("selected", "searchSelected")
    m.top.FindNode("now").ObserveField("selected", "nowSelected")
    m.top.FindNode("refresh").ObserveField("selected", "refreshSelected")
    m.top.ObserveField("focusedChild", "liveFocusChanged")
    m.top.ObserveField("visible", "liveFocusChanged")
    m.observingSceneFocus = false
end sub

function guideLabel(parent as Object, position as Object, width as Integer, height as Integer, size as Integer, color as String) as Object
    node = parent.CreateChild("Label")
    node.translation = position
    node.width = width
    node.height = height
    node.color = color
    font = CreateObject("roSGNode", "Font")
    font.uri = "pkg:/fonts/Inter-Regular.ttf"
    font.size = size
    node.font = font
    return node
end function

function createGuideRow(index as Integer) as Object
    group = m.top.FindNode("grid").CreateChild("Group")
    group.translation = [0, index * 84]
    rail = group.CreateChild("Poster")
    rail.width = 300
    rail.height = 76
    rail.uri = "pkg:/images/card-well.9.png"
    rail.blendColor = "0xC1B3DFCC"
    logo = group.CreateChild("Poster")
    logo.translation = [15, 12]
    logo.width = 62
    logo.height = 52
    logo.loadDisplayMode = "scaleToFit"
    name = guideLabel(group, [92, 10], 192, 32, 22, "0xF1EEF7FF")
    number = guideLabel(group, [92, 44], 192, 26, 18, "0x9390A5FF")
    cells = []
    ' Reuse cells; unusually dense listings grow the pool once, then keep it.
    for i = 0 to 11
        cells.Push(createGuideCell(group))
    end for
    return {group:group, rail:rail, logo:logo, name:name, number:number, cells:cells}
end function

function createGuideCell(group as Object) as Object
    container = group.CreateChild("Group")
    fill = container.CreateChild("Poster")
    fill.height = 76
    fill.uri = "pkg:/images/card-well.9.png"
    glow = container.CreateChild("Poster")
    glow.height = 76
    glow.uri = "pkg:/images/button-white.9.png"
    glow.blendColor = "0x4A3B65FF"
    glow.visible = false
    rim = container.CreateChild("Poster")
    rim.height = 76
    rim.uri = "pkg:/images/button-focus.9.png"
    rim.visible = false
    title = guideLabel(container, [16, 11], 280, 31, 23, "0xE7E3F0FF")
    time = guideLabel(container, [16, 46], 280, 24, 17, "0x9F98AFFF")
    progress = container.CreateChild("Rectangle")
    progress.translation = [12, 71]
    progress.height = 2
    progress.color = "0xA58BC9B0"
    return {group:container, fill:fill, glow:glow, rim:rim, title:title, time:time, progress:progress}
end function

sub modelChanged()
    oldId = ""
    if m.channelIndex < m.rows.Count() then oldId = VStr(VGet(m.rows[m.channelIndex].channel, "id"))
    model = m.top.model
    m.now = VNowMs() / 1000#
    m.favoriteIds = VGuideFavoriteIds(VGet(model, "favoriteIds"))
    m.favoritesOnly = VBool(VGet(model, "favoritesOnly"))
    allRows = VLiveRows(VGet(model, "channels"), VGet(model, "guide", {}), VStr(VGet(model, "query")), m.now)
    m.rows = VGuideFavoriteRows(allRows, m.favoriteIds, m.favoritesOnly)
    m.channelIndex = 0
    for i = 0 to m.rows.Count() - 1
        if VStr(VGet(m.rows[i].channel, "id")) = oldId then m.channelIndex = i
    end for
    m.lastTime = VGuideLastTime(m.rows, m.now)
    if m.followNow
        m.windowStart = VGuideWindowStart(m.now)
        m.focusTime = m.now
    else if m.windowStart < VGuideWindowStart(m.now)
        m.windowStart = VGuideWindowStart(m.now)
        if m.focusTime < m.windowStart then m.focusTime = m.now
    end if
    m.top.FindNode("search").label = "Find a channel or program"
    query = VStr(VGet(model, "query"))
    if query <> m.query and m.rows.Count() > 0
        m.focusTime = VGuideSearchTime(m.rows[m.channelIndex], query, m.now)
        m.windowStart = VGuideWindowStart(m.focusTime)
        m.followNow = m.focusTime = m.now
        m.query = query
    end if
    if query = "" then m.query = ""
    if query <> "" then m.top.FindNode("search").label = "Search: " + query
    m.top.FindNode("all").accent = not m.favoritesOnly
    m.top.FindNode("favorites").accent = m.favoritesOnly
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

sub focusLiveArea()
    target = m.top
    if m.area = "header" then target = m.top.FindNode(m.headerIds[m.headerIndex])
    if m.area = "details" then target = m.top.FindNode("programDescription")
    for each id in ["all", "favorites", "search", "now", "refresh", "programDescription"]
        control = m.top.FindNode(id)
        if not control.IsSameNode(target) and control.IsInFocusChain() then control.SetFocus(false)
    end for
    if not target.HasFocus() then target.SetFocus(true)
    liveFocusChanged()
end sub

sub liveFocusChanged()
    active = m.top.visible and m.top.IsInFocusChain()
    for i = 0 to m.headerIds.Count() - 1
        m.top.FindNode(m.headerIds[i]).focused = active and m.area = "header" and m.headerIndex = i
    end for
    for each row in m.gridRows
        for each cell in row.cells
            cell.rim.opacity = 0
            cell.glow.opacity = 0.35
            if active and m.area = "grid"
                cell.rim.opacity = 1
                cell.glow.opacity = 1
            end if
        end for
    end for
end sub

function focusedGuideSegment() as Dynamic
    if m.rows.Count() = 0 then return invalid
    segments = VGuideWindowSegments(m.rows[m.channelIndex].programs, m.windowStart)
    index = VGuideSegmentAt(segments, m.focusTime)
    if index < 0 then return invalid
    return segments[index]
end function

sub paintLive()
    m.top.FindNode("clock").text = VGuideClock(m.now, true)
    for i = 0 to 3
        m.rulerLabels[i].text = VGuideClock(m.windowStart + i * 1800#)
    end for
    m.top.FindNode("status").text = VStr(m.rows.Count()) + " channels"
    if VBool(VGet(m.top.model, "loading")) then m.top.FindNode("status").text = "Updating guide…"
    if m.channelIndex < m.rowOffset then m.rowOffset = m.channelIndex
    if m.channelIndex >= m.rowOffset + 6 then m.rowOffset = m.channelIndex - 5
    if m.rowOffset > m.rows.Count() - 6 then m.rowOffset = m.rows.Count() - 6
    if m.rowOffset < 0 then m.rowOffset = 0
    for i = 0 to m.gridRows.Count() - 1
        ui = m.gridRows[i]
        index = m.rowOffset + i
        ui.group.visible = index < m.rows.Count()
        if ui.group.visible
            row = m.rows[index]
            channel = row.channel
            ui.name.text = VStr(VGet(channel, "name"))
            ui.number.text = VStr(VGet(channel, "number"))
            if VGuideHasFavorite(m.favoriteIds, VStr(VGet(channel, "id"))) then ui.number.text += "   ★ Favorite"
            ui.logo.uri = VStr(VGet(channel, "logoUrl"))
            ui.logo.visible = ui.logo.uri <> ""
            ui.rail.blendColor = "0xC1B3DFCC"
            if index = m.channelIndex then ui.rail.blendColor = "0xE3D5FFFF"
            segments = VGuideWindowSegments(row.programs, m.windowStart)
            while ui.cells.Count() < segments.Count()
                ui.cells.Push(createGuideCell(ui.group))
            end while
            focusIndex = VGuideSegmentAt(segments, m.focusTime)
            for j = 0 to ui.cells.Count() - 1
                cell = ui.cells[j]
                cell.group.visible = j < segments.Count()
                if cell.group.visible
                    segment = segments[j]
                    x = (segment.startSeconds - m.windowStart) / 7200# * 1408
                    width = Int((segment.endSeconds - segment.startSeconds) / 7200# * 1408) - 6
                    if width < 1 then width = 1
                    cell.group.translation = [320 + x, 0]
                    cell.fill.width = width
                    cell.glow.width = width
                    cell.rim.width = width
                    labelWidth = width - 32
                    if labelWidth < 1 then labelWidth = 1
                    cell.title.width = labelWidth
                    cell.time.width = labelWidth
                    cell.title.visible = width >= 80
                    cell.time.visible = width >= 150
                    cell.rim.visible = index = m.channelIndex and j = focusIndex
                    cell.glow.visible = cell.rim.visible
                    cell.title.color = "0xE7E3F0FF"
                    cell.fill.opacity = 1
                    cell.progress.visible = false
                    program = segment.program
                    if program = invalid
                        cell.title.text = "Schedule unavailable"
                        cell.time.text = "Watch channel live"
                        cell.title.color = "0x777487FF"
                        cell.fill.opacity = 0.45
                    else
                        cell.title.text = VStr(VGet(program, "title"))
                        cell.time.text = VGuideClock(program.startSeconds) + " – " + VGuideClock(program.endSeconds)
                        if VBool(VGet(program, "isNow"))
                            cell.progress.visible = width > 24
                            portion = (m.now - segment.startSeconds) / (segment.endSeconds - segment.startSeconds)
                            if portion < 0 then portion = 0
                            if portion > 1 then portion = 1
                            cell.progress.width = (width - 24) * portion
                        end if
                    end if
                end if
            end for
        end if
    end for
    marker = m.top.FindNode("nowMarker")
    marker.visible = m.rows.Count() > 0 and m.now >= m.windowStart and m.now < m.windowStart + 7200#
    marker.translation = [416 + (m.now - m.windowStart) / 7200# * 1408, 444]
    paintSelection()
    liveFocusChanged()
    if m.top.visible and m.top.IsInFocusChain() then focusLiveArea()
end sub

sub paintSelection()
    title = m.top.FindNode("selectionTitle")
    meta = m.top.FindNode("selectionMeta")
    description = m.top.FindNode("selectionDescription")
    action = m.top.FindNode("selectionAction")
    footer = m.top.FindNode("footer")
    if m.rows.Count() = 0
        title.text = "Your guide, your way"
        meta.text = "LIVE TV"
        description.text = "Channels and their schedules will appear here."
        if m.favoritesOnly then description.text = "Add your favorites with the Options button while browsing All channels."
        if VStr(VGet(m.top.model, "query")) <> "" then description.text = "No channels or programs match. Try another search."
        message = VStr(VGet(m.top.model, "message"))
        if message <> "" then description.text = message
        action.text = ""
        footer.text = "Choose a filter or search above · Back for navigation"
        return
    end if
    row = m.rows[m.channelIndex]
    segment = focusedGuideSegment()
    program = segment.program
    channelName = VStr(VGet(row.channel, "name"))
    meta.text = channelName
    action.text = "OK · Program details"
    description.text = "No schedule was supplied for this time. Press Play to watch the channel live."
    title.text = "Schedule unavailable"
    if program <> invalid
        title.text = VStr(VGet(program, "title"))
        meta.text += "  ·  " + VGuideClock(program.startSeconds, true) + " – " + VGuideClock(program.endSeconds)
        if VBool(VGet(program, "isLive")) then meta.text += "  ·  LIVE"
        if VBool(VGet(program, "isNew")) then meta.text += "  ·  NEW"
        rating = VStr(VGet(program, "rating"))
        if rating <> "" then meta.text += "  ·  " + rating
        description.text = VStr(VGet(program, "description"), "No description is available for this program.")
        episode = VStr(VGet(program, "episodeTitle"))
        if episode <> "" then description.text = episode + " · " + description.text
    end if
    current = m.now >= segment.startSeconds and m.now < segment.endSeconds
    if current then action.text = "OK · Watch live"
    footer.text = VStr(m.channelIndex + 1) + " / " + VStr(m.rows.Count()) + "   ·   ↑ ↓ Channels   ·   ← → Schedule   ·   Play: watch live   ·   Options: favorite"
    message = VStr(VGet(m.top.model, "message"))
    if message <> "" then footer.text = "Guide update: " + message
end sub

sub allSelected()
    m.top.action = {kind:"liveFilter", favoritesOnly:false}
end sub
sub favoritesSelected()
    m.top.action = {kind:"liveFilter", favoritesOnly:true}
end sub
sub searchSelected()
    m.top.action = {kind:"liveSearch"}
end sub
sub nowSelected()
    m.now = VNowMs() / 1000#
    m.windowStart = VGuideWindowStart(m.now)
    m.focusTime = m.now
    m.followNow = true
    if m.rows.Count() > 0 then m.area = "grid"
    paintLive()
end sub
sub refreshSelected()
    m.top.action = {kind:"liveRefresh"}
end sub
sub watchSelected()
    if m.rows.Count() > 0 then m.top.action = {kind:"liveTune", channel:m.rows[m.channelIndex].channel}
end sub

sub showProgram()
    segment = focusedGuideSegment()
    if segment = invalid then return
    program = segment.program
    if program = invalid
        m.top.FindNode("programTitle").text = "Schedule unavailable"
        m.top.FindNode("programTime").text = VGuideClock(segment.startSeconds, true) + " – " + VGuideClock(segment.endSeconds)
        m.top.FindNode("programDescription").text = "This channel has no verified listing for the selected time. You can still press Play to watch what is airing live."
    else
        m.top.FindNode("programTitle").text = VStr(VGet(program, "title"))
        m.top.FindNode("programTime").text = VGuideRange(program)
        description = VStr(VGet(program, "description"), "No description is available for this program.")
        episode = VStr(VGet(program, "episodeTitle"))
        if episode <> "" then description = episode + Chr(10) + Chr(10) + description
        if program.startSeconds > m.now then description += Chr(10) + Chr(10) + "This program airs later. Play watches the channel's current live broadcast."
        m.top.FindNode("programDescription").text = description
    end if
    m.top.FindNode("details").visible = true
    m.area = "details"
    focusLiveArea()
end sub

sub moveGuideTime(direction as Integer)
    destination = VGuideNavigateTime(m.rows[m.channelIndex].programs, m.windowStart, m.focusTime, m.now, m.lastTime, direction)
    m.windowStart = destination.windowStart
    m.focusTime = destination.focusTime
    m.followNow = false
    if destination.focusHeader
        m.area = "header"
        m.headerIndex = 0
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "play"
        watchSelected()
        return true
    end if
    if m.area = "details"
        if key = "back" or key = "OK"
            m.top.FindNode("details").visible = false
            m.area = "grid"
            paintLive()
            return true
        end if
        return false
    end if
    if key = "back"
        m.top.action = {kind:"liveBack"}
        return true
    end if
    if m.area = "header"
        if key = "left" and m.headerIndex > 0 then m.headerIndex -= 1
        if key = "right" and m.headerIndex < m.headerIds.Count() - 1 then m.headerIndex += 1
        if key = "down" and m.rows.Count() > 0 then m.area = "grid"
    else if m.area = "grid" and m.rows.Count() > 0
        if key = "up"
            if m.channelIndex = 0 then m.area = "header" else m.channelIndex -= 1
        else if key = "down"
            if m.channelIndex < m.rows.Count() - 1 then m.channelIndex += 1
        else if key = "left"
            moveGuideTime(-1)
        else if key = "right"
            moveGuideTime(1)
        else if key = "options"
            m.top.action = {kind:"liveFavorite", channelId:VStr(VGet(m.rows[m.channelIndex].channel, "id"))}
            return true
        else if key = "OK"
            segment = focusedGuideSegment()
            if m.now >= segment.startSeconds and m.now < segment.endSeconds then watchSelected() else showProgram()
            return true
        else if key = "rewind"
            nowSelected()
            return true
        else if key = "fastforward"
            m.channelIndex += 6
            if m.channelIndex >= m.rows.Count() then m.channelIndex = m.rows.Count() - 1
        end if
    end if
    paintLive()
    return true
end function
