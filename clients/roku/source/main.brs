sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)
    scene = screen.CreateScene("VelvetScene")
    screen.Show()
    ' Register after Show has attached the scene's render thread. Some Roku
    ' builds reject a port observer earlier; retain a bounded fallback there.
    observed = scene.ObserveField("exitRequested", port)
    print "[Velvet] exit observer registered="; observed
    timeout = 0
    if not observed then timeout = 250
    while true
        event = Wait(timeout, port)
        if scene.exitRequested
            screen.Close()
            return
        end if
        if Type(event) = "roSGScreenEvent"
            if event.IsScreenClosed() then return
        end if
    end while
end sub
