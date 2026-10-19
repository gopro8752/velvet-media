' Pure presentation/selection policy shared by the custom player and logic specs.
' Roku track identifiers are opaque strings; never replace them with array indexes.
function VTrackOptions(tracks as dynamic, kind as string, currentId = "" as string, captionMode = "Off" as string) as object
    result = []
    seen = []
    subtitles = kind = "subtitle"
    if subtitles then result.Push({id: "subtitle:off", nativeId: "", label: "Off", subtitle: "", selected: LCase(captionMode) = "off", enabled: true})
    for each track in VArray(tracks)
        if subtitles
            nativeId = VStr(VGet(track, "TrackName"))
            name = VCleanTrackText(VGet(track, "Description"))
        else
            nativeId = VStr(VGet(track, "Track"))
            name = VCleanTrackText(VGet(track, "Name"))
        end if
        duplicate = false
        for each priorId in seen
            if priorId = nativeId then duplicate = true
        end for
        if nativeId <> "" and not duplicate
            seen.Push(nativeId)
            language = VLanguageName(VStr(VGet(track, "Language")))
            if name = "" then name = language
            if name = "" then name = "Track " + VStr(result.Count() + 1)
            detail = ""
            if language <> "" and Instr(1, LCase(name), LCase(language)) = 0 then detail = language
            if VBool(VGet(track, "HasAccessibilityDescription"))
                if subtitles then detail = VJoinDetail(detail, "Includes sound descriptions") else detail = VJoinDetail(detail, "Audio description")
            end if
            if VBool(VGet(track, "HasAccessibilityCaption")) then detail = VJoinDetail(detail, "Closed captions")
            selected = nativeId = currentId
            if subtitles and LCase(captionMode) = "off" then selected = false
            result.Push({id: kind + ":" + nativeId, nativeId: nativeId, label: name, subtitle: detail, selected: selected, enabled: true})
        end if
    end for
    return result
end function

function VCleanTrackText(value as dynamic) as string
    text = VStr(value)
    text = text.Replace(Chr(10), " ").Replace(Chr(13), " ").Replace(Chr(9), " ")
    ' Roku's MKV audio parser can expose an internal uniqueness wrapper as Name.
    ' Clean the display label only; selection always retains the original Track ID.
    unique = CreateObject("roRegex", "^#uniq:(.*)[(][0-9]+[)]$", "i").Match(text)
    if unique.Count() > 1 then text = unique[1]
    return Left(text.Trim(), 160)
end function

function VLanguageName(code as string) as string
    code = LCase(code.Trim())
    names = {en: "English", eng: "English", es: "Spanish", spa: "Spanish", fr: "French", fra: "French", fre: "French", de: "German", deu: "German", ger: "German", it: "Italian", ita: "Italian", ja: "Japanese", jpn: "Japanese", ko: "Korean", kor: "Korean", zh: "Chinese", zho: "Chinese", chi: "Chinese", pt: "Portuguese", por: "Portuguese", ar: "Arabic", ara: "Arabic", hi: "Hindi", hin: "Hindi", ru: "Russian", rus: "Russian", nl: "Dutch", nld: "Dutch", dut: "Dutch", sv: "Swedish", swe: "Swedish", da: "Danish", dan: "Danish", no: "Norwegian", nor: "Norwegian", fi: "Finnish", fin: "Finnish", pl: "Polish", pol: "Polish"}
    base = code.Tokenize("-_")[0]
    if base = invalid or base = "und" or base = "zxx" then return ""
    known = names.Lookup(base)
    if known <> invalid then return known
    return UCase(code)
end function

function VJoinDetail(leftText as string, rightText as string) as string
    if leftText = "" then return rightText
    if rightText = "" then return leftText
    return leftText + " · " + rightText
end function

function VPreferredSubtitleTrack(tracks as dynamic) as string
    fallback = ""
    for each track in VArray(tracks)
        nativeId = VStr(VGet(track, "TrackName"))
        if nativeId <> ""
            if fallback = "" then fallback = nativeId
            language = LCase(VStr(VGet(track, "Language")))
            description = LCase(VStr(VGet(track, "Description")))
            if language = "en" or language = "eng" or Left(language, 3) = "en-" or Instr(1, description, "english") > 0 then return nativeId
        end if
    end for
    return fallback
end function

' Match Android/iOS exactly: the source-provided binge key is the identity.
' A filename suffix or source/addon name is not evidence of a release group.
function VReleaseGroup(bingeGroup as dynamic) as dynamic
    if Type(bingeGroup) <> "String" and Type(bingeGroup) <> "roString" then return invalid
    key = VStr(bingeGroup).Trim()
    if key = "" or Len(key) > 512 then return invalid
    for i = 1 to Len(key)
        character = Asc(Mid(key, i, 1))
        if character < 32 or (character >= 127 and character <= 159) then return invalid
    end for
    label = key
    if Left(key, 7) = "velvet-"
        label = Mid(key, 8)
        unidentified = "|rls|unknown|none|null|mkv|mp4|avi|mov|ts|m2ts|web|dl|hd|ma|bluray|webrip|hdtv|remux|proper|repack|x264|x265|h264|h265|hevc|avc|av1|aac|ac3|eac3|dts|truehd|atmos|hdr|hdr10|dv|2160p|1080p|720p|480p|"
        if label = "" or Instr(1, unidentified, "|" + LCase(label) + "|") > 0 then return invalid
    end if
    return {key: key, label: label}
end function

function VReleaseGroupFromStream(stream as dynamic) as dynamic
    key = VGet(VGet(stream, "behaviorHints", {}), "bingeGroup")
    if key = invalid then key = VGet(stream, "bingeGroup")
    return VReleaseGroup(key)
