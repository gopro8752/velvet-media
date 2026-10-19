sub init()
    m.model = {}
    m.controlsShown = true
    m.userHidControls = false
    m.focusArea = "buttons"
    m.focusId = "playPause"
    m.buttons = []
    m.menuItems = []
    m.menuRows = []
    m.menuIndex = 0
    m.menuOffset = 0
    m.menuOpen = false
    m.contextKind = ""
    m.contextFocus = "play"
    m.menuSignature = ""
    m.menuPositions = {}
    m.seekTarget = invalid
    m.surface = m.top.findNode("surface")
    m.menuSurface = m.top.findNode("menuSurface")
    m.controlsAnimation = m.top.findNode("controlsAnimation")
    m.menuAnimation = m.top.findNode("menuAnimation")
    m.hideTimer = m.top.findNode("hideTimer")
    m.seekTimer = m.top.findNode("seekTimer")
    m.hideTimer.observeField("fire", "hideTimerFired")
    m.seekTimer.observeField("fire", "commitSeek")
    m.menuAnimation.observeField("state", "menuAnimationChanged")
    createButtons()
    createMenuRows()
    paintFocus()
end sub

sub createButtons()
    host = m.top.findNode("buttons")
    definitions = [
        {id: "replay", icon: "replay", label: "What did they say?", x: 0, size: 82},
        {id: "rewind10", icon: "rewind10", label: "Rewind 10 seconds", x: 598, size: 82},
        {id: "previous", icon: "previous", label: "Previous episode", x: 704, size: 82},
        {id: "playPause", icon: "play", label: "Play", x: 810, size: 108},
        {id: "next", icon: "next", label: "Next episode", x: 942, size: 82},
        {id: "forward10", icon: "forward10", label: "Forward 10 seconds", x: 1048, size: 82},
        {id: "streams", icon: "streams", label: "Streams", x: 1516, size: 82},
        {id: "options", icon: "options", label: "Playback options", x: 1646, size: 82}
    ]
    for each definition in definitions
        group = host.createChild("Group")
        group.translation = [definition.x, (108 - definition.size) / 2]
        fill = group.createChild("Poster")
        fill.width = definition.size
        fill.height = definition.size
        fill.uri = "pkg:/images/player/circle.png"
        icon = group.createChild("Poster")
        icon.width = 42
        icon.height = 42
        icon.translation = [(definition.size - 42) / 2, (definition.size - 42) / 2]
        icon.uri = "pkg:/images/player/" + definition.icon + ".png"
        m.buttons.push({id: definition.id, label: definition.label, group: group, fill: fill, icon: icon, enabled: true, shown: true})
    end for
end sub

sub createMenuRows()
    host = m.top.findNode("menuRows")
    for i = 0 to 6
        group = host.createChild("Group")
        group.translation = [0, i * 102]
        fill = group.createChild("Poster")
        fill.width = 696
        fill.height = 94
        fill.uri = "pkg:/images/player/row.9.png"
        icon = group.createChild("Poster")
        icon.width = 35
        icon.height = 35
        icon.translation = [22, 29]
        title = group.createChild("Label")
        title.translation = [76, 15]
        title.width = 548
        title.height = 34
        title.font = VPFont("Inter-Medium", 26)
        subtitle = group.createChild("Label")
        subtitle.translation = [76, 52]
        subtitle.width = 548
        subtitle.height = 28
        subtitle.font = VPFont("Inter-Regular", 21)
        check = group.createChild("Poster")
        check.translation = [643, 31]
        check.width = 30
        check.height = 30
        check.uri = "pkg:/images/player/check.png"
        m.menuRows.push({group: group, fill: fill, icon: icon, title: title, subtitle: subtitle, check: check})
    end for
end sub

function VPFont(face as String, size as Integer) as Object
    font = createObject("roSGNode", "Font")
    font.uri = "pkg:/fonts/" + face + ".ttf"
    font.size = size
    return font
end function

