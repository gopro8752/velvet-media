' Pure presentation boundary. The scene owns requests, dialogs and playback;
' this view only turns a model into native nodes and emits user intent.
sub init()
    names = ["cinema", "leftScrim", "backdrop", "nextBackdrop", "artReveal", "artDelay", "viewportMove", "header", "wordmark", "headerHint", "hero", "heroLogo", "heroTitle", "heroTagline", "heroMeta", "heroOverview", "overviewFocus", "heroActions", "playButton", "secondaryButton", "listButton", "descriptionHint", "heading", "pageTitle", "pageSubtitle", "searchButton", "listClip", "rows", "grid", "profiles", "menu", "menuItems", "menuMove", "empty", "status", "reading", "readingTitle", "readingText", "dock", "createButton", "profileButton", "choicePanel", "choiceSurface", "choiceTitle", "choiceItems"]
    for each name in names
        m[name] = m.top.findNode(name)
    end for
    m.model = {}
    m.page = ""
    m.pageIdentity = ""
    m.signature = ""
    m.contentFocus = invalid
    m.menuButtons = []
    m.menuActions = []
    m.menuIndex = 0
    m.menuScroll = 0
    m.savedPages = {}
    m.pendingFocus = ""
    m.lastRowItem = [0, 0]
    m.lastGridItem = 0
    m.heroItem = invalid
    m.overviewFocused = false
    m.overviewExpanded = false
    m.baseRowsY = 552
    m.baseHeroY = 80
    m.choiceButtons = []
    m.choiceIndex = 0
    m.choiceSignature = ""
    m.rows.observeField("rowItemSelected", "rowSelected")
    m.rows.observeField("rowItemFocused", "rowFocused")
    m.grid.observeField("itemSelected", "gridSelected")
    m.grid.observeField("itemFocused", "gridFocused")
    m.profiles.observeField("itemSelected", "profileSelected")
    m.dock.observeField("action", "dockAction")
    m.playButton.observeField("selected", "playSelected")
    m.secondaryButton.observeField("selected", "secondarySelected")
    m.listButton.observeField("selected", "listSelected")
    m.searchButton.observeField("selected", "searchSelected")
    m.createButton.observeField("selected", "createSelected")
    m.profileButton.observeField("selected", "profileRequested")
    m.heroLogo.observeField("loadStatus", "logoLoaded")
    m.nextBackdrop.observeField("loadStatus", "artLoaded")
    m.artReveal.observeField("state", "artAnimationChanged")
    m.artDelay.observeField("fire", "loadPendingArtwork")
end sub

function textValue(value as Dynamic, fallback = "" as String) as String
    if value = invalid then return fallback
    kind = type(value)
    if kind = "String" or kind = "roString" then return value
    if kind = "Integer" or kind = "roInt" or kind = "roInteger" or kind = "Float" or kind = "roFloat" or kind = "Double" or kind = "roDouble" or kind = "LongInteger" or kind = "roLongInteger" or kind = "roLongInt" then return value.toStr()
    return fallback
end function

function arrayValue(value as Dynamic) as Object
    if type(value) = "roArray" then return value
    return []
end function

function firstText(data as Dynamic, fields as Object, fallback = "" as String) as String
    if type(data) <> "roAssociativeArray" then return fallback
    for each key in fields
        value = textValue(data[key])
        if value <> "" then return value
    end for
    return fallback
end function

function numericValue(value as Dynamic, fallback = 0 as Float) as Float
    if value = invalid then return fallback
    return val(textValue(value))
end function

sub emit(action as Object)
    m.top.action = action
end sub

sub modelChanged()
    model = m.top.model
    if model = invalid then return
    ownedFocus = m.top.isInFocusChain()
    newPage = textValue(model.page, "setup")
    identity = newPage + ":" + firstText(model.profile, ["id", "profileId"])
    if newPage = "details" and type(model.details) = "roAssociativeArray"
        identity = identity + ":" + firstText(model.details.item, ["type"]) + ":" + firstText(model.details.item, ["mediaId"])
    end if
    changedPage = identity <> m.pageIdentity
    if changedPage and m.pageIdentity <> ""
        focusId = ""
        if m.contentFocus <> invalid then focusId = m.contentFocus.id
        m.savedPages[m.pageIdentity] = {row: m.lastRowItem, grid: m.lastGridItem, focusId: focusId, menuIndex: m.menuIndex}
    end if
    m.model = model
    m.page = newPage
    m.top.FindNode("pageContent").visible = newPage <> "live" and newPage <> "sports"
    m.pageIdentity = identity
    m.status.text = textValue(model.message)
    if m.status.text = "" and model.busy = true then m.status.text = "Loading…"
    m.profileButton.label = ucase(left(firstText(model.profile, ["name", "displayName"], "Profile"), 1))
    m.dock.activeRoute = newPage
    if changedPage
        m.dock.opened = false
        m.reading.visible = false
        m.signature = ""
        m.contentFocus = invalid
        m.heroItem = invalid
        m.lastRowItem = [0, 0]
        m.lastGridItem = 0
        m.pendingFocus = ""
        prior = m.savedPages[identity]
        if prior <> invalid
            m.lastRowItem = prior.row
            m.lastGridItem = prior.grid
            m.pendingFocus = textValue(prior.focusId)
            m.menuIndex = prior.menuIndex
        end if
        showPage(newPage)
    end if
    if newPage = "home" or newPage = "categories"
        renderRows(arrayValue(model.rows), changedPage)
        if newPage = "home"
            updateHeroFromSelection()
            if m.heroItem = invalid then m.hero.visible = false
        end if
    else if newPage = "details"
        renderDetails(changedPage)
    else if newPage = "profiles"
        renderProfiles(changedPage)
    else if newPage = "search" or newPage = "live"
        renderGrid(changedPage)
    else if newPage = "settings" or newPage = "setup"
        renderSettings(changedPage)
    end if
    renderChoice()
    if newPage <> "live" and newPage <> "sports" and canRestoreViewFocus() and not m.dock.opened and not m.reading.visible and not m.choicePanel.visible
        if changedPage
            focusInitial()
        else if ownedFocus and not contentTargetVisible(m.contentFocus)
            ' A data update can hide or detach the previously focused control.
            ' Repair that target without taking focus from a dialog or player.
            focusInitial()
        end if
    end if
end sub

