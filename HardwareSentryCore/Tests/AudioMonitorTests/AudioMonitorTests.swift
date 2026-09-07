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
    /// Runs a script through the monitor and returns what it announced.
    ///
    /// `expecting` is the number of notifications the script should produce. Waiting for
    /// the debounce in wall clock alone is not enough: the mic-stop notification is
    /// raised by a task that wakes when the debounce elapses, and under a full-suite run
    /// that task can still be waiting its turn when the sleep returns. The bounded poll
    /// that follows waits for the announcement itself, the same way the volume suite
    /// below already does.
    private func run(
        _ script: [AudioSourceEvent],
        settleFor debounce: Double = 0.05,
        notifiesVirtualDevices: Bool = false,
        expecting: Int
    ) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = AudioMonitor(
            source: ScriptedAudioSource(script: script),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: AudioMonitor.category,
                // These exercise what happens when something *changes*, so the startup
                // sweep is switched off: with it on, the first snapshot is announced and
                // every count below would be measuring the sweep as well as the change.
                announcesWhatIsAlreadyThere: false
            ),
            micStopDebounce: debounce,
            notifiesVirtualDevices: notifiesVirtualDevices
        )

        await monitor.start()
        try? await Task.sleep(nanoseconds: UInt64((debounce + 0.05) * 1_000_000_000))
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the first device snapshot is a silent baseline")
    func deviceBaselineIsSilent() async {
        let events = await run([.deviceSnapshot([device("1", transport: .hdmi)])], expecting: 0)
        #expect(events.isEmpty)
    }

    @Test("a Bluetooth-paired device is never announced here — Bluetooth Monitor already does")
    func coveredTransportIsSuppressed() async {
        let events = await run([
            .deviceSnapshot([]),
            .deviceSnapshot([device("1", transport: .bluetooth)])
        ], expecting: 0)
        #expect(events.isEmpty)
    }

    @Test("a device over an uncovered transport is announced connecting and disconnecting")
    func uncoveredTransportIsAnnounced() async {
        let events = await run([
            .deviceSnapshot([]),
            .deviceSnapshot([device("1", name: "Studio Display", transport: .displayPort)]),
            .deviceSnapshot([])
        ], expecting: 2)

        #expect(events.count == 2)
        #expect(events[0].name == "AudioDeviceConnected")
        #expect(events[1].name == "AudioDeviceDisconnected")
    }

    @Test("a USB audio device is announced too, alongside whatever USB Monitor says")
    func usbTransportIsAnnouncedTooNow() async {
        // Reported live: HG4MAC and this application both used to stay quiet here, on the
        // theory that USB Monitor already said something about the same physical device.
        // What USB Monitor says is "a USB device connected" and never the sample rate, the
        // channel count, or which of two interfaces just became the default — asked for
        // both, since the second one is the only place that information exists.
        let events = await run([
            .deviceSnapshot([]),
            .deviceSnapshot([device("1", name: "USB Audio Interface", transport: .usb)]),
            .deviceSnapshot([])
        ], expecting: 2)

        #expect(events.count == 2)
        #expect(events[0].name == "AudioDeviceConnected")
        #expect(events[1].name == "AudioDeviceDisconnected")
    }

    @Test("a suppressed Bluetooth device disconnecting never fires a stray disconnect")
    func suppressedDeviceNeverFiresDisconnect() async {
        let events = await run([
            .deviceSnapshot([device("1", transport: .bluetooth)]),
            .deviceSnapshot([])
        ], expecting: 0)
        #expect(events.isEmpty)
    }

    // A USB audio device always gets its own notice here now — whether USB Monitor's own
    // generic notice for the same device also fires is USB Monitor's own decision (fed by
    // this module's setting through the registry), not something this module suppresses
    // itself for any more. Reported live: "Notify for USB devices independently of USB
    // Monitor" switched off used to silence this module's own notice, leaving only USB
    // Monitor's — the opposite of what was asked for once Audio's own wording became the
    // one worth keeping. The connect-only case above already covers this; this one is the
    // disconnect side, since that used to be the one that stayed silent.
    @Test("a USB device disconnecting is announced too, not just connecting")
    func usbDeviceDisconnectIsAnnouncedToo() async {
        let events = await run([
            .deviceSnapshot([]),
            .deviceSnapshot([device("1", transport: .usb)]),
            .deviceSnapshot([])
        ], expecting: 2)
        #expect(events.map(\.name) == ["AudioDeviceConnected", "AudioDeviceDisconnected"])
    }

    @Test("a virtual or aggregate device is not announced by default")
    func virtualDeviceIsSuppressedByDefault() async {
        let events = await run([
            .deviceSnapshot([]),
            .deviceSnapshot([device("1", name: "ZoomAudioDevice", transport: .virtual)]),
            .deviceSnapshot([device("2", name: "Multi-Output Device", transport: .aggregate)])
        ], expecting: 0)
        #expect(events.isEmpty)
    }

    @Test("a virtual or aggregate device is announced once asked for, and takes effect live")
    func virtualDeviceCanBeSwitchedOnWhileRunning() async {
        // Not run() — this needs to flip the setting mid-flight, which only apply() does.
        let delivery = CollectingDelivery()
        let monitor = AudioMonitor(
            source: ScriptedAudioSource(script: [
                .deviceSnapshot([]),
                .deviceSnapshot([device("1", name: "ZoomAudioDevice", transport: .virtual)])
            ]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: AudioMonitor.category,
                announcesWhatIsAlreadyThere: false
            )
        )
        await monitor.apply(volumeCriticalThreshold: 90, notifiesVirtualDevices: true)
        await monitor.start()
        for _ in 0..<200 where await delivery.events.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()

        let events = await delivery.events
        #expect(events.count == 1)
        #expect(events.first?.name == "AudioDeviceConnected")
    }

    @Test("a suppressed virtual device disconnecting never fires a stray disconnect")
    func suppressedVirtualDeviceNeverFiresDisconnect() async {
        let events = await run([
            .deviceSnapshot([device("1", transport: .virtual)]),
            .deviceSnapshot([])
        ], expecting: 0)
        #expect(events.isEmpty)
    }

    @Test("the first default reading is a silent baseline, a real change is announced")
    func defaultOutputBaselineThenChange() async {
        let events = await run([
            .defaultOutputChanged(id: "1", name: "Built-in Speakers"),
            .defaultOutputChanged(id: "2", name: "AirPods")
        ], expecting: 1)

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
        ], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "AudioDefaultOutputChanged")
    }

    @Test("a mic starting is announced immediately")
    func micStartIsImmediate() async {
        let events = await run([
            .micRunningSnapshot([:]),
            .micRunningSnapshot(["1": "Built-in Microphone"])
        ], expecting: 1)

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
        ], settleFor: 0.05, expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.title == "Microphone Stopped Being Used")
    }

    @Test("a mic that flickers off and back on before the debounce fires is never announced as stopped")
    func micFlickerIsNeverAnnouncedAsStopped() async {
        let events = await run([
            .micRunningSnapshot(["1": "Built-in Microphone"]),
            .micRunningSnapshot([:]),
            .micRunningSnapshot(["1": "Built-in Microphone"])
        ], settleFor: 0.05, expecting: 0)

        #expect(events.isEmpty)
    }

    @Test("every event it can raise is declared for preferences to find")
    func eventsAreDeclared() {
        let declared = Set(AudioMonitor.events.map(\.name))
        #expect(declared == [
            "AudioDefaultOutputChanged", "AudioDefaultInputChanged",
            "AudioDeviceConnected", "AudioDeviceDisconnected",
            "AudioMicInUseChanged", "AudioMIDIDeviceAdded", "AudioMIDIDeviceRemoved",
            "AudioSampleRateChanged", "AudioVolumeCritical", "AudioJackChanged",
            "AudioDataSourceChanged", "AudioDeviceStoppedResponding",
            "AudioMicrophoneModeChanged",
            "AudioHeadTrackingHeadphonesConnected", "AudioHeadTrackingHeadphonesDisconnected"
        ])
    }

    @Test("a MIDI device appearing and disappearing is announced")
    func midiAddedAndRemoved() async {
        let events = await run([
            .midiDeviceAdded(name: "Launchkey Mini"),
            .midiDeviceRemoved(name: "Launchkey Mini")
        ], expecting: 2)

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

@Suite("Audio device detail")
struct AudioDeviceDetailTests {
    @Test("a fixed-rate device does not pretend to offer a choice")
    func singleRateRangeIsOmitted() {
        // "48000–48000 Hz" is a fixed rate dressed up as a range.
        let fixed = AudioDeviceDetail(sampleRateRange: 48000...48000)
        #expect(fixed.sampleRateRangeNote == nil)

        let variable = AudioDeviceDetail(sampleRateRange: 44100...192000)
        #expect(variable.sampleRateRangeNote == "44100–192000 Hz")
    }

    @Test("latency is given in milliseconds as well as frames when the rate is known")
    func latencyIsTranslated() {
        // Frames alone mean nothing without the rate to divide by.
        let known = AudioDeviceDetail(sampleRate: 48000, latencyFrames: 512)
        #expect(known.latencyNote == "512 frames (~10.7 ms)")
    }

    @Test("latency without a rate is still reported, in the unit that is known")
    func latencyWithoutRate() {
        #expect(AudioDeviceDetail(latencyFrames: 512).latencyNote == "512 frames")
    }

    @Test("model and manufacturer read as one line rather than two opaque strings")
    func modelAndManufacturerCombine() {
        let both = AudioDeviceDetail(modelUID: "AppleUSBAudio:Scarlett", manufacturer: "Focusrite")
        #expect(both.modelManufacturerNote == "Focusrite · AppleUSBAudio:Scarlett")

        // A device that answers only one still gets a line.
        #expect(AudioDeviceDetail(manufacturer: "Apple Inc.").modelManufacturerNote == "Apple Inc.")
        #expect(AudioDeviceDetail().modelManufacturerNote == nil)
    }

    @Test("a device that answers nothing produces no lines at all")
    func silenceWhenNothingIsKnown() {
        let empty = AudioDeviceDetail()
        #expect(empty.sampleRateNote == nil)
        #expect(empty.outputChannelsNote == nil)
        #expect(empty.muteNote == nil)
        #expect(empty.bitDepthNote == nil)
        #expect(empty.latencyNote == nil)
    }

    @Test("muted reads both ways, unlike the present-only lines elsewhere")
    func muteReadsBothWays() {
        // Whether the thing you just plugged in is muted is worth knowing either way.
        #expect(AudioDeviceDetail(isMuted: true).muteNote == "Yes")
        #expect(AudioDeviceDetail(isMuted: false).muteNote == "No")
    }
}

@Suite("Dangerous output volume")
struct AudioVolumeCriticalTests {
    private func run(_ script: [AudioSourceEvent], expecting: Int, threshold: Int = 90) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = AudioMonitor(
            source: ScriptedAudioSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: AudioMonitor.category
            ),
            volumeCriticalThreshold: threshold
        )
        await monitor.start()
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("crossing the threshold warns once")
    func warnsOnCrossing() async {
        let events = await run([
            .outputVolume(name: "MacBook Air Speakers", percent: 50),
            .outputVolume(name: "MacBook Air Speakers", percent: 95)
        ], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "AudioVolumeCritical")
        #expect(events.first?.title == "Volume Critically High")
        #expect(events.first?.body == "MacBook Air Speakers:\t95%")
    }

    @Test("nudging around the threshold does not warn per keypress")
    func hysteresisHoldsBackRepeats() async {
        // Without this, each press of the volume key produces a warning.
        let events = await run([
            .outputVolume(name: "Speakers", percent: 95),
            .outputVolume(name: "Speakers", percent: 89),
            .outputVolume(name: "Speakers", percent: 95),
            .outputVolume(name: "Speakers", percent: 100)
        ], expecting: 1)
        #expect(events.count == 1)
    }

    @Test("turning it properly down re-arms the warning")
    func comingDownReArms() async {
        // Ten points below is far enough that coming back means somebody actually turned
        // it down rather than jiggling it.
        let events = await run([
            .outputVolume(name: "Speakers", percent: 95),
            .outputVolume(name: "Speakers", percent: 70),
            .outputVolume(name: "Speakers", percent: 95)
        ], expecting: 2)
        #expect(events.count == 2)
    }

    @Test("a volume already high at launch is warned about")
    func alreadyHighAtLaunchWarns() async {
        // Unlike a device inventory, this is a live hazard rather than a fact about what
        // is plugged in — it deserves saying whether or not it just changed.
        let events = await run([.outputVolume(name: "Speakers", percent: 100)], expecting: 1)
        #expect(events.count == 1)
    }

    @Test("moving the threshold takes effect without a relaunch")
    func thresholdAppliesWhileRunning() async {
        // The gap this closes: the threshold lived in the core with a default of 90 and
        // nothing in the settings window could reach it, so the only way to change it was
        // not to. Now the slider has to reach a running monitor.
        let delivery = CollectingDelivery()
        let source = ScriptedAudioSource(script: [.outputVolume(name: "Speakers", percent: 75)])
        let monitor = AudioMonitor(
            source: source,
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: AudioMonitor.category
            ),
            volumeCriticalThreshold: 90
        )
        await monitor.apply(volumeCriticalThreshold: 70, notifiesVirtualDevices: false)
        await monitor.start()
        for _ in 0..<200 where await delivery.events.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        #expect(await delivery.events.count == 1)
    }

    @Test("the threshold is configurable")
    func thresholdIsConfigurable() async {
        let events = await run([.outputVolume(name: "Speakers", percent: 75)], expecting: 1, threshold: 70)
        #expect(events.count == 1)
    }
}

