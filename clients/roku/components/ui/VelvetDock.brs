sub init()
    m.routes = ["home", "search", "live", "sports", "categories", "settings", "exit"]
    labels = ["Home", "Search", "Live TV", "Live Sports", "Categories", "Settings", "Exit"]
    m.index = 0
    m.cells = []
    m.surface = m.top.findNode("surface")
    m.focusPill = m.top.findNode("focusPill")
    m.focusMove = m.top.findNode("focusMove")
    m.glassSample = m.top.findNode("glassSample")
    m.glassArt = m.top.findNode("glassArt")
    m.supportsMask = lcase(createObject("roDeviceInfo").GetGraphicsPlatform()) = "opengl"
    m.reveal = m.top.findNode("reveal")
    m.reveal.observeField("state", "animationChanged")
    host = m.top.findNode("items")
    for i = 0 to m.routes.count() - 1
        cell = host.createChild("Group")
        cell.translation = [i * 159, 0]
        fill = cell.createChild("Poster")
        fill.width = 150
        fill.height = 114
        fill.uri = "pkg:/images/dock-selected.9.png"
        fill.opacity = 0
        icon = cell.createChild("Poster")
        icon.width = 39
        icon.height = 39
        icon.translation = [55.5, 18]
        icon.uri = "pkg:/images/" + m.routes[i] + ".png"
        label = cell.createChild("Label")
        label.translation = [0, 72]
        label.width = 150
        label.height = 30
        label.horizAlign = "center"
        label.text = labels[i]
        font = createObject("roSGNode", "Font")
        font.uri = "pkg:/fonts/Inter-Medium.ttf"
        font.size = 21
        label.font = font
        m.cells.push({fill: fill, icon: icon, label: label})
    end for
    routeChanged()
    backdropChanged()
end sub

sub backdropChanged()
    if m.glassArt = invalid then return
    ' A low-resolution copy softly samples the current artwork. SceneGraph 15
    ' has no backdrop blur, so real content also shows through the glass tint.
    m.glassSample.visible = m.supportsMask and m.top.backdropUri <> ""
    m.glassArt.translation = [-m.top.translation[0], -m.top.translation[1]]
    m.glassArt.uri = m.top.backdropUri
end sub

sub routeChanged()
    if m.cells = invalid then return
    for i = 0 to m.routes.count() - 1
        if m.routes[i] = m.top.activeRoute then m.index = i
    end for
    paintFocus()
end sub

sub paintFocus()
    target = [27 + m.index * 159, 12]
    m.focusMove.control = "stop"
    if m.top.opened and m.lastFocusIndex <> invalid
        m.top.findNode("focusSlide").keyValue = [m.focusPill.translation, target]
        m.focusMove.control = "start"
    else
        m.focusPill.translation = target
    end if
    m.lastFocusIndex = m.index
    for i = 0 to m.cells.count() - 1
        cell = m.cells[i]
        cell.fill.opacity = 0
        cell.label.color = "0xE2E5EDFF"
        cell.icon.blendColor = "0xE2E5EDFF"
        if m.routes[i] = m.top.activeRoute
            cell.fill.opacity = 0.7
            cell.label.color = "0xC7BCFFFF"
            cell.icon.blendColor = "0xC7BCFFFF"
        end if
        if i = m.index
            cell.label.color = "0xFFFFFFFF"
            cell.icon.blendColor = "0xFFFFFFFF"
        end if
    end for
end sub

sub openChanged()
    if m.surface = invalid then return
    m.reveal.control = "stop"
    startOpacity = m.surface.opacity
    startY = m.surface.translation[1]
    if m.top.opened
        m.top.visible = true
        backdropChanged()
        routeChanged()
        m.top.findNode("fade").keyValue = [startOpacity, 1]
        m.top.findNode("slide").keyValue = [[0, startY], [0, 0]]
    else
        m.top.findNode("fade").keyValue = [startOpacity, 0]
        m.top.findNode("slide").keyValue = [[0, startY], [0, 18]]
    end if
    m.reveal.control = "start"
end sub

sub animationChanged()
    ' openChanged stops an interrupted animation before starting its reverse.
    ' Only hide after the fade actually reached zero, not on that earlier stop.
    if m.reveal.state = "stopped" and not m.top.opened and m.surface.opacity < 0.001 then m.top.visible = false
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return true
    if key = "left"
        if m.index > 0 then m.index = m.index - 1
        paintFocus()
        return true
    else if key = "right"
        if m.index < m.routes.count() - 1 then m.index = m.index + 1
        paintFocus()
        return true
    else if key = "back" or key = "up"
        m.top.action = {kind: "close"}
        return true
    else if key = "OK"
        if m.routes[m.index] = "exit"
            m.top.action = {kind: "exit"}
        else
            m.top.action = {kind: "navigate", route: m.routes[m.index]}
        end if
        return true
    else if key = "down"
        return true
    end if
    return false
end function