sub showPage(page as String)
    for each key in ["hero", "heading", "listClip", "grid", "profiles", "menu", "searchButton", "empty"]
        m[key].visible = false
    end for
    m.cinema.visible = page = "home" or page = "details"
    m.leftScrim.uri = "pkg:/images/scrim-left.png"
    if page = "details" then m.leftScrim.uri = "pkg:/images/scrim-left-details.png"
    m.hero.visible = m.cinema.visible
    m.createButton.visible = page = "home" or page = "categories"
    m.profileButton.visible = page <> "setup" and page <> "profiles"
    m.header.visible = page <> "details"
    m.headerHint.opacity = 0
    m.wordmark.translation = [1390, 8]
    if page = "setup" or page = "profiles" then m.wordmark.translation = [96, 8]
    m.overviewExpanded = false
    m.hero.opacity = 1
    m.cinema.opacity = 1
    m.viewportMove.control = "stop"
    m.listButton.visible = page = "home"
    m.descriptionHint.visible = false
    m.overviewFocused = false
    m.overviewFocus.opacity = 0
    m.heroOverview.maxLines = 2
    m.heroOverview.height = 84
    m.heroOverview.translation = [0, 250]
    m.heroMeta.translation = [0, 196]
    m.heroTagline.visible = false
    m.overviewY = 250
    m.heroActions.translation = [0, 350]
    m.heroLogo.height = 176
    m.heroLogo.width = 700
    m.heroLogo.translation = [0, 0]
    m.heroTitle.height = 176
    m.heroTitle.font.size = 68
    m.baseHeroY = 80
    m.hero.translation = [96, m.baseHeroY]
    m.baseRowsY = 552
    m.listClip.translation = [72, m.baseRowsY]
    m.listClip.clippingRect = [0, -24, 1848, 1104 - m.baseRowsY]
    m.rows.numRows = 3
    m.playButton.enabled = true
    m.playButton.icon = "pkg:/images/play.png"
    m.searchButton.translation = [96, 285]
    m.searchButton.width = 1728
    m.searchButton.icon = "pkg:/images/search.png"
    m.secondaryButton.label = "Details"
    m.secondaryButton.icon = "pkg:/images/info.png"
    m.heading.translation = [96, 156]
    m.status.translation = [96, 117]
    if page = "profiles"
        m.heading.visible = true
        m.heading.translation = [96, 210]
        m.pageTitle.text = "Who's watching?"
        m.pageSubtitle.text = "Your favorites. Your next episode. Your Velvet."
        m.profiles.visible = true
    else if page = "search"
        m.heading.visible = true
        m.pageTitle.text = "Search"
        m.pageSubtitle.text = ""
        m.searchButton.visible = true
        m.grid.visible = true
    else if page = "live"
        m.heading.visible = true
        m.pageTitle.text = "Live TV"
        m.pageSubtitle.text = "On now, from your connected TV service."
        m.grid.visible = true
    else if page = "categories"
        m.heading.visible = true
        m.pageTitle.text = "Your categories"
        m.pageSubtitle.text = "Collections of movies, shows and specific episodes."
        m.baseRowsY = 396
        m.listClip.translation = [72, m.baseRowsY]
        m.listClip.clippingRect = [0, -24, 1848, 1104 - m.baseRowsY]
    else if page = "settings" or page = "setup"
        m.heading.visible = true
        m.menu.visible = true
        if page = "setup"
            m.pageTitle.text = "Make yourself at home."
            m.pageSubtitle.text = "Connect this Roku to your Velvet library."
        else
            m.pageTitle.text = "Settings"
            m.pageSubtitle.text = "Your connection, your profile, your Velvet."
        end if
    else if page = "details"
        m.heroTitle.font.size = 64
        m.heroOverview.translation = [0, 250]
        m.heroOverview.height = 0
        m.heroOverview.maxLines = 5
        m.overviewFocus.translation = [-16, 238]
        m.heroActions.translation = [0, 450]
        m.secondaryButton.label = "My List"
        m.secondaryButton.icon = "pkg:/images/plus.png"
    end if
end sub

function mediaCaption(item as Object) as String
    parts = []
    if item.season <> invalid and item.episode <> invalid
        parts.push("S" + textValue(item.season) + " E" + textValue(item.episode))
        epTitle = textValue(item.episodeTitle)
        if epTitle <> "" then parts.push(epTitle)
    else
        year = textValue(item.year)
        if year <> "" and year <> "0" then parts.push(year)
        rating = numericValue(item.rating)
        if rating > 0
            tenths = int(rating * 10 + 0.5)
            parts.push("★ " + textValue(tenths \ 10) + "." + textValue(tenths mod 10))
        end if
    end if
    return parts.join(" · ")
end function

function contentItem(item as Object, width as Integer, artHeight as Integer, style as String) as Object
    node = createObject("roSGNode", "ContentNode")
    title = firstText(item, ["displayTitle", "title", "name", "episodeTitle"], "Untitled")
    node.title = title
    node.HDPosterUrl = mediaArtwork(item, style)
    fraction = 0.0
    duration = numericValue(item.durationMs)
    if duration > 0 then fraction = numericValue(item.positionMs) / duration
    caption = mediaCaption(item)
    if style = "channel" then caption = firstText(item, ["nowTitle", "programTitle", "description"], "Live")
    if style = "person" then caption = firstText(item, ["character", "role"])
    if style = "landscape" and duration > 0
        remaining = int((duration - numericValue(item.positionMs)) / 60000)
        if remaining < 1 then remaining = 1
        caption = textValue(remaining) + "m left"
        if item.season <> invalid and item.episode <> invalid then caption = "S" + textValue(item.season) + " E" + textValue(item.episode) + " · " + caption
    end if
    mode = "scaleToZoom"
    if style = "channel" then mode = "scaleToFit"
    node.addFields({data: item, cardWidth: width, artHeight: artHeight, caption: caption, progress: fraction, actionKind: "", categoryId: "", artMode: mode, mediaStyle: style, actionLabel: "", actionHint: "", actionIcon: ""})
    return node
end function

function mediaArtwork(item as Object, style as String) as String
    if style = "landscape"
        if item.episode <> invalid then return firstText(item, ["stillUrl", "backdropUrl", "posterUrl", "logoUrl"])
        return firstText(item, ["backdropUrl", "stillUrl", "posterUrl", "logoUrl"])
    else if style = "channel"
        return firstText(item, ["logoUrl", "imageUrl", "posterUrl"])
    end if
    return firstText(item, ["posterUrl", "backdropUrl", "logoUrl", "imageUrl", "profileUrl", "photoUrl"])
end function

