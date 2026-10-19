sub init()
    m.artGroup = m.top.findNode("artGroup")
    m.art = m.top.findNode("art")
    m.well = m.top.findNode("well")
    m.corners = m.top.findNode("corners")
    m.ring = m.top.findNode("focusRing")
    m.title = m.top.findNode("title")
    m.meta = m.top.findNode("meta")
end sub

sub contentChanged()
    if m.boundContent <> invalid then m.boundContent.unobserveField("data")
    m.boundContent = m.top.itemContent
    if m.boundContent <> invalid then m.boundContent.observeField("data", "updateContent")
    updateContent()
end sub

sub updateContent()
    c = m.top.itemContent
    if c = invalid then return
    w = c.cardWidth
    h = c.artHeight
    if w <= 0 then w = 246
    if h <= 0 then h = 348
    ' Focus growth and its rim must remain inside the native list/grid cell.
    ' The View includes this gutter in both item dimensions, even at row edges.
    inset = 16
    m.artGroup.translation = [inset, inset]
    m.well.width = w
    m.well.height = h
    m.art.width = w
    m.art.height = h
    m.art.loadWidth = w
    m.art.loadHeight = h
    m.art.loadDisplayMode = c.artMode
    m.art.uri = c.HDPosterUrl
    m.corners.width = w
    m.corners.height = h
    m.ring.width = w + 12
    m.ring.height = h + 12
    m.artGroup.scaleRotateCenter = [w / 2, h / 2]
    m.title.translation = [inset, inset + h + 14]
    m.title.horizAlign = "left"
    m.title.height = 40
    m.title.maxLines = 1
    m.title.wrap = false
    m.meta.horizAlign = "left"
    m.corners.uri = "pkg:/images/card-corners.9.png"
    m.ring.uri = "pkg:/images/focus-ring.9.png"
    m.title.width = w
    m.title.text = c.title
    m.meta.translation = [inset, inset + h + 56]
    m.meta.width = w
    m.meta.text = c.caption
    if c.mediaStyle = "person"
        m.corners.uri = "pkg:/images/person-corners.png"
        m.ring.uri = "pkg:/images/person-focus.png"
        m.title.horizAlign = "center"
        m.title.height = 68
        m.title.maxLines = 2
        m.title.wrap = true
        m.title.font.size = 25
        m.meta.horizAlign = "center"
        m.meta.translation = [inset, inset + h + 86]
        m.meta.font.size = 21
    else
        m.title.font.size = 28
        m.meta.font.size = 23
    end if
    special = c.actionKind = "categoryActions" or c.actionKind = "selectSeason"
    m.art.visible = not special
    m.well.blendColor = "0xFFFFFFFF"
    if c.hasField("selected")
        if c.selected then m.well.blendColor = "0xA99AEAFF"
    end if
    m.top.findNode("actionIcon").visible = special and c.actionIcon <> ""
    m.top.findNode("actionLabel").visible = special
    m.top.findNode("actionHint").visible = special
    if special
        m.top.findNode("actionIcon").translation = [(w - 54) / 2, h / 2 - 72]
        m.top.findNode("actionLabel").translation = [0, h / 2 - 2]
        m.top.findNode("actionLabel").width = w
        m.top.findNode("actionLabel").text = c.actionLabel
        m.top.findNode("actionHint").translation = [0, h / 2 + 42]
        m.top.findNode("actionHint").width = w
        m.top.findNode("actionHint").text = c.actionHint
        if c.actionKind = "selectSeason"
            m.top.findNode("actionLabel").translation = [0, (h - 42) / 2]
            m.top.findNode("actionLabel").height = 42
            m.top.findNode("actionHint").visible = false
        else
            m.top.findNode("actionLabel").height = 60
        end if
    end if
    p = c.progress
    if p < 0 then p = 0
    if p > 1 then p = 1
    m.top.findNode("progressTrack").visible = p > 0
    m.top.findNode("progress").visible = p > 0
    m.top.findNode("progressTrack").translation = [0, h - 6]
    m.top.findNode("progress").translation = [0, h - 6]
    m.top.findNode("progressTrack").width = w
    m.top.findNode("progress").width = w * p
    focusChanged()
end sub

sub focusChanged()
    f = m.top.focusPercent
    active = m.top.rowListHasFocus or m.top.gridHasFocus
    if not active then f = 0
    if m.top.rowListHasFocus then f = f * m.top.rowFocusPercent
    m.ring.opacity = f
    s = 1 + 0.025 * f
    m.artGroup.scale = [s, s]
    if f > 0.5
        m.title.color = "0xF2F4F8FF"
    else
        m.title.color = "0xCCD1DCFF"
    end if
end sub
