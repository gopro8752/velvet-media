sub init()
    m.top.backgroundColor = "0x0A0C12FF"
    m.top.backgroundUri = ""
    m.view = m.top.FindNode("view")
    m.view.ObserveField("action", "onViewAction")
    m.registry = CreateObject("roRegistrySection", "Velvet")
    m.baseUrl = VBackendUrl(m.registry.Read("backendUrl"))
    m.token = m.registry.Read("token")
    m.profileId = m.registry.Read("profileId")
    m.categories = []
    m.backendEpoch = 0
    m.sync = {profiles: [], progress: [], watched: [], mylist: []}
    m.catalogRows = []
    m.halloween = invalid
    m.requestSequence = 0
    m.requests = {}
    m.tasks = []
    m.requestQueue = []
    m.failedPushes = []
    m.generation = 0
    m.history = []
    m.model = {page: "setup", busy: false, message: "", profiles: [], rows: [], items: [], settings: {backendUrl: m.baseUrl, tokenConfigured: m.token <> ""}}
    m.syncTimer = m.top.FindNode("syncTimer")
    m.syncTimer.ObserveField("fire", "onSyncTimer")
    initPreferences()
    initLiveBrowser()
    initSportsBrowser()
    initCategoryComposer()
    initPlayback()
    initHandoff()
    publishModel()
    m.view.CallFunc("restoreFocus")
    if m.baseUrl <> "" then connectBackend()
end sub

sub publishModel()
    m.model.settingsRows = preferencesSettingsRows()
    m.model.settings = {backendUrl: m.baseUrl, tokenConfigured: m.token <> ""}
    m.model.profile = activeProfile()
    m.model.profiles = activeRecords(m.sync.profiles)
    m.view.model = VCopy(m.model)
end sub

function activeProfile() as object
    for each profile in VArray(m.sync.profiles)
        if VStr(VGet(profile, "id")) = m.profileId and not VBool(VGet(profile, "deleted")) then return profile
    end for
    return {}
end function

function activeRecords(records as dynamic, filterProfile = false as boolean) as object
    output = []
    for each item in VArray(records)
        matches = not VBool(VGet(item, "deleted"))
        if filterProfile and VStr(VGet(item, "profileId")) <> m.profileId then matches = false
        if matches then output.Push(item)
    end for
    return output
end function

sub requestApi(kind as string, path as string, method = "GET" as string, body = invalid as dynamic, context = invalid as dynamic, timeout = 25000 as integer)
    m.requestSequence += 1
    id = m.requestSequence.ToStr()
    m.requests[id] = {kind: kind, generation: m.generation, epoch: m.backendEpoch, context: context}
    if kind = "push" then m.requests[id].pushBody = VCopy(body)
    print "[Velvet] request queued "; kind; " #"; id
    m.requestQueue.Push({id: id, baseUrl: m.baseUrl, token: m.token, path: path, method: method, body: body, timeout: timeout})
    drainRequests()
end sub

sub drainRequests()
    while m.tasks.Count() < 3 and m.requestQueue.Count() > 0
        request = m.requestQueue.Shift()
        context = m.requests.Lookup(request.id)
        if context <> invalid
            background = isBackgroundRequest(context.kind)
            if context.epoch = m.backendEpoch and (background or context.generation = m.generation)
                task = CreateObject("roSGNode", "ApiTask")
                task.request = request
                task.ObserveField("result", "onApiResult")
                m.tasks.Push(task)
                print "[Velvet] request started "; context.kind; " #"; request.id
                task.control = "RUN"
            else
                m.requests.Delete(request.id)
            end if
        end if
    end while
end sub

