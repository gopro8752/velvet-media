' Scene include. UI uses VelvetView's existing glass choices and native keyboard.
sub initPreferences()
    m.preferences = {quality: "2160p", layouts: {}}
    stored = m.registry.Read("preferences")
    if stored <> ""
        parsed = ParseJson(stored)
        if Type(parsed) = "roAssociativeArray"
            m.preferences.quality = VStr(VGet(parsed, "quality"), "2160p")
            if Type(VGet(parsed, "layouts")) = "roAssociativeArray" then m.preferences.layouts = parsed.layouts
        end if
    end if
    quality = m.preferences.quality
    if quality <> "2160p" and quality <> "1080p" and quality <> "720p" then m.preferences.quality = "2160p"
    m.preferenceMenus = []
    m.preferenceActions = []
    m.preferenceMenuPage = ""
    m.preferenceAvailableRows = []
    m.preferenceProfile = ""
    m.preferenceItem = invalid
    m.preferenceContext = invalid
end sub

sub preferencesReconcileProfiles()
    layouts = VPruneDeletedProfileLayouts(m.preferences.layouts, m.baseUrl, m.sync.profiles)
    if layouts.Count() <> m.preferences.layouts.Count()
        m.preferences.layouts = layouts
        savePreferences()
    end if
end sub

function preferenceLayoutKey() as string
    return m.baseUrl + "|" + m.profileId
end function

function preferenceLayout() as object
    value = m.preferences.layouts.Lookup(preferenceLayoutKey())
    return {order: VPreferenceIds(VGet(value, "order")), hidden: VPreferenceIds(VGet(value, "hidden"))}
end function

sub savePreferences()
    m.registry.Write("preferences", FormatJson(m.preferences))
    m.registry.Flush()
end sub

function preferencesSettingsRows() as object
    quality = VStr(VGet(m.preferences, "quality"), "2160p")
    if quality = "2160p" then quality = "4K preferred"
    return [
        {label: "Manage profiles", subtitle: "Add, rename, change colors, or remove a profile", kind: "manageProfiles"},
        {label: "Home rows", subtitle: "Show, hide, and arrange rows for this profile", kind: "customizeHome"},
        {label: "Preferred quality", subtitle: quality + " · compatible alternatives stay available", kind: "preferredQuality"}
    ]
end function

function preferencesHomeRows(rows as object) as object
    m.preferenceAvailableRows = VCopy(rows)
    layout = preferenceLayout()
    return VOrderedHomeRows(rows, layout.order, layout.hidden)
end function

function preferencesStreams(streams as object) as object
    return VStartupQualityStreams(streams, VStr(VGet(m.preferences, "quality"), "2160p"))
end function

function handlePreferencesAction(action as object) as boolean
    kind = VStr(VGet(action, "kind"))
    if kind = "manageProfiles"
        preferenceProfiles()
    else if kind = "createProfile"
        m.preferenceProfile = ""
        openKeyboard("preferenceCreate", "Name your profile", "", false)
    else if kind = "profileActions"
        m.preferenceProfile = VStr(VGet(action, "profileId"), m.profileId)
        preferenceProfileMenu()
    else if kind = "customizeHome"
        preferenceRowsMenu()
    else if kind = "preferredQuality"
        preferenceQualityMenu()
    else if kind = "contentActions"
        m.preferenceItem = VCopy(VGet(action, "item", {}))
        preferenceContentMenu()
    else if kind = "closeChoice" and m.dialogKind = "preferences"
        preferenceBack()
    else
        return false
    end if
    return true
end function

sub preferencePresent(page as string, title as string, entries as object)
    m.preferenceContext = {epoch: m.backendEpoch, generation: m.generation, profileId: m.profileId, playGeneration: m.playGeneration}
    m.preferenceMenuPage = page
    m.preferenceActions = entries
    m.dialogKind = "preferences"
    items = []
    for i = 0 to entries.Count() - 1
        entry = entries[i]
        items.Push({id: VStr(i), label: VStr(VGet(entry, "label")), subtitle: VStr(VGet(entry, "subtitle"))})
    end for
    m.model.choice = {title: title, items: items}
    publishModel()
end sub

sub preferenceClose()
    m.model.Delete("choice")
    m.preferenceMenuPage = ""
    m.preferenceActions = []
    m.dialogKind = ""
    publishModel()
    m.view.CallFunc("restoreFocus")
