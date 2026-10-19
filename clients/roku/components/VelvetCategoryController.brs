' Category composition stays in-app; the keyboard is opened only by Type instead.
sub initCategoryComposer()
    m.categoryComposer = m.top.FindNode("categoryComposer")
    m.categoryComposer.ObserveField("action", "onCategoryComposerAction")
    m.categoryGeneration = 0
end sub

sub openCategoryComposer()
    dialog = m.top.dialog
    if dialog <> invalid
        edit = dialog.GetField("textEditBox")
        if edit <> invalid then edit.voiceEnabled = false
    end if
    m.categoryGeneration += 1
    m.categoryComposer.draft = ""
    m.categoryComposer.CallFunc("open")
end sub

sub closeCategoryComposer(restore = true as boolean)
    if m.categoryComposer = invalid then return
    m.categoryGeneration += 1
    m.categoryComposer.CallFunc("pauseVoice")
    m.categoryComposer.visible = false
    m.categoryComposer.busy = false
    dialog = m.top.dialog
    if dialog <> invalid and VStr(dialog.GetField("velvetKind")) = "categoryDraft"
        dialog.velvetHandled = true
        dialog.textEditBox.voiceEnabled = false
        dialog.textEditBox.active = false
        dialog.close = true
    end if
    if restore then restoreBrowsePage()
end sub

sub onCategoryComposerAction(event as object)
    if not m.categoryComposer.visible then return
    action = event.GetData()
    kind = VStr(VGet(action, "kind"))
    if kind = "categoryClose"
        closeCategoryComposer()
    else if kind = "categoryType"
        if m.categoryComposer.busy then return
        m.categoryComposer.CallFunc("pauseVoice")
        openKeyboard("categoryDraft", "Describe your category", VStr(VGet(action, "text")), false)
    else if kind = "categorySubmit"
        prompt = VStr(VGet(action, "text")).Trim()
        if Len(prompt) < 3 or m.categoryComposer.busy then return
        if activeProfile().Count() = 0 then closeCategoryComposer() : return
        m.categoryGeneration += 1
        m.categoryComposer.busy = true
        requestApi("categoryGenerate", "/categories/generate", "POST", {prompt: prompt}, {categoryId: m.categoryGeneration, profileId: m.profileId}, 180000)
    end if
end sub

function handleCategoryResponse(kind as string, result as object, context as dynamic) as boolean
    if kind <> "categoryGenerate" and kind <> "categorySave" then return false
    if VNum(VGet(context, "categoryId"), -1) <> m.categoryGeneration or VStr(VGet(context, "profileId")) <> m.profileId then return true
    if not m.categoryComposer.visible then return true
    if activeProfile().Count() = 0 then closeCategoryComposer() : return true
    if not VBool(VGet(result, "ok"))
        m.categoryComposer.busy = false
        m.categoryComposer.message = VStr(VGet(result, "error"), "Could not create this category. Please try again.")
        m.categoryComposer.CallFunc("restoreFocus")
        return true
    end if
    data = VGet(result, "data", {})
    if kind = "categoryGenerate"
        if VArray(VGet(data, "items")).Count() = 0
            m.categoryComposer.busy = false
            m.categoryComposer.message = "No matches found. Try another description."
            m.categoryComposer.CallFunc("restoreFocus")
        else
            requestApi("categorySave", "/categories/saved", "POST", {profileId: m.profileId, category: data}, context)
        end if
    else
        closeCategoryComposer(false)
        navigate("home")
    end if
    return true
end function
