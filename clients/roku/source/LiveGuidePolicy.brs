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
            item = {id:identity, title:title, startTime:VGet(raw,"startTime"), endTime:VGet(raw,"endTime"), description:VGet(raw,"description"), episodeTitle:VGet(raw,"episodeTitle")}
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
