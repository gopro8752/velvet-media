' Pure guide normalization. Listings never create playback history or tune a channel.
function VGuideEpoch(value as Dynamic) as Double
    value = VStr(value)
    if not CreateObject("roRegex", "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$", "").IsMatch(value) then return -1
    date = CreateObject("roDateTime")
    ' Normalize offsets ourselves: Roku releases differ in accepted ISO offsets.
    date.FromISO8601String(Left(value, 19) + "Z")
    if date.GetYear() <> Val(Left(value, 4)) or date.GetMonth() <> Val(Mid(value, 6, 2)) or date.GetDayOfMonth() <> Val(Mid(value, 9, 2)) then return -1
    if Val(Mid(value, 12, 2)) > 23 or Val(Mid(value, 15, 2)) > 59 or Val(Mid(value, 18, 2)) > 59 then return -1
    offset = 0
    if Right(value, 1) <> "Z"
        zone = Right(value, 6)
        hours = Val(Mid(zone, 2, 2))
        minutes = Val(Right(zone, 2))
        if hours > 23 or minutes > 59 then return -1
        offset = (hours * 60 + minutes) * 60
        if Left(zone, 1) = "-" then offset = -offset
    end if
    return date.AsSeconds() - offset
end function

function VGuidePrograms(value as Dynamic, nowSeconds as Double) as Object
    output = []
    ids = []
    for each raw in VArray(value)
        start = VNum(VGet(raw, "startSeconds"), -1)
        finish = VNum(VGet(raw, "endSeconds"), -1)
        if start < 0 then start = VGuideEpoch(VGet(raw, "startTime"))
        if finish < 0 then finish = VGuideEpoch(VGet(raw, "endTime"))
        title = VStr(VGet(raw, "title")).Trim()
        identity = VStr(VGet(raw, "id"), title + ":" + VStr(start))
        duplicate = false
        for each id in ids
            if id = identity then duplicate = true
        end for
        if start >= 0 and finish > start and finish > nowSeconds and title <> "" and not duplicate
            item = VCopy(raw)
            item.id = identity
            item.title = title
            item.startSeconds = start
            item.endSeconds = finish
            item.isNow = start <= nowSeconds and finish > nowSeconds
            output.Push(item)
            ids.Push(identity)
        end if
        if output.Count() >= 160 then exit for
    end for
    output.SortBy("startseconds")
    return output
end function

function VLiveRows(channels as Dynamic, guide as Dynamic, query as String, nowSeconds as Double) as Object
    query = LCase(query.Trim())
    output = []
    for each channel in VArray(channels)
        id = VStr(VGet(channel, "id"))
        if id <> ""
            programs = []
            for each entry in VArray(VGet(guide, "channels"))
                if VStr(VGet(entry, "channelId")) = id
                    programs = VGuidePrograms(VGet(entry, "programs"), nowSeconds)
                    exit for
                end if
            end for
            current = invalid
            upcoming = invalid
            for each program in programs
                if VBool(VGet(program, "isNow")) and current = invalid then current = program
                if VNum(VGet(program, "startSeconds")) > nowSeconds and upcoming = invalid then upcoming = program
            end for
            haystack = LCase(VStr(VGet(channel, "name")) + " " + VStr(VGet(channel, "number")) + " " + VStr(VGet(channel, "group")))
            for each program in programs
                haystack += " " + LCase(VStr(VGet(program, "title")) + " " + VStr(VGet(program, "episodeTitle")))
            end for
            if query = "" or Instr(1, haystack, query) > 0
                output.Push({channel: channel, programs: programs, current: current, upcoming: upcoming})
            end if
        end if
    end for
    return output
end function

function VGuideTime(value as Dynamic, includeDay = true as Boolean) as String
    epoch = VGuideEpoch(value)
    if epoch < 0 then return "Time unavailable"
    date = CreateObject("roDateTime")
    date.FromSeconds(epoch)
    date.ToLocalTime()
    hour = date.GetHours()
    suffix = " AM"
    if hour >= 12 then suffix = " PM"
    hour = hour Mod 12
    if hour = 0 then hour = 12
    result = VStr(hour) + ":" + Right("0" + VStr(date.GetMinutes()), 2) + suffix
    if includeDay
        days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        result = days[date.GetDayOfWeek()] + " " + result
    end if
    return result
end function

function VGuideRange(program as Object) as String
    return VGuideTime(VGet(program, "startTime")) + " – " + VGuideTime(VGet(program, "endTime"), false)
end function

' Cache timestamp parsing when the HTTP guide arrives, not on each clock tick.
function VPrepareGuide(guide as Dynamic) as Object
    output = {channels:[]}
    for each raw in VArray(VGet(guide,"channels"))
        programs = []
        for each program in VArray(VGet(raw,"programs"))
            copy = VCopy(program)
            copy.startSeconds = VGuideEpoch(VGet(program,"startTime"))
            copy.endSeconds = VGuideEpoch(VGet(program,"endTime"))
            programs.Push(copy)
        end for
        output.channels.Push({channelId:VGet(raw,"channelId"), programs:programs})
    end for
    return output
end function