sub onApiResult(event as object)
    result = event.GetData()
    id = VStr(VGet(result, "id"))
    context = m.requests.Lookup(id)
    for i = m.tasks.Count() - 1 to 0 step -1
        if VStr(VGet(m.tasks[i].request, "id")) = id
            m.tasks[i].UnobserveField("result")
            m.tasks.Delete(i)
        end if
    end for
    m.requests.Delete(id)
    drainRequests()
    if context = invalid then return
    if context.epoch <> m.backendEpoch then return
    kind = context.kind
    ' A late legacy collection or queue response must not follow a profile switch.
    if kind = "halloween" or (kind = "queue" and VStr(VGet(context.context, "categoryId")) = "halloween-nostalgia")
        if not VLegacyHalloweenResponseCurrent(context.context, m.profileId) then return
    end if
    if Left(kind, 4) = "hand"
        if VBool(VGet(result, "ok"))
            handleHandoffResponse(kind, VGet(result, "data", {}), context.context)
        else
            onHandoffRequestFailed(kind, context.context)
        end if
        return
    end if
    if Left(kind, 9) = "rokuAudio"
        if VBool(VGet(result, "ok"))
            handleRokuAudioResponse(kind, VGet(result, "data", {}), context.context)
        else
            onRokuAudioRequestFailed(kind, context.context)
        end if
        return
    end if
    print "[Velvet] request completed "; kind; " #"; id; " status="; VNum(VGet(result, "status"))
    ' Background writes and pulls are independent of the visible page generation.
    background = isBackgroundRequest(kind)
    if not background and context.generation <> m.generation
        print "[Velvet] ignoring old page request "; kind; " request="; context.generation; " current="; m.generation
        return
    end if
    if kind = "playDetails" or kind = "resolve" or kind = "nextSeason" or kind = "liveTune" or kind = "queue" or kind = "playerEpisodes" or kind = "segments" or kind = "playerSources"
        if VNum(VGet(context.context, "playId"), -1) <> m.playGeneration
            print "[Velvet] ignoring old playback request "; kind; " request="; VNum(VGet(context.context, "playId"), -1); " current="; m.playGeneration
            return
        end if
    end if
    if handleCategoryResponse(kind, result, context.context) then return
    if not VBool(VGet(result, "ok"))
        if handleSportsBrowserError(kind, VStr(VGet(result, "error"), "Could not load sports."), context.context) then return
        if handleLiveBrowserError(kind, VStr(VGet(result, "error"), "Could not load the TV guide.")) then return
        if kind = "playerSources"
            playerAlternativesFailed()
            return
        end if
        if kind = "push"
            attempts = VNum(VGet(context.context, "attempts"))
            if attempts < 3
                if m.failedPushes.Count() >= 32 then m.failedPushes.Shift()
                m.failedPushes.Push({body: context.pushBody, attempts: attempts + 1, context: VCopy(context.context)})
            end if
            return
        end if
        if kind = "sync" or kind = "push" or kind = "report" or kind = "prepare" or kind = "liveStop" then return
        if kind = "halloween" or kind = "playerEpisodes" or kind = "segments" then return
        m.model.busy = false
        m.model.message = VStr(VGet(result, "error"), "Something went wrong. Please try again.")
        if kind = "resolve" or kind = "playDetails" or kind = "nextSeason" or kind = "liveTune" then m.playResolving = false
        publishModel()
        if m.player.visible and (kind = "resolve" or kind = "playDetails" or kind = "nextSeason" or kind = "liveTune") then playbackFailure(m.model.message)
        return
    end if
    data = VGet(result, "data", {})
    if handleLiveBrowserResponse(kind, data) then return
    if handleSportsBrowserResponse(kind, data, context.context) then return
    if kind = "push" and VStr(m.pendingProfileCreate) <> "" and VStr(VGet(context.context, "profileId")) = VStr(m.pendingProfileCreate)
        createdId = m.pendingProfileCreate
        m.pendingProfileCreate = ""
        if createdId = m.profileId then requestApi("savedCategories", "/categories/saved?profileId=" + VEncode(m.profileId), "GET", invalid, {profileId: m.profileId})
    else if kind = "connect" or kind = "sync"
        if Type(data) <> "roAssociativeArray" then return
        m.sync = VMergeSync(m.sync, data)
        preferencesReconcileProfiles()
        if kind = "connect"
            if not m.handoffEnabled then initHandoff()
            m.model.busy = false
            m.model.message = ""
            m.syncTimer.control = "start"
            if activeProfile().Count() > 0
                navigate("home")
            else
                navigate("profiles")
            end if
        else if activeProfile().Count() = 0
            if m.playing or m.playResolving or m.player.visible then closePlayback()
            navigate("profiles")
        else if m.model.page = "home"
            composeHome()
        else if m.model.page = "profiles" or m.model.page = "settings"
            publishModel()
        end if
    else if kind = "home"
        m.catalogRows = VArray(VGet(data, "rows"))
        m.model.busy = false
        m.model.message = VStr(VGet(data, "message"))
        composeHome()
    else if kind = "halloween"
        m.halloween = data
        if m.model.page = "home" then composeHome()
    else if kind = "search"
        m.model.items = VArray(VGet(data, "items"))
        m.model.busy = false
        m.model.message = ""
        if m.model.items.Count() = 0 then m.model.message = "No matches. Try another title."
        publishModel()
    else if kind = "details"
        m.model.details = data
        item = VGet(data, "item", {})
        m.model.inMyList = isInMyList(item)
        m.model.busy = false
        m.model.message = ""
        seasons = VArray(VGet(data, "seasons"))
        if seasons.Count() > 0
            progress = findProgress(item)
            season = VNum(VGet(progress, "season", seasons[0].number), 1)
            selectSeason(season)
        else
            publishModel()
        end if
    else if kind = "episodes"
        if VNum(VGet(context.context, "season")) <> m.model.selectedSeason
            print "[Velvet] ignoring old season request wanted="; m.model.selectedSeason; " received="; VNum(VGet(context.context, "season"))
            return
        end if
        m.model.episodes = VArray(VGet(data, "episodes"))
        m.model.busy = false
        publishModel()
    else if kind = "generate"
        if VArray(VGet(data, "items")).Count() = 0
            m.model.busy = false
            m.model.message = "No matching titles or episodes were found. Try another description."
            publishModel()
        else
            requestApi("saveCategory", "/categories/saved", "POST", {profileId: m.profileId, category: data})
        end if
    else if kind = "savedCategories"
        if VStr(VGet(context.context, "profileId")) <> m.profileId then return
        m.categories = VArray(VGet(data, "categories"))
        if m.model.page = "home" then composeHome()
        if m.model.page = "categories"
            m.model.rows = categoryRows()
            publishModel()
        end if
    else if kind = "saveCategory" or kind = "deleteCategory"
        m.model.busy = false
        m.model.message = ""
        requestApi("savedCategories", "/categories/saved?profileId=" + VEncode(m.profileId), "GET", invalid, {profileId: m.profileId})
        publishModel()
    else if kind = "playerSources"
        handlePlayerAlternatives(data)
    else if kind = "playerEpisodes" or kind = "segments"
        handlePlayerMetadata(kind, data)
    else if kind = "queue"
        m.model.busy = false
        items = VArray(VGet(data, "items"))
        if items.Count() = 0
            m.model.message = "No playable titles or episodes were found for this category."
            publishModel()
        else
            m.queue = items
            m.queueIndex = 0
            startPlayback(items[0], true)
        end if
    else if kind = "live"
        m.liveChannels = VArray(VGet(data, "channels"))
        m.model.items = m.liveChannels
        m.model.busy = false
        m.model.message = VStr(VGet(data, "message"))
        publishModel()
        requestApi("guide", "/live/guide")
    else if kind = "guide"
        applyGuide(data)
    else if kind = "playDetails" or kind = "resolve" or kind = "liveTune" or kind = "nextSeason"
        handlePlaybackResponse(kind, data, context.context)
    end if
