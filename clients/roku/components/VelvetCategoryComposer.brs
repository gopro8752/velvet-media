sub init()
    m.voice = m.top.FindNode("voice")
    m.voice.ObserveField("text", "voiceChanged")
    m.voice.ObserveField("isDictating", "stateChanged")
    m.buttons = [m.top.FindNode("create"), m.top.FindNode("type"), m.top.FindNode("cancel")]
    m.focusIndex = -1
    m.changingText = false
    m.voiceFocusTimer = m.top.FindNode("voiceFocusTimer")
    m.voiceFocusTimer.ObserveField("fire", "activateVoiceFocus")
end sub

sub open()
    m.top.visible = true
    m.top.opacity = 1
    m.top.busy = false
    m.top.message = ""
    m.voice.voiceEnabled = false
    m.focusIndex = -1
    m.top.SetFocus(true)
    m.voiceFocusTimer.control = "start"
    stateChanged()
end sub

sub activateVoiceFocus()
    if not m.top.visible or m.top.busy or m.focusIndex <> -1 then return
    ' Native dictation registers its focus target after the sheet is rendered.
    ' Focusing the hidden input earlier can leave the native mic hint inactive.
    m.voice.SetFocus(false)
    restoreFocus()
end sub

sub pauseVoice()
    m.voiceFocusTimer.control = "stop"
    m.voice.voiceEnabled = false
    m.voice.active = false
end sub

sub draftChanged()
    if m.changingText then return
    m.voice.text = m.top.draft
    stateChanged()
end sub

sub voiceChanged()
    m.changingText = true
    m.top.draft = m.voice.text
    m.changingText = false
    stateChanged()
end sub

sub stateChanged()
    if m.voice = invalid then return
    m.buttons[0].enabled = not m.top.busy and Len(m.top.draft.Trim()) >= 3
    m.buttons[1].enabled = not m.top.busy
    if m.top.busy
        pauseVoice()
        m.focusIndex = 2
        if m.top.visible then m.top.SetFocus(true)
        for i = 0 to m.buttons.Count() - 1
            m.buttons[i].focused = i = m.focusIndex
        end for
    end if
    hint = "Hold the microphone button on your Roku remote and describe your category."
    if m.focusIndex <> -1 then hint = "Choose Create when ready, or move up to speak again."
    if m.voice.isDictating = true and m.voice.voiceEnabled = true and m.focusIndex = -1 then hint = "Listening…"
    if m.top.message <> "" then hint = m.top.message
    if m.top.busy then hint = "Creating your category…"
    m.top.FindNode("hint").text = hint
end sub

sub restoreFocus()
    if not m.top.visible then return
    if m.top.busy then m.focusIndex = 2
    if m.focusIndex = -1
        m.voice.voiceEnabled = true
        m.voice.active = true
        m.voice.SetFocus(true)
    else
        m.voice.voiceEnabled = false
        m.voice.active = false
        m.top.SetFocus(true)
    end if
    for i = 0 to m.buttons.Count() - 1
        m.buttons[i].focused = i = m.focusIndex
    end for
    if m.focusIndex = -1 then m.top.FindNode("inputRim").opacity = 0.8 else m.top.FindNode("inputRim").opacity = 0.15
    stateChanged()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back"
        pauseVoice()
        m.top.action = {kind: "categoryClose"}
        return true
    end if
    if m.top.busy
        if key = "OK" then m.top.action = {kind: "categoryClose"}
        return true
    end if
    if key = "down"
        m.focusIndex = 0
        if not m.buttons[0].enabled then m.focusIndex = 1
        restoreFocus()
        return true
    else if key = "up"
        m.focusIndex = -1
        restoreFocus()
        return true
    else if key = "left" or key = "right"
        if m.focusIndex < 0 then return false
        stepValue = 1
        if key = "left" then stepValue = -1
        nextIndex = m.focusIndex + stepValue
        while nextIndex >= 0 and nextIndex < m.buttons.Count()
            if m.buttons[nextIndex].enabled
                m.focusIndex = nextIndex
                exit while
            end if
            nextIndex += stepValue
        end while
        restoreFocus()
        return true
    else if key = "OK"
        if m.focusIndex = -1
            m.focusIndex = 0
            if not m.buttons[0].enabled then m.focusIndex = 1
            restoreFocus()
        else if m.focusIndex = 0 and m.buttons[0].enabled
            pauseVoice()
            m.top.action = {kind: "categorySubmit", text: m.top.draft.Trim()}
        else if m.focusIndex = 1 and m.buttons[1].enabled
            pauseVoice()
            m.top.action = {kind: "categoryType", text: m.top.draft}
        else if m.focusIndex = 2
            pauseVoice()
            m.top.action = {kind: "categoryClose"}
        end if
        return true
    end if
    return false
end function