end sub

sub preferenceBack()
    page = m.preferenceMenuPage
    if page = "profile" then preferenceProfiles() : return
    if page = "color" or page = "deleteProfile" then preferenceProfileMenu() : return
    if page = "row" then preferenceRowsMenu() : return
    if page = "clearHistory" then preferenceContentMenu() : return
    preferenceClose()
end sub

sub preferenceProfiles()
    entries = [{label: "Add profile", subtitle: "A separate place for someone's shows and movies", command: "createProfile"}]
    for each profile in activeRecords(m.sync.profiles)
        subtitle = "Rename, color, or remove"
        if VStr(VGet(profile, "id")) = m.profileId then subtitle = "Current profile · " + subtitle
        entries.Push({label: VStr(VGet(profile, "name")), subtitle: subtitle, command: "editProfile", profileId: profile.id})
    end for
    preferencePresent("profiles", "Manage profiles", entries)
end sub

function preferenceFindProfile(id as string) as dynamic
    for each profile in activeRecords(m.sync.profiles)
        if VStr(VGet(profile, "id")) = id then return profile
    end for
    return invalid
end function

sub preferenceProfileMenu()
    profile = preferenceFindProfile(m.preferenceProfile)
    if profile = invalid then preferenceProfiles() : return
    entries = [
        {label: "Watch as " + VStr(profile.name), command: "selectProfile"},
        {label: "Rename", subtitle: VStr(profile.name), command: "renameProfile"},
        {label: "Change color", command: "profileColor"}
    ]
    if activeRecords(m.sync.profiles).Count() > 1 then entries.Push({label: "Delete profile", subtitle: "Remove this profile from all your Velvet devices", command: "deleteProfile"})
    preferencePresent("profile", VStr(profile.name), entries)
end sub

sub preferenceColors()
    labels = ["Violet", "Green", "Gold", "Rose", "Sky", "Orange", "Lilac", "Mint"]
    palette = VProfilePalette()
    entries = []
    profile = preferenceFindProfile(m.preferenceProfile)
    if profile = invalid then preferenceProfiles() : return
    for i = 0 to palette.Count() - 1
        label = labels[i]
        if LCase(VStr(profile.color)) = LCase(palette[i]) then label = "✓  " + label
        entries.Push({label: label, command: "setColor", color: palette[i]})
    end for
    preferencePresent("color", "Choose a color", entries)
end sub

sub preferenceWriteProfile(profile as object)
    now = VNowMs()
    if now <= VNum(VGet(profile, "updatedAt")) then now = VNum(VGet(profile, "updatedAt")) + 1
    profile.updatedAt = now
    m.sync = VMergeSync(m.sync, {profiles: [profile]})
    preferencesReconcileProfiles()
    requestApi("push", "/push", "POST", {profiles: [profile]}, {profileId: VStr(profile.id)})
end sub

sub preferenceSelectProfile(id as string)
    if preferenceFindProfile(id) = invalid then return
    m.profileId = id
    m.categories = []
    m.preferenceAvailableRows = []
    m.registry.Write("profileId", id)
    m.registry.Flush()
    preferenceClose()
    navigate("home")
end sub

function handlePreferencesKeyboard(kind as string, text as string, accepted = true as boolean) as boolean
    if kind <> "preferenceCreate" and kind <> "preferenceRename" then return false
    if not accepted
        m.dialogKind = ""
        if Type(VGet(m.model, "choice")) = "roAssociativeArray" then m.dialogKind = "preferences"
        publishModel()
        m.view.CallFunc("restoreFocus")
        return true
    end if
    id = ""
    if kind = "preferenceRename" then id = m.preferenceProfile
    message = VProfileNameError(m.sync.profiles, text, id)
    if message <> ""
        m.model.message = message
        title = "Name your profile"
        if kind = "preferenceRename" then title = "Rename profile"
        openKeyboard(kind, message, text, false)
        return true
    end if
    if kind = "preferenceCreate"
        now = VNowMs()
        profile = {id: LCase(CreateObject("roDeviceInfo").GetRandomUUID()), name: text.Trim(), color: VNextProfileColor(m.sync.profiles), createdAt: now, updatedAt: now, deleted: false}
        m.pendingProfileCreate = profile.id
        preferenceWriteProfile(profile)
        preferenceSelectProfile(profile.id)
    else
        existing = preferenceFindProfile(id)
        if existing = invalid
            m.model.message = "That profile was removed on another device."
            preferenceProfiles()
        else
            profile = VCopy(existing)
            profile.name = text.Trim()
            preferenceWriteProfile(profile)
            preferenceProfileMenu()
        end if
    end if
    return true
