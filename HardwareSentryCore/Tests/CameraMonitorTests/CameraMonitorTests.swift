import AppKit
import CoreAudio
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

/// A source that can be driven event by event, for the cases where a setting has to be
/// changed *between* two events rather than before both of them.
final class LiveCameraSource: CameraSource, @unchecked Sendable {
    private let continuation: AsyncStream<CameraSourceEvent>.Continuation
    private let stream: AsyncStream<CameraSourceEvent>

    init() {
        var escaped: AsyncStream<CameraSourceEvent>.Continuation!
        stream = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func changes() -> AsyncStream<CameraSourceEvent> { stream }
    func send(_ event: CameraSourceEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
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

    @Test("a USB camera is announced by default, alongside whatever USB Monitor says")
    func usbCameraIsAnnouncedByDefault() async {
        let events = await run([
            .connected(uid: "cam-1", name: "Composite Webcam", detail: CameraDetail(transport: "USB"))
        ])
        #expect(events.count == 1)
        // Its own event, not the built-in camera's: switching one off must not silence
        // the other, the same reasoning USB Monitor's own per-class rows rest on.
        #expect(events.first?.name == "CameraWebcamConnected")
        #expect(events.first?.title == "Webcam Connected")
    }

    // Reported live: with USB Monitor's own notice folded away for a kind Camera already
    // covers, "Camera Connected" was the only wording left for what is, in hand, a
    // webcam — the one place that word came from was the very notice being folded away.
    @Test("a built-in camera still says Camera; a USB one says Webcam, connecting and disconnecting")
    func wordingMatchesWhatActuallyConnected() async {
        let builtIn = await run([
            .connected(uid: "cam-1", name: "FaceTime HD Camera", detail: CameraDetail(transport: "Built-in")),
            .disconnected(uid: "cam-1", name: "FaceTime HD Camera")
        ])
        #expect(builtIn.map(\.title) == ["Camera Connected", "Camera Disconnected"])
        #expect(builtIn.map(\.name) == ["CameraConnected", "CameraDisconnected"])

        let webcam = await run([
            .connected(uid: "cam-2", name: "Logitech BRIO", detail: CameraDetail(transport: "USB")),
            .disconnected(uid: "cam-2", name: "Logitech BRIO")
        ])
        #expect(webcam.map(\.title) == ["Webcam Connected", "Webcam Disconnected"])
        #expect(webcam.map(\.name) == ["CameraWebcamConnected", "CameraWebcamDisconnected"])
    }

    @Test("an iPhone providing Continuity Camera is named as one, not as a webcam")
    func continuityCameraIsNamedCorrectly() async {
        // Continuity Camera is reported over a USB-shaped transport by the system, the
        // same as an ordinary external webcam — checked ahead of the USB case on purpose,
        // since the more specific answer is the useful one.
        let events = await run([
            .connected(uid: "cam-1", name: "Jensy's iPhone", detail: CameraDetail(transport: "USB", isContinuityCamera: true)),
            .disconnected(uid: "cam-1", name: "Jensy's iPhone")
        ])
        #expect(events.map(\.title) == ["Continuity Camera Connected", "Continuity Camera Disconnected"])
        #expect(events.map(\.name) == ["CameraContinuityConnected", "CameraContinuityDisconnected"])
    }

    @Test("Desk View is named as Desk View, ahead of Continuity or webcam")
    func deskViewIsNamedCorrectly() async {
        let events = await run([
            .connected(
                uid: "cam-1", name: "Jensy's iPhone",
                detail: CameraDetail(transport: "USB", isContinuityCamera: true, isDeskViewCamera: true)
            ),
            .disconnected(uid: "cam-1", name: "Jensy's iPhone")
        ])
        #expect(events.map(\.title) == ["Desk View Connected", "Desk View Disconnected"])
        #expect(events.map(\.name) == ["CameraDeskViewConnected", "CameraDeskViewDisconnected"])
    }

    /// The exact shape of a live failure this replaces: the source described the
    /// transport in lower case, an old switch compared against "USB", and the check
    /// never matched. There is no switch to break that way any more — a USB camera is
    /// always announced as a webcam — but the case-insensitive naming still deserves its
    /// own pin, independent of `CameraDetail.describe(transport:)`'s own test for it.
    @Test("a USB camera is always named a webcam, whatever case the transport is spelled in")
    func webcamNamingIgnoresCase() async {
        for spelling in ["usb", "USB", "Usb"] {
            let events = await run([
                .connected(uid: "cam-1", name: "Composite Webcam", detail: CameraDetail(transport: spelling)),
                .disconnected(uid: "cam-1", name: "Composite Webcam")
            ])
            #expect(events.map(\.name) == ["CameraWebcamConnected", "CameraWebcamDisconnected"], "\(spelling) should read as a webcam")
        }
    }

    /// A camera is always announced as what it is, independent of any setting — the
    /// invariant that replaced "notify for USB devices independently of USB Monitor"
    /// ever silencing this module's own notice. Modelled live, across a setting change
    /// mid-connection, to confirm nothing here still depends on it.
    @Test("a webcam is announced connecting and disconnecting, unaffected by unrelated settings changing mid-flight")
    func webcamAnnouncedRegardlessOfSettingChanges() async {
        let source = LiveCameraSource()
        let delivery = CollectingDelivery()
        let monitor = CameraMonitor(
            source: source,
            context: MonitorContext(dispatcher: NotificationDispatcher(delivery: delivery), category: CameraMonitor.category),
            stopDebounce: 0.01
        )
        await monitor.start()

        source.send(.connected(uid: "cam-1", name: "Logitech BRIO", detail: CameraDetail(transport: "USB")))
        for _ in 0..<200 { await Task.yield() }
        #expect(await delivery.events.map(\.title) == ["Webcam Connected"])

        // An unrelated setting changing mid-connection must not affect this camera.
        await monitor.apply(notifiesVirtualDevices: true)

        source.send(.disconnected(uid: "cam-1", name: "Logitech BRIO"))
        for _ in 0..<200 { await Task.yield() }
        source.finish()
        await monitor.stop()

        #expect(await delivery.events.map(\.title) == ["Webcam Connected", "Webcam Disconnected"])
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

    // Reported live: "webcam.fill" compiles — `.symbol(_:)` just wraps a string — but does
    // not exist as an SF Symbol on this system, and a banner asking for a symbol that does
    // not exist shows no icon at all rather than a placeholder. A compile-clean typo in an
    // icon name is exactly the kind of mistake this pins against happening silently again.
    @Test("every SF Symbol icon this monitor declares actually exists on this system")
    func declaredSymbolsExist() {
        for event in CameraMonitor.events {
            guard case .symbol(let name) = event.icon else { continue }
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(event.name) names a symbol that does not exist: \(name)")
        }
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: CameraMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "CameraConnected": true,
            "CameraDisconnected": true,
            "CameraWebcamConnected": true,
            "CameraWebcamDisconnected": true,
            "CameraContinuityConnected": true,
            "CameraContinuityDisconnected": true,
            "CameraDeskViewConnected": true,
            "CameraDeskViewDisconnected": true,
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

@Suite("AVFoundationCameraSource · which transports get their own report")
struct AVFoundationCameraSourceTransportTests {
    // Reported live: a real USB webcam was seen by USB Monitor as a generic device
    // (many declare class 0xEF, "Miscellaneous", at the device level) and never announced
    // as a camera at all. This monitor used to stay quiet for any USB or Bluetooth
    // transport, on the theory that USB/Bluetooth Monitor already said something; that
    // theory held for Bluetooth (a pairing is a pairing) but not for USB, where what gets
    // said is never the resolution, the manufacturer, or whether Center Stage is active.

    @Test("USB is announced by this monitor too now")
    func usbIsNotSuppressed() {
        #expect(AVFoundationCameraSource.isAlreadyCoveredByAnotherMonitor(Int32(bitPattern: kAudioDeviceTransportTypeUSB)) == false)
    }

    // Reported live: the "notify for USB devices independently" switch did nothing at
    // all. The switch compares the described transport against "USB", but no case here
    // named USB, so a USB webcam fell through to the raw four-character code and
    // described itself as "usb" — which never matched. The tests that covered the switch
    // passed throughout, because they built a `CameraDetail(transport: "USB")` by hand
    // rather than using the spelling the real source produces. This pins the spelling
    // itself so the two halves cannot drift apart again.
    @Test("a USB camera describes its transport as USB, the spelling the setting compares")
    func usbTransportIsSpelledUSB() {
        #expect(CameraDetail.describe(transport: Int32(bitPattern: kAudioDeviceTransportTypeUSB)) == "USB")
    }

    @Test("the named transports keep the spellings they are shown with")
    func namedTransportsKeepTheirSpelling() {
        #expect(CameraDetail.describe(transport: Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)) == "Built-in")
        #expect(CameraDetail.describe(transport: Int32(bitPattern: kAudioDeviceTransportTypeVirtual)) == "Virtual")
        #expect(CameraDetail.describe(transport: Int32(bitPattern: kAudioDeviceTransportTypeThunderbolt)) == "Thunderbolt")
    }

    @Test("Bluetooth stays Bluetooth Monitor's own announcement")
    func bluetoothIsStillSuppressed() {
        #expect(AVFoundationCameraSource.isAlreadyCoveredByAnotherMonitor(Int32(bitPattern: kAudioDeviceTransportTypeBluetooth)))
        #expect(AVFoundationCameraSource.isAlreadyCoveredByAnotherMonitor(Int32(bitPattern: kAudioDeviceTransportTypeBluetoothLE)))
    }

    @Test("an ordinary transport was never suppressed, and still is not")
    func ordinaryTransportIsUnaffected() {
        #expect(AVFoundationCameraSource.isAlreadyCoveredByAnotherMonitor(Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)) == false)
    }
}
