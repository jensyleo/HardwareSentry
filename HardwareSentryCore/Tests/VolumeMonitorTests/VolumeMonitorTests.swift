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
    private func run(_ script: [VolumeSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = VolumeMonitor(
            source: ScriptedVolumeSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: VolumeMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
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
        let events = await run([.unmounted(path: "/Volumes/SDCard", name: "SDCard")])

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
        ])

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
        ])

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
