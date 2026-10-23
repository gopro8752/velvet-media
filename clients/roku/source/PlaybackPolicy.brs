' Compatibility filtering is Roku-only; the server's quality ranking stays intact.
function VStartupStatus(stream as dynamic) as string
    status = VStr(VGet(VGet(VGet(stream, "behaviorHints", {}), "velvetSourceReadiness", {}), "status"))
    if status = "ready" or status = "unavailable" then return status
    return "unverified"
end function

function VStartupOrderedStreams(streams as dynamic) as object
    ordered = []
    for each status in ["ready", "unverified", "unavailable"]
        for each stream in VArray(streams)
            if VStartupStatus(stream) = status then ordered.Push(stream)
        end for
    end for
    return ordered
end function

function VStartupQualityStreams(streams as dynamic, preferred as string) as object
    buckets = {"2160p": [], "1080p": [], "720p": [], "480p": [], "unknown": []}
    for each stream in VArray(streams)
        description = LCase(VStr(VGet(VGet(stream, "behaviorHints", {}), "filename")) + " " + VStr(VGet(stream, "title")) + " " + VStr(VGet(stream, "name")))
        quality = "unknown"
        if Instr(1, description, "2160") > 0 or Instr(1, description, "4k") > 0
            quality = "2160p"
        else if Instr(1, description, "1080") > 0
            quality = "1080p"
        else if Instr(1, description, "720") > 0
            quality = "720p"
        else if Instr(1, description, "480") > 0
            quality = "480p"
        end if
        buckets[quality].Push(stream)
    end for
    ordered = []
    qualities = ["2160p", "1080p", "720p", "480p", "unknown"]
    if buckets.DoesExist(preferred)
        for each stream in buckets[preferred]
            ordered.Push(stream)
        end for
    end if
    for each quality in qualities
        if quality <> preferred
            for each stream in buckets[quality]
                ordered.Push(stream)
            end for
        end if
    end for
    return VStartupOrderedStreams(ordered)
end function

function VAutomaticSourceIndex(streams as object, attempted as object) as integer
    for each status in ["ready", "unverified"]
        for index = 0 to streams.Count() - 1
            stream = streams[index]
            if VStartupStatus(stream) = status and not attempted.DoesExist(VStr(VGet(stream, "url"))) then return index
        end for
    end for
    return -1
end function

sub VApplyStartupReadiness(streams as object, readiness as object)
    for each stream in streams
        status = readiness.Lookup(VStreamId(VStr(VGet(stream, "url"))))
        if status <> invalid
            if VGet(stream, "behaviorHints") = invalid then stream.behaviorHints = {}
            stream.behaviorHints.velvetSourceReadiness = status
        end if
    end for
end sub

function VUhdEligible(videoMode as string, modelType as string, decodesUhd as boolean, hdcp22 as boolean) as boolean
    ' The decoder alone can report UHD support while its active output is 1080p.
    ' Roku TVs have no external HDMI output to validate; STBs require HDCP 2.2.
    return decodesUhd and Left(LCase(videoMode.Trim()), 5) = "2160p" and (UCase(modelType) = "TV" or hdcp22)
end function

function VCompatibleStreams(streams as dynamic, supportsHevc as boolean, supportsUhd as boolean, item = invalid as dynamic, allowAudioConversion = false as boolean) as object
    preferred = []
    fallback = []
    for each stream in VArray(streams)
        hints = VGet(stream, "behaviorHints", {})
        title = LCase(VStr(VGet(hints, "filename")) + " " + VStr(VGet(stream, "name")) + " " + VStr(VGet(stream, "title")))
        incompatibleVideo = false
        if VGet(item, "type") = "show" and not VExactEpisodeRelease(stream, item) then incompatibleVideo = true
        if not supportsHevc and (Instr(1, title, "hevc") > 0 or Instr(1, title, "h265") > 0 or Instr(1, title, "h.265") > 0 or Instr(1, title, "x265") > 0) then incompatibleVideo = true
        if not supportsUhd and (Instr(1, title, "2160") > 0 or Instr(1, title, "4k") > 0) then incompatibleVideo = true
        if Instr(1, title, "3d") > 0 or Instr(1, title, "av1") > 0 then incompatibleVideo = true
        if not incompatibleVideo
            audioTags = title.Replace(".", "").Replace("-", "").Replace(" ", "").Replace(":", "").Replace("_", "")
            incompatibleAudio = Instr(1, audioTags, "truehd") > 0 or Instr(1, audioTags, "dtshd") > 0 or Instr(1, audioTags, "dtsx") > 0
            if incompatibleAudio
                fallback.Push(stream)
                if allowAudioConversion then preferred.Push(stream)
            else
                preferred.Push(stream)
            end if
        end if
    end for
    ' Unsupported lossless-only candidates are never silently selected. The UI can
    ' explain why another release is needed instead of starting a silent video.
    return {streams: preferred, incompatibleAudio: fallback.Count()}
