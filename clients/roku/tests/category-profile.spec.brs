sub main()
    m.failures = 0
    halloween = {id: "halloween-nostalgia", title: "Monstober & Nick Halloween", items: [{mediaId: 1}]}
    generated = {id: "new-halloween-collection", title: "My Halloween episodes", items: [{mediaId: 2}]}
    expect(VHasLegacyHalloween("default"), "original profile can fetch its legacy Halloween collection")
    expect(not VHasLegacyHalloween("another-profile"), "other profiles do not fetch the legacy collection")
    expect(not VHasLegacyHalloween(""), "no profile does not inherit legacy collection ownership")

    visible = VProfileCategories([generated], halloween, "default")
    expect(visible.Count() = 2 and visible[0].id = halloween.id, "legacy Halloween remains visible for the original profile")
    visible = VProfileCategories([generated], halloween, "another-profile")
    expect(visible.Count() = 1 and visible[0].id = generated.id, "switching profiles hides cached legacy metadata while retaining its own generated collection")
    visible = VProfileCategories([halloween, generated], halloween, "another-profile")
    expect(visible.Count() = 1 and visible[0].id = generated.id, "legacy category ID cannot resolve from saved rows for another profile")
    visible = VProfileCategories([], halloween, "")
    expect(visible.Count() = 0, "clearing the active profile hides cached Halloween")
    visible = VProfileCategories([], halloween, "default")
    expect(visible.Count() = 1, "switching back restores the owner's cached collection")

    pending = {profileId: "default"}
    expect(VLegacyHalloweenResponseCurrent(pending, "default"), "current owner's metadata and playback queue responses are accepted")
    expect(not VLegacyHalloweenResponseCurrent(pending, "another-profile"), "late metadata or playback queue response is discarded after switching profiles")
    expect(not VLegacyHalloweenResponseCurrent(pending, ""), "late response is discarded after clearing the profile")
    expect(not VLegacyHalloweenResponseCurrent(invalid, "default"), "response with no captured owner cannot adopt a profile")
    if m.failures = 0 then print "VELVET_TEST_PASS"
end sub

sub expect(condition as boolean, reason as string)
    if not condition
        m.failures += 1
        print "VELVET_TEST_FAIL: " + reason
    end if
end sub