end sub

sub connectBackend()
    if m.baseUrl = ""
        m.model.page = "setup"
        m.model.message = "Enter your Velvet backend address to connect."
        publishModel()
        return
    end if
    m.generation += 1
    m.model.busy = true
    m.model.message = "Connecting to Velvet…"
    publishModel()
    requestApi("connect", "/state?since=0")
end sub

sub navigate(page as string)
    closeCategoryComposer(false)
    dismissScopedKeyboard()
    closeLiveBrowser()
    closeSportsBrowser()
    m.view.visible = true
    m.generation += 1
    m.history = []
    m.playResolving = false
    m.model = {page: page, busy: false, message: "", rows: [], items: [], profiles: [], query: "", episodes: []}
    if page = "home"
        composeHome()
        if m.catalogRows.Count() = 0
            m.model.busy = true
            requestApi("home", "/catalog/home?date=" + localDate(), "GET", invalid, invalid, 40000)
        end if
        if VHasLegacyHalloween(m.profileId) and m.halloween = invalid then requestApi("halloween", "/catalog/halloween", "GET", invalid, {profileId: m.profileId}, 90000)
        if VStr(m.pendingProfileCreate) <> m.profileId then requestApi("savedCategories", "/categories/saved?profileId=" + VEncode(m.profileId), "GET", invalid, {profileId: m.profileId})
    else if page = "live"
        m.model.busy = false
    else if page = "categories"
        m.model.rows = categoryRows()
        requestApi("savedCategories", "/categories/saved?profileId=" + VEncode(m.profileId), "GET", invalid, {profileId: m.profileId})
        if m.model.rows.Count() = 0 then m.model.message = "Create a category from a mood, a movie series, or favorite episodes."
    else if page = "profiles"
        if activeRecords(m.sync.profiles).Count() = 0 then m.model.message = "Add your first profile to start watching."
    end if
    publishModel()
    if page = "live" then openLiveBrowser()
    if page = "sports" then openSportsBrowser()