end function

function VCompactTitle(value as string) as string
    return CreateObject("roRegex", "[^a-z0-9]", "i").ReplaceAll(LCase(value), "")
end function

function VExactEpisodeRelease(stream as object, item as object) as boolean
    filename = VStr(VGet(VGet(stream, "behaviorHints", {}), "filename"))
    if filename = "" then return false
    coordinates = CreateObject("roRegex", "s([0-9]+)[ ._-]*e([0-9]+)", "i").Match(filename)
    if coordinates.Count() = 0 then coordinates = CreateObject("roRegex", "([0-9]+)x([0-9]+)", "i").Match(filename)
    if coordinates.Count() < 3 then return false
    if Val(coordinates[1]) <> VNum(VGet(item, "season")) or Val(coordinates[2]) <> VNum(VGet(item, "episode")) then return false
    marker = Instr(1, LCase(filename), LCase(coordinates[0]))
    prefix = Left(filename, marker - 1)
    prefix = CreateObject("roRegex", "^\[[^\]]+\][ ._-]*", "i").ReplaceAll(prefix, "")
    expected = VCompactTitle(VStr(VGet(item, "title")))
    actual = VCompactTitle(prefix)
    if expected = "" then return false
    matchesTitle = actual = expected or actual = expected + VStr(VGet(item, "year"))
    if not matchesTitle then return false
    tail = Mid(filename, marker + Len(coordinates[0]))
    multi = CreateObject("roRegex", "^[ ._+&/-]*(e[0-9]|s[0-9]+[ ._-]*e[0-9]|[0-9]+x[0-9]|[+&/-][0-9]{1,3}([^0-9]|$))", "i").IsMatch(tail)
    return not multi
end function

function VStreamFormat(stream as dynamic) as string
    hints = VGet(stream, "behaviorHints", {})
    filename = LCase(VStr(VGet(hints, "filename")))
    if Right(filename, 4) = ".mkv" then return "mkv"
    if Right(filename, 5) = ".webm" then return "mkv"
    if Instr(1, LCase(VStr(VGet(stream, "url"))), ".m3u8") > 0 then return "hls"
    if Right(filename, 4) = ".mp4" or Right(filename, 4) = ".m4v" or Right(filename, 4) = ".mov" then return "mp4"
    ' Usenet release names normally omit the container; native testing confirms
    ' Matroska is the useful first attempt. The player can retry MP4 if needed.
    return "mkv"
end function

function VQueueNext(index as integer, count as integer, direction as integer) as integer
    if count <= 0 then return -1
    if direction < 0
        if index <= 0 then return -1
        return index - 1
    end if
    return (index + 1) mod count
end function

function VShouldSaveProgress(positionMs as dynamic, durationMs as dynamic, inQueue as boolean, isLive as boolean) as boolean
    return not inQueue and not isLive and positionMs >= 1000 and durationMs > 0
end function

function VCompleted(positionMs as dynamic, durationMs as dynamic) as boolean
    if durationMs <= 0 then return false
    return positionMs >= durationMs * 0.95 or (durationMs - positionMs <= 90000 and positionMs > durationMs * 0.8)
end function

function VReachedPlaybackEnd(position as dynamic, duration as dynamic) as boolean
    ' A decoder's premature EOF/error must not mark an episode watched or skip it.
    return duration > 0 and position > 0 and position >= duration - 5
end function