' Refresh payload and progress without replacing the list, scrolling it or
' losing the native horizontal position of rows that are not focused.
sub refreshCard(node as Object, item as Object)
    if node.actionKind = "selectSeason"
        node.selected = numericValue(item.season) = numericValue(m.model.selectedSeason, 1)
        node.data = item
        return
    end if
    node.title = firstText(item, ["displayTitle", "title", "name", "episodeTitle"], "Untitled")
    node.HDPosterUrl = mediaArtwork(item, node.mediaStyle)
    node.caption = mediaCaption(item)
    if node.mediaStyle = "channel" then node.caption = firstText(item, ["nowTitle", "programTitle", "description"], "Live")
    if node.mediaStyle = "person" then node.caption = firstText(item, ["character", "role"])
    fraction = 0.0
    duration = numericValue(item.durationMs)
    if duration > 0 then fraction = numericValue(item.positionMs) / duration
    node.progress = fraction
    if node.mediaStyle = "landscape" and duration > 0
        remaining = int((duration - numericValue(item.positionMs)) / 60000)
        if remaining < 1 then remaining = 1
        node.caption = textValue(remaining) + "m left"
        if item.season <> invalid and item.episode <> invalid then node.caption = "S" + textValue(item.season) + " E" + textValue(item.episode) + " · " + node.caption
    end if
    node.data = item
end sub

sub refreshRows(rows as Object)
    content = m.rows.content
    if content = invalid then return
    rowIndex = 0
    m.rowModels = []
    for each row in rows
        items = arrayValue(row.items)
        category = row.category = true
        if items.count() > 0 or category
            target = content.getChild(rowIndex)
            if target <> invalid
                target.title = textValue(row.title)
                index = 0
                if category then index = 1
                for each item in items
                    child = target.getChild(index)
                    if child <> invalid then refreshCard(child, item)
                    index = index + 1
                end for
            end if
            m.rowModels.push(row)
            rowIndex = rowIndex + 1
        end if
    end for
end sub

function rowsSignature(rows as Object) as String
    parts = []
    for each row in rows
        parts.push(firstText(row, ["id", "title"]) + ":" + textValue(row.style))
        for each item in arrayValue(row.items)
            parts.push(textValue(item.type) + ":" + firstText(item, ["mediaId", "id", "title", "name"]) + ":" + textValue(item.season) + ":" + textValue(item.episode) + ":" + textValue(item.actionKind))
        end for
    end for
    return parts.join("|")
end function

sub renderRows(rows as Object, changedPage as Boolean)
    signature = m.page + rowsSignature(rows)
    if signature = m.signature
        refreshRows(rows)
        return
    end if
    m.signature = signature
    root = createObject("roSGNode", "ContentNode")
    sizes = []
    heights = []
    m.rowModels = []
    for each row in rows
        items = arrayValue(row.items)
        category = row.category = true
        if items.count() > 0 or category
            content = root.createChild("ContentNode")
            content.title = textValue(row.title)
            width = 240
            artHeight = 360
            style = textValue(row.style, "poster")
            if style = "landscape" or style = "episode"
                width = 456
                artHeight = 256
                style = "landscape"
            else if style = "season"
                width = 230
                artHeight = 76
            else if style = "person"
                width = 180
                artHeight = 180
            end if
            if m.page = "details" and style = "landscape"
                width = 384
                artHeight = 216
            end if
            if category
                control = contentItem({title: "Collection options"}, width, artHeight, style)
                control.actionKind = "categoryActions"
                control.categoryId = textValue(row.id)
                control.actionLabel = "Play collection"
                control.actionHint = "Play all · Shuffle · More"
                control.actionIcon = "play"
                content.appendChild(control)
            end if
            for each item in items
                child = contentItem(item, width, artHeight, style)
                if style = "season"
                    child.actionKind = "selectSeason"
                    child.actionLabel = textValue(item.title)
                    child.actionHint = ""
                    child.addFields({selected: numericValue(item.season) = numericValue(m.model.selectedSeason, 1)})
                    child.title = ""
                    child.caption = ""
                else if style = "person"
                    child.actionKind = "cast"
                end if
                content.appendChild(child)
            end for
            captionHeight = 102
            if style = "season" then captionHeight = 0
            if style = "person" then captionHeight = 126
            sizes.push([width + 32, artHeight + captionHeight + 32])
            heights.push(artHeight + captionHeight + 80)
            m.rowModels.push(row)
        end if
    end for
    if sizes.count() = 0 then sizes.push([260, 464])
    m.rows.rowItemSize = sizes
    m.rows.rowHeights = heights
    savedPosition = m.lastRowItem
    m.rows.content = root
    m.lastRowItem = savedPosition
    m.listClip.visible = root.getChildCount() > 0
    m.empty.visible = not m.listClip.visible
    if m.page = "categories"
        m.empty.text = "Start with + to create a collection for whatever you're in the mood for."
    else
        m.empty.text = "Your library will appear here."
    end if
    restoreRowPosition()
end sub

sub restoreRowPosition()
    content = m.rows.content
    if content = invalid or content.getChildCount() = 0 then return
    row = m.lastRowItem[0]
    col = m.lastRowItem[1]
    if row >= content.getChildCount() then row = content.getChildCount() - 1
    count = content.getChild(row).getChildCount()
    if col >= count then col = count - 1
    if col < 0 then col = 0
    m.lastRowItem = [row, col]
    m.rows.jumpToRowItem = m.lastRowItem
end sub

sub renderDetails(changedPage as Boolean)
    detail = m.model.details
    if type(detail) <> "roAssociativeArray" or type(detail.item) <> "roAssociativeArray"
        m.hero.visible = false
        m.empty.visible = true
        m.empty.text = "Loading this title…"
        return
    end if
    m.heroItem = detail.item
    paintHero()
    m.playButton.enabled = detail.digitallyAvailable <> false
    if not m.playButton.enabled
        m.playButton.label = "Coming soon"
        m.playButton.icon = ""
        if m.playButton.hasFocus() then focusNode(m.secondaryButton)
    else
        m.playButton.icon = "pkg:/images/play.png"
    end if
    m.secondaryButton.label = "My List"
    m.secondaryButton.icon = "pkg:/images/plus.png"
    if m.model.inMyList = true
        m.secondaryButton.label = "In My List"
        m.secondaryButton.icon = "pkg:/images/check.png"
    end if
    rows = []
    seasons = []
    for each season in arrayValue(detail.seasons)
        if type(season) = "roAssociativeArray"
            number = numericValue(season.number, -1)
            if number < 0 then number = numericValue(season.season, -1)
            if number < 0 then number = numericValue(season.seasonNumber, -1)
            name = firstText(season, ["name", "title"], "Season " + textValue(number))
        else
            number = numericValue(season)
            name = "Season " + textValue(number)
        end if
        if number = 0 then name = "Specials"
        seasons.push({title: name, season: number})
    end for
    if seasons.count() > 0 then rows.push({id: "seasons", title: "Seasons", style: "season", items: seasons})
    episodes = []
    for each ep in arrayValue(m.model.episodes)
        item = {}
        item.append(detail.item)
        item.append(ep)
        item.mediaId = detail.item.mediaId
        item.type = "show"
        item.season = numericValue(ep.season, numericValue(m.model.selectedSeason, 1))
        item.episode = numericValue(ep.episode, numericValue(ep.number, 1))
        item.episodeTitle = firstText(ep, ["episodeTitle", "title", "name"])
        item.title = textValue(detail.item.title)
        item.displayTitle = item.episodeTitle
        item.backdropUrl = firstText(ep, ["stillUrl", "backdropUrl", "imageUrl"], textValue(detail.item.backdropUrl))
        episodes.push(item)
    end for
    if episodes.count() > 0 then rows.push({id: "episodes", title: "Episodes", style: "landscape", items: episodes})
    if arrayValue(detail.cast).count() > 0 then rows.push({id: "cast", title: "Cast", style: "person", items: detail.cast})
    if arrayValue(detail.similar).count() > 0 then rows.push({id: "similar", title: "More like this", style: "poster", items: detail.similar})
    renderRows(rows, changedPage)
    m.empty.visible = false
