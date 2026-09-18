import Foundation
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

/// Waits until `isReady` answers true, or a couple of seconds pass.
///
/// Bounded by the clock rather than by a number of turns. How many turns a scripted
/// source needs depends on how the runtime schedules and how busy the machine is, so a
/// fixed count is a guess that holds until the next toolchain: the counts this replaced
/// began failing at random under Swift 6.4. Sleeping rather than spinning on `yield`
/// also lets the monitor's own task run instead of competing with it.
private func waitUntil(_ isReady: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while await isReady() == false, Date() < deadline {
        try? await Task.sleep(nanoseconds: 200_000)
    }
}