' Every program shares one clock. Gaps describe absent listings, never invented shows.
function VGuideWindowStart(nowSeconds as Double) as Double
    return Int(nowSeconds / 1800#) * 1800#
end function

function VGuideWindowSegments(programs as Dynamic, startSeconds as Double, durationSeconds = 7200# as Double) as Object
    finish = startSeconds + durationSeconds
    cursor = startSeconds
    segments = []
    for each program in VArray(programs)
        first = VNum(VGet(program, "startSeconds"), -1)
        last = VNum(VGet(program, "endSeconds"), -1)
        if first < finish and last > cursor
            if first > cursor then segments.Push({startSeconds:cursor, endSeconds:first, program:invalid})
            if first < cursor then first = cursor
            if last > finish then last = finish
            segments.Push({startSeconds:first, endSeconds:last, program:program})
            cursor = last
        end if
        if cursor >= finish then exit for
    end for
    if cursor < finish then segments.Push({startSeconds:cursor, endSeconds:finish, program:invalid})
    return segments
end function

' Half-open time ranges keep vertical focus on the same broadcast at a boundary.
function VGuideSegmentAt(segments as Object, seconds as Double) as Integer
    for i = 0 to segments.Count() - 1
        if seconds >= segments[i].startSeconds and seconds < segments[i].endSeconds then return i
    end for
    if segments.Count() = 0 then return -1
    if seconds < segments[0].startSeconds then return 0
    return segments.Count() - 1
end function

function VGuideLastTime(rows as Object, nowSeconds as Double) as Double
    result = VGuideWindowStart(nowSeconds) + 7200#
    for each row in rows
        for each program in row.programs
            if program.endSeconds > result then result = program.endSeconds
        end for
    end for
    return result
end function

function VGuideFavoriteIds(value as Dynamic) as Object
    output = []
    for each raw in VArray(value)
        id = VStr(raw)
        if id <> "" and not VGuideHasFavorite(output, id) then output.Push(id)
    end for
    return output
end function

function VGuideHasFavorite(ids as Object, id as String) as Boolean
    for each entry in ids
        if entry = id then return true
    end for
    return false
end function

function VGuideToggleFavorite(ids as Object, id as String) as Object
    output = []
    existed = VGuideHasFavorite(ids, id)
    for each entry in ids
        if entry <> id then output.Push(entry)
    end for
    if not existed and id <> "" then output.Push(id)
    return output
end function

function VGuideFavoriteRows(rows as Object, ids as Object, onlyFavorites as Boolean) as Object
    if not onlyFavorites then return rows
    output = []
    for each row in rows
        if VGuideHasFavorite(ids, VStr(VGet(row.channel, "id"))) then output.Push(row)
    end for
    return output
end function

function VGuideClock(seconds as Double, includeDay = false as Boolean) as String
    date = CreateObject("roDateTime")
    date.FromSeconds(seconds)
    date.ToLocalTime()
    hour = date.GetHours()
    suffix = " AM"
    if hour >= 12 then suffix = " PM"
    hour = hour Mod 12
    if hour = 0 then hour = 12
    result = VStr(hour) + ":" + Right("0" + VStr(date.GetMinutes()), 2) + suffix
    if includeDay
        days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        result = days[date.GetDayOfWeek()] + " · " + result
    end if
    return result
end function

function VGuideNavigateTime(programs as Object, windowStart as Double, focusTime as Double, nowSeconds as Double, lastTime as Double, direction as Integer) as Object
    result = {windowStart:windowStart, focusTime:focusTime, focusHeader:false}
    segments = VGuideWindowSegments(programs, windowStart)
    index = VGuideSegmentAt(segments, focusTime)
    nextIndex = index + direction
    if direction < 0 and index = 0 and windowStart = VGuideWindowStart(nowSeconds)
        result.focusHeader = true
    else if nextIndex >= 0 and nextIndex < segments.Count()
        result.focusTime = segments[nextIndex].startSeconds + 1
    else if direction > 0 and windowStart + 7200# < lastTime
        result.focusTime = windowStart + 7200# + 1
        result.windowStart += 3600#
    else if direction < 0 and windowStart > VGuideWindowStart(nowSeconds)
        result.focusTime = windowStart - 1
        result.windowStart -= 3600#
        if result.windowStart < VGuideWindowStart(nowSeconds) then result.windowStart = VGuideWindowStart(nowSeconds)
    end if
    return result
end function

function VGuideSearchTime(row as Object, query as String, nowSeconds as Double) as Double
    query = LCase(query.Trim())
    channel = row.channel
    channelText = LCase(VStr(VGet(channel, "name")) + " " + VStr(VGet(channel, "number")) + " " + VStr(VGet(channel, "group")))
    if query = "" or Instr(1, channelText, query) > 0 then return nowSeconds
    for each program in row.programs
        text = LCase(VStr(VGet(program, "title")) + " " + VStr(VGet(program, "episodeTitle")))
        if Instr(1, text, query) > 0
            if program.startSeconds < nowSeconds then return nowSeconds
            return program.startSeconds + 1
        end if
    end for
    return nowSeconds
end function