end sub

sub openLiveDock()
    m.view.visible = true
    m.view.CallFunc("openDock")
end sub

sub openSportsDock()
    m.view.visible = true
    m.view.CallFunc("openDock")
end sub

sub restoreBrowsePage()
    if m.model.page = "live"
        restoreLiveBrowser()
    else if m.model.page = "sports"
        restoreSportsBrowser()
    else
        m.view.CallFunc("restoreFocus")
    end if
end sub

function localDate() as string
    now = CreateObject("roDateTime")
    now.ToLocalTime()
    return Left(now.ToISOString(), 10)
end function

sub composeHome()
    rows = []
    progress = VNewestFirst(activeRecords(m.sync.progress, true), "updatedAt")
    continueItems = []
    for each item in progress
        if VNum(VGet(item, "positionMs")) > 1000 and not VCompleted(VNum(VGet(item, "positionMs")), VNum(VGet(item, "durationMs"))) then continueItems.Push(item)
    end for
    if continueItems.Count() > 0 then rows.Push({id: "continue", title: "Continue Watching", style: "landscape", items: continueItems})
    mylist = VNewestFirst(activeRecords(m.sync.mylist, true), "addedAt")
    if mylist.Count() > 0 then rows.Push({id: "mylist", title: "My List", style: "poster", items: mylist})
    for each row in categoryRows()
        rows.Push(row)
    end for
    for each row in m.catalogRows
        rows.Push(row)
    end for
    m.model.rows = preferencesHomeRows(rows)
    publishModel()
end sub

function categoryRows() as object
    rows = []
    for each category in VProfileCategories(m.categories, m.halloween, m.profileId)
        rows.Push({id: category.id, categoryId: category.id, title: category.title, style: "landscape", items: VArray(VGet(category, "items")), category: true})
    end for
    return rows
end function

sub openDetails(item as object)
    m.history.Push(VCopy(m.model))
    m.generation += 1
    m.model = {page: "details", busy: true, message: "", details: {item: item}, episodes: [], selectedSeason: 1}
    publishModel()
    requestApi("details", "/catalog/" + VStr(item.type) + "/" + VStr(item.mediaId) + "?date=" + localDate())
end sub

sub selectSeason(season as integer)
    item = VGet(m.model.details, "item", {})
    m.model.selectedSeason = season
    m.model.busy = true
    m.model.episodes = []
    publishModel()
    requestApi("episodes", "/catalog/show/" + VStr(item.mediaId) + "/seasons/" + season.ToStr(), "GET", invalid, {season: season})
end sub

function findProgress(item as object) as object
    for each record in activeRecords(m.sync.progress, true)
        if VMediaKey(record) = VMediaKey(item) then return record
    end for
    return {}
end function

function isInMyList(item as object) as boolean
    return VFindMedia(activeRecords(m.sync.mylist, true), item) >= 0
end function

sub toggleMyList(item as object)
    record = VCopy(item)
    record.profileId = m.profileId
    record.addedAt = VNowMs()
    record.updatedAt = record.addedAt
    record.deleted = isInMyList(item)
    upsertSync("mylist", record)
    requestApi("push", "/push", "POST", {mylist: [record]})
    if m.model.page = "details" then m.model.inMyList = not record.deleted
    if m.model.page = "home" then composeHome() else publishModel()
