import Foundation
import SentryTestSupport
import SignalCore
import SentryContract
import Testing
@testable import VolumeMonitor

struct ScriptedVolumeSource: VolumeSource {
    let script: [VolumeSourceEvent]

    func changes() -> AsyncStream<VolumeSourceEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

actor CollectingDelivery: NotificationDelivering {
    private(set) var events: [NotificationEvent] = []

    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        events.append(event)
        return .presented
    }
}

@Suite("VolumeMonitor")
struct VolumeMonitorTests {
    /// Waits for the monitor's own task to actually finish, rather than assuming a fixed
    /// number of yields is enough. It was not: the first `ByteCountFormatter` call of the
    /// process is slow enough to still be running when the yields ran out, so the one test
    /// that formatted a size saw no notification at all.
    private func run(_ script: [VolumeSourceEvent], expecting: Int = 1) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = VolumeMonitor(
            source: ScriptedVolumeSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: VolumeMonitor.category)
        )

        await monitor.start()
        await waitUntil { await delivery.events.count >= expecting }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a mount is announced")
    func mountIsAnnounced() async {
        let events = await run([.mounted(path: "/Volumes/Backup", name: "Backup")])

        #expect(events.count == 1)
        #expect(events.first?.name == "VolumeMounted")
        #expect(events.first?.subject == "/Volumes/Backup")
    }

    @Test("a graceful eject (willUnmount then unmounted) only fires the plain unmount")
    func gracefulEjectIsPlainUnmount() async {
        let events = await run([
            .willUnmount(path: "/Volumes/Backup", name: "Backup"),
            .unmounted(path: "/Volumes/Backup", name: "Backup")
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "VolumeUnmounted")
    }

    @Test("a surprise removal (unmounted with no prior willUnmount) also fires unsafe eject")
    func surpriseRemovalAlsoFiresUnsafeEject() async {
        let events = await run([.unmounted(path: "/Volumes/SDCard", name: "SDCard")], expecting: 2)

        #expect(events.count == 2)
        #expect(events[0].name == "VolumeUnsafeEject")
        #expect(events[1].name == "VolumeUnmounted")
    }

    @Test("free space dropping to the threshold fires once, not every poll")
    func lowSpaceFiresOnce() async {
        let events = await run([
            .freeSpaceSnapshot(["/Volumes/Backup": 4.0]),
            .freeSpaceSnapshot(["/Volumes/Backup": 3.0])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "VolumeLowSpace")
        #expect(events.first?.body.contains("4% free") == true)
    }

    @Test("free space recovering above the recovery threshold re-arms the check")
    func lowSpaceRearmsAfterRecovery() async {
        let events = await run([
            .freeSpaceSnapshot(["/Volumes/Backup": 4.0]),
            .freeSpaceSnapshot(["/Volumes/Backup": 20.0]),
            .freeSpaceSnapshot(["/Volumes/Backup": 4.0])
        ], expecting: 2)

        #expect(events.count == 2)
    }

    @Test("free space hovering between threshold and recovery does not re-fire")
    func lowSpaceHysteresisPreventsFlapping() async {
        let events = await run([
            .freeSpaceSnapshot(["/Volumes/Backup": 4.0]),
            .freeSpaceSnapshot(["/Volumes/Backup": 7.0]), // above threshold, below recovery
            .freeSpaceSnapshot(["/Volumes/Backup": 4.0])
        ])

        #expect(events.count == 1)
    }

    @Test("a volume that unmounts drops its low-space bookkeeping, so a fresh mount starts clean")
    func unmountingDropsLowSpaceBookkeeping() async {
        let events = await run([
            .freeSpaceSnapshot(["/Volumes/Backup": 4.0]),
            .freeSpaceSnapshot([:]), // unmounted between polls
            .freeSpaceSnapshot(["/Volumes/Backup": 4.0])
        ], expecting: 2)

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.name == "VolumeLowSpace" })
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: VolumeMonitor.events.map { ($0.name, $0.enabledByDefault) })

        // Three rows per kind of drive, then the generics and the two about a drive
        // going wrong rather than coming and going.
        #expect(Set(byName.keys) == Set(VolumeEvent.allCases.map(\.rawValue)))
        #expect(byName["VolumeMounted"] == true)
        #expect(byName["VolumeUnmounted"] == true)
        // On by default, as in the original: an unreadable card is a real problem
        // somebody would want told about, not a detail to opt into.
        #expect(byName["VolumeNotReadable"] == true)
        #expect(byName["VolumeUnsafeEject"] == false)
        #expect(byName["VolumeLowSpace"] == false)

        for kind in VolumeKind.allCases {
            #expect(byName[kind.mountedEvent.rawValue] == true)
            #expect(byName[kind.unmountedEvent.rawValue] == true)
            // Low space stays off per kind too: it is the one that repeats.
            #expect(byName[kind.lowSpaceEvent.rawValue] == false)
        }
    }

    @Test("the details a volume can report show up when it mounts")
    func mountCarriesDeclaredDetails() async {
        let events = await run([.mounted(
            path: "/Volumes/Backup",
            name: "Backup",
            detail: VolumeDetail(fileSystemType: "apfs", totalBytes: 2_000_000_000_000, isReadOnly: false)
        )])

        // The volume's name is the title, not the first body line — with eight volumes
        // announced at once, identical headings say nothing about which is which.
        #expect(events.first?.title == "Backup Mounted")

        let body = events.first?.body ?? ""
        #expect(body.hasPrefix("Click to open"))
        #expect(body.contains("/Volumes/Backup"))
        #expect(body.contains("File system: apfs"))
        #expect(body.contains("Size: "))
        // Writable is the normal case; saying so every time would be noise.
        #expect(!body.contains("Read-only"))
    }

    @Test("a read-only volume says so, and one with nothing to report says only its name")
    func readOnlyIsCalledOutAndBlanksOmitted() async {
        let readOnly = await run([.mounted(
            path: "/Volumes/Installer", name: "Installer",
            detail: VolumeDetail(fileSystemType: "hfs", isReadOnly: true)
        )])
        #expect(readOnly.first?.body.contains("Read-only:\tYes") == true)
        #expect(readOnly.first?.body.contains("Size:") == false)

        let bare = await run([.mounted(path: "/Volumes/X", name: "X")])
        #expect(bare.first?.title == "X Mounted")
        #expect(bare.first?.body.contains("File system:") == false)
    }

    @Test("a network share's file system is named for the protocol, not macOS's internal name")
    func networkFileSystemsAreShownByProtocolName() async {
        let cases: [(String, String)] = [
            ("smbfs", "SMB"), ("afpfs", "AFP"), ("nfs", "NFS"), ("webdav", "WebDAV"), ("ftp", "FTP")
        ]
        for (raw, friendly) in cases {
            let events = await run([.mounted(
                path: "/Volumes/Share", name: "Share",
                detail: VolumeDetail(fileSystemType: raw, kind: .nas)
            )])
            #expect(events.first?.body.contains("File system: \(friendly)") == true)
        }
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = VolumeMonitor(
            source: ScriptedVolumeSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: VolumeMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}

@Suite("Unreadable disks")
struct UnreadableDiskTests {
    private func partition(
        _ bsd: String, whole: String, name: String = "Untitled", isInternal: Bool = false
    ) -> UnreadablePartition {
        UnreadablePartition(bsdName: bsd, wholeDiskName: whole, displayName: name, isInternal: isInternal)
    }

    @Test("one card with four unreadable partitions is one notification")
    func partitionsAreGroupedByDisk() {
        // A person inserted one card and wants to be told about one card.
        var tracker = UnreadableDiskTracker()
        let reports = tracker.consider(unreadable: [
            partition("disk4s1", whole: "disk4"),
            partition("disk4s2", whole: "disk4"),
            partition("disk4s3", whole: "disk4"),
            partition("disk4s4", whole: "disk4")
        ], readableWholeDisks: [])

        #expect(reports.count == 1)
        #expect(reports.first?.wholeDiskName == "disk4")
    }

    @Test("two separate cards are two notifications, in a stable order")
    func separateDisksReportSeparately() {
        var tracker = UnreadableDiskTracker()
        let reports = tracker.consider(unreadable: [
            partition("disk5s1", whole: "disk5", name: "Card B"),
            partition("disk4s1", whole: "disk4", name: "Card A")
        ], readableWholeDisks: [])

        #expect(reports.map(\.wholeDiskName) == ["disk4", "disk5"])
    }

    @Test("a disk already reported is not reported again")
    func reportedDisksAreRemembered() {
        // Something re-probing a card in a slot must not warn about it every time.
        var tracker = UnreadableDiskTracker()
        _ = tracker.consider(unreadable: [partition("disk4s1", whole: "disk4")], readableWholeDisks: [])
        let again = tracker.consider(unreadable: [partition("disk4s1", whole: "disk4")], readableWholeDisks: [])
        #expect(again.isEmpty)
    }

    @Test("re-inserting a card that has left warns again")
    func forgettingReArms() {
        var tracker = UnreadableDiskTracker()
        _ = tracker.consider(unreadable: [partition("disk4s1", whole: "disk4")], readableWholeDisks: [])
        tracker.forget(wholeDiskName: "disk4")

        let again = tracker.consider(unreadable: [partition("disk4s1", whole: "disk4")], readableWholeDisks: [])
        #expect(again.count == 1)
    }

    @Test("a card where something did mount is described as partly unreadable")
    func readableSiblingChangesTheWording() {
        // Saying the whole card is unreadable when half of it mounted sends somebody
        // looking for a fault that is not there.
        var tracker = UnreadableDiskTracker()
        let reports = tracker.consider(
            unreadable: [partition("disk4s2", whole: "disk4", name: "SD Card")],
            readableWholeDisks: ["disk4"]
        )

        #expect(reports.first?.hasReadableSibling == true)
        #expect(reports.first?.message == "Part of this device (SD Card) could not be read. It may be unformatted or use an unsupported file system.")
    }

    @Test("a card where nothing mounted is described as unreadable outright")
    func noReadableSiblingWording() {
        var tracker = UnreadableDiskTracker()
        let reports = tracker.consider(
            unreadable: [partition("disk4s1", whole: "disk4", name: "Untitled")],
            readableWholeDisks: []
        )
        #expect(reports.first?.message == "Untitled could not be read. It may be unformatted or use an unsupported file system.")
    }

    @Test("the Mac's own hidden partitions are never reported")
    func internalDisksAreExcluded() {
        // The startup disk's recovery and preboot partitions are unreadable by design;
        // warning about them at every launch would be pure noise.
        var tracker = UnreadableDiskTracker()
        let reports = tracker.consider(unreadable: [
            partition("disk3s5", whole: "disk3", isInternal: true),
            partition("disk3s6", whole: "disk3", isInternal: true)
        ], readableWholeDisks: [])
        #expect(reports.isEmpty)
    }
}

@Suite("Whole-disk names")
struct WholeDiskNameTests {
    @Test("a partition name reduces to the disk it sits on")
    func partitionsMapToTheirDisk() {
        #expect(UnreadableDiskWatcher.wholeDiskName(of: "disk4s1") == "disk4")
        #expect(UnreadableDiskWatcher.wholeDiskName(of: "disk12s3") == "disk12")
    }

    @Test("a whole disk is already its own answer")
    func wholeDisksAreUnchanged() {
        #expect(UnreadableDiskWatcher.wholeDiskName(of: "disk4") == "disk4")
    }

    @Test("something that is not a disk name is left alone")
    func nonDiskNamesAreUntouched() {
        #expect(UnreadableDiskWatcher.wholeDiskName(of: "en0") == "en0")
        #expect(UnreadableDiskWatcher.wholeDiskName(of: "") == "")
    }
}

@Suite("Volume exclusions")
struct VolumeExclusionTests {
    @Test("an exact name is matched whichever case it is written in")
    func exactMatchIsCaseInsensitive() {
        let exclusions = VolumeExclusions(patterns: ["TimeMachine"])
        #expect(exclusions.excludes(path: "/Volumes/timemachine", name: "timemachine"))
        #expect(exclusions.excludes(path: "/x", name: "TIMEMACHINE"))
        #expect(!exclusions.excludes(path: "/Volumes/Backup", name: "Backup"))
    }

    @Test("a trailing star covers everything under a path")
    func wildcardMatchesPrefix() {
        // What makes "every disk image under /Volumes/VM" one entry rather than one per
        // disk.
        let exclusions = VolumeExclusions(patterns: ["/Volumes/VM*"])
        #expect(exclusions.excludes(path: "/Volumes/VM-ubuntu", name: "VM-ubuntu"))
        #expect(exclusions.excludes(path: "/Volumes/VM", name: "VM"))
        #expect(!exclusions.excludes(path: "/Volumes/Work", name: "Work"))
    }

    @Test("a bare star does not silently silence everything")
    func bareStarIsRefused() {
        // It would silence the module by accident while it still looked like it was
        // running.
        let exclusions = VolumeExclusions(patterns: ["*"])
        #expect(!exclusions.excludes(path: "/Volumes/Anything", name: "Anything"))
    }

    @Test("either the path or the name matching is enough")
    func eitherSideMatches() {
        let byPath = VolumeExclusions(patterns: ["/Volumes/Scratch"])
        #expect(byPath.excludes(path: "/Volumes/Scratch", name: "Something Else"))

        let byName = VolumeExclusions(patterns: ["Scratch"])
        #expect(byName.excludes(path: "/private/tmp/mnt", name: "Scratch"))
    }

    @Test("whitespace and empty patterns are ignored rather than matching everything")
    func emptyPatternsAreIgnored() {
        let exclusions = VolumeExclusions(patterns: ["", "   "])
        #expect(!exclusions.excludes(path: "/Volumes/Backup", name: "Backup"))
    }
}

@Suite("Volume detail lines")
struct VolumeDetailLineTests {
    @Test("the drive's own warning is appended to the health figure")
    func healthCarriesTheWarning() {
        // A percentage invites arguing about what counts as low; a drive saying it is in
        // trouble does not.
        #expect(VolumeDetail(healthPercent: 97, hasHealthWarning: false).healthNote == "97%")
        #expect(VolumeDetail(healthPercent: 12, hasHealthWarning: true).healthNote == "12% (Warning)")
        #expect(VolumeDetail().healthNote == nil)
    }

    @Test("removable and ejectable share one line")
    func removableAndEjectableCombine() {
        // Two lines of Yes/No for almost the same question reads as padding.
        let detail = VolumeDetail(isRemovable: true, isEjectable: false)
        #expect(detail.removableNote == "Yes\tEjectable:\tNo")
        // Both or neither: half the answer answers nothing.
        #expect(VolumeDetail(isRemovable: true).removableNote == nil)
    }

    @Test("the bus line gathers whichever parts are known")
    func busLineIsBuiltFromParts() {
        #expect(VolumeDetail(busName: "USB", sectorSize: 512).busNote == "USB, Sector size: 512 bytes")
        #expect(VolumeDetail(busName: "USB").busNote == "USB")
        #expect(VolumeDetail(sectorSize: 4096).busNote == "Sector size: 4096 bytes")
        #expect(VolumeDetail().busNote == nil)
    }

    @Test("encryption and case sensitivity read both ways")
    func flagsReadBothWays() {
        // Whether the disk you just plugged in is encrypted is worth knowing either way.
        #expect(VolumeDetail(isEncrypted: true).encryptedNote == "Yes")
        #expect(VolumeDetail(isEncrypted: false).encryptedNote == "No")
        #expect(VolumeDetail(isCaseSensitive: true).caseSensitiveNote == "Yes")
        #expect(VolumeDetail().caseSensitiveNote == nil)
    }
}

@Suite("VolumeMonitor · one row per kind of drive")
struct VolumeKindRowTests {
    @Test("every kind has three rows, each with artwork that exists")
    func everyKindHasThreeRows() {
        // Mounted, unmounted and low space are three different pieces of news about the
        // same drive: somebody who wants the low-space warning on an external disk does
        // not necessarily want telling every time they plug it in.
        for kind in VolumeKind.allCases {
            for event in [kind.mountedEvent, kind.unmountedEvent, kind.lowSpaceEvent] {
                let declared = VolumeMonitor.events.first { $0.name == event.rawValue }
                #expect(declared != nil, "\(kind) has no row for \(event)")
                // `.asset` gives no icon for a name that resolves to nothing, so this
                // catches a typo in an artwork name as well as a missing row.
                #expect(declared?.icon != NotificationIcon.none, "\(kind) \(event) has no icon")
            }
        }
        #expect(VolumeKind.allCases.count == 5)
    }

    @Test("the module's icon is the plain volume glyph, not whichever kind comes first")
    func moduleIconIsDeclared() {
        #expect(VolumeMonitor.icon == .asset("DisksVolumes-Mounted", in: .module))
        #expect(VolumeMonitor.icon != VolumeMonitor.events.first?.icon)
    }
}

@Suite("UnreadableDiskNaming")
struct UnreadableDiskNamingTests {
    @Test("a disk is named by its maker and model — the real Kingston stick that read as 'Apple'")
    func makerAndModel() {
        #expect(UnreadableDiskNaming.deviceName(vendor: "KINGSTON", model: "DT 100 G2", mediaName: "DT 100 G2") == "KINGSTON DT 100 G2")
        #expect(UnreadableDiskNaming.deviceName(vendor: "  Kingston ", model: " DT 100 G2 ", mediaName: nil) == "Kingston DT 100 G2")
    }

    @Test("a model that already starts with its maker is not repeated")
    func noRepeatedMaker() {
        #expect(UnreadableDiskNaming.deviceName(vendor: "SanDisk", model: "SanDisk Ultra", mediaName: nil) == "SanDisk Ultra")
    }

    @Test("with only half the pair, the half there is — and with neither, the media name without its ' Media'")
    func fallbacks() {
        #expect(UnreadableDiskNaming.deviceName(vendor: nil, model: "DT 100 G2", mediaName: nil) == "DT 100 G2")
        #expect(UnreadableDiskNaming.deviceName(vendor: "Generic", model: "", mediaName: nil) == "Generic")
        #expect(UnreadableDiskNaming.deviceName(vendor: nil, model: nil, mediaName: "KINGSTON DT 100 G2 Media") == "KINGSTON DT 100 G2")
        #expect(UnreadableDiskNaming.deviceName(vendor: "", model: "  ", mediaName: "Card Reader") == "Card Reader")
    }

    @Test("a disk that says nothing usable gives no name, so the caller keeps its own")
    func nothing() {
        #expect(UnreadableDiskNaming.deviceName(vendor: nil, model: nil, mediaName: nil) == nil)
        #expect(UnreadableDiskNaming.deviceName(vendor: " ", model: "", mediaName: "  ") == nil)
        #expect(UnreadableDiskNaming.deviceName(vendor: nil, model: nil, mediaName: " Media") == "Media")
    }

    @Test("partition maps, drivers and free space can never be unreadable")
    func nonDataPartitions() {
        for type in ["Apple_partition_map", "Apple_Driver43", "Apple_Driver_ATA", "Apple_Free", "Apple_Void", "Apple_Scratch", "Apple_Patches"] {
            #expect(UnreadableDiskNaming.holdsNoFilesystem(contentType: type), "\(type)")
        }
    }

    @Test("a data partition, or one whose type is unknown, still counts")
    func dataPartitions() {
        for type in ["Apple_HFS", "Apple_APFS", "Microsoft Basic Data", "Windows_NTFS", "Linux Filesystem", "EFI", ""] {
            #expect(!UnreadableDiskNaming.holdsNoFilesystem(contentType: type), "\(type)")
        }
        #expect(!UnreadableDiskNaming.holdsNoFilesystem(contentType: nil))
    }

    @Test("a partition can be re-described under the disk's name without losing anything else")
    func renamed() {
        let part = UnreadablePartition(bsdName: "disk4s1", wholeDiskName: "disk4", displayName: "Apple", isInternal: false)
        let renamed = part.named("KINGSTON DT 100 G2")
        #expect(renamed.displayName == "KINGSTON DT 100 G2")
        #expect(renamed.bsdName == "disk4s1")
        #expect(renamed.wholeDiskName == "disk4")
        #expect(!renamed.isInternal)

        var tracker = UnreadableDiskTracker()
        let report = tracker.consider(unreadable: [renamed], readableWholeDisks: [])
        #expect(report.first?.message == "KINGSTON DT 100 G2 could not be read. It may be unformatted or use an unsupported file system.")
    }
}

@Suite("NetworkVolumeEndpoint")
struct NetworkVolumeEndpointTests {
    private func parse(_ source: String?, _ type: String?) -> NetworkVolumeEndpoint? {
        NetworkVolumeEndpoint.parse(mountSource: source, fileSystemType: type)
    }

    @Test("an SMB share is found at its server's SMB port — the real mount of a NAS called nas")
    func smb() {
        #expect(parse("//Admin@nas/LEO", "smbfs") == NetworkVolumeEndpoint(host: "nas", port: 445))
        #expect(parse("//GUEST:@192.168.1.5/share", "smbfs") == NetworkVolumeEndpoint(host: "192.168.1.5", port: 445))
        #expect(parse("//nas/share", "smbfs") == NetworkVolumeEndpoint(host: "nas", port: 445))
    }

    @Test("a password with awkward characters does not leak into the host")
    func smbCredentials() {
        #expect(parse("//user:p%40ss@host.local/share", "smbfs")?.host == "host.local")
        #expect(parse("//a:b@c@nas/share", "smbfs")?.host == "nas")
    }

    @Test("an explicit port is honoured, with or without the brackets an IPv6 address needs")
    func ports() {
        #expect(parse("//nas:4455/x", "smbfs") == NetworkVolumeEndpoint(host: "nas", port: 4455))
        #expect(parse("//user@[fe80::1]:4455/x", "smbfs") == NetworkVolumeEndpoint(host: "fe80::1", port: 4455))
        #expect(parse("//user@[fe80::1]/x", "smbfs") == NetworkVolumeEndpoint(host: "fe80::1", port: 445))
        #expect(parse("//user@fe80::1/x", "smbfs")?.host == "fe80::1")
    }

    @Test("a share found through Bonjour is turned back into a name that can be looked up")
    func bonjour() {
        #expect(parse("//user@Leo-NAS._smb._tcp.local/Share", "smbfs")?.host == "Leo-NAS.local")
        #expect(parse("afp_0TrHMlKS00Chj0CHf0Hm@Server._afpovertcp._tcp.local/Share", "afpfs") == NetworkVolumeEndpoint(host: "Server.local", port: 548))
    }

    @Test("NFS, WebDAV and FTP are found at their own ports")
    func otherProtocols() {
        #expect(parse("nas:/export/media", "nfs") == NetworkVolumeEndpoint(host: "nas", port: 2049))
        #expect(parse("http://dav.example.com/path", "webdav") == NetworkVolumeEndpoint(host: "dav.example.com", port: 80))
        #expect(parse("https://dav.example.com/path", "webdav") == NetworkVolumeEndpoint(host: "dav.example.com", port: 443))
        #expect(parse("https://dav.example.com:8443/path", "webdav") == NetworkVolumeEndpoint(host: "dav.example.com", port: 8443))
        #expect(parse("ftp://ftp.example.com/pub", "ftp") == NetworkVolumeEndpoint(host: "ftp.example.com", port: 21))
    }

    @Test("anything that is not a network share, or names no host, gives nothing")
    func refusals() {
        #expect(parse(nil, "smbfs") == nil)
        #expect(parse("", "smbfs") == nil)
        #expect(parse("//nas/x", nil) == nil)
        #expect(parse("/dev/disk3s1", "apfs") == nil)
        #expect(parse("//@/share", "smbfs") == nil)
        #expect(parse("nocolon", "nfs") == nil)
        #expect(parse(":/export", "nfs") == nil)
    }
}

/// Answers a network drive's "are you there?" from a script, repeating the last answer.
actor ScriptedProbe: NetworkReachabilityProbe {
    private var answers: [Bool]
    private var last = true
    private(set) var asked = 0

    init(_ answers: [Bool]) { self.answers = answers }

    func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool {
        asked += 1
        if !answers.isEmpty { last = answers.removeFirst() }
        return last
    }
}

final class LiveVolumeSource: VolumeSource, @unchecked Sendable {
    private let stream: AsyncStream<VolumeSourceEvent>
    private let continuation: AsyncStream<VolumeSourceEvent>.Continuation

    init() {
        var escaped: AsyncStream<VolumeSourceEvent>.Continuation!
        stream = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func changes() -> AsyncStream<VolumeSourceEvent> { stream }
    func send(_ event: VolumeSourceEvent) { continuation.yield(event) }
}

@Suite("VolumeMonitor · network drive stops answering")
struct NetworkDriveReachabilityTests {
    private static let nas = VolumeDetail(fileSystemType: "smbfs", kind: .nas, mountSource: "//Admin@nas/LEO")

    private func make(
        _ source: any VolumeSource, probe: ScriptedProbe, interval: Duration = .milliseconds(20)
    ) -> (VolumeMonitor, CollectingDelivery) {
        let delivery = CollectingDelivery()
        let monitor = VolumeMonitor(
            source: source,
            context: MonitorContext(dispatcher: NotificationDispatcher(delivery: delivery), category: VolumeMonitor.category),
            reachabilityProbe: probe,
            reachabilityInterval: interval,
            reachabilityFollowUp: interval / 2,
            reachabilityTimeout: .milliseconds(5)
        )
        return (monitor, delivery)
    }

    private func names(_ delivery: CollectingDelivery) async -> [String] {
        await delivery.events.map(\.name).filter { $0 == "VolumeNotResponding" || $0 == "VolumeResponding" }
    }

    private func run(_ answers: [Bool], until done: @escaping @Sendable ([String]) -> Bool) async -> (names: [String], asked: Int, events: [NotificationEvent]) {
        let probe = ScriptedProbe(answers)
        let (monitor, delivery) = make(ScriptedVolumeSource(script: [.mounted(path: "/Volumes/LEO", name: "LEO", detail: Self.nas)]), probe: probe)
        await monitor.start()
        await waitUntil { done(await names(delivery)) }
        await settle()
        await monitor.stop()
        return (await names(delivery), await probe.asked, await delivery.events)
    }

    @Test("a server that was answering and then twice is not, is reported — once, however long it stays down")
    func goesDown() async {
        let result = await run([true, false, false]) { $0.contains("VolumeNotResponding") }
        #expect(result.names == ["VolumeNotResponding"])
        #expect(result.asked >= 4)
    }

    @Test("what is said names the drive and the server, with a picture that already says it is not answering")
    func announcement() async {
        let result = await run([true, false, false]) { !$0.isEmpty }
        let event = result.events.first { $0.name == "VolumeNotResponding" }
        #expect(event?.title == "LEO Not Responding")
        #expect(event?.body.contains("nas") == true)
        #expect(event?.iconKind == "volume.nas")
        #expect(event?.iconBadge == .warning)
        // The picture carries the state; the icon stages add a mark only to one that does not.
        #expect(event?.showsIconBadge == false)
        #expect(event?.icon == .asset("Device-NAS-NotResponding", in: .module))
        #expect(event?.subject == "/Volumes/LEO")
    }

    @Test("one failed answer is a blip, not an outage")
    func blip() async {
        let result = await run([true, false, true]) { _ in false } // runs to the settle
        #expect(result.names.isEmpty)
    }

    @Test("coming back is announced, after going away was")
    func comesBack() async {
        let result = await run([true, false, false, true]) { $0.count >= 2 }
        #expect(result.names == ["VolumeNotResponding", "VolumeResponding"])
        let back = result.events.first { $0.name == "VolumeResponding" }
        #expect(back?.title == "LEO Responding Again")
        #expect(back?.iconBadge == .positive)
    }

    @Test("a server that has never answered is not reported: that may be this application not being allowed to look")
    func neverAnswered() async {
        let result = await run([false]) { _ in false }
        #expect(result.names.isEmpty)
        #expect(result.asked >= 3)
    }

    @Test("only a network drive is checked")
    func localDrivesAreNotChecked() async {
        let probe = ScriptedProbe([false])
        let local = VolumeDetail(fileSystemType: "msdos", kind: .usbDrive, mountSource: "/dev/disk4s1")
        let (monitor, delivery) = make(ScriptedVolumeSource(script: [.mounted(path: "/Volumes/ANDREA", name: "ANDREA", detail: local)]), probe: probe)
        await monitor.start()
        await waitUntil { await delivery.events.count >= 1 }
        await settle()
        await monitor.stop()
        #expect(await probe.asked == 0)
    }

    @Test("unmounting the drive ends the checking, so nothing is said about a share that is gone")
    func unmountEndsChecking() async {
        let probe = ScriptedProbe([true, false])
        let source = LiveVolumeSource()
        let (monitor, delivery) = make(source, probe: probe, interval: .milliseconds(200))
        await monitor.start()
        source.send(.mounted(path: "/Volumes/LEO", name: "LEO", detail: Self.nas))
        await waitUntil { await probe.asked >= 1 }
        source.send(.unmounted(path: "/Volumes/LEO", name: "LEO"))
        try? await Task.sleep(for: .milliseconds(700))
        await monitor.stop()

        #expect(await names(delivery).isEmpty)
        #expect(await probe.asked <= 2)
    }

    @Test("a drive that stops answering is declared for preferences to find")
    func declared() {
        let names = VolumeMonitor.events.map(\.name)
        #expect(names.contains("VolumeNotResponding"))
        #expect(names.contains("VolumeResponding"))
    }
}