end sub

sub renderGrid(changedPage as Boolean)
    items = arrayValue(m.model.items)
    if m.page = "search"
        query = textValue(m.model.query)
        m.searchButton.label = query
        if query = "" then m.searchButton.label = "Search movies and shows"
        m.grid.translation = [80, 410]
        m.grid.numColumns = 6
        m.grid.numRows = 1
        m.grid.itemSize = [290, 521]
        m.grid.itemSpacing = [4, 10]
    else
        m.grid.translation = [80, 350]
        m.grid.numColumns = 4
        m.grid.numRows = 2
        m.grid.itemSize = [428, 314]
        m.grid.itemSpacing = [10, 19]
    end if
    signature = m.page + rowsSignature([{items: items}])
    if signature = m.signature
        content = m.grid.content
        if content <> invalid
            for i = 0 to items.count() - 1
                child = content.getChild(i)
                if child <> invalid then refreshCard(child, items[i])
            end for
        end if
        return
    end if
    m.signature = signature
    content = createObject("roSGNode", "ContentNode")
    for each item in items
        if m.page = "live"
            node = contentItem(item, 396, 180, "channel")
        else
            node = contentItem(item, 258, 387, "poster")
        end if
        content.appendChild(node)
    end for
    savedIndex = m.lastGridItem
    m.grid.content = content
    m.lastGridItem = savedIndex
    m.grid.visible = items.count() > 0
    if m.lastGridItem >= items.count() then m.lastGridItem = 0
    if items.count() > 0 then m.grid.jumpToItem = m.lastGridItem
    m.empty.visible = items.count() = 0
    if m.page = "search"
        m.empty.text = "Search for a movie or show to get started."
        if textValue(m.model.query) <> "" then m.empty.text = "No matches yet. Try another title."
    else
        m.empty.text = "Your connected live channels will appear here."
    end if
end sub

sub renderProfiles(changedPage as Boolean)
    profiles = arrayValue(m.model.profiles)
    signature = "profiles" + rowsSignature([{items: profiles}])
    for each profile in profiles
        signature = signature + ":" + textValue(profile.name) + ":" + textValue(profile.color)
    end for
    if signature = m.signature then return
    m.signature = signature
    content = createObject("roSGNode", "ContentNode")
    colors = ["0xFFFFFFFF", "0x9DD8FFFF", "0xFFC8D6FF", "0xB6EBD7FF"]
    i = 0
    for each profile in profiles
        node = content.createChild("ContentNode")
        node.title = firstText(profile, ["name", "displayName"], "Profile")
        node.addFields({data: profile, color: profileColor(profile, colors[i mod colors.count()])})
        i = i + 1
    end for
    add = content.createChild("ContentNode")
    add.title = "Add profile"
    add.addFields({data: {actionKind: "createProfile"}, color: "0xFFFFFFFF"})
    columns = content.getChildCount()
    if columns > 5 then columns = 5
    if columns < 1 then columns = 1
    m.profiles.numColumns = columns
    m.profiles.translation = [(1920 - (columns * 254 + (columns - 1) * 22)) / 2, 422]
    m.profiles.content = content
    m.profiles.visible = true
    m.empty.visible = false
    m.searchButton.visible = false
    m.pageSubtitle.text = "Choose a profile · Press * to edit"
end sub

function profileColor(profile as Object, fallback as String) as String
    value = textValue(profile.color)
    if left(value, 1) = "#" and len(value) = 7 then return "0x" + mid(value, 2) + "FF"
    return fallback
end function

sub renderSettings(changedPage as Boolean)
    settings = m.model.settings
    if type(settings) <> "roAssociativeArray" then settings = {}
    tokenText = "Not configured"
    if settings.tokenConfigured = true then tokenText = "Configured"
    backend = textValue(settings.backendUrl, "Choose your Velvet server")
    entries = [
        {label: "Velvet server", subtitle: backend, kind: "editBackend"}
        {label: "Access key", subtitle: tokenText, kind: "editToken"}
        {label: "Connect", subtitle: "Open your library on this Roku", kind: "connect"}
    ]
    if m.page = "settings"
        entries[2] = {label: "Reconnect", subtitle: "Refresh your connection and library", kind: "connect"}
        entries.push({label: "Switch profile", subtitle: firstText(m.model.profile, ["name", "displayName"], "Choose who's watching"), kind: "navigate", route: "profiles"})
        for each entry in arrayValue(m.model.settingsRows)
            entries.push(entry)
        end for
    end if
    if m.menuButtons.count() <> entries.count()
        m.menuItems.removeChildrenIndex(m.menuItems.getChildCount(), 0)
        m.menuButtons = []
        for i = 0 to entries.count() - 1
            button = m.menuItems.createChild("VelvetButton")
            button.width = 1056
            button.height = 108
            button.translation = [0, i * 132]
            button.observeField("selected", "menuSelected")
            m.menuButtons.push(button)
        end for
    end if
    m.menuActions = entries
    for i = 0 to entries.count() - 1
        m.menuButtons[i].label = entries[i].label
        m.menuButtons[i].subtitle = entries[i].subtitle
    end for
    if m.menuIndex >= entries.count() then m.menuIndex = 0
    layoutSettingsMenu()
end sub