end sub

sub upsertSync(kind as string, record as object)
    records = VArray(VGet(m.sync, kind))
    for i = records.Count() - 1 to 0 step -1
        same = VMediaKey(records[i]) = VMediaKey(record) and VGet(records[i], "profileId") = VGet(record, "profileId")
        if kind = "watched" then same = same and VGet(records[i], "season") = VGet(record, "season") and VGet(records[i], "episode") = VGet(record, "episode")
        if same then records.Delete(i)
    end for
    records.Push(record)
    m.sync[kind] = records
end sub

sub onSyncTimer()
    if m.failedPushes.Count() > 0
        retry = m.failedPushes.Shift()
        retryContext = VGet(retry, "context", {})
        if Type(retryContext) <> "roAssociativeArray" then retryContext = {}
        retryContext.attempts = retry.attempts
        requestApi("push", "/push", "POST", retry.body, retryContext)
    end if
    if m.baseUrl <> "" then requestApi("sync", "/state?since=0")
end sub

sub onViewAction()
    action = m.view.action
    if handlePreferencesAction(action) then return
    kind = VStr(VGet(action, "kind"))
    if kind = "navigate"
        navigate(VStr(VGet(action, "route"), "home"))
    else if kind = "dockDismissed"
        restoreBrowsePage()
    else if kind = "selectProfile"
        m.preferenceAvailableRows = []
        m.categories = []
        m.profileId = VStr(VGet(action, "profileId"))
        m.registry.Write("profileId", m.profileId)
        m.registry.Flush()
        navigate("home")
    else if kind = "openItem"
        openDetails(action.item)
    else if kind = "play"
        startPlayback(action.item, false)
    else if kind = "toggleMyList"
        toggleMyList(action.item)
    else if kind = "contentActions"
        m.dialogItem = action.item
        m.dialogRow = VStr(VGet(action, "rowId"))
        labels = ["Resume", "Details"]
        if m.dialogRow = "continue" then labels.Push("Remove from Continue Watching")
        showChoice("contentActions", VStr(VGet(action.item, "title")), labels)
    else if kind = "choice"
        handleChoice(Int(Val(VStr(VGet(action, "id")))))
    else if kind = "closeChoice"
        m.model.Delete("choice")
        publishModel()
    else if kind = "selectSeason"
        selectSeason(VNum(VGet(action, "season"), 1))
    else if kind = "connect"
        connectBackend()
    else if kind = "editBackend"
        openKeyboard("backend", "Velvet backend address", m.baseUrl, false)
    else if kind = "editToken"
        openKeyboard("token", "Backend token (if required)", m.token, true)
    else if kind = "search"
        openKeyboard("search", "Search movies and shows", VStr(VGet(m.model, "query")), false)
    else if kind = "createCategory"
        openCategoryComposer()
    else if kind = "categoryActions"
        categoryDialog(VStr(VGet(action, "categoryId")))
    else if kind = "playCategory"
        prepareCategory(VStr(VGet(action, "categoryId")), VBool(VGet(action, "shuffle")))
    else if kind = "deleteCategory"
        deleteCategory(VStr(VGet(action, "categoryId")))
    else if kind = "tune"
        tuneChannel(action.channel)
    else if kind = "refresh"
        if m.model.page = "profiles" or m.model.page = "setup"
            connectBackend()
        else if m.model.page = "home"
            m.catalogRows = []
            navigate("home")
        else if m.model.page = "details"
            requestApi("details", "/catalog/" + VStr(m.model.details.item.type) + "/" + VStr(m.model.details.item.mediaId))
        else
            navigate(m.model.page)
        end if
    else if kind = "back"
        goBack()
    else if kind = "exit"
        showChoice("exit", "Leave Velvet?", ["Exit", "Stay"])
    end if
end sub

sub goBack()
    if m.history.Count() > 0
        m.generation += 1
        m.model = m.history.Pop()
        publishModel()
        m.view.CallFunc("restoreFocus")
    else
        navigate("home")
    end if