sub modelChanged()
    if m.surface = invalid then return
    previousPlaying = VPBool(m.model.playing)
    previousBusy = VPBool(m.model.busy)
    if type(m.top.model) = "roAssociativeArray" then m.model = m.top.model else m.model = {}
    subtitle = VPStr(m.model.subtitle)
    title = VPStr(m.model.title)
    if subtitle <> ""
        m.top.findNode("eyebrow").text = title
        m.top.findNode("title").text = subtitle
    else
        m.top.findNode("eyebrow").text = ""
        m.top.findNode("title").text = title
    end if
    m.top.findNode("statusGroup").visible = VPBool(m.model.busy)
    backdrop = VPStr(m.model.backdropUrl)
    showBackdrop = VPBool(m.model.busy) and not VPBool(m.model.playing) and (VPNum(m.model.duration) <= 0 or VPBool(m.model.showBackdrop))
    m.top.findNode("preparingBackdrop").visible = showBackdrop and backdrop <> ""
    m.top.findNode("backdrop").uri = backdrop
    status = VPStr(m.model.status)
    m.top.findNode("noticeGroup").visible = status <> "" and not VPBool(m.model.busy)
    m.top.findNode("notice").text = status
    if status = "" then status = "Starting playback…"
    m.top.findNode("status").text = status
    if VPBool(m.model.busy)
        if not previousBusy then m.top.findNode("loadingPulse").control = "start"
    else
        m.top.findNode("loadingPulse").control = "stop"
    end if
    for each button in m.buttons
        button.enabled = true
        button.shown = true
        if button.id = "playPause"
            if VPBool(m.model.playing)
                button.icon.uri = "pkg:/images/player/pause.png"
                button.label = "Pause"
            else
                button.icon.uri = "pkg:/images/player/play.png"
                button.label = "Play"
            end if
        else if button.id = "previous"
            button.shown = VPBool(m.model.episodic)
            button.enabled = VPBool(m.model.hasPrevious)
        else if button.id = "next"
            button.shown = VPBool(m.model.episodic)
            button.enabled = VPBool(m.model.hasNext)
        else if button.id = "replay"
            button.enabled = not VPBool(m.model.isLive) and VPNum(m.model.duration) > 0
        else if button.id = "rewind10" or button.id = "forward10"
            button.shown = not VPBool(m.model.isLive)
            button.enabled = VPNum(m.model.duration) > 0
            if button.id = "rewind10" then button.enabled = button.enabled and VPNum(m.model.position) > 0
            if button.id = "forward10" then button.enabled = button.enabled and VPNum(m.model.position) < VPNum(m.model.duration) - 1
            x = 704
            if button.id = "forward10" then x = 942
            if VPBool(m.model.episodic)
                if button.id = "rewind10" then x = 598 else x = 1048
            end if
            button.group.translation = [x, 13]
        else if button.id = "streams"
            button.shown = not VPBool(m.model.isLive)
        else if button.id = "options"
            button.label = "Playback options"
            if VPBool(m.model.captionsEnabled) then button.label = "Playback options · Captions on"
        end if
        button.group.visible = button.shown
    end for
    if not focusAvailable(m.focusId) then m.focusId = "playPause"
    previousContext = m.contextKind
    m.contextKind = ""
    if VPBool(m.model.skipIntro)
        m.contextKind = "skipIntro"
        m.top.findNode("contextLabel").text = "Skip intro  ›"
    else if type(m.model.upNext) = "roAssociativeArray" and VPBool(m.model.hasNext)
        m.contextKind = "next"
        nextLabel = VPStr(m.model.upNext.label)
        if nextLabel = "" then nextLabel = "Next episode"
        if VPNum(m.model.upNext.seconds) > 0 then nextLabel = nextLabel + " · " + VPStr(int(VPNum(m.model.upNext.seconds))) + "s"
        m.top.findNode("contextLabel").text = nextLabel
    end if
    m.top.findNode("contextAction").visible = m.contextKind <> ""
    m.top.findNode("contextDismiss").visible = m.contextKind = "next"
    if m.contextKind = "next"
        m.top.findNode("contextAction").translation = [1300, 604]
    else
        m.top.findNode("contextAction").translation = [1384, 604]
    end if
    if m.contextKind <> previousContext then m.contextFocus = "play"
    if m.contextKind = "" and m.focusArea = "context" then m.focusArea = "timeline"
    if VPBool(m.model.isLive) and m.focusArea = "timeline" then m.focusArea = "buttons"
    updateTimeline()
    updateMenu()
    paintFocus()
    if not VPBool(m.model.playing) or VPBool(m.model.busy)
        if not m.userHidControls then setControlsShown(true)
        m.hideTimer.control = "stop"
    else if not previousPlaying or previousBusy
        restartHideTimer()
    end if
