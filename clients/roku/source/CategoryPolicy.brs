' The original Halloween collection belongs to the original profile. Its cached
' catalog metadata may be reused only when that profile is selected again.
function VHasLegacyHalloween(profileId as string) as boolean
    return profileId = "default"
end function

function VLegacyHalloweenResponseCurrent(context as dynamic, profileId as string) as boolean
    return VHasLegacyHalloween(profileId) and VStr(VGet(context, "profileId")) = profileId
end function

' Use the same collection list for rendering and resolving Play all/Shuffle.
function VProfileCategories(categories as dynamic, halloween as dynamic, profileId as string) as object
    output = []
    ownsHalloween = VHasLegacyHalloween(profileId)
    if ownsHalloween and halloween <> invalid then output.Push(halloween)
    for each category in VArray(categories)
        if ownsHalloween or VStr(VGet(category, "id")) <> "halloween-nostalgia" then output.Push(category)
    end for
    return output
end function