end sub

sub openKeyboard(kind as string, title as string, text as string, secret as boolean)
    m.dialogKind = kind
    dialog = CreateObject("roSGNode", "StandardKeyboardDialog")
    dialog.AddFields({velvetHandled: false, velvetKind: kind, velvetContext: {epoch: m.backendEpoch, generation: m.generation, profileId: m.profileId, playGeneration: m.playGeneration}})
    dialog.title = title
    dialog.text = text
    dialog.buttons = ["Done", "Cancel"]
    dialog.textEditBox.maxTextLength = 500
    if secret
        dialog.keyboardDomain = "password"
        dialog.textEditBox.secureMode = true
    end if
    dialog.ObserveField("buttonSelected", "onKeyboardButton")
    dialog.ObserveField("close", "onKeyboardClosed")
    m.top.dialog = dialog
end sub

sub dismissScopedKeyboard()
    dialog = m.top.dialog
    if dialog = invalid then return
    if dialog.HasField("velvetHandled") then dialog.velvetHandled = true
    edit = dialog.GetField("textEditBox")
    if edit <> invalid
        edit.voiceEnabled = false
        edit.active = false
    end if
    dialog.close = true
end sub

sub onKeyboardClosed(event as object)
    dialog = event.GetRoSGNode()
    if not dialog.close then return
    dialog.textEditBox.voiceEnabled = false
    if dialog.velvetHandled then return
    dialog.velvetHandled = true
    if not VPreferencesContextCurrent(dialog.velvetContext, m.backendEpoch, m.generation, m.profileId, m.playGeneration) then return
    kind = VStr(dialog.velvetKind)
    if handlePreferencesKeyboard(kind, "", false) then return
    if kind = "categoryDraft" and m.categoryComposer.visible then m.categoryComposer.CallFunc("restoreFocus")
end sub

sub onKeyboardButton(event as object)
    dialog = event.GetRoSGNode()
    if dialog.velvetHandled then return
    selected = event.GetData()
    text = dialog.text.Trim()
    kind = VStr(dialog.velvetKind)
    dialog.velvetHandled = true
    dialog.textEditBox.voiceEnabled = false
    dialog.close = true
    if not VPreferencesContextCurrent(dialog.velvetContext, m.backendEpoch, m.generation, m.profileId, m.playGeneration) then return
    if handlePreferencesKeyboard(kind, text, selected = 0) then return
    if kind = "categoryDraft"
        if selected = 0 then m.categoryComposer.draft = text
        m.categoryComposer.CallFunc("restoreFocus")
        return
    end if
    if selected <> 0 then return
    if kind = "backend"
        base = VBackendUrl(text)
        if base = ""
            m.model.message = "Use a complete http:// or https:// backend address."
        else
            if base <> m.baseUrl
                ' An access token must never be sent automatically to a new server.
                m.token = ""
                resetBackendSession()
                m.registry.Delete("token")
                m.syncTimer.control = "stop"
                m.catalogRows = []
                m.halloween = invalid
                m.sync = {profiles: [], progress: [], watched: [], mylist: []}
            end if
            m.baseUrl = base
            m.registry.Write("backendUrl", base)
            m.registry.Flush()
            m.model.message = "Address saved. Connect when ready."
        end if
        publishModel()
    else if kind = "token"
        resetBackendSession()
        m.token = text
        m.registry.Write("token", text)
        m.registry.Flush()
        m.model.message = "Token saved."
        publishModel()
    else if kind = "search"
        if Len(text) < 2 then return
        m.generation += 1
        m.model.page = "search"
        m.model.query = text
        m.model.busy = true
        m.model.message = ""
        publishModel()
        requestApi("search", "/catalog/search?q=" + VEncode(text))
    else if kind = "category"
        if Len(text) < 3 then return
        m.model.busy = true
        m.model.message = "Creating your category…"
        publishModel()
        requestApi("generate", "/categories/generate", "POST", {prompt: text}, invalid, 180000)
    end if
end sub

sub showChoice(kind as string, title as string, buttons as object)
    m.dialogKind = kind
    items = []
    for i = 0 to buttons.Count() - 1
        items.Push({id: VStr(i), label: buttons[i]})
    end for
    m.model.choice = {title: title, items: items}
    publishModel()