sub layoutSettingsMenu()
    targetY = m.menuIndex * 132
    if targetY < m.menuScroll then m.menuScroll = targetY
    if targetY + 108 > m.menuScroll + 637 then m.menuScroll = targetY + 108 - 637
    if m.menuScroll < 0 then m.menuScroll = 0
    m.menuMove.control = "stop"
    m.top.findNode("menuSlide").keyValue = [m.menuItems.translation, [0, -m.menuScroll]]
    m.menuMove.control = "start"
end sub

sub updateHeroFromSelection()
    content = m.rows.content
    if content = invalid then return
    featuredRow = -1
    for i = 0 to m.rowModels.count() - 1
        row = m.rowModels[i]
        id = textValue(row.id)
        if id <> "continue" and id <> "mylist" and row.category <> true
            featuredRow = i
            exit for
        end if
    end for
    if featuredRow >= 0
        row = content.getChild(featuredRow)
        index = 0
        if m.lastRowItem[0] = featuredRow then index = m.lastRowItem[1]
        if index >= row.getChildCount() then index = 0
        if row.getChildCount() > 0 then m.heroItem = enrichedHeroItem(row.getChild(index).data)
    else if m.heroItem = invalid
        for each row in content.getChildren(-1, 0)
            for each item in row.getChildren(-1, 0)
                if item.actionKind = ""
                    m.heroItem = enrichedHeroItem(item.data)
                    exit for
                end if
            end for
            if m.heroItem <> invalid then exit for
        end for
    end if
    paintHero()
end sub

sub paintHero()
    item = m.heroItem
    if item = invalid then return
    m.hero.visible = true
    m.heroTitle.text = textValue(item.title)
    logo = textValue(item.logoUrl)
    if m.heroLogo.uri <> logo
        m.heroLogo.uri = logo
        m.heroLogo.visible = false
        m.heroTitle.visible = true
    end if
    if logo = ""
        m.heroLogo.visible = false
        m.heroTitle.visible = true
    end if
    image = firstText(item, ["backdropUrl", "posterUrl"])
    queueArtwork(image)
    meta = heroCaption(item)
    runtime = numericValue(item.runtimeMinutes)
    if runtime > 0
        if meta <> "" then meta = meta + " · "
        meta = meta + runtimeCaption(runtime)
    end if
    genres = arrayValue(item.genres)
    if genres.count() > 0
        genre = textValue(genres[0])
        if genre <> ""
            if meta <> "" then meta = meta + " · "
            meta = meta + genre
        end if
    end if
    if m.page = "details"
        certification = textValue(m.model.details.certification)
        if certification <> "" then meta = certification + " · " + meta
        tagline = textValue(m.model.details.tagline)
        m.heroTagline.text = tagline
        m.heroTagline.visible = tagline <> ""
        m.overviewY = 250
        m.heroMeta.translation = [0, 196]
        if tagline <> ""
            m.heroMeta.translation = [0, 246]
            m.overviewY = 300
        end if
        m.heroOverview.translation = [0, m.overviewY]
        m.overviewFocus.translation = [-16, m.overviewY - 12]
    end if
    m.heroMeta.text = meta
    logoLoaded()
    m.heroOverview.text = textValue(item.overview)
    if m.page = "details" then layoutDetailsOverview()
    if m.page = "home"
        inList = heroIsInMyList(item)
        m.listButton.label = "My List"
        m.listButton.icon = "pkg:/images/plus.png"
        if inList
            m.listButton.label = "In My List"
            m.listButton.icon = "pkg:/images/check.png"
        end if
    end if
    m.playButton.label = "Play"
    if numericValue(item.positionMs) > 0 then m.playButton.label = "Resume"
end sub

sub layoutDetailsOverview()
    bounds = m.heroOverview.boundingRect()
    textHeight = bounds.height
    actionsY = m.overviewY + textHeight + 42
    m.overviewFocus.height = textHeight + 24
    m.overviewFocus.width = 1072
    m.heroActions.translation = [0, actionsY]
    m.descriptionHint.translation = [0, actionsY - 28]
    m.baseRowsY = m.baseHeroY + actionsY + 80 + 62
    if not m.rows.hasFocus() and m.hero.opacity > 0.5
        m.listClip.translation = [72, m.baseRowsY]
        m.listClip.clippingRect = [0, -24, 1848, maxNumber(0, 1104 - m.baseRowsY)]
    end if
end sub

function maxNumber(a as Float, b as Float) as Float
    if a > b then return a
    return b
end function

sub logoLoaded()
    ready = m.heroLogo.loadStatus = "ready" and m.heroLogo.uri <> ""
    m.heroLogo.visible = ready
    m.heroTitle.visible = not ready
    if ready
        w = m.heroLogo.bitmapWidth
        h = m.heroLogo.bitmapHeight
        if w > 0 and h > 0
            scale = 176 / h
            if w * scale > 700 then scale = 700 / w
            m.heroLogo.width = w * scale
            m.heroLogo.height = h * scale
            m.heroLogo.translation = [0, 176 - h * scale]
        end if
    end if
end sub

function runtimeCaption(minutes as Float) as String
    hours = int(minutes / 60)
    mins = int(minutes) mod 60
    if hours < 1 then return textValue(mins) + "m"
    result = textValue(hours) + "h"
    if mins > 0 then result = result + " " + textValue(mins) + "m"
    return result
end function

function heroCaption(item as Object) as String
    parts = []
    rating = numericValue(item.rating)
    if rating > 0
        tenths = int(rating * 10 + 0.5)
        parts.push("★ " + textValue(tenths \ 10) + "." + textValue(tenths mod 10))
    end if
    year = textValue(item.year)
    if year <> "" and year <> "0" then parts.push(year)
    if item.season <> invalid and item.episode <> invalid then parts.push("S" + textValue(item.season) + " E" + textValue(item.episode))
    return parts.join(" · ")
end function

function enrichedHeroItem(item as Object) as Object
    result = {}
    for each row in arrayValue(m.model.rows)
        for each candidate in arrayValue(row.items)
            if textValue(candidate.mediaId) = textValue(item.mediaId) and textValue(candidate.type) = textValue(item.type)
                if textValue(candidate.overview) <> "" then result.append(candidate)
            end if
        end for
    end for
    for each key in item
        if item[key] <> invalid and textValue(item[key], "nonstring") <> "" then result[key] = item[key]
    end for
    return result
end function

function heroIsInMyList(item as Object) as Boolean
    for each row in arrayValue(m.model.rows)
        if textValue(row.id) = "mylist"
            for each entry in arrayValue(row.items)
                if textValue(entry.mediaId) = textValue(item.mediaId) and textValue(entry.type) = textValue(item.type) then return true
            end for
        end if
    end for
    return false
end function