end function

function VFilterBlockedStreams(streams as dynamic, groups as dynamic) as object
    result = []
    for each stream in VArray(streams)
        group = VReleaseGroupFromStream(stream)
        blocked = false
        if group <> invalid
            for each stored in VArray(groups)
                if group.key = VStr(VGet(stored, "key")) then blocked = true
            end for
        end if
        if not blocked then result.Push(stream)
    end for
    return result
end function

function VStreamDisplay(stream as dynamic, index = 0 as integer) as object
    hints = VGet(stream, "behaviorHints", {})
    raw = LCase(VStr(VGet(hints, "filename")) + " " + VStr(VGet(stream, "title")) + " " + VStr(VGet(stream, "name")))
    compact = CreateObject("roRegex", "[^a-z0-9]", "i").ReplaceAll(raw, "")
    label = "Stream " + VStr(index + 1)
    if Instr(1, raw, "2160") > 0 or CreateObject("roRegex", "(^|[^a-z0-9])4k([^a-z0-9]|$)", "i").IsMatch(raw)
        label = "4K"
    else if Instr(1, raw, "1080") > 0
        label = "1080p"
    else if Instr(1, raw, "720") > 0
        label = "720p"
    else if Instr(1, raw, "480") > 0
        label = "480p"
    end if
    if Instr(1, compact, "dolbyvision") > 0 or CreateObject("roRegex", "(^|[^a-z0-9])(dv|dovi)([^a-z0-9]|$)", "i").IsMatch(raw)
        label = VJoinDetail(label, "Dolby Vision")
    else if Instr(1, raw, "hdr10+") > 0 or Instr(1, compact, "hdr10plus") > 0
        label = VJoinDetail(label, "HDR10+")
    else if Instr(1, raw, "hdr") > 0
        label = VJoinDetail(label, "HDR")
    end if
    codec = ""
    if Instr(1, compact, "hevc") > 0 or Instr(1, compact, "h265") > 0 or Instr(1, compact, "x265") > 0
        codec = "HEVC"
    else if Instr(1, compact, "h264") > 0 or Instr(1, compact, "x264") > 0 or Instr(1, compact, "avc") > 0
        codec = "H.264"
    else if Instr(1, compact, "av1") > 0
        codec = "AV1"
    end if
    audio = ""
    if Instr(1, compact, "truehd") > 0
        audio = "TrueHD"
    else if Instr(1, compact, "ddp") > 0 or Instr(1, compact, "eac3") > 0
        audio = "Dolby Digital Plus"
    else if Instr(1, compact, "ac3") > 0
        audio = "Dolby Digital"
    else if Instr(1, compact, "dtshd") > 0
        audio = "DTS-HD"
    else if Instr(1, compact, "dts") > 0
        audio = "DTS"
    else if Instr(1, compact, "aac") > 0
        audio = "AAC"
    else if Instr(1, compact, "flac") > 0
        audio = "FLAC"
    end if
    channels = CreateObject("roRegex", "(7[.]1|5[.]1|2[.]0)", "i").Match(raw)
    if channels.Count() > 0
        if audio <> "" then audio += " "
        audio += channels[0]
    end if
    if Instr(1, compact, "atmos") > 0 then audio = VJoinDetail(audio, "Atmos")
    detail = VJoinDetail(codec, audio)
    size = VNum(VGet(hints, "videoSize"))
    if size > 0 then detail = VJoinDetail(detail, VPlayerSizeLabel(size))
    return {label: label, subtitle: detail}
end function

function VPlayerSizeLabel(bytes as dynamic) as string
    divisor = 1048576#
    unit = " MB"
    if bytes >= 1073741824#
        divisor = 1073741824#
        unit = " GB"
    end if
    rounded = Fix(bytes / divisor * 10 + 0.5)
    whole = Fix(rounded / 10)
    fraction = rounded mod 10
    value = VStr(CInt(whole))
    if fraction > 0 then value += "." + VStr(CInt(fraction))
    return value + unit
end function

' Observe a position below the restore point before ending temporary captions:
' the first callback after a seek can still contain the pre-seek timestamp.
function VReplayBegin(position as dynamic, captionMode as string, subtitleId as string, tracks as dynamic, prior = invalid as dynamic, seconds = 10 as integer) as object
    position = VNum(position)
    target = position - seconds
    if target < 0 then target = 0
    restoreMode = captionMode
    restoreTrack = subtitleId
    restoreAt = position
    if Type(prior) = "roAssociativeArray" and not VBool(VGet(prior, "readyToRestore"))
        restoreMode = VStr(VGet(prior, "restoreMode"), captionMode)
        restoreTrack = VStr(VGet(prior, "restoreTrack"), subtitleId)
        if VNum(VGet(prior, "restoreAt")) > restoreAt then restoreAt = VNum(prior.restoreAt)
    end if
    trackId = subtitleId
    if trackId = "" or LCase(captionMode) = "off" then trackId = VPreferredSubtitleTrack(tracks)
    return {target: target, restoreAt: restoreAt, restoreMode: restoreMode, restoreTrack: restoreTrack, trackId: trackId, enableCaptions: trackId <> "", seekConfirmed: position <= 0, readyToRestore: false}
end function

function VReplayAdvance(state as dynamic, position as dynamic) as dynamic
    if Type(state) <> "roAssociativeArray" then return invalid
    result = VCopy(state)
    position = VNum(position)
    if position < VNum(result.restoreAt) - 0.5 then result.seekConfirmed = true
    result.readyToRestore = VBool(result.seekConfirmed) and position >= VNum(result.restoreAt)
    return result
end function