@Suite("Audio device state events")
struct AudioDeviceStateTests {
    private func run(_ script: [AudioSourceEvent], expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = AudioMonitor(
            source: ScriptedAudioSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: AudioMonitor.category
            )
        )
        await monitor.start()
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a sample rate moving names both rates")
    func sampleRateChangeNamesBoth() async {
        let events = await run([
            .sampleRateChanged(id: "uid", name: "Scarlett 2i2", from: 44100, to: 48000)
        ], expecting: 1)

        #expect(events.first?.name == "AudioSampleRateChanged")
        #expect(events.first?.title == "Sample Rate Changed")
        #expect(events.first?.body == "Scarlett 2i2:\t44100 Hz → 48000 Hz")
    }

    @Test("plugging into a jack and unplugging read as two things")
    func jackDirectionsAreSeparate() async {
        // A shared subject would make the second update the first banner rather than
        // arriving as its own.
        let events = await run([
            .jackChanged(name: "Built-in Output", isConnected: true),
            .jackChanged(name: "Built-in Output", isConnected: false)
        ], expecting: 2)

        #expect(events.map(\.title) == ["Audio Jack Connected", "Audio Jack Disconnected"])
        #expect(events[0].subject != events[1].subject)
    }

    @Test("a device switching which socket it uses says which")
    func dataSourceChangeNamesTheSource() async {
        let events = await run([
            .dataSourceChanged(name: "Built-in Output", source: "Headphones")
        ], expecting: 1)

        #expect(events.first?.name == "AudioDataSourceChanged")
        #expect(events.first?.body == "Built-in Output\nHeadphones")
    }