end sub

sub updateTimeline()
    position = VPNum(m.model.position)
    if m.seekTarget <> invalid then position = m.seekTarget
    duration = VPNum(m.model.duration)
    fraction = 0.0
    bufferFraction = 0.0
    if duration > 0
        fraction = VPClamp(position / duration, 0, 1)
        bufferFraction = VPClamp(VPNum(m.model.buffered) / duration, 0, 1)
    end if
    m.top.findNode("progress").width = 1728 * fraction
    m.top.findNode("buffered").width = 1728 * bufferFraction
    m.top.findNode("thumb").translation = [1728 * fraction - 9, -7]
    m.top.findNode("thumb").visible = not VPBool(m.model.isLive)
    m.top.findNode("elapsed").text = VPTime(position)
    remaining = ""
    if duration > 0 then remaining = "−" + VPTime(duration - position)
    if VPBool(m.model.isLive)
        m.top.findNode("elapsed").text = "●  LIVE"
        m.top.findNode("elapsed").color = "0xD8C9FFFF"
        remaining = ""
    else
        m.top.findNode("elapsed").color = "0xB9BECCFF"
    end if
    m.top.findNode("remaining").text = remaining
end sub

sub paintFocus()
    for each button in m.buttons
        focused = m.focusArea = "buttons" and m.focusId = button.id
        button.fill.uri = "pkg:/images/player/circle.png"
        button.icon.blendColor = "0xF3F2F8FF"
        button.group.opacity = 1
        if button.id = "replay" and VPBool(m.model.replayActive)
            button.fill.uri = "pkg:/images/player/circle-active.png"
            button.icon.blendColor = "0xCDBDFFFF"
        end if
        if focused and button.enabled
            button.fill.uri = "pkg:/images/player/circle-focus.png"
            button.icon.blendColor = "0x141621FF"
            m.top.findNode("focusLabel").text = button.label
        end if
        if not button.enabled then button.group.opacity = 0.32
    end for
    timelineFocused = m.focusArea = "timeline"
    m.top.findNode("seekHint").visible = timelineFocused
    m.top.findNode("focusLabel").visible = not timelineFocused
    if m.focusArea = "context"
        m.top.findNode("focusLabel").visible = false
        if m.contextFocus = "play"
            m.top.findNode("contextFill").uri = "pkg:/images/player/row-focus.9.png"
        else
            m.top.findNode("contextFill").uri = "pkg:/images/player/row.9.png"
        end if
    else
        m.top.findNode("contextFill").uri = "pkg:/images/player/row.9.png"
    end if
    dismissFocused = m.focusArea = "context" and m.contextKind = "next" and m.contextFocus = "dismiss"
    m.top.findNode("dismissHint").visible = dismissFocused
    if dismissFocused
        m.top.findNode("dismissFill").uri = "pkg:/images/player/circle-focus.png"
        m.top.findNode("dismissIcon").blendColor = "0x141621FF"
    else
        m.top.findNode("dismissFill").uri = "pkg:/images/player/circle.png"
        m.top.findNode("dismissIcon").blendColor = "0xF3F2F8FF"
    end if
    if timelineFocused
        m.top.findNode("progress").color = "0xCABAFFFF"
        m.top.findNode("thumb").blendColor = "0xCABAFFFF"
    else
        m.top.findNode("progress").color = "0xF4F2FFFF"
        m.top.findNode("thumb").blendColor = "0xFFFFFFFF"
    end if
end sub

sub revealControls()
    m.userHidControls = false
    setControlsShown(true)
    restartHideTimer()
end sub

sub restoreFocus()
    m.top.setFocus(true)
    revealControls()
end sub