end sub

sub onChoice(event as object)
    index = event.GetData()
    event.GetRoSGNode().close = true
    handleChoice(index)
end sub

sub handleChoice(index as integer)
    if handlePreferencesChoice(index) then return
    m.model.Delete("choice")
    publishModel()
    kind = m.dialogKind
    if kind = "exit" and index = 0
        endTelemetry("ended")
        deactivateHandoff()
        m.top.exitRequested = true
        print "[Velvet] exit field="; m.top.GetField("exitRequested")
    else if kind = "categoryActions"
        if index = 0 then prepareCategory(m.dialogCategory, false)
        if index = 1 then prepareCategory(m.dialogCategory, true)
        if index = 2 then deleteCategory(m.dialogCategory)
    else if kind = "contentActions"
        if index = 0 then startPlayback(m.dialogItem, false)
        if index = 1 then openDetails(m.dialogItem)
        if index = 2 and m.dialogRow = "continue"
            record = VCopy(m.dialogItem)
            record.profileId = m.profileId
            record.updatedAt = VNowMs()
            record.deleted = true
            upsertSync("progress", record)
            requestApi("push", "/push", "POST", {progress: [record]})
            composeHome()
        end if
    end if
end sub

function isBackgroundRequest(kind as string) as boolean
    return Left(kind, 4) = "hand" or Left(kind, 9) = "rokuAudio" or kind = "sync" or kind = "push" or kind = "report" or kind = "prepare" or kind = "liveStop"
end function

function findCategory(id as string) as dynamic
    for each category in VProfileCategories(m.categories, m.halloween, m.profileId)
        if category.id = id then return category
    end for
    return invalid
end function

sub categoryDialog(id as string)
    category = findCategory(id)
    if category = invalid then return
    m.dialogCategory = id
    buttons = ["Play all", "Shuffle"]
    if id <> "halloween-nostalgia" then buttons.Push("Delete category")
    showChoice("categoryActions", category.title, buttons)
end sub

sub prepareCategory(id as string, shuffle as boolean)
    category = findCategory(id)
    if category = invalid then return
    m.playGeneration += 1
    m.model.busy = true
    m.model.message = "Preparing your playlist…"
    publishModel()
    requestApi("queue", "/categories/queue", "POST", {title: category.title, items: category.items, shuffle: shuffle}, {playId: m.playGeneration, categoryId: id, profileId: m.profileId}, 150000)
end sub

sub deleteCategory(id as string)
    if id = "halloween-nostalgia" then return
    m.model.busy = true
    publishModel()
    requestApi("deleteCategory", "/categories/saved/" + VEncode(id) + "?profileId=" + VEncode(m.profileId), "DELETE")
end sub

sub applyGuide(data as object)
    now = VNowMs()
    for each channel in VArray(m.liveChannels)
        for each guide in VArray(VGet(data, "channels"))
            if VGet(guide, "channelId") = VGet(channel, "id")
                for each program in VArray(VGet(guide, "programs"))
                    startAt = VIsoMs(VGet(program, "startTime"))
                    endAt = VIsoMs(VGet(program, "endTime"))
                    if startAt <= now and endAt > now then channel.nowTitle = VStr(VGet(program, "title"))
                end for
            end if
        end for
    end for
    if m.model.page = "live"
        m.model.items = m.liveChannels
        publishModel()
    end if
end sub

sub resetBackendSession()
    resetTelemetryBackend()
    closeCategoryComposer(false)
    dismissScopedKeyboard()
    m.preferenceAvailableRows = []
    deactivateHandoff()
    m.failedPushes = []
    m.backendEpoch += 1
    m.generation += 1
    m.requestQueue = []
    for each task in m.tasks
        task.UnobserveField("result")
        task.control = "STOP"
    end for
    m.tasks = []
    m.requests = {}
    m.syncTimer.control = "stop"
    m.categories = []
    m.sync = {profiles: [], progress: [], watched: [], mylist: []}
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if m.playing
        if key = "back"
            closePlayback()
            return true
        else if key = "options"
            openPlayerOptions()
            return true
        end if
    end if
    return false
end function
