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
    private func run(
        _ script: [CameraSourceEvent],
        stopDebounce: Double = 0.02,
        settleSeconds: Double = 0,
        notifiesVirtualDevices: Bool = false
    ) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = CameraMonitor(
            source: ScriptedCameraSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: CameraMonitor.category),
            stopDebounce: stopDebounce,
            notifiesVirtualDevices: notifiesVirtualDevices
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

    @Test("a virtual camera is not announced by default")
    func virtualCameraIsSuppressedByDefault() async {
        let events = await run([
            .connected(uid: "cam-1", name: "OBS Virtual Camera", detail: CameraDetail(transport: "Virtual"))
        ])
        #expect(events.isEmpty)
    }

    @Test("a virtual camera is announced once asked for, and takes effect live")
    func virtualCameraCanBeSwitchedOnWhileRunning() async {
        let delivery = CollectingDelivery()
        let monitor = CameraMonitor(
            source: ScriptedCameraSource(script: [
                .connected(uid: "cam-1", name: "OBS Virtual Camera", detail: CameraDetail(transport: "Virtual"))
            ]),
            context: MonitorContext(dispatcher: NotificationDispatcher(delivery: delivery), category: CameraMonitor.category)
        )
        await monitor.apply(notifiesVirtualDevices: true)
        await monitor.start()
        for _ in 0..<200 where await delivery.events.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()

        let events = await delivery.events
        #expect(events.count == 1)
        #expect(events.first?.name == "CameraConnected")
    }

    @Test("a suppressed virtual camera disconnecting never fires a stray disconnect")
    func suppressedVirtualCameraNeverFiresDisconnect() async {
        let events = await run([
            .connected(uid: "cam-1", name: "OBS Virtual Camera", detail: CameraDetail(transport: "Virtual")),
            .disconnected(uid: "cam-1", name: "OBS Virtual Camera")
        ])
        #expect(events.isEmpty)
    }

    @Test("Continuity Camera is never treated as virtual")
    func continuityCameraIsUnaffected() async {
        let events = await run([
            .connected(uid: "cam-1", name: "Jensy's iPhone", detail: CameraDetail(transport: "Continuity"))
        ])
        #expect(events.count == 1)
        #expect(events.first?.name == "CameraConnected")
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

private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>
    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

@Suite("CameraMonitor optional fields")
struct CameraMonitorFieldTests {
    private static let iPhone = CameraDetail(
        transport: "Continuity",
        manufacturer: "Apple Inc.",
        position: "Back",
        maxResolution: "1920 × 1080",
        maxFrameRate: "60 fps",
        isContinuityCamera: true,
        isDeskViewCamera: false,
        isCenterStageActive: true,
        isSystemPreferred: true,
        linkedDevices: "Desk View Camera"
    )

    private func body(_ event: CameraSourceEvent, allowing allowed: Set<String>) async -> String? {
        let delivery = CollectingDelivery()
        let monitor = CameraMonitor(
            source: ScriptedCameraSource(script: [event]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: CameraMonitor.category,
                preferences: ChosenFields(allowed: allowed)
            )
        )
        await monitor.start()
        for _ in 0..<100 where await delivery.events.isEmpty { await Task.yield() }
        await monitor.stop()
        return await delivery.events.first?.body
    }

    @Test("with everything switched on, the details read in the declared order")
    func fullDetailReadsInOrder() async {
        let body = await body(
            .connected(uid: "cam-1", name: "iPhone Camera", detail: Self.iPhone),
            allowing: Set(CameraField.allCases.map(\.rawValue))
        )

        #expect(body == """
        iPhone Camera
        Transport:\tContinuity
        Manufacturer:\tApple Inc.
        Position:\tBack
        Max resolution:\t1920 × 1080
        Max frame rate:\t60 fps
        Continuity Camera:\tYes
        Center Stage:\tActive
        System Preferred Camera:\tYes
        Linked devices:\tDesk View Camera
        """)
    }

    @Test("out of the box the message says which camera it is and what it can do")
    func defaultFieldsAreTheIdentifyingOnes() async {
        // Not everything: how it attaches, how big it shoots, whether it is an iPhone
        // standing in as a webcam, and whether auto-framing is on. The rest is
        // specification somebody can turn on if they want it.
        let defaults = Set(CameraMonitor.fields.filter(\.shownByDefault).map(\.name))
        #expect(defaults == [
            CameraField.transport.rawValue, CameraField.maxResolution.rawValue,
            CameraField.continuityCamera.rawValue, CameraField.deskView.rawValue,
            CameraField.centerStage.rawValue
        ])
        #expect(CameraMonitor.fields.count == CameraField.allCases.count)

        let body = await body(.connected(uid: "cam-1", name: "iPhone Camera", detail: Self.iPhone), allowing: [])
        #expect(body == "iPhone Camera")
    }

    @Test("a capability the camera does not have is not reported as absent")
    func absentCapabilitiesAreSilent() async {
        // The iPhone above is not a Desk View camera, and no "Desk View companion: No" line appears
        // for it above. Same for an ordinary webcam with nothing special at all.
        let webcam = CameraDetail(transport: "Built-in", manufacturer: "Apple Inc.")
        let body = await body(
            .connected(uid: "cam-2", name: "FaceTime HD Camera", detail: webcam),
            allowing: Set(CameraField.allCases.map(\.rawValue))
        )

        #expect(body == "FaceTime HD Camera\nTransport:\tBuilt-in\nManufacturer:\tApple Inc.")
    }

    @Test("only the connect message carries the specification")
    func startingToBeUsedStaysShort() async {
        // The in-use notification is the privacy signal and is read at a glance; the
        // camera's fixed properties were already said when it appeared.
        let delivery = CollectingDelivery()
        let monitor = CameraMonitor(
            source: ScriptedCameraSource(script: [
                .runningStateChanged(running: [:]),
                .runningStateChanged(running: ["cam-1": "iPhone Camera"])
            ]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: CameraMonitor.category,
                preferences: ChosenFields(allowed: Set(CameraField.allCases.map(\.rawValue)))
            )
        )
        await monitor.start()
        for _ in 0..<100 where await delivery.events.isEmpty { await Task.yield() }
        await monitor.stop()

        #expect(await delivery.events.first?.body == "iPhone Camera")
    }

    @Test("a source that says nothing about the camera still produces a usable message")
    func noDetailIsFine() async {
        let body = await body(
            .connected(uid: "cam-3", name: "Some Camera"),
            allowing: Set(CameraField.allCases.map(\.rawValue))
        )

        #expect(body == "Some Camera")
    }
}
