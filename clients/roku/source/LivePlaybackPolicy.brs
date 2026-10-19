' Native DRM uses Roku's protected player. Only backend capabilities enter Video.
function VLiveRequestHeaders(path as string) as object
    if path <> "/live/tune" then return {}
    return {"X-Velvet-Client": "roku", "X-Velvet-Playback-Capabilities": "hls-clear,dash-widevine"}
end function

function VLiveSessionId(value as dynamic) as string
    if Type(value) <> "String" and Type(value) <> "roString" then return ""
    if not CreateObject("roRegex", "^[A-Za-z0-9_-]{1,256}$", "").IsMatch(value) then return ""
    return value
end function

function VLivePlaybackDescriptor(base as string, data as dynamic, expectedChannelId = "" as string) as dynamic
    base = VBackendUrl(base)
    if base = "" then return invalid
    sid = VLiveSessionId(VGet(data, "sessionId"))
    if sid = "" then return invalid
    if expectedChannelId <> "" and VStr(VGet(VGet(data, "channel"), "id")) <> expectedChannelId then return invalid
    path = VStr(VGet(data, "playbackPath"))
    prefix = "/live/streams/" + sid + "/"
    if Left(path, Len(prefix)) <> prefix then return invalid
    file = Mid(path, Len(prefix) + 1)
    if not CreateObject("roRegex", "^[A-Za-z0-9_-]+[.](m3u8|mpd)$", "").IsMatch(file) then return invalid
    mime = LCase(VStr(VGet(data, "mimeType")))
    drm = VGet(data, "drm")
    if drm = invalid
        if mime <> "application/vnd.apple.mpegurl" and mime <> "application/x-mpegurl" then return invalid
        if Right(file, 5) <> ".m3u8" then return invalid
        return {sessionId: sid, url: base + path, streamFormat: "hls", drmParams: invalid}
    end if
    if mime <> "application/dash+xml" or Right(file, 4) <> ".mpd" then return invalid
    if not CreateObject("roRegex", "^[a-f0-9]{48}$", "").IsMatch(sid) then return invalid
    if VStr(VGet(drm, "scheme")) <> "widevine" then return invalid
    licensePath = VStr(VGet(drm, "licensePath"))
    if licensePath <> "/live/drm/" + sid then return invalid
    rotation = VGet(drm, "multiSession", false)
    if Type(rotation) <> "Boolean" and Type(rotation) <> "roBoolean" then return invalid
    ' Roku handles Widevine key rotation inside its CDM; multiSession is not a
    ' Roku ContentNode field. Provider headers/credentials stay in the backend.
    return {sessionId: sid, url: base + path, streamFormat: "dash", drmParams: {keySystem: "Widevine", licenseServerURL: base + licensePath}}
end function
