import Foundation
import Testing
@testable import VolumeMonitor

@Suite("VolumeExclusions · the volumes macOS manages itself")
struct SystemManagedVolumeExclusionTests {
    /// Every path and name below was read from this application's own history over the
    /// upgrade to macOS 27, 2026-09-15 — not invented for the test.
    private let systemManaged: [(path: String, name: String)] = [
        ("/System/Volumes/Update/mnt1", "mnt1"),
        ("/System/Volumes/Preboot", "Preboot"),
        ("/System/Volumes/VM", "VM"),
        ("/System/Volumes/xarts", "xarts"),
        ("/System/Volumes/iSCPreboot", "iSCPreboot"),
        ("/System/Volumes/Hardware", "Hardware"),
        ("/System/Volumes/Data/home", "home"),
        ("/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset", "cryptex"),
        ("/Volumes/msu-target-GOp4u3HS", "msu-target-GOp4u3HS"),
        ("/Volumes/msutargetcontroller-mount-kb2Tqy", "msutargetcontroller-mount-kb2Tqy"),
        ("/Volumes/tmp-mount-HUnUd0", "tmp-mount-HUnUd0"),
        ("/Volumes/tmp-mount-0pLNqq", "tmp-mount-0pLNqq")
    ]

    @Test("on by default, every one of them is passed over")
    func systemVolumesAreIgnoredByDefault() {
        let exclusions = VolumeExclusions()
        for volume in systemManaged {
            #expect(exclusions.excludes(path: volume.path, name: volume.name), "\(volume.path)")
        }
    }

    @Test("switched off, every one of them is announced again")
    func switchingOffRestoresThemAll() {
        let exclusions = VolumeExclusions(ignoresSystemManagedVolumes: false)
        for volume in systemManaged {
            #expect(!exclusions.excludes(path: volume.path, name: volume.name), "\(volume.path)")
        }
    }

    @Test("a real disk is never mistaken for one of them")
    func realDisksAreUntouched() {
        // The regression that matters: silencing somebody's own disk would be far worse
        // than the noise this removes. Two of these are named exactly like the system's
        // own volumes, which is why the built-in set matches those by path, never by name.
        let exclusions = VolumeExclusions()
        for volume in [
            ("/Volumes/Backup", "Backup"),
            ("/Volumes/SanDisk Cruzer", "SanDisk Cruzer"),
            ("/Volumes/Update", "Update"),
            ("/Volumes/Hardware", "Hardware"),
            ("/Volumes/tmp", "tmp"),
            ("/Volumes/My System Volumes", "My System Volumes"),
            // The disk actually mounted on this Mac while the set was written, alongside
            // the seven system volumes it does silence.
            ("/Volumes/LEO", "LEO")
        ] {
            #expect(!exclusions.excludes(path: volume.0, name: volume.1), "\(volume.0)")
        }
    }

    @Test("somebody's own patterns keep working, whichever way the switch is set")
    func ownPatternsAreUnaffected() {
        for ignoring in [true, false] {
            let exclusions = VolumeExclusions(patterns: ["/Volumes/Backup", "VM Images*"],
                                              ignoresSystemManagedVolumes: ignoring)
            #expect(exclusions.excludes(path: "/Volumes/Backup", name: "Backup"))
            #expect(exclusions.excludes(path: "/Volumes/VM Images 2", name: "VM Images 2"))
            #expect(!exclusions.excludes(path: "/Volumes/Photos", name: "Photos"))
        }
    }

    @Test("\"no exclusions\" means nobody wrote one, not that nothing is silenced")
    func isEmptyDescribesTheUsersOwnList() {
        // The built-in set is not something somebody configured, so it must not make the
        // list look non-empty — the editor would then show a list nobody can see or edit.
        #expect(VolumeExclusions().isEmpty)
        #expect(!VolumeExclusions(patterns: ["/Volumes/Backup"]).isEmpty)
    }
}