end function

function preferenceKnownRows() as object
    rows = [{id: "continue", title: "Continue Watching"}, {id: "mylist", title: "My List"}]
    for each row in categoryRows()
        rows.Push(row)
    end for
    for each row in m.catalogRows
        rows.Push(row)
    end for
    for each row in m.preferenceAvailableRows
        rows.Push(row)
    end for
    return VOrderedHomeRows(rows, preferenceLayout().order, [])
end function

sub preferenceRowsMenu()
    entries = []
    layout = preferenceLayout()
    for each row in preferenceKnownRows()
        hidden = VPreferenceHas(layout.hidden, VStr(row.id))
        subtitle = "Visible · select to hide or move"
        if hidden then subtitle = "Hidden · select to show or move"
        entries.Push({label: VStr(row.title), subtitle: subtitle, command: "editRow", rowId: row.id})
    end for
    entries.Push({label: "Reset home layout", subtitle: "Show every row in its default position", command: "resetRows"})
    preferencePresent("rows", "Home rows", entries)
end sub

sub preferenceRowMenu()
    layout = preferenceLayout()
    rows = preferenceKnownRows()
    title = "Home row"
    index = -1
    for i = 0 to rows.Count() - 1
        if rows[i].id = m.preferenceRow
            title = rows[i].title
            index = i
        end if
    end for
    label = "Hide from Home"
    if VPreferenceHas(layout.hidden, m.preferenceRow) then label = "Show on Home"
    entries = [{label: label, command: "toggleRow"}]
    if index > 0 then entries.Push({label: "Move up", command: "moveRow", direction: -1})
    if index >= 0 and index < rows.Count() - 1 then entries.Push({label: "Move down", command: "moveRow", direction: 1})
    entries.Push({label: "Back to home rows", command: "rows"})
    preferencePresent("row", title, entries)
end sub

sub preferenceQualityMenu()
    entries = []
    for each quality in ["2160p", "1080p", "720p"]
        label = quality
        if quality = "2160p" then label = "4K / 2160p"
        if quality = m.preferences.quality then label = "✓  " + label
        entries.Push({label: label, subtitle: "Prefer this quality when a compatible stream is available", command: "setQuality", quality: quality})
    end for
    preferencePresent("quality", "Preferred quality", entries)
end sub

sub preferenceContentMenu()
    item = m.preferenceItem
    if Type(item) <> "roAssociativeArray" then return
    progress = findProgress(item)
    playLabel = "Play"
    if VNum(VGet(progress, "positionMs")) > 1000 then playLabel = "Resume"
    listLabel = "Add to My List"
    if isInMyList(item) then listLabel = "Remove from My List"
    entries = [
        {label: playLabel, command: "playContent"},
        {label: "Start from beginning", command: "restartContent"},
        {label: "Details", command: "contentDetails"},
        {label: listLabel, command: "toggleList"}
    ]
    if progress.Count() > 0 then entries.Push({label: "Remove from Continue Watching", command: "removeContinue"})
    history = VHistoryTombstones(m.sync, m.profileId, item, VNowMs())
    if history.progress.Count() > 0 or history.watched.Count() > 0 then entries.Push({label: "Clear watch history", subtitle: "For this title and profile only", command: "clearHistory"})
    preferencePresent("content", VStr(VGet(item, "title")), entries)
end sub

sub preferenceClearHistory(onlyContinue as boolean)
    body = VHistoryTombstones(m.sync, m.profileId, m.preferenceItem, VNowMs(), onlyContinue)
    for each record in body.progress
        upsertSync("progress", record)
    end for
    for each record in body.watched
        upsertSync("watched", record)
    end for
    if body.progress.Count() > 0 or body.watched.Count() > 0 then requestApi("push", "/push", "POST", body)
    preferenceClose()
    if m.model.page = "home" then composeHome()
end sub