sub queueArtwork(uri as String)
    if uri = "" then return
    m.pendingArtwork = uri
    if m.backdrop.uri = uri
        m.artDelay.control = "stop"
        return
    end if
    if m.nextBackdrop.uri = uri then return
    m.artDelay.control = "stop"
    m.artDelay.control = "start"
end sub

sub loadPendingArtwork()
    m.artReveal.control = "stop"
    m.nextBackdrop.opacity = 0
    m.nextBackdrop.uri = textValue(m.pendingArtwork)
end sub

sub artLoaded()
    if m.nextBackdrop.loadStatus = "ready"
        m.artReveal.control = "stop"
        m.artReveal.control = "start"
    end if
end sub

sub artAnimationChanged()
    if m.artReveal.state = "stopped" and m.nextBackdrop.opacity > 0.9
        m.backdrop.uri = m.nextBackdrop.uri
        m.nextBackdrop.opacity = 0
    end if
end sub

' Native row focus animates the individual cards. Move the page only when a
' row needs room; the first Home rail keeps its cinematic hero composition.
sub updateViewport(node as Object)
    if m.page <> "home" and m.page <> "details" and m.page <> "categories" then return
    rowsY = m.baseRowsY
    heroY = m.baseHeroY
    heroAlpha = 1.0
    artAlpha = 1.0
    if node.isSameNode(m.rows)
        if m.page = "details" or m.page = "categories" or m.lastRowItem[0] > 0
            rowsY = 186
            heroAlpha = 0
            artAlpha = 0.18
        end if
    else if m.page = "details"
        if node.isSameNode(m.playButton) or node.isSameNode(m.secondaryButton)
            actionScreenY = m.baseHeroY + m.heroActions.translation[1]
            if actionScreenY > 680
                heroY = m.baseHeroY - (actionScreenY - 680)
                rowsY = m.baseRowsY - (actionScreenY - 680)
            end if
        end if
    end if
    m.viewportMove.control = "stop"
    m.top.findNode("rowSlide").keyValue = [m.listClip.translation, [72, rowsY]]
    m.top.findNode("heroSlide").keyValue = [m.hero.translation, [96, heroY]]
    m.top.findNode("heroFade").keyValue = [m.hero.opacity, heroAlpha]
    m.top.findNode("artFade").keyValue = [m.cinema.opacity, artAlpha]
    m.listClip.clippingRect = [0, -24, 1848, maxNumber(0, 1104 - rowsY)]
    m.viewportMove.control = "start"
end sub

function focusedRowNode() as Dynamic
    content = m.rows.content
    if content = invalid then return invalid
    rowIndex = m.lastRowItem[0]
    itemIndex = m.lastRowItem[1]
    if rowIndex < 0 or rowIndex >= content.getChildCount() then return invalid
    row = content.getChild(rowIndex)
    if itemIndex < 0 or itemIndex >= row.getChildCount() then return invalid
    return row.getChild(itemIndex)
end function

sub rowFocused()
    position = m.rows.rowItemFocused
    if position.count() <> 2 then return
    m.lastRowItem = [position[0], position[1]]
    if m.rows.hasFocus() then m.contentFocus = m.rows
    if m.rows.hasFocus() then updateViewport(m.rows)
    if m.page = "home" then updateHeroFromSelection()
end sub

sub rowSelected()
    position = m.rows.rowItemSelected
    if position.count() = 2 then m.lastRowItem = position
    item = focusedRowNode()
    if item = invalid then return
    if item.actionKind = "categoryActions"
        emit({kind: "categoryActions", categoryId: item.categoryId})
    else if item.actionKind = "selectSeason"
        emit({kind: "selectSeason", season: item.data.season})
    else if item.actionKind = "cast"
        ' Cast is informational; it never starts an unrelated title.
        return
    else if m.page = "home" and textValue(m.rowModels[m.lastRowItem[0]].id) = "continue"
        emit({kind: "play", item: item.data})
    else if m.page = "details" and item.data.episode <> invalid
        emit({kind: "play", item: item.data})
    else
        emit({kind: "openItem", item: item.data})
    end if
end sub

sub gridFocused()
    m.lastGridItem = m.grid.itemFocused
    if m.grid.hasFocus() then m.contentFocus = m.grid
end sub

sub gridSelected()
    content = m.grid.content
    index = m.grid.itemSelected
    if content = invalid or index < 0 or index >= content.getChildCount() then return
    item = content.getChild(index).data
    if m.page = "live"
        emit({kind: "tune", channel: item})
    else
        emit({kind: "openItem", item: item})
    end if
end sub

sub profileSelected()
    content = m.profiles.content
    index = m.profiles.itemSelected
    if content = invalid or index < 0 or index >= content.getChildCount() then return
    profile = content.getChild(index).data
    if textValue(profile.actionKind) = "createProfile"
        emit({kind: "createProfile"})
        return
    end if
    emit({kind: "selectProfile", profileId: firstText(profile, ["id", "profileId"])})
end sub

sub playSelected()
    if m.heroItem <> invalid and m.playButton.enabled then emit({kind: "play", item: m.heroItem})
end sub

sub secondarySelected()
    if m.heroItem = invalid then return
    if m.page = "details"
        emit({kind: "toggleMyList", item: m.heroItem})
    else
        emit({kind: "openItem", item: m.heroItem})
    end if
end sub

sub listSelected()
    if m.heroItem <> invalid then emit({kind: "toggleMyList", item: m.heroItem})
end sub

sub searchSelected()
    if m.page = "profiles"
        emit({kind: "refresh"})
    else
        emit({kind: "search"})
    end if
end sub

sub createSelected()
    emit({kind: "createCategory"})
end sub

sub profileRequested()
    emit({kind: "navigate", route: "profiles"})
end sub

sub menuSelected()
    if m.menuIndex < m.menuActions.count() then emit(m.menuActions[m.menuIndex])
end sub

sub focusNode(node as Dynamic)
    if node = invalid then return
    for each button in [m.playButton, m.secondaryButton, m.listButton, m.createButton, m.profileButton, m.searchButton]
        button.focused = false
    end for
    for each button in m.menuButtons
        button.focused = false
    end for
    m.overviewFocused = false
    m.overviewFocus.opacity = 0
    m.descriptionHint.visible = false
    m.headerHint.opacity = 0
    if node.id = "heroOverview"
        m.overviewFocused = true
        m.overviewFocus.opacity = 0.24
        m.descriptionHint.visible = true
        m.descriptionHint.text = "OK to read more"
        if m.overviewExpanded then m.descriptionHint.text = "OK to show less"
    else if node.hasField("focused")
        node.focused = true
    end if
    m.contentFocus = node
    if m.menu.visible then layoutSettingsMenu()
    if node.id = "createButton"
        m.headerHint.text = "Create category"
        m.headerHint.opacity = 1
    else if node.id = "profileButton"
        m.headerHint.text = firstText(m.model.profile, ["name", "displayName"], "Switch profile")
        m.headerHint.opacity = 1
    end if
    updateViewport(node)
    node.setFocus(true)
