sub init()
    m.ring = m.top.findNode("ring")
end sub

sub contentChanged()
    c = m.top.itemContent
    if c = invalid then return
    m.top.findNode("name").text = c.title
    m.top.findNode("initial").text = ucase(left(c.title, 1))
    isAdd = c.data.actionKind = "createProfile"
    m.top.findNode("initial").visible = not isAdd
    m.top.findNode("addIcon").visible = isAdd
    m.top.findNode("fill").uri = "pkg:/images/profile-tile.png"
    if c.data.color <> invalid or isAdd then m.top.findNode("fill").uri = "pkg:/images/profile-glass.png"
    if c.color <> "" then m.top.findNode("fill").blendColor = c.color
    if isAdd then m.top.findNode("fill").blendColor = "0x34394AFF"
end sub

sub focusChanged()
    f = m.top.focusPercent
    if not m.top.gridHasFocus then f = 0
    m.ring.opacity = f
end sub