function handlePreferencesChoice(index as integer) as boolean
    if m.dialogKind <> "preferences" then return false
    if not VPreferencesContextCurrent(m.preferenceContext, m.backendEpoch, m.generation, m.profileId, m.playGeneration)
        m.model.Delete("choice")
        m.dialogKind = ""
        m.preferenceActions = []
        publishModel()
        return true
    end if
    if index < 0 or index >= m.preferenceActions.Count() then return true
    action = m.preferenceActions[index]
    command = VStr(VGet(action, "command"))
    if command = "createProfile"
        m.preferenceProfile = ""
        openKeyboard("preferenceCreate", "Name your profile", "", false)
    else if command = "editProfile"
        m.preferenceProfile = VStr(action.profileId)
        preferenceProfileMenu()
    else if command = "selectProfile"
        preferenceSelectProfile(m.preferenceProfile)
    else if command = "renameProfile"
        profile = preferenceFindProfile(m.preferenceProfile)
        if profile <> invalid then openKeyboard("preferenceRename", "Rename profile", VStr(profile.name), false)
    else if command = "profileColor"
        preferenceColors()
    else if command = "setColor"
        existing = preferenceFindProfile(m.preferenceProfile)
        if existing <> invalid
            profile = VCopy(existing)
            profile.color = action.color
            preferenceWriteProfile(profile)
        end if
        preferenceProfileMenu()
    else if command = "deleteProfile"
        profile = preferenceFindProfile(m.preferenceProfile)
        if profile <> invalid
            preferencePresent("deleteProfile", "Delete " + VStr(profile.name) + "?", [
                {label: "Keep profile", command: "cancelDelete"},
                {label: "Delete profile", subtitle: "Removes this profile from every connected Velvet device", command: "confirmDelete"}
            ])
        end if
    else if command = "cancelDelete"
        preferenceProfileMenu()
    else if command = "confirmDelete"
        tombstone = VProfileTombstone(m.sync.profiles, m.preferenceProfile, VNowMs())
        if tombstone <> invalid
            preferenceWriteProfile(tombstone)
            if m.profileId = m.preferenceProfile
                for each other in activeRecords(m.sync.profiles)
                    m.profileId = other.id
                    exit for
                end for
                m.categories = []
                m.preferenceAvailableRows = []
                m.registry.Write("profileId", m.profileId)
                m.registry.Flush()
                requestApi("savedCategories", "/categories/saved?profileId=" + VEncode(m.profileId), "GET", invalid, {profileId: m.profileId})
                if m.model.page = "home" then composeHome()
            end if
        end if
        preferenceProfiles()
    else if command = "editRow"
        m.preferenceRow = VStr(action.rowId)
        preferenceRowMenu()
    else if command = "rows"
        preferenceRowsMenu()
    else if command = "toggleRow" or command = "moveRow"
        layout = preferenceLayout()
        if command = "toggleRow" then layout.hidden = VPreferenceToggle(layout.hidden, m.preferenceRow)
        if command = "moveRow" then layout.order = VMoveHomeRow(preferenceKnownRows(), layout.order, m.preferenceRow, VNum(action.direction))
        m.preferences.layouts[preferenceLayoutKey()] = layout
        savePreferences()
        if m.model.page = "home" then composeHome()
        preferenceRowMenu()
    else if command = "resetRows"
        m.preferences.layouts.Delete(preferenceLayoutKey())
        savePreferences()
        if m.model.page = "home" then composeHome()
        preferenceRowsMenu()
    else if command = "setQuality"
        m.preferences.quality = action.quality
        savePreferences()
        preferenceQualityMenu()
    else if command = "playContent" or command = "restartContent"
        item = VCopy(m.preferenceItem)
        if command = "restartContent" then item.startFromBeginning = true
        preferenceClose()
        startPlayback(item, false)
    else if command = "contentDetails"
        item = VCopy(m.preferenceItem)
        preferenceClose()
        openDetails(item)
    else if command = "toggleList"
        toggleMyList(m.preferenceItem)
        preferenceContentMenu()
    else if command = "removeContinue"
        preferenceClearHistory(true)
    else if command = "clearHistory"
        preferencePresent("clearHistory", "Clear watch history?", [
            {label: "Keep history", command: "keepHistory"},
            {label: "Clear history", subtitle: "Removes progress and watched marks for this title on your profile", command: "confirmHistory"}
        ])
    else if command = "keepHistory"
        preferenceContentMenu()
    else if command = "confirmHistory"
        preferenceClearHistory(false)
    end if
    return true
end function