end sub

sub focusInitial()
    previous = m.pendingFocus
    m.pendingFocus = ""
    if previous = "rows" and m.listClip.visible
        focusNode(m.rows)
        return
    else if previous = "grid" and m.grid.visible
        focusNode(m.grid)
        return
    else if previous = "listButton" and m.listButton.visible
        focusNode(m.listButton)
        return
    else if previous = "secondaryButton" and m.hero.visible
        focusNode(m.secondaryButton)
        return
    else if previous = "heroOverview" and m.page = "details"
        focusNode(m.heroOverview)
        return
    end if
    if m.page = "home" or m.page = "details"
        if m.hero.visible
            focusHeroActions()
        else if m.listClip.visible
            focusNode(m.rows)
        else
            focusNode(m.profileButton)
        end if
    else if m.page = "profiles"
        if m.profiles.visible
            focusNode(m.profiles)
        else
            focusNode(m.searchButton)
        end if
    else if m.page = "search"
        focusNode(m.searchButton)
    else if m.page = "live"
        if m.grid.visible
            focusNode(m.grid)
        else
            focusNode(m.profileButton)
        end if
    else if m.page = "categories"
        if m.listClip.visible
            focusNode(m.rows)
        else
            focusNode(m.createButton)
        end if
    else if m.menuButtons.count() > 0
        focusNode(m.menuButtons[m.menuIndex])
    else
        m.top.setFocus(true)
    end if
end sub

sub focusHeroActions()
    if m.playButton.enabled
        focusNode(m.playButton)
    else
        focusNode(m.secondaryButton)
    end if
end sub

' Check ancestors too: a visible row node may live inside a now-hidden pane,
' and a removed settings button can remain referenced after its replacement.
function contentTargetVisible(node as Dynamic) as Boolean
    current = node
    while current <> invalid
        if current.hasField("visible")
            if not current.visible then return false
        end if
        if current.isSameNode(m.top) then return true
        current = current.getParent()
    end while
    return false
end function

function canRestoreViewFocus() as Boolean
    if not m.top.visible then return false
    if m.choicePanel.visible then return false
    scene = m.top.getScene()
    if scene <> invalid
        dialog = scene.dialog
        if dialog <> invalid
            if dialog.visible and not dialog.close then return false
        end if
    end if
    return true
end function

sub restoreFocus()
    if not canRestoreViewFocus() then return
    if (m.page = "live" or m.page = "sports") and not m.dock.opened and not m.choicePanel.visible then return
    if m.reading.visible
        m.readingText.setFocus(true)
    else if m.dock.opened
        m.dock.setFocus(true)
    else if contentTargetVisible(m.contentFocus)
        focusNode(m.contentFocus)
    else
        focusInitial()
    end if
end sub

sub openDock()
    for each button in [m.playButton, m.secondaryButton, m.listButton, m.createButton, m.profileButton, m.searchButton]
        button.focused = false
    end for
    for each button in m.menuButtons
        button.focused = false
    end for
    m.overviewFocus.opacity = 0
    m.headerHint.opacity = 0
    m.descriptionHint.visible = false
    m.dock.backdropUri = "pkg:/images/ambient.png"
    if m.cinema.visible and m.backdrop.uri <> "" then m.dock.backdropUri = m.backdrop.uri
    m.dock.visible = true
    m.dock.opened = true
    m.dock.setFocus(true)
    print "[Velvet] dock focused="; m.dock.HasFocus()
end sub

sub dockAction()
    action = m.dock.action
    print "[Velvet] dock action="; action.kind
    if action = invalid then return
    m.dock.opened = false
    ' Standalone guide/sports live in a sibling view. Release this native key
    ' target explicitly before the Scene returns focus to that sibling.
    m.dock.setFocus(false)
    restoreFocus()
    if action.kind = "exit"
        emit(action)
    else if action.kind = "navigate" and action.route <> m.page
        emit(action)
    else if m.page = "live" or m.page = "sports"
        emit({kind: "dockDismissed"})
    end if
end sub

