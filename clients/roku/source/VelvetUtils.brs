function VGet(value as dynamic, key as string, fallback = invalid as dynamic) as dynamic
    if Type(value) <> "roAssociativeArray" then return fallback
    ' JSON objects preserve case on native Roku, while dot assignments lowercase
    ' field names. Prefer a newer dot-written value and then the wire spelling.
    result = value.Lookup(LCase(key))
    if result = invalid then result = value.Lookup(key)
    if result = invalid then return fallback
    return result
end function

function VStr(value as dynamic, fallback = "" as string) as string
    if value = invalid then return fallback
    kind = Type(value)
    if kind = "String" or kind = "roString" then return value
    if kind = "Integer" or kind = "roInt" or kind = "roInteger" or kind = "LongInteger" or kind = "roLongInteger" or kind = "roLongInt" or kind = "Float" or kind = "roFloat" or kind = "Double" or kind = "roDouble" then return value.ToStr()
    return fallback
end function

function VNum(value as dynamic, fallback = 0 as dynamic) as dynamic
    if value = invalid then return fallback
    kind = Type(value)
    if kind = "Integer" or kind = "roInt" or kind = "roInteger" or kind = "LongInteger" or kind = "roLongInteger" or kind = "roLongInt" or kind = "Float" or kind = "roFloat" or kind = "Double" or kind = "roDouble" then return value
    if kind = "String" or kind = "roString"
        if value.Trim() <> "" then return Val(value)
    end if
    return fallback
end function

function VArray(value as dynamic) as object
    if Type(value) = "roArray" then return value
    return []
end function

function VCopy(value as dynamic) as dynamic
    if value = invalid then return invalid
    return ParseJson(FormatJson(value))
end function

function VBool(value as dynamic) as boolean
    if Type(value) = "Boolean" or Type(value) = "roBoolean" then return value
    return false
end function

function VEncode(value as dynamic) as string
    return VStr(value).EncodeUriComponent()
end function

function VMediaKey(item as dynamic) as string
    return VStr(VGet(item, "type")) + ":" + VStr(VGet(item, "mediaId"))
end function

function VNowMs() as double
    now = CreateObject("roDateTime")
    return now.AsSeconds() * 1000# + now.GetMilliseconds()
end function

