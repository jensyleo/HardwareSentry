import Foundation
import SignalCore
import SentryContract
import Testing
@testable import CameraMonitor

struct ScriptedCameraSource: CameraSource {
    let script: [CameraSourceEvent]

    func changes() -> AsyncStream<CameraSourceEvent> {
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

@Suite("CameraMonitor")
struct CameraMonitorTests {
    private func run(_ script: [CameraSourceEvent], stopDebounce: Double = 0.02, settleSeconds: Double = 0) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = CameraMonitor(
            source: ScriptedCameraSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: CameraMonitor.category),
            stopDebounce: stopDebounce
        )

        await monitor.start()
        if settleSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        }
        for _ in 0..<200 {
            await Task.yield()
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a connection is announced")
    func connectIsAnnounced() async {
        let events = await run([.connected(uid: "cam-1", name: "Logitech Brio")])

        #expect(events.count == 1)
        #expect(events.first?.name == "CameraConnected")
        #expect(events.first?.subject == "cam-1")
        #expect(events.first?.body == "Logitech Brio")
    }

    @Test("a disconnection is announced")
    func disconnectIsAnnounced() async {
        let events = await run([.disconnected(uid: "cam-1", name: "Logitech Brio")])
        #expect(events.first?.name == "CameraDisconnected")
    }

    @Test("the first running snapshot is a silent baseline")
    func firstRunningSnapshotIsSilent() async {
        let events = await run([.runningStateChanged(running: ["cam-1": "FaceTime HD Camera"])])
        #expect(events.isEmpty)
    }

    @Test("a camera starting after the baseline is announced immediately")
    func startAfterBaselineIsImmediate() async {
        let events = await run([
            .runningStateChanged(running: [:]),
            .runningStateChanged(running: ["cam-1": "FaceTime HD Camera"])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "CameraInUseChanged")
        #expect(events.first?.title == "Camera Started Being Used")
        #expect(events.first?.subject == "cam-1-started")
    }

    @Test("a camera stopping only announces after the debounce survives")
    func stopIsDebounced() async {
        let events = await run([
            .runningStateChanged(running: ["cam-1": "FaceTime HD Camera"]),
            .runningStateChanged(running: [:])
        ], stopDebounce: 0.02, settleSeconds: 0.06)

        #expect(events.count == 1)
        #expect(events.first?.name == "CameraInUseChanged")
        #expect(events.first?.title == "Camera Stopped Being Used")
        #expect(events.first?.subject == "cam-1-stopped")
    }

    @Test("a camera that flickers off and back on before the debounce fires is never announced as stopped")
    func flickerDuringDebounceIsIgnored() async {
        let events = await run([
            .runningStateChanged(running: ["cam-1": "FaceTime HD Camera"]),
            .runningStateChanged(running: [:]),
            .runningStateChanged(running: ["cam-1": "FaceTime HD Camera"])
        ], stopDebounce: 0.05, settleSeconds: 0.09)

        #expect(events.isEmpty)
    }

    @Test("a video effect change is announced with its own on/off title")
    func videoEffectIsAnnounced() async {
        let events = await run([.videoEffectChanged(.studioLight, enabled: true)])

        #expect(events.count == 1)
        #expect(events.first?.name == "CameraStudioLightChanged")
        #expect(events.first?.title == "Studio Light Enabled")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: CameraMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "CameraConnected": true,
            "CameraDisconnected": true,
            "CameraInUseChanged": true,
            "CameraPortraitEffectChanged": false,
            "CameraStudioLightChanged": false,
            "CameraReactionsChanged": false,
            "CameraBackgroundReplacementChanged": false
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = CameraMonitor(
            source: ScriptedCameraSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: CameraMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
