import Foundation
import SentryContract
import SignalCore

/// Says which device macOS is actually using for output/input, when a device not already
/// covered by USB/Bluetooth Monitor connects or disconnects, when a microphone starts or
/// stops being used by any app, and when a MIDI device appears or disappears.
public actor AudioMonitor: Monitor {
    public static let category = AudioEvent.category

    /// In the original's order and its words. Micro-detail worth keeping: the original
    /// pairs the microphone's two states as one row and the head-tracking pair as one, but
    /// this keeps them apart — an "in use" notification and an "idle" one are the two
    /// halves of a privacy signal, and somebody may reasonably want only the first.
    public static let events: [MonitorEventDescription] = [
        .init(name: AudioEvent.connected.rawValue, title: "Connected", icon: .asset("AudioMonitor-Icon", in: .module)),
        .init(name: AudioEvent.disconnected.rawValue, title: "Disconnected/Muted", icon: .asset("AudioMonitor-Icon-Off", in: .module)),
        .init(name: AudioEvent.defaultOutputChanged.rawValue, title: "Default Output Changed", icon: .asset("AudioMonitor-Icon", in: .module)),
        .init(name: AudioEvent.defaultInputChanged.rawValue, title: "Default Input Changed", icon: .asset("AudioMonitor-Icon-MicIdle", in: .module)),
        .init(name: AudioEvent.micInUseChanged.rawValue, title: "Microphone In Use / Idle", icon: .asset("AudioMonitor-Icon-MicInUse", in: .module)),
        .init(name: AudioEvent.sampleRateChanged.rawValue, title: "Sample Rate Changed", icon: .asset("AudioMonitor-Icon-SampleRate", in: .module)),
        .init(name: AudioEvent.volumeCritical.rawValue, title: "Volume Critical", enabledByDefault: false, icon: .asset("AudioMonitor-Icon-VolumeCritical", in: .module)),
        .init(name: AudioEvent.jackChanged.rawValue, title: "Audio Jack Changed", enabledByDefault: false, icon: .asset("AudioMonitor-Icon", in: .module)),
        .init(name: AudioEvent.dataSourceChanged.rawValue, title: "Audio Source Changed", enabledByDefault: false, icon: .asset("AudioMonitor-Icon", in: .module)),
        .init(name: AudioEvent.deviceStoppedResponding.rawValue, title: "Device Stopped Responding", enabledByDefault: false, icon: .asset("AudioMonitor-Icon-Off", in: .module)),
        .init(name: AudioEvent.microphoneModeChanged.rawValue, title: "Microphone Mode Changed", enabledByDefault: false, icon: .asset("AudioMonitor-Icon-MicInUse", in: .module)),
        .init(name: AudioEvent.headTrackingConnected.rawValue, title: "Head-Tracking Headphones", enabledByDefault: false, icon: .asset("AudioMonitor-Icon", in: .module)),
        .init(name: AudioEvent.headTrackingDisconnected.rawValue, title: "Head-Tracking Headphones Gone", enabledByDefault: false, icon: .asset("AudioMonitor-Icon-Off", in: .module)),
        .init(name: AudioEvent.midiDeviceAdded.rawValue, title: "MIDI Device Connected", enabledByDefault: false, icon: .asset("AudioMonitor-Icon", in: .module)),
        .init(name: AudioEvent.midiDeviceRemoved.rawValue, title: "MIDI Device Disconnected", enabledByDefault: false, icon: .asset("AudioMonitor-Icon-Off", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = AudioField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any AudioSource
    private let context: MonitorContext
    /// Same reasoning as `CameraMonitor`'s: a call starting/ending can briefly cycle
    /// CoreAudio's "running somewhere" state, so a stop is only announced once it survives
    /// this wait. Configurable so tests don't wait a real second per case.
    private let micStopDebounceNanoseconds: UInt64
    private var watching: Task<Void, Never>?
    /// The percentage at which the volume warning fires. Ninety is the original's figure.
    /// Above this percentage the "Volume Critical" warning fires; ten points below it the
    /// warning re-arms. Changeable while running, so moving the slider takes effect now.
    private var volumeCriticalThreshold: Int
    /// Off by default: a virtual/aggregate device is not something that arrived or left,
    /// and most people who see "Audio Device Connected: Zoom Audio Device" once do not
    /// want to see it again every time that app runs.
    private var notifiesVirtualDevices: Bool
    private var hasWarnedAboutVolume = false
    private var lastVolumePercent: Int?

    private var knownDevices: [String: AudioDeviceSnapshot] = [:]
    /// Device IDs this monitor actually announced connecting — a device whose connect was
    /// suppressed by the transport filter must not later fire a confusing disconnect with
    /// no matching connect ever having appeared.
    private var reportedConnectedIDs: Set<String> = []
    private var hasDeviceBaseline = false

    private var lastKnownDefaultOutput: String?
    private var lastKnownDefaultInput: String?

    private var currentlyRunningMics: Set<String> = []
    private var runningMicNames: [String: String] = [:]
    private var lastNotifiedRunningMics: Set<String> = []
    private var hasMicBaseline = false
    private var pendingMicStops: [String: Task<Void, Never>] = [:]

    public init(
        source: any AudioSource,
        context: MonitorContext,
        micStopDebounce: Double = 1.0,
        volumeCriticalThreshold: Int = 90,
        notifiesVirtualDevices: Bool = false
    ) {
        self.source = source
        self.context = context
        self.micStopDebounceNanoseconds = UInt64(micStopDebounce * 1_000_000_000)
        self.volumeCriticalThreshold = volumeCriticalThreshold
        self.notifiesVirtualDevices = notifiesVirtualDevices
    }

    /// Called when a setting changes, so it applies without a relaunch.
    public func apply(volumeCriticalThreshold: Int, notifiesVirtualDevices: Bool) {
        self.volumeCriticalThreshold = volumeCriticalThreshold
        self.notifiesVirtualDevices = notifiesVirtualDevices
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source] in
            for await event in source.changes() {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
        pendingMicStops.values.forEach { $0.cancel() }
        pendingMicStops.removeAll()
    }

    /// Warns once when the output volume crosses into territory that will damage hearing,
    /// and stays quiet until it comes properly back down.
    ///
    /// The hysteresis is what makes this usable rather than infuriating: without it,
    /// nudging the volume around the threshold produces a warning per keypress. Ten points
    /// below is far enough that coming back means somebody actually turned it down.
    private func handleOutputVolume(name: String, percent: Int) async {
        defer { lastVolumePercent = percent }

        if percent >= volumeCriticalThreshold {
            guard !hasWarnedAboutVolume else { return }
            hasWarnedAboutVolume = true
            await context.notify(
                AudioEvent.volumeCritical.rawValue, subject: name,
                title: "Volume Critically High",
                body: "\(name):\t\(percent)%",
                icon: .asset("AudioMonitor-Icon-VolumeCritical", in: .module)
            )
        } else if percent <= volumeCriticalThreshold - 10 {
            hasWarnedAboutVolume = false
        }
    }

    /// The lines describing a device, in the order the original prints them.
    ///
    /// Shared by the connect notification and the default-changed ones, because the same
    /// device deserves the same description whichever brought it up.
    private static func detailLines(for device: AudioDeviceSnapshot) -> [BodyLine] {
        [
            .field(AudioField.transport.rawValue, "Transport", device.transport.label),
            .field(AudioField.channels.rawValue, "Output channels", device.detail.outputChannelsNote),
            .field(AudioField.channels.rawValue, "Input channels", device.detail.inputChannelsNote),
            .field(AudioField.sampleRate.rawValue, "Sample rate", device.detail.sampleRateNote),
            .field(AudioField.deviceUID.rawValue, "Device UID", device.detail.uid),
            .field(AudioField.modelManufacturer.rawValue, "Model", device.detail.modelManufacturerNote),
            .field(AudioField.clockSource.rawValue, "Clock source", device.detail.clockSource),
            .field(AudioField.sampleRateRange.rawValue, "Supported sample rates", device.detail.sampleRateRangeNote),
            .field(AudioField.muteState.rawValue, "Muted", device.detail.muteNote),
            .field(AudioField.bitDepth.rawValue, "Bit depth", device.detail.bitDepthNote),
            .field(AudioField.latency.rawValue, "Latency", device.detail.latencyNote)
        ]
    }

    private func handle(_ event: AudioSourceEvent) async {
        switch event {
        case .deviceSnapshot(let devices):
            await handleDeviceSnapshot(devices)
        case .defaultOutputChanged(let id, let name):
            await handleDefaultChange(kind: .output, id: id, name: name)
        case .defaultInputChanged(let id, let name):
            await handleDefaultChange(kind: .input, id: id, name: name)
        case .micRunningSnapshot(let running):
            currentlyRunningMics = Set(running.keys)
            runningMicNames = running
            if !hasMicBaseline {
                hasMicBaseline = true
                lastNotifiedRunningMics = currentlyRunningMics
                return
            }
            await refreshMicNotifications()
        case .midiDeviceAdded(let name):
            await context.notify(AudioEvent.midiDeviceAdded.rawValue, subject: name, title: "MIDI Device Connected", body: name, icon: .asset("AudioMonitor-Icon", in: .module))
        case .sampleRateChanged(_, let name, let from, let to):
            await context.notify(
                AudioEvent.sampleRateChanged.rawValue, subject: name,
                title: "Sample Rate Changed",
                body: String(format: "%@:\t%.0f Hz → %.0f Hz", name, from, to),
                icon: .asset("AudioMonitor-Icon-SampleRate", in: .module)
            )

        case .outputVolume(let name, let percent):
            await handleOutputVolume(name: name, percent: percent)

        case .jackChanged(let name, let isConnected):
            await context.notify(
                AudioEvent.jackChanged.rawValue,
                // Per direction, so plugging in and unplugging read as two things rather
                // than one banner updating itself.
                subject: "\(name)-\(isConnected ? "in" : "out")",
                title: isConnected ? "Audio Jack Connected" : "Audio Jack Disconnected",
                body: name,
                icon: .asset(isConnected ? "AudioMonitor-Icon" : "AudioMonitor-Icon-Off", in: .module)
            )

        case .dataSourceChanged(let name, let source):
            await context.notify(
                AudioEvent.dataSourceChanged.rawValue, subject: name,
                title: "Audio Source Changed",
                body: "\(name)\n\(source)",
                icon: .asset("AudioMonitor-Icon", in: .module)
            )

        case .deviceStoppedResponding(let name):
            await context.notify(
                AudioEvent.deviceStoppedResponding.rawValue, subject: name,
                title: "Audio Device Stopped Responding", body: name,
                icon: .asset("AudioMonitor-Icon-Off", in: .module)
            )

        case .microphoneModeChanged(let mode):
            await context.notify(
                AudioEvent.microphoneModeChanged.rawValue, subject: "MicrophoneMode",
                title: "Microphone Mode Changed", body: mode,
                icon: .asset("AudioMonitor-Icon-MicInUse", in: .module)
            )

        case .headTrackingChanged(let isActive):
            await context.notify(
                (isActive ? AudioEvent.headTrackingConnected : AudioEvent.headTrackingDisconnected).rawValue,
                subject: "HeadTracking",
                title: isActive ? "Head-Tracking Headphones Connected" : "Head-Tracking Headphones Disconnected",
                body: isActive ? "AirPods (or similar) with spatial audio head tracking are now active" : "",
                icon: .asset(isActive ? "AudioMonitor-Icon" : "AudioMonitor-Icon-Off", in: .module)
            )

        case .midiDeviceRemoved(let name):
            await context.notify(AudioEvent.midiDeviceRemoved.rawValue, subject: name, title: "MIDI Device Disconnected", body: name, icon: .asset("AudioMonitor-Icon-Off", in: .module))
        }
    }

    private func handleDeviceSnapshot(_ devices: [AudioDeviceSnapshot]) async {
        let current = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })

        if !hasDeviceBaseline {
            hasDeviceBaseline = true
            // Falls through with nothing "known" when the startup sweep is meant to
            // speak: every item then reads as newly arrived, which is exactly what
            // "here is what is plugged in" means. The dispatcher's `.launching` phase is
            // what keeps that burst from being mistaken for a dozen separate events.
            guard context.announcesWhatIsAlreadyThere else {
                knownDevices = current
                return
            }
        }

        let currentIDs = Set(current.keys)
        let knownIDs = Set(knownDevices.keys)

        for id in currentIDs.subtracting(knownIDs) {
            let device = current[id]!
            guard !device.transport.isCoveredByAnotherMonitor else { continue }
            guard notifiesVirtualDevices || !device.transport.isVirtualOrAggregate else { continue }
            reportedConnectedIDs.insert(id)
            await context.notify(
                AudioEvent.connected.rawValue,
                subject: id,
                title: "Audio Device Connected",
                body: await context.body(Self.detailLines(for: device)),
                icon: .asset("AudioMonitor-Icon", in: .module)
            )
        }
        for id in knownIDs.subtracting(currentIDs) {
            guard reportedConnectedIDs.remove(id) != nil else { continue }
            let name = knownDevices[id]?.name ?? "Audio Device"
            await context.notify(AudioEvent.disconnected.rawValue, subject: id, title: "Audio Device Disconnected", body: name, icon: .asset("AudioMonitor-Icon-Off", in: .module))
        }

        knownDevices = current
    }

    private enum DefaultKind { case output, input }

    private func handleDefaultChange(kind: DefaultKind, id: String, name: String) async {
        let lastKnown = (kind == .output) ? lastKnownDefaultOutput : lastKnownDefaultInput
        if kind == .output { lastKnownDefaultOutput = id } else { lastKnownDefaultInput = id }
        guard let lastKnown, lastKnown != id else { return } // first sighting — baseline only

        let label = kind == .output ? "Default Output" : "Default Input"
        let previousName = knownDevices[lastKnown]?.name

        await context.notify(
            kind == .output ? AudioEvent.defaultOutputChanged.rawValue : AudioEvent.defaultInputChanged.rawValue,
            subject: kind == .output ? "DefaultOutput" : "DefaultInput",
            title: kind == .output ? "Default Audio Output Changed" : "Default Audio Input Changed",
            body: await context.body([
                // The arrow when the device it replaced is still known, the plain name
                // when it is not — a device that has just been unplugged is gone from the
                // list, and "→ Speakers" with nothing before it reads as a fault.
                .field(AudioField.deviceChangeArrow.rawValue, previousName.map { "\(label):\t\($0) → \(name)" }),
                .always(previousName == nil ? name : "")
            ] + (knownDevices[id].map(Self.detailLines(for:)) ?? [])),
            // An input change should not show a speaker: this is the microphone's own
            // notification, and the artwork is half of what makes it recognisable.
            icon: .asset(kind == .output ? "AudioMonitor-Icon" : "AudioMonitor-Icon-MicIdle", in: .module)
        )
    }

    private func refreshMicNotifications() async {
        for id in currentlyRunningMics {
            pendingMicStops.removeValue(forKey: id)?.cancel()
        }

        for id in currentlyRunningMics where !lastNotifiedRunningMics.contains(id) {
            lastNotifiedRunningMics.insert(id)
            await notifyMicChanged(id: id, running: true)
        }

        let droppedOut = lastNotifiedRunningMics.subtracting(currentlyRunningMics)
        for id in droppedOut where pendingMicStops[id] == nil {
            pendingMicStops[id] = Task { [micStopDebounceNanoseconds] in
                try? await Task.sleep(nanoseconds: micStopDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                await self.confirmMicStop(id: id)
            }
        }
    }

    private func confirmMicStop(id: String) async {
        pendingMicStops.removeValue(forKey: id)
        guard !currentlyRunningMics.contains(id) else { return }
        lastNotifiedRunningMics.remove(id)
        await notifyMicChanged(id: id, running: false)
    }

    private func notifyMicChanged(id: String, running: Bool) async {
        let name = runningMicNames[id] ?? "Microphone"
        await context.notify(
            AudioEvent.micInUseChanged.rawValue,
            subject: "\(id)-\(running ? "started" : "stopped")",
            title: running ? "Microphone Started Being Used" : "Microphone Stopped Being Used",
            body: name,
            icon: .asset(running ? "AudioMonitor-Icon-MicInUse" : "AudioMonitor-Icon-MicIdle", in: .module)
        )
    }
}
