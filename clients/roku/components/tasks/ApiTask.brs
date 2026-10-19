sub init()
    m.top.functionName = "runRequest"
end sub

sub runRequest()
    request = m.top.request
    transfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    transfer.SetMessagePort(port)
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.InitClientCertificates()
    transfer.EnableEncodings(true)
    transfer.RetainBodyOnError(true)
    transfer.SetUrl(request.baseUrl + request.path)
    transfer.AddHeader("Accept", "application/json")
    token = VStr(VGet(request, "token"))
    if token <> "" then transfer.AddHeader("Authorization", "Bearer " + token)
    method = VStr(VGet(request, "method", "GET"))
    started = false
    if method = "POST"
        transfer.AddHeader("Content-Type", "application/json")
        started = transfer.AsyncPostFromString(FormatJson(VWireValue(VGet(request, "body", {}))))
    else
        if method <> "GET" then transfer.SetRequest(method)
        started = transfer.AsyncGetToString()
    end if
    if not started
        m.top.result = {id: request.id, ok: false, status: 0, error: "The request could not start."}
        return
    end if
    clock = CreateObject("roTimespan")
    clock.Mark()
    timeout = VNum(VGet(request, "timeout", 25000))
    while clock.TotalMilliseconds() < timeout
        event = Wait(250, port)
        if Type(event) = "roUrlEvent"
            status = event.GetResponseCode()
            responseText = event.GetString()
            data = invalid
            if responseText.Trim() <> "" then data = ParseJson(responseText)
            ok = status >= 200 and status < 300
            if ok and Type(data) <> "roAssociativeArray"
                if status = 202 or status = 204
                    data = {}
                else
                    m.top.result = {id: request.id, ok: false, status: status, error: "The server returned an invalid response. Check the backend address."}
                    return
                end if
            end if
            if ok
                m.top.result = {id: request.id, ok: true, status: status, data: data}
            else
                message = "Could not connect to your Velvet server. Try again."
                if status = 401 or status = 403 then message = "The backend token was not accepted. Check Settings."
                if status = 404 then message = "This server needs the Roku catalog update."
                if Type(data) = "roAssociativeArray" then message = VStr(VGet(data, "error"), message)
                ' Never log URLs, tokens, response bodies or transport failure text.
                m.top.result = {id: request.id, ok: false, status: status, error: message}
            end if
            return
        end if
    end while
    transfer.AsyncCancel()
    m.top.result = {id: request.id, ok: false, status: 0, error: "The server took too long. Try again."}
end sub