sub resetSession()
    m.top.setFocus(true)
    m.seekTimer.control = "stop"
    m.hideTimer.control = "stop"
    m.seekTarget = invalid
    m.focusArea = "buttons"
    m.focusId = "playPause"
    m.menuIndex = 0
    m.menuOffset = 0
    m.menuSignature = ""
    m.menuPositions = {}
    m.menuOpen = false
    m.menuItems = []
    m.menuAnimation.control = "stop"
    m.menuSurface.opacity = 0
    m.menuSurface.visible = false
    m.contextKind = ""
    m.contextFocus = "play"
    m.userHidControls = false
    m.top.findNode("contextAction").visible = false
    setControlsShown(true)
    paintFocus()
end sub

sub setControlsShown(shown as Boolean)
    if m.controlsShown = shown then return
    m.controlsShown = shown
    m.controlsAnimation.control = "stop"
    opacity = 0
    y = 22
    if shown
        opacity = 1
        y = 0
    end if
    m.top.findNode("controlsFade").keyValue = [m.surface.opacity, opacity]
    m.top.findNode("controlsSlide").keyValue = [m.surface.translation, [0, y]]
    m.controlsAnimation.control = "start"
end sub

sub restartHideTimer()
    m.hideTimer.control = "stop"
    if VPBool(m.model.playing) and not VPBool(m.model.busy) and not m.menuOpen
        m.hideTimer.control = "start"
    end if
end sub

sub hideTimerFired()
    if VPBool(m.model.playing) and not VPBool(m.model.busy) and not m.menuOpen and m.seekTarget = invalid
        setControlsShown(false)
    end if
end sub

sub updateMenu()
    menu = m.model.menu
    open = type(menu) = "roAssociativeArray"
    if open
        items = menu.items
        if type(items) <> "roArray" then items = []
        signature = VPStr(menu.title)
        for each item in items
            signature = signature + "|" + VPStr(item.id)
        end for
        if signature <> m.menuSignature
            if m.menuSignature <> "" then m.menuPositions[m.menuSignature] = m.menuIndex
            m.menuIndex = 0
            m.menuOffset = 0
            for i = 0 to items.count() - 1
                if VPBool(items[i].selected) then m.menuIndex = i
            end for
            previousIndex = m.menuPositions.Lookup(signature)
            if previousIndex <> invalid then m.menuIndex = int(VPNum(previousIndex))
            m.menuSignature = signature
        end if
        m.menuItems = items
        if m.menuIndex >= items.count() then m.menuIndex = 0
        if items.count() > 0 and not VPEnabled(items[m.menuIndex])
            for i = 0 to items.count() - 1
                if VPEnabled(items[i])
                    m.menuIndex = i
                    exit for
                end if
            end for
        end if
        m.top.findNode("menuTitle").text = VPStr(menu.title)
        m.top.findNode("menuSubtitle").text = VPStr(menu.subtitle)
        m.top.findNode("menuEmpty").text = VPStr(menu.emptyMessage)
        m.top.findNode("menuEmpty").visible = items.count() = 0
        paintMenu()
    end if
    if open <> m.menuOpen
        m.menuOpen = open
        m.menuAnimation.control = "stop"
        opacity = 0
        x = 1150
        if open
            m.menuSurface.visible = true
            opacity = 1
            x = 1120
            m.hideTimer.control = "stop"
        else
            if m.menuSignature <> "" then m.menuPositions[m.menuSignature] = m.menuIndex
            m.menuSignature = ""
            restartHideTimer()
        end if
        m.top.findNode("menuFade").keyValue = [m.menuSurface.opacity, opacity]
        m.top.findNode("menuSlide").keyValue = [m.top.findNode("sheet").translation, [x, 42]]
        m.menuAnimation.control = "start"
    end if
end sub

sub menuAnimationChanged()
    if m.menuAnimation.state = "stopped" and not m.menuOpen then m.menuSurface.visible = false
end sub