function VMediaMilliseconds(seconds as dynamic) as integer
    ' Shared progress readers use integer milliseconds, never fractional JSON values.
    value = Fix(VNum(seconds) * 1000#)
    if value < 0 then return 0
    if value > 2147483647 then return 2147483647
    return CInt(value)
end function

function VBackendUrl(value as string) as string
    value = value.Trim()
    while Right(value, 1) = "/"
        value = Left(value, Len(value) - 1)
    end while
    lower = LCase(value)
    if Left(lower, 7) <> "http://" and Left(lower, 8) <> "https://" then return ""
    schemeEnd = Instr(1, value, "://") + 3
    hostAndPath = Mid(value, schemeEnd)
    if hostAndPath = "" then return ""
    if Left(hostAndPath, 1) = "/" then return ""
    for i = 1 to Len(value)
        if Asc(Mid(value, i, 1)) < 33 then return ""
    end for
    if Instr(1, hostAndPath, "@") > 0 or Instr(1, value, "?") > 0 or Instr(1, value, "#") > 0 or Instr(1, value, " ") > 0 then return ""
    return value
end function

function VOrigin(value as string) as string
    i = Instr(1, value, "://")
    if i = 0 then return ""
    tail = Mid(value, i + 3)
    slash = Instr(1, tail, "/")
    if slash > 0 then tail = Left(tail, slash - 1)
    return LCase(Left(value, i + 2) + tail)
end function

function VBackendMediaUrl(base as string, path as string) as string
    if Left(path, 1) = "/" and Left(path, 2) <> "//" then return base + path
    if VOrigin(path) <> "" and VOrigin(path) = VOrigin(base) then return path
    return ""
end function

function VStreamKey(item as dynamic) as string
    key = VStr(VGet(item, "imdbId"))
    if Left(key, 2) <> "tt" then key = "tmdb:" + VStr(VGet(item, "mediaId"))
    if VGet(item, "type") = "show"
        key += ":" + VStr(VGet(item, "season", 1)) + ":" + VStr(VGet(item, "episode", 1))
    end if
    return key
end function

function VStreamId(url as string) as string
    marker = Instr(1, url, "/stream/")
    if marker = 0 then return ""
    result = Mid(url, marker + 8)
    query = Instr(1, result, "?")
    if query > 0 then result = Left(result, query - 1)
    if Instr(1, result, "/") > 0 then return ""
    return result
end function

function VFindMedia(items as dynamic, item as dynamic) as integer
    key = VMediaKey(item)
    for i = 0 to VArray(items).Count() - 1
        if VMediaKey(items[i]) = key then return i
    end for
    return -1
end function

function VRegisteredStreamUrl(base as string, url as string) as string
    sid = VStreamId(url)
    if sid = "" or Len(sid) > 128 then return ""
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    for i = 1 to Len(sid)
        if Instr(1, allowed, Mid(sid, i, 1)) = 0 then return ""
    end for
    ' Reuse only the registered ID when a LAN server advertises its public host.
    ' Playback credentials must never follow an arbitrary source URL.
    return base + "/stream/" + sid
end function

function VIsoMs(value as dynamic) as double
    text = VStr(value)
    if Len(text) < 20 or Mid(text, 5, 1) <> "-" then return 0
    date = CreateObject("roDateTime")
    date.FromISO8601String(text)
    return date.AsSeconds() * 1000#
end function

function VSyncKey(kind as string, record as object) as string
    if kind = "profiles" then return VStr(VGet(record, "id"))
    key = VStr(VGet(record, "profileId")) + ":" + VMediaKey(record)
    if kind = "watched" then key = VStr(VGet(record, "profileId")) + ":" + VStr(VGet(record, "mediaId")) + ":" + VStr(VGet(record, "season")) + ":" + VStr(VGet(record, "episode"))
    return key
end function

function VMergeSync(local as object, remote as object) as object
    merged = {}
    for each kind in ["profiles", "progress", "watched", "mylist"]
        records = {}
        for each record in VArray(VGet(local, kind))
            records[VSyncKey(kind, record)] = record
        end for
        for each record in VArray(VGet(remote, kind))
            key = VSyncKey(kind, record)
            prior = records.Lookup(key)
            if prior = invalid
                records[key] = record
            else if VNum(VGet(record, "updatedAt")) >= VNum(VGet(prior, "updatedAt"))
                records[key] = record
            end if
        end for
        list = []
        for each key in records
            list.Push(records[key])
        end for
        merged[kind] = list
    end for
    return merged
end function

function VNewestFirst(records as object, field as string) as object
    result = []
    for each record in records
        result.Push(record)
        i = result.Count() - 1
        while i > 0
            if VNum(VGet(record, field)) <= VNum(VGet(result[i - 1], field)) then exit while
            result[i] = result[i - 1]
            result[i - 1] = record
            i -= 1
        end while
    end for
    return result
end function

function VWireValue(value as dynamic, names = invalid as dynamic) as dynamic
    ' Native BrightScript lowercases unquoted literal/dot-assignment keys.
    ' Preserve the backend's camelCase JSON contract independently of that behavior.
    if names = invalid
        names = {}
        for each name in ["profileId", "mediaId", "imdbId", "posterUrl", "backdropUrl", "logoUrl", "episodeTitle", "positionMs", "durationMs", "createdAt", "updatedAt", "addedAt", "watchedAt", "channelId", "categoryId", "stillUrl", "runtimeMinutes", "airDate", "buttonIsDisabled", "deviceId", "sessionId", "deviceName", "profileName", "appVersion", "playedMs", "bufferedMs", "errorCount", "sourceSwitches", "startupMs", "telemetryVersion", "buildChannel", "sourceSwitchAttempts", "successfulSourceSwitches", "automaticSwitchAttempts", "manualSwitchAttempts", "automaticSourceSwitches", "manualSourceSwitches", "rebufferCount", "rebufferedMs", "maxRebufferMs", "seekCount", "bufferedPositionMs", "playbackSessionId"]
            names.AddReplace(LCase(name), name)
        end for
    end if
    if Type(value) = "roAssociativeArray"
        output = {}
        for each key in value
            wireKey = names.Lookup(LCase(key))
            if wireKey = invalid then wireKey = key
            output.AddReplace(wireKey, VWireValue(VGet(value, key), names))
        end for
        return output
    else if Type(value) = "roArray"
        output = []
        for each item in value
            output.Push(VWireValue(item, names))
        end for
        return output
    end if
    return value
end function

' Playback attribution is only attached to an exact owned stream resource.
' The original selected URL stays untouched for handoff and source identity.
function VAttributedMediaUrl(base as string, url as string, session as string) as string
    if VOrigin(base) = "" or VOrigin(base) <> VOrigin(url) or Instr(1, url, "#") > 0 then return url
    if Len(session) < 1 or Len(session) > 80 then return url
    validSession = CreateObject("roRegex", "^[A-Za-z0-9-]+$", "")
    if not validSession.IsMatch(session) then return url
    pieces = url.Split("?")
    validPath = CreateObject("roRegex", "/stream/[0-9a-f]{16}$", "")
    if not validPath.IsMatch(pieces[0]) then return url
    query = []
    if pieces.Count() > 1
        for each part in pieces[1].Split("&")
            name = part.Split("=")[0]
            if name <> "playbackSessionId" and part <> "" then query.Push(part)
        end for
    end if
    query.Push("playbackSessionId=" + VEncode(session))
    return pieces[0] + "?" + query.Join("&")
end function
