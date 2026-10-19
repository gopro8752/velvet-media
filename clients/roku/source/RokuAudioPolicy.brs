function VRokuAudioHint(stream as dynamic) as string
    text = LCase(VStr(VGet(stream, "title")) + " " + VStr(VGet(stream, "name")) + " " + VStr(VGet(VGet(stream, "behaviorHints", {}), "filename")))
    compact = CreateObject("roRegex", "[^a-z0-9]", "i").ReplaceAll(text, "")
    if Instr(1, compact, "truehd") > 0 then return "truehd"
    if Instr(1, compact, "dtshd") > 0 or Instr(1, compact, "dtsx") > 0 then return "dtshd"
    if Instr(1, compact, "dts") > 0 then return "dts"
    if Instr(1, compact, "eac3") > 0 or Instr(1, compact, "ddp") > 0 then return "eac3"
    if Instr(1, compact, "ac3") > 0 then return "ac3"
    if Instr(1, compact, "flac") > 0 then return "flac"
    if Instr(1, compact, "opus") > 0 then return "opus"
    if Instr(1, compact, "aac") > 0 then return "aac"
    return ""
end function

function VRokuAudioSessionId(value as dynamic) as string
    id = VStr(value)
    if not CreateObject("roRegex", "^[a-fA-F0-9]{32}$", "").IsMatch(id) then return ""
    return id
end function

function VRokuAudioTimeline(nativeSeconds as dynamic, sourceOffsetMs as dynamic, durationMs as dynamic) as double
    position = VNum(nativeSeconds) + VNum(sourceOffsetMs) / 1000#
    if position < 0 then position = 0
    duration = VNum(durationMs) / 1000#
    if duration > 0 and position > duration then position = duration
    return position
end function

function VRokuAudioNativeStart(requestedMs as dynamic, offsetMs as dynamic) as integer
    return Int(VRokuAudioNativeTarget(requestedMs, offsetMs))
end function

function VRokuAudioNativeTarget(requestedMs as dynamic, offsetMs as dynamic) as double
    seconds = (VNum(requestedMs) - VNum(offsetMs)) / 1000#
    if seconds < 0 then seconds = 0
    return seconds
end function

function VRokuAudioRenderedPosition(info as dynamic, clipId as dynamic) as double
    if VNum(VGet(info, "epoch"), -1) <> 0 then return -1#
    if VNum(VGet(info, "clip_id"), -1) <> VNum(clipId, -2) then return -1#
    return VNum(VGet(info, "video"), -1)
end function

function VRokuAudioStartupAction(target as double, issued as boolean, state as string, position as double, settled = false as boolean) as string
    if target < 0 then return "ready"
    if state <> "playing" and state <> "paused" then return "wait"
    if not issued then return "seek"
    if not settled
        if state = "paused" then return "resume"
        return "wait"
    end if
    ' A keyframe before the target is preroll; a jump to the live edge is not
    ' success either. Allow only normal position-notification/frame rounding.
    if position >= target - 0.03 and position <= target + 1 then return "ready"
    if state = "paused" then return "resume"
    return "wait"
end function

function VRokuAudioTrackOptions(tracks as dynamic, selectedIndex as dynamic) as object
    items = []
    for each track in VArray(tracks)
        index = VNum(VGet(track, "index"), -1)
        if index >= 0
            name = VCleanTrackText(VGet(track, "title"))
            language = VLanguageName(VStr(VGet(track, "language")))
            if name = "" then name = language
            if name = "" then name = "Audio track " + VStr(items.Count() + 1)
            detail = UCase(VStr(VGet(track, "codec")))
            channels = VNum(VGet(track, "channels"))
            if channels > 0 then detail = VJoinDetail(detail, VStr(channels) + " channels")
            if language <> "" and Instr(1, LCase(name), LCase(language)) = 0 then detail = VJoinDetail(detail, language)
            items.Push({id: "rokuAudio:" + VStr(index), nativeId: VStr(index), label: name, subtitle: detail, selected: index = VNum(selectedIndex, -1), enabled: true, icon: "audio"})
        end if
    end for
    return items
end function

function VRokuPreferredAudioIndex(tracks as dynamic, preferredLabel as string) as integer
    options = VRokuAudioTrackOptions(tracks, -1)
    for each option in options
        if option.label = preferredLabel then return Int(Val(option.nativeId))
    end for
    if options.Count() > 0 then return Int(Val(options[0].nativeId))
    return -1
end function

function VRokuSubtitleTrackOptions(tracks as dynamic, selectedIndex as dynamic, captionsOn as boolean) as object
    items = [{id: "rokuSubtitle:off", nativeId: "", label: "Off", subtitle: "", selected: not captionsOn, enabled: true}]
    seen = {}
    for each track in VArray(tracks)
        index = VNum(VGet(track, "index"), -1)
        codec = LCase(VStr(VGet(track, "codec")))
        supported = Instr(1, "|subrip|srt|ass|ssa|webvtt|mov_text|text|", "|" + codec + "|") > 0 and codec <> ""
        if index >= 0 and supported and not seen.DoesExist(VStr(index))
            seen[VStr(index)] = true
            name = VCleanTrackText(VGet(track, "title"))
            language = VLanguageName(VStr(VGet(track, "language")))
            if name = "" then name = language
            if name = "" then name = "Subtitle track " + VStr(items.Count())
            detail = ""
            if language <> "" and Instr(1, LCase(name), LCase(language)) = 0 then detail = language
            items.Push({id: "rokuSubtitle:" + VStr(index), nativeId: VStr(index), label: name, subtitle: detail, selected: captionsOn and index = VNum(selectedIndex, -1), enabled: true, icon: "captions"})
        end if
    end for
    return items
end function

function VRokuPreferredSubtitleIndex(tracks as dynamic, preferredLabel as string) as integer
    options = VRokuSubtitleTrackOptions(tracks, -1, false)
    for each option in options
        if option.nativeId <> "" and option.label = preferredLabel then return Int(Val(option.nativeId))
    end for
    for each option in options
        if option.nativeId <> "" and Instr(1, LCase(option.label + " " + option.subtitle), "english") > 0 then return Int(Val(option.nativeId))
    end for
    if options.Count() > 1 then return Int(Val(options[1].nativeId))
    return -1
end function

function VRokuAudioPlaybackPath(session as string, path as string) as boolean
    if VRokuAudioSessionId(session) = "" then return false
    prefix = "/roku/audio/" + session + "/"
    return path = prefix + "index.m3u8" or path = prefix + "master.m3u8"
end function
