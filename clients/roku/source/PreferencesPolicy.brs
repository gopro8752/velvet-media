' Pure validation/order helpers shared by settings and profile management.
function VPreferencesContextCurrent(context as dynamic, epoch as integer, generation as integer, profileId as string, playGeneration as integer) as boolean
    return VNum(VGet(context, "epoch"), -1) = epoch and VNum(VGet(context, "generation"), -1) = generation and VStr(VGet(context, "profileId")) = profileId and VNum(VGet(context, "playGeneration"), -1) = playGeneration
end function

function VPruneDeletedProfileLayouts(layouts as dynamic, backendUrl as string, profiles as dynamic) as object
    result = VCopy(layouts)
    if Type(result) <> "roAssociativeArray" then result = {}
    for each profile in VArray(profiles)
        id = VStr(VGet(profile, "id"))
        if id <> "" and VBool(VGet(profile, "deleted")) then result.Delete(backendUrl + "|" + id)
    end for
    return result
end function

function VProfilePalette() as object
    return ["#8B7CF6", "#46D369", "#F5C76B", "#E0506A", "#5BC0EB", "#E08A3C", "#B07CF6", "#5AD1C0"]
end function

function VProfileNameError(records as dynamic, name as string, excludingId = "" as string) as string
    name = name.Trim()
    if name = "" then return "Enter a name for this profile."
    if Len(name) > 32 then return "Keep the name to 32 characters or fewer."
    for i = 1 to Len(name)
        if Asc(Mid(name, i, 1)) < 32 then return "Use a name without line breaks."
    end for
    for each profile in VArray(records)
        if not VBool(VGet(profile, "deleted")) and VStr(VGet(profile, "id")) <> excludingId
            if LCase(VStr(VGet(profile, "name")).Trim()) = LCase(name) then return "A profile with that name already exists."
        end if
    end for
    return ""
end function

function VNextProfileColor(records as dynamic) as string
    palette = VProfilePalette()
    for each color in palette
        used = false
        for each profile in VArray(records)
            if not VBool(VGet(profile, "deleted")) and LCase(VStr(VGet(profile, "color"))) = LCase(color) then used = true
        end for
        if not used then return color
    end for
    return palette[0]
end function

function VProfileTombstone(records as dynamic, id as string, now as double) as dynamic
    count = 0
    selected = invalid
    for each record in VArray(records)
        if not VBool(VGet(record, "deleted"))
            count += 1
            if VStr(VGet(record, "id")) = id then selected = record
        end if
    end for
    if count < 2 or selected = invalid then return invalid
    result = VCopy(selected)
    result.deleted = true
    if now <= VNum(VGet(selected, "updatedAt")) then now = VNum(VGet(selected, "updatedAt")) + 1
    result.updatedAt = now
    return result
end function

function VPreferenceIds(value as dynamic) as object
    ids = []
    seen = {}
    for each id in VArray(value)
        if Type(id) = "String" or Type(id) = "roString"
            if id <> "" and Len(id) <= 256 and not seen.DoesExist(id)
                ids.Push(id)
                seen[id] = true
            end if
        end if
    end for
    return ids
end function

function VPreferenceHas(ids as dynamic, wanted as string) as boolean
    for each id in VArray(ids)
        if VStr(id) = wanted then return true
    end for
    return false
end function

function VPreferenceToggle(ids as dynamic, id as string) as object
    result = []
    found = false
    for each existing in VPreferenceIds(ids)
        if existing = id then found = true else result.Push(existing)
    end for
    if not found then result.Push(id)
    return result
end function

function VOrderedHomeRows(rows as dynamic, order as dynamic, hidden as dynamic) as object
    result = []
    added = {}
    for each id in VPreferenceIds(order)
        for each row in VArray(rows)
            if VStr(VGet(row, "id")) = id and not added.DoesExist(id) and not VPreferenceHas(hidden, id)
                result.Push(row)
                added[id] = true
            end if
        end for
    end for
    for each row in VArray(rows)
        id = VStr(VGet(row, "id"))
        if id <> "" and not added.DoesExist(id) and not VPreferenceHas(hidden, id)
            result.Push(row)
            added[id] = true
        end if
    end for
    return result
end function

function VMoveHomeRow(rows as dynamic, order as dynamic, id as string, direction as integer) as object
    current = VOrderedHomeRows(rows, order, [])
    ids = []
    index = -1
    for each row in current
        if VStr(VGet(row, "id")) = id then index = ids.Count()
        ids.Push(VStr(VGet(row, "id")))
    end for
    other = index + direction
    if index >= 0 and other >= 0 and other < ids.Count()
        swap = ids[index]
        ids[index] = ids[other]
        ids[other] = swap
    end if
    ' Keep unseen saved IDs, so temporarily unavailable categories retain order.
    for each saved in VPreferenceIds(order)
        if not VPreferenceHas(ids, saved) then ids.Push(saved)
    end for
    return ids
end function

function VPreferredQualityStreams(streams as dynamic, quality as string) as object
    if quality <> "2160p" and quality <> "1080p" and quality <> "720p" then return VArray(streams)
    preferred = []
    other = []
    for each stream in VArray(streams)
        description = LCase(VStr(VGet(stream, "title")) + " " + VStr(VGet(stream, "name")) + " " + VStr(VGet(VGet(stream, "behaviorHints", {}), "filename")))
        matches = Instr(1, description, quality) > 0
        if quality = "2160p" and Instr(1, description, "4k") > 0 then matches = true
        if matches then preferred.Push(stream) else other.Push(stream)
    end for
    for each stream in other
        preferred.Push(stream)
    end for
    return preferred
end function

function VHistoryTombstones(sync as dynamic, profileId as string, item as dynamic, now as double, onlyContinue = false as boolean) as object
    body = {progress: [], watched: []}
    for each kind in ["progress", "watched"]
        if kind <> "watched" or not onlyContinue
            for each record in VArray(VGet(sync, kind))
                matches = VStr(VGet(record, "profileId")) = profileId and not VBool(VGet(record, "deleted"))
                if kind = "watched"
                    matches = matches and VStr(VGet(record, "mediaId")) = VStr(VGet(item, "mediaId")) and VGet(item, "type") = "show"
                else
                    matches = matches and VMediaKey(record) = VMediaKey(item)
                end if
                if matches
                    tombstone = VCopy(record)
                    tombstone.deleted = true
                    timestamp = now
                    if timestamp <= VNum(VGet(record, "updatedAt")) then timestamp = VNum(VGet(record, "updatedAt")) + 1
                    tombstone.updatedAt = timestamp
                    body[kind].Push(tombstone)
                end if
            end for
        end if
    end for
    return body
end function