    @Test("a device that stops answering is reported without being called disconnected")
    func stoppedRespondingIsItsOwnThing() async {
        // It is still in the device list — saying it disconnected would be wrong, and
        // saying nothing would leave somebody wondering why audio stopped.
        let events = await run([.deviceStoppedResponding(name: "Scarlett 2i2")], expecting: 1)
        #expect(events.first?.name == "AudioDeviceStoppedResponding")
        #expect(events.first?.title == "Audio Device Stopped Responding")
    }

    @Test("the microphone mode is named")
    func microphoneModeIsNamed() async {
        let events = await run([.microphoneModeChanged("Voice Isolation")], expecting: 1)
        #expect(events.first?.name == "AudioMicrophoneModeChanged")
        #expect(events.first?.body == "Voice Isolation")
    }

    @Test("head-tracking headphones use distinct events in each direction")
    func headTrackingBothDirections() async {
        let events = await run([
            .headTrackingChanged(isActive: true),
            .headTrackingChanged(isActive: false)
        ], expecting: 2)

        #expect(events.map(\.name) == [
            "AudioHeadTrackingHeadphonesConnected",
            "AudioHeadTrackingHeadphonesDisconnected"
        ])
        #expect(events[0].body.contains("spatial audio head tracking"))
    }
}

@Suite("AudioTransport")
struct AudioTransportTests {
    @Test("the transports that are real devices are named, not filed under Other")
    func namedTransports() {
        // Both added after an audit found them falling through: an iPhone standing in as
        // a microphone over Continuity is common, and AVB is what pro interfaces use.
        #expect(AudioTransport.continuity.label == "Continuity")
        #expect(AudioTransport.avb.label == "AVB")
        // Neither is wireless-in-the-Bluetooth sense, and neither is software, so neither
        // may be swept up by the switches that silence those.
        #expect(!AudioTransport.continuity.isCoveredByAnotherMonitor)
        #expect(!AudioTransport.continuity.isVirtualOrAggregate)
        #expect(!AudioTransport.avb.isCoveredByAnotherMonitor)
        #expect(!AudioTransport.avb.isVirtualOrAggregate)
        // The fallback still exists for a transport genuinely nobody has named.
        #expect(AudioTransport.other.label == "Other")
    }
}