sub paintMenu()
    if m.menuIndex < m.menuOffset then m.menuOffset = m.menuIndex
    if m.menuIndex > m.menuOffset + 6 then m.menuOffset = m.menuIndex - 6
    for i = 0 to 6
        row = m.menuRows[i]
        index = m.menuOffset + i
        row.group.visible = index < m.menuItems.count()
        if row.group.visible
            item = m.menuItems[index]
            row.title.text = VPStr(item.label)
            row.subtitle.text = VPStr(item.subtitle)
            row.title.color = "0xF2F2F7FF"
            row.subtitle.color = "0xAEB7C9FF"
            row.check.visible = VPBool(item.selected)
            row.check.blendColor = "0xD0BEFFFF"
            icon = VPStr(item.icon)
            if not VPValidIcon(icon) then icon = "arrow"
            row.icon.uri = "pkg:/images/player/" + icon + ".png"
            row.icon.blendColor = "0xD3D7E2FF"
            row.group.opacity = 1
            if not VPEnabled(item) then row.group.opacity = 0.38
            row.fill.uri = "pkg:/images/player/row.9.png"
            if index = m.menuIndex and VPEnabled(item)
                row.fill.uri = "pkg:/images/player/row-focus.9.png"
                row.icon.blendColor = "0xE5DBFFFF"
                row.title.color = "0xFFFFFFFF"
            end if
            if row.subtitle.text = ""
                row.title.translation = [76, 29]
            else
                row.title.translation = [76, 15]
            end if
        end if
    end for
    count = m.menuItems.count()
    hint = "Back to player"
    if count > 7 then hint = VPStr(m.menuIndex + 1) + " of " + VPStr(count) + "    ·    Back to player"
    m.top.findNode("menuCount").text = hint
end sub

function VPValidIcon(icon as String) as Boolean
    return icon = "play" or icon = "pause" or icon = "previous" or icon = "next" or icon = "replay" or icon = "streams" or icon = "options" or icon = "check" or icon = "captions" or icon = "audio" or icon = "block" or icon = "reset" or icon = "arrow"
end function

function focusAvailable(id as String) as Boolean
    for each button in m.buttons
        if button.id = id then return button.enabled and button.shown
    end for
    return false
end function

sub moveButton(direction as Integer)
    index = 0
    for i = 0 to m.buttons.count() - 1
        if m.buttons[i].id = m.focusId then index = i
    end for
    index = index + direction
    while index >= 0 and index < m.buttons.count()
        button = m.buttons[index]
        if button.enabled and button.shown
            m.focusId = button.id
            exit while
        end if
        index = index + direction
    end while
    paintFocus()
end sub

sub seekBy(seconds as Integer)
    if VPBool(m.model.isLive) or VPNum(m.model.duration) <= 0 then return
    position = VPNum(m.model.position)
    if m.seekTarget <> invalid then position = m.seekTarget
    m.seekTarget = VPClamp(position + seconds, 0, VPNum(m.model.duration) - 0.1)
    m.focusArea = "timeline"
    revealControls()
    updateTimeline()
    paintFocus()
    m.seekTimer.control = "stop"
    m.seekTimer.control = "start"
end sub

