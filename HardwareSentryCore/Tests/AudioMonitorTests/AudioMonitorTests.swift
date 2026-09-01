import Foundation
import SignalCore
import SentryContract
import Testing
@testable import AudioMonitor

struct ScriptedAudioSource: AudioSource {
    let script: [AudioSourceEvent]

    func changes() -> AsyncStream<AudioSourceEvent> {
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

private func device(_ id: String, name: String = "Device", transport: AudioTransport = .hdmi, input: Bool = false) -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(id: id, name: name, transport: transport, isInputCapable: input)
}

@Suite("AudioMonitor")
struct AudioMonitorTests {
    private func run(_ script: [AudioSourceEvent], settleFor debounce: Double = 0.05) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = AudioMonitor(
            source: ScriptedAudioSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: AudioMonitor.category),
            micStopDebounce: debounce
        )

        await monitor.start()
        try? await Task.sleep(nanoseconds: UInt64((debounce + 0.05) * 1_000_000_000))
        await monitor.stop()
        return await delivery.events
    }

    @Test("the first device snapshot is a silent baseline")
    func deviceBaselineIsSilent() async {
        let events = await run([.deviceSnapshot([device("1", transport: .hdmi)])])
        #expect(events.isEmpty)
    }

    @Test("a device over a covered transport (USB/Bluetooth) is never announced")
    func coveredTransportIsSuppressed() async {
        let events = await run([
            .deviceSnapshot([]),
            .deviceSnapshot([device("1", transport: .usb)])
        ])
        #expect(events.isEmpty)
    }

    @Test("a device over an uncovered transport is announced connecting and disconnecting")
    func uncoveredTransportIsAnnounced() async {
        let events = await run([
            .deviceSnapshot([]),
            .deviceSnapshot([device("1", name: "Studio Display", transport: .displayPort)]),
            .deviceSnapshot([])
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "AudioDeviceConnected")
        #expect(events[1].name == "AudioDeviceDisconnected")
    }

    @Test("a suppressed device disconnecting never fires a stray disconnect")
    func suppressedDeviceNeverFiresDisconnect() async {
        let events = await run([
            .deviceSnapshot([device("1", transport: .usb)]),
            .deviceSnapshot([])
        ])
        #expect(events.isEmpty)
    }

    @Test("the first default reading is a silent baseline, a real change is announced")
    func defaultOutputBaselineThenChange() async {
        let events = await run([
            .defaultOutputChanged(id: "1", name: "Built-in Speakers"),
            .defaultOutputChanged(id: "2", name: "AirPods")
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "AudioDefaultOutputChanged")
        #expect(events.first?.body == "AirPods")
    }

    @Test("default output and input are tracked independently")
    func outputAndInputAreIndependent() async {
        let events = await run([
            .defaultOutputChanged(id: "1", name: "Speakers"),
            .defaultInputChanged(id: "2", name: "Mic"),
            .defaultOutputChanged(id: "3", name: "Headphones")
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "AudioDefaultOutputChanged")
    }

    @Test("a mic starting is announced immediately")
    func micStartIsImmediate() async {
        let events = await run([
            .micRunningSnapshot([:]),
            .micRunningSnapshot(["1": "Built-in Microphone"])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "AudioMicInUseChanged")
        #expect(events.first?.title == "Microphone Started Being Used")
    }

    @Test("a mic stopping only announces after the debounce survives")
    func micStopIsDebounced() async {
        // The first snapshot is the baseline (silent, like every other baselined signal in
        // this app) — only the drop-out that follows it is a real, announced transition.
        let events = await run([
            .micRunningSnapshot(["1": "Built-in Microphone"]),
            .micRunningSnapshot([:])
        ], settleFor: 0.05)

        #expect(events.count == 1)
        #expect(events.first?.title == "Microphone Stopped Being Used")
    }

    @Test("a mic that flickers off and back on before the debounce fires is never announced as stopped")
    func micFlickerIsNeverAnnouncedAsStopped() async {
        let events = await run([
            .micRunningSnapshot(["1": "Built-in Microphone"]),
            .micRunningSnapshot([:]),
            .micRunningSnapshot(["1": "Built-in Microphone"])
        ], settleFor: 0.05)

        #expect(events.isEmpty)
    }

    @Test("every event it can raise is declared for preferences to find")
    func eventsAreDeclared() {
        let declared = Set(AudioMonitor.events.map(\.name))
        #expect(declared == [
            "AudioDefaultOutputChanged", "AudioDefaultInputChanged",
            "AudioDeviceConnected", "AudioDeviceDisconnected",
            "AudioMicInUseChanged", "AudioMIDIDeviceAdded", "AudioMIDIDeviceRemoved"
        ])
    }

    @Test("a MIDI device appearing and disappearing is announced")
    func midiAddedAndRemoved() async {
        let events = await run([
            .midiDeviceAdded(name: "Launchkey Mini"),
            .midiDeviceRemoved(name: "Launchkey Mini")
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "AudioMIDIDeviceAdded")
        #expect(events[1].name == "AudioMIDIDeviceRemoved")
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = AudioMonitor(
            source: ScriptedAudioSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: AudioMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