@Suite("Audio device identity")
struct AudioIdentityTests {
    @Test("CoreAudio's \"Unknown Manufacturer\" placeholder is not reported as a maker")
    func placeholderManufacturerIsRefused() {
        // Read live 2026-09-07 from a real Logitech BRIO: CoreAudio answers the phrase
        // "Unknown Manufacturer", so the notification read
        // "Model: Unknown Manufacturer · Logitech BRIO:046D:085E".
        #expect(AudioDeviceDetail.realAnswer("Unknown Manufacturer") == nil)
        #expect(AudioDeviceDetail.realAnswer("unknown manufacturer") == nil)
        #expect(AudioDeviceDetail.realAnswer("  Unknown Manufacturer ") == nil)
        #expect(AudioDeviceDetail.realAnswer("Unknown") == nil)
        #expect(AudioDeviceDetail.realAnswer("") == nil)
        #expect(AudioDeviceDetail.realAnswer(nil) == nil)
        // Real makers, read live from the same machine, still come through.
        #expect(AudioDeviceDetail.realAnswer("Apple Inc.") == "Apple Inc.")
        #expect(AudioDeviceDetail.realAnswer("Microsoft Corp.") == "Microsoft Corp.")
        // Matched whole: a company whose name merely starts that way is not a placeholder.
        #expect(AudioDeviceDetail.realAnswer("Unknown Devices Ltd") == "Unknown Devices Ltd")
    }

    @Test("with the maker refused, the model line still says the model")
    func modelSurvivesWithoutAMaker() {
        // What the BRIO now produces: the placeholder gone, the model kept.
        let detail = AudioDeviceDetail(modelUID: "Logitech BRIO:046D:085E", manufacturer: nil)
        #expect(detail.modelManufacturerNote == "Logitech BRIO:046D:085E")
        let both = AudioDeviceDetail(modelUID: "Digital Mic", manufacturer: "Apple Inc.")
        #expect(both.modelManufacturerNote == "Apple Inc. · Digital Mic")
    }
}
