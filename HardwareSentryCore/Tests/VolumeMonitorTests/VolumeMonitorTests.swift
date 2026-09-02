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
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
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

        #expect(byName == [
            "VolumeMounted": true,
            "VolumeUnmounted": true,
            "VolumeUnsafeEject": false,
            "VolumeLowSpace": false
        ])
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
