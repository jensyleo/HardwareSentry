import Foundation
import SentryContract
import SignalCore

/// Says which device macOS is actually using for output/input, when a device not already
/// covered by USB/Bluetooth Monitor connects or disconnects, when a microphone starts or
/// stops being used by any app, and when a MIDI device appears or disappears.
public actor AudioMonitor: Monitor {
    public static let category = AudioEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: AudioEvent.defaultOutputChanged.rawValue, title: "Default output device changed"),
        .init(name: AudioEvent.defaultInputChanged.rawValue, title: "Default input device changed"),
        .init(name: AudioEvent.connected.rawValue, title: "Device connected (not USB/Bluetooth)"),
        .init(name: AudioEvent.disconnected.rawValue, title: "Device disconnected (not USB/Bluetooth)"),
        .init(name: AudioEvent.micInUseChanged.rawValue, title: "Microphone started/stopped being used"),
        .init(name: AudioEvent.midiDeviceAdded.rawValue, title: "MIDI device added"),
        .init(name: AudioEvent.midiDeviceRemoved.rawValue, title: "MIDI device removed")
    ]

    private let source: any AudioSource
    private let context: MonitorContext
    /// Same reasoning as `CameraMonitor`'s: a call starting/ending can briefly cycle
    /// CoreAudio's "running somewhere" state, so a stop is only announced once it survives
    /// this wait. Configurable so tests don't wait a real second per case.
    private let micStopDebounceNanoseconds: UInt64
    private var watching: Task<Void, Never>?

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

    public init(source: any AudioSource, context: MonitorContext, micStopDebounce: Double = 1.0) {
        self.source = source
        self.context = context
        self.micStopDebounceNanoseconds = UInt64(micStopDebounce * 1_000_000_000)
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
            await context.notify(AudioEvent.midiDeviceAdded.rawValue, subject: name, title: "MIDI Device Added", body: name)
        case .midiDeviceRemoved(let name):
            await context.notify(AudioEvent.midiDeviceRemoved.rawValue, subject: name, title: "MIDI Device Removed", body: name)
        }
    }

    private func handleDeviceSnapshot(_ devices: [AudioDeviceSnapshot]) async {
        let current = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })

        if !hasDeviceBaseline {
            hasDeviceBaseline = true
            knownDevices = current
            return
        }

        let currentIDs = Set(current.keys)
        let knownIDs = Set(knownDevices.keys)

        for id in currentIDs.subtracting(knownIDs) {
            let device = current[id]!
            guard !device.transport.isCoveredByAnotherMonitor else { continue }
            reportedConnectedIDs.insert(id)
            await context.notify(AudioEvent.connected.rawValue, subject: id, title: "Audio Device Connected", body: device.name)
        }
        for id in knownIDs.subtracting(currentIDs) {
            guard reportedConnectedIDs.remove(id) != nil else { continue }
            let name = knownDevices[id]?.name ?? "Audio Device"
            await context.notify(AudioEvent.disconnected.rawValue, subject: id, title: "Audio Device Disconnected", body: name)
        }

        knownDevices = current
    }

    private enum DefaultKind { case output, input }

    private func handleDefaultChange(kind: DefaultKind, id: String, name: String) async {
        let lastKnown = (kind == .output) ? lastKnownDefaultOutput : lastKnownDefaultInput
        if kind == .output { lastKnownDefaultOutput = id } else { lastKnownDefaultInput = id }
        guard let lastKnown, lastKnown != id else { return } // first sighting — baseline only

        await context.notify(
            kind == .output ? AudioEvent.defaultOutputChanged.rawValue : AudioEvent.defaultInputChanged.rawValue,
            subject: kind == .output ? "DefaultOutput" : "DefaultInput",
            title: kind == .output ? "Default Output Changed" : "Default Input Changed",
            body: name
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
            icon: running ? .symbol("mic.fill") : .symbol("mic")
        )
    }
}