sub toggleReading()
    if m.reading.visible
        m.reading.visible = false
        m.overviewExpanded = false
        m.heroOverview.maxLines = 5
        layoutDetailsOverview()
        focusNode(m.heroOverview)
        return
    end if
    m.overviewExpanded = not m.overviewExpanded
    if m.overviewExpanded
        m.heroOverview.maxLines = 0
    else
        m.heroOverview.maxLines = 5
    end if
    layoutDetailsOverview()
    if m.overviewExpanded and m.heroOverview.boundingRect().height > 570
        m.readingTitle.text = textValue(m.heroItem.title)
        m.readingText.text = textValue(m.heroItem.overview)
        m.reading.visible = true
        m.readingText.setFocus(true)
    else
        focusNode(m.heroOverview)
    end if
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.choicePanel.visible then return handleChoiceKey(key)
    if m.reading.visible
        if key = "back" or key = "OK"
            toggleReading()
            return true
        end if
        return false
    end if
    if key = "back"
        if m.page = "details"
            emit({kind: "back"})
        else if m.page = "setup" or m.page = "profiles"
            emit({kind: "exit"})
        else if m.dock.opened
            m.dock.opened = false
            m.dock.setFocus(false)
            restoreFocus()
            if m.page = "live" or m.page = "sports" then emit({kind: "dockDismissed"})
        else
            openDock()
        end if
        return true
    end if
    if key = "options" and m.rows.hasFocus()
        row = m.lastRowItem[0]
        if m.rowModels <> invalid and row < m.rowModels.count()
            data = m.rowModels[row]
            if data.category = true
                emit({kind: "categoryActions", categoryId: textValue(data.id)})
                return true
            else
                item = focusedRowNode()
                if item <> invalid
                    emit({kind: "contentActions", item: item.data, rowId: textValue(data.id)})
                    return true
                end if
            end if
        end if
    end if
    if key = "options" and m.profiles.hasFocus()
        content = m.profiles.content
        index = m.profiles.itemFocused
        if content <> invalid and index >= 0 and index < content.getChildCount()
            profile = content.getChild(index).data
            profileId = firstText(profile, ["id", "profileId"])
            if profileId <> "" then emit({kind: "profileActions", profileId: profileId})
        end if
        return true
    end if
    if key = "options" and m.grid.hasFocus() and m.page = "search"
        content = m.grid.content
        index = m.grid.itemFocused
        if content <> invalid and index >= 0 and index < content.getChildCount() then emit({kind: "contentActions", item: content.getChild(index).data})
        return true
    end if
    if m.overviewFocused
        if key = "OK"
            toggleReading()
            return true
        else if key = "down"
            focusHeroActions()
            return true
        else if key = "up"
            if m.profileButton.visible and m.header.visible then focusNode(m.profileButton)
            return true
        end if
    end if
    if m.playButton.hasFocus() or m.secondaryButton.hasFocus() or m.listButton.hasFocus()
        if key = "right"
            if m.playButton.hasFocus()
                focusNode(m.secondaryButton)
            else if m.listButton.visible
                focusNode(m.listButton)
            end if
        else if key = "left"
            if m.listButton.hasFocus()
                focusNode(m.secondaryButton)
            else
                focusHeroActions()
            end if
        else if key = "down" and m.listClip.visible
            focusNode(m.rows)
        else if key = "up"
            if m.page = "details" and m.heroOverview.text <> ""
                focusNode(m.heroOverview)
            else if m.createButton.visible
                focusNode(m.createButton)
            else if m.header.visible
                focusNode(m.profileButton)
            end if
        else
            return false
        end if
        return true
    end if
    if m.profileButton.hasFocus() or m.createButton.hasFocus()
        if key = "left" and m.createButton.visible
            focusNode(m.createButton)
        else if key = "right"
            focusNode(m.profileButton)
        else if key = "down"
            if m.hero.visible
                focusHeroActions()
            else if m.searchButton.visible
                focusNode(m.searchButton)
            else if m.listClip.visible
                focusNode(m.rows)
            else if m.grid.visible
                focusNode(m.grid)
            else if m.menuButtons.count() > 0
                focusNode(m.menuButtons[m.menuIndex])
            end if
        else
            return false
        end if
        return true
    end if
    if m.rows.hasFocus() and key = "up"
        if m.hero.visible
            focusHeroActions()
        else
            focusNode(m.createButton)
        end if
        return true
    end if
    if m.searchButton.hasFocus()
        if key = "down" and m.grid.visible
            focusNode(m.grid)
            return true
        else if key = "up"
            focusNode(m.profileButton)
            return true
        end if
    end if
    if m.grid.hasFocus() and key = "up"
        if m.page = "search"
            focusNode(m.searchButton)
        else
            focusNode(m.profileButton)
        end if
        return true
    end if
    if m.menu.visible
        for i = 0 to m.menuButtons.count() - 1
            if m.menuButtons[i].hasFocus()
                if key = "down" and i < m.menuButtons.count() - 1
                    m.menuIndex = i + 1
                else if key = "up" and i > 0
                    m.menuIndex = i - 1
                else if key = "up" and m.profileButton.visible
                    focusNode(m.profileButton)
                    return true
                else
                    return false
                end if
                focusNode(m.menuButtons[m.menuIndex])
                return true
            end if
        end for
    end if
    return false
end function

sub renderChoice()
    choice = m.model.choice
    if type(choice) <> "roAssociativeArray"
        wasVisible = m.choicePanel.visible
        m.choicePanel.visible = false
        m.choiceSignature = ""
        if wasVisible then restoreFocus()
        return
    end if
    entries = arrayValue(choice.items)
    if entries.count() = 0 then return
    signature = textValue(choice.title)
    for each entry in entries
        signature = signature + "|" + textValue(entry.id) + ":" + textValue(entry.label) + ":" + textValue(entry.subtitle)
    end for
    if signature = m.choiceSignature
        if not m.choicePanel.isInFocusChain() then focusChoice()
        return
    end if
    m.choiceSignature = signature
    m.choiceEntries = entries
    m.choiceIndex = 0
    m.choiceItems.removeChildrenIndex(m.choiceItems.getChildCount(), 0)
    m.choiceButtons = []
    m.choiceOffsets = []
    m.choiceTitle.text = textValue(choice.title)
    totalHeight = 150
    for i = 0 to entries.count() - 1
        entry = entries[i]
        button = m.choiceItems.createChild("VelvetButton")
        button.width = 900
        button.height = 76
        m.choiceOffsets.push(totalHeight - 150)
        button.translation = [0, totalHeight - 150]
        button.label = textValue(entry.label)
        button.subtitle = textValue(entry.subtitle)
        if button.subtitle <> "" then button.height = 104
        totalHeight = totalHeight + button.height + 14
        button.observeField("selected", "choiceSelected")
        m.choiceButtons.push(button)
    end for
    totalHeight = totalHeight + 24
    if totalHeight > 900 then totalHeight = 900
    m.choiceViewportHeight = totalHeight - 150
    m.choiceItems.clippingRect = [-6, -6, 912, m.choiceViewportHeight]
    m.choiceScroll = 0
    topY = int((1080 - totalHeight) / 2)
    if topY < 72 then topY = 72
    m.choiceSurface.translation = [456, topY]
    m.choiceSurface.height = totalHeight
    m.choiceTitle.translation = [510, topY + 44]
    m.choiceItems.translation = [510, topY + 124]
    m.choicePanel.visible = true
    m.top.findNode("choiceReveal").control = "start"
    focusChoice()
end sub

sub focusChoice()
    if m.choiceButtons.count() = 0 then return
    targetY = m.choiceOffsets[m.choiceIndex]
    targetHeight = m.choiceButtons[m.choiceIndex].height
    if targetY < m.choiceScroll then m.choiceScroll = targetY
    if targetY + targetHeight > m.choiceScroll + m.choiceViewportHeight - 12 then m.choiceScroll = targetY + targetHeight - m.choiceViewportHeight + 12
    for i = 0 to m.choiceButtons.count() - 1
        m.choiceButtons[i].translation = [0, m.choiceOffsets[i] - m.choiceScroll]
        m.choiceButtons[i].focused = i = m.choiceIndex
    end for
    m.choiceButtons[m.choiceIndex].setFocus(true)
end sub

sub choiceSelected()
    if m.choiceIndex < m.choiceEntries.count() then emit({kind: "choice", id: textValue(m.choiceEntries[m.choiceIndex].id)})
end sub

function handleChoiceKey(key as String) as Boolean
    if key = "back"
        emit({kind: "closeChoice"})
    else if key = "up"
        if m.choiceIndex > 0 then m.choiceIndex = m.choiceIndex - 1
        focusChoice()
    else if key = "down"
        if m.choiceIndex < m.choiceButtons.count() - 1 then m.choiceIndex = m.choiceIndex + 1
        focusChoice()
    end if
    return true
end function
