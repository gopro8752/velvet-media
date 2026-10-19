sub init()
    m.fill = m.top.findNode("fill")
    m.rim = m.top.findNode("rim")
    m.label = m.top.findNode("label")
    m.subtitle = m.top.findNode("subtitle")
    m.icon = m.top.findNode("icon")
    updateStyle()
end sub

sub updateStyle()
    if m.fill = invalid then return
    w = m.top.width
    h = m.top.height
    m.fill.width = w
    m.fill.height = h
    m.rim.width = w + 6
    m.rim.height = h + 6
    m.rim.opacity = 0
    if m.top.focused then m.rim.opacity = 1
    bright = (m.top.primary or m.top.focused) and m.top.enabled
    m.top.opacity = 1
    if not m.top.enabled then m.top.opacity = 0.45
    m.fill.blendColor = "0xFFFFFFFF"
    if bright
        m.fill.uri = "pkg:/images/button-white.9.png"
        m.label.color = "0x11141CFF"
        m.subtitle.color = "0x545D70FF"
        m.icon.blendColor = "0x11141CFF"
    else
        m.fill.uri = "pkg:/images/button.9.png"
        m.label.color = "0xF2F4F8FF"
        m.subtitle.color = "0x9BA3B4FF"
        m.icon.blendColor = "0xF2F4F8FF"
    end if
    if m.top.accent and not m.top.focused
        m.fill.uri = "pkg:/images/profile-tile.png"
    end if
    x = 26
    m.icon.visible = m.top.icon <> ""
    m.icon.uri = m.top.icon
    if m.icon.visible then x = 68
    m.icon.translation = [27, (h - 30) / 2]
    m.label.width = w - x - 20
    m.label.horizAlign = "left"
    m.label.text = m.top.label
    m.subtitle.width = w - x - 24
    m.subtitle.text = m.top.subtitle
    m.subtitle.visible = m.top.subtitle <> ""
    if m.subtitle.visible
        m.label.translation = [x, 15]
        m.subtitle.translation = [x, 55]
    else
        m.label.translation = [x, (h - 42) / 2]
    end if
    if m.top.label = "" and m.icon.visible then m.icon.translation = [(w - 30) / 2, (h - 30) / 2]
    if m.top.centered
        m.label.width = w
        m.label.translation = [0, (h - 42) / 2]
        m.label.horizAlign = "center"
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if key = "OK"
        if press and m.top.enabled then m.top.selected = true
        return true
    end if
    return false
end function