sub commitSeek()
    if m.seekTarget = invalid then return
    target = m.seekTarget
    m.seekTarget = invalid
    m.seekTimer.control = "stop"
    m.top.action = {kind: "seek", position: target}
    restartHideTimer()
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press
        if key = "left" or key = "right" or key = "rewind" or key = "fastforward" then commitSeek()
        return true
    end if
    if m.menuOpen
        if key = "back" or key = "left"
            m.top.action = {kind: "menuClose"}
        else if key = "up" or key = "down"
            delta = 1
            if key = "up" then delta = -1
            index = m.menuIndex + delta
            while index >= 0 and index < m.menuItems.count()
                if VPEnabled(m.menuItems[index])
                    m.menuIndex = index
                    exit while
                end if
                index = index + delta
            end while
            paintMenu()
        else if key = "OK"
            if m.menuIndex >= 0 and m.menuIndex < m.menuItems.count()
                item = m.menuItems[m.menuIndex]
                if VPEnabled(item) then m.top.action = {kind: "menuSelect", id: VPStr(item.id)}
            end if
        else if key = "play"
            m.top.action = {kind: "playPause"}
        end if
        return true
    end if
    if key = "back"
        commitSeek()
        if m.controlsShown
            m.userHidControls = true
            setControlsShown(false)
            m.hideTimer.control = "stop"
        else
            m.top.action = {kind: "back"}
        end if
        return true
    else if key = "play"
        revealControls()
        m.top.action = {kind: "playPause"}
        return true
    else if key = "replay"
        revealControls()
        if focusAvailable("replay") then m.top.action = {kind: "replay"}
        return true
    else if key = "rewind"
        seekBy(-10)
        return true
    else if key = "fastforward"
        seekBy(10)
        return true
    else if key = "options" or key = "info"
        revealControls()
        m.focusArea = "buttons"
        m.focusId = "options"
        paintFocus()
        m.top.action = {kind: "options"}
        return true
    end if
    if not m.controlsShown
        revealControls()
        return true
    end if
    restartHideTimer()
    if key = "up"
        if m.focusArea = "timeline" and m.contextKind <> ""
            m.focusArea = "context"
        else if not VPBool(m.model.isLive) and VPNum(m.model.duration) > 0
            m.focusArea = "timeline"
        end if
        paintFocus()
    else if key = "down"
        commitSeek()
        if m.focusArea = "context" then m.focusArea = "timeline" else m.focusArea = "buttons"
        paintFocus()
    else if key = "left" or key = "right"
        if m.focusArea = "context" and m.contextKind = "next"
            if key = "right" then m.contextFocus = "dismiss" else m.contextFocus = "play"
            paintFocus()
        else if m.focusArea = "timeline"
            delta = 10
            if key = "left" then delta = -10
            seekBy(delta)
        else if m.focusArea = "buttons"
            delta = 1
            if key = "left" then delta = -1
            moveButton(delta)
        end if
    else if key = "OK"
        commitSeek()
        if m.focusArea = "timeline"
            m.top.action = {kind: "playPause"}
        else if m.focusArea = "context" and m.contextKind <> ""
            if m.contextKind = "next" and m.contextFocus = "dismiss"
                m.contextKind = ""
                m.focusArea = "timeline"
                m.top.findNode("contextAction").visible = false
                paintFocus()
                m.top.action = {kind: "dismissUpNext"}
            else
                m.top.action = {kind: m.contextKind}
            end if
        else if m.focusId = "rewind10" or m.focusId = "forward10"
            if focusAvailable(m.focusId)
                delta = 10
                if m.focusId = "rewind10" then delta = -10
                target = VPClamp(VPNum(m.model.position) + delta, 0, VPNum(m.model.duration) - 1)
                m.top.action = {kind: "seek", position: target}
            end if
        else if focusAvailable(m.focusId)
            m.top.action = {kind: m.focusId}
        end if
    end if
    return true
end function

function VPStr(value as Dynamic) as String
    kind = type(value)
    if kind = "String" or kind = "roString" then return value
    if kind = "Integer" or kind = "roInteger" or kind = "roInt" or kind = "LongInteger" or kind = "roLongInteger" or kind = "roLongInt" or kind = "Float" or kind = "roFloat" or kind = "Double" or kind = "roDouble" then return value.toStr()
    return ""
end function

function VPNum(value as Dynamic) as Float
    kind = type(value)
    if kind = "Integer" or kind = "roInteger" or kind = "roInt" or kind = "LongInteger" or kind = "roLongInteger" or kind = "roLongInt" or kind = "Float" or kind = "roFloat" or kind = "Double" or kind = "roDouble" then return value
    return 0
end function

function VPBool(value as Dynamic) as Boolean
    if type(value) = "Boolean" or type(value) = "roBoolean" then return value
    return false
end function

function VPEnabled(item as Object) as Boolean
    if type(item.enabled) = "Boolean" or type(item.enabled) = "roBoolean" then return item.enabled
    return true
end function

function VPClamp(value as Float, minimum as Float, maximum as Float) as Float
    if value < minimum then return minimum
    if value > maximum then return maximum
    return value
end function

function VPTime(seconds as Float) as String
    seconds = int(seconds)
    if seconds < 0 then seconds = 0
    hours = int(seconds / 3600)
    minutes = int((seconds mod 3600) / 60)
    secs = int(seconds mod 60)
    secText = secs.toStr()
    if secs < 10 then secText = "0" + secText
    if hours > 0
        minuteText = minutes.toStr()
        if minutes < 10 then minuteText = "0" + minuteText
        return hours.toStr() + ":" + minuteText + ":" + secText
    end if
    return minutes.toStr() + ":" + secText
end function
