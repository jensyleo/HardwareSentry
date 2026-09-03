import Foundation
import SentryContract
import SignalCore

/// Says when a camera connects or disconnects — wired or over USB, though not yet a
/// Bluetooth-paired one, which Bluetooth Monitor already announces — when one starts or
/// stops being used by any app, a privacy-relevant signal the same fact macOS's own
/// camera-in-use indicator reflects, and when a Control Center video effect changes
/// system-wide.
public actor CameraMonitor: Monitor {
    public static let category = CameraEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: CameraEvent.connected.rawValue, title: "Camera connected", icon: .asset("CameraMonitor-Icon", in: .module)),
        .init(name: CameraEvent.disconnected.rawValue, title: "Camera disconnected", icon: .asset("CameraMonitor-Icon", in: .module)),
        .init(name: CameraEvent.inUseChanged.rawValue, title: "Camera started/stopped being used", icon: .asset("CameraMonitor-Icon-InUse", in: .module)),
        .init(name: CameraEvent.portraitEffectChanged.rawValue, title: "Portrait Effect changed", enabledByDefault: false, icon: .asset("CameraMonitor-Icon", in: .module)),
        .init(name: CameraEvent.studioLightChanged.rawValue, title: "Studio Light changed", enabledByDefault: false, icon: .asset("CameraMonitor-Icon", in: .module)),
        .init(name: CameraEvent.reactionsChanged.rawValue, title: "Reactions changed", enabledByDefault: false, icon: .asset("CameraMonitor-Icon", in: .module)),
        .init(name: CameraEvent.backgroundReplacementChanged.rawValue, title: "Background Replacement changed", enabledByDefault: false, icon: .asset("CameraMonitor-Icon", in: .module))
    ]

    // All off by default. These describe the camera rather than report anything that
    // happened, and the connect notification's job is to say a camera showed up — someone
    // who wants the specification can turn on the lines they care about.
    public static let fields: [MonitorFieldDescription] = CameraField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any CameraSource
    private let context: MonitorContext
    /// How long a camera dropping out of the running set is held before being believed —
    /// activating a camera can briefly cycle CoreMediaIO's "running" state during stream
    /// setup, so a stop is only announced once it survives this wait. Configurable so
    /// tests don't have to wait a real second per case.
    private let stopDebounceNanoseconds: UInt64
    private var watching: Task<Void, Never>?

    /// Off by default: an app's virtual camera (OBS, a video-call plugin) is software
    /// that starts and stops, not a camera that arrived or left the room — the same
    /// reasoning as `AudioMonitor`'s equivalent switch, which this reuses the wording of.
    private var notifiesVirtualDevices: Bool
    /// UIDs a connect was suppressed for, so the matching disconnect is suppressed too
    /// rather than reporting the departure of an arrival nobody was told about.
    private var suppressedVirtualUIDs: Set<String> = []

    private var currentlyRunning: Set<String> = []
    private var runningNames: [String: String] = [:]
    private var lastNotifiedRunning: Set<String> = []
    private var hasRunningBaseline = false
    private var pendingStops: [String: Task<Void, Never>] = [:]

    public init(
        source: any CameraSource,
        context: MonitorContext,
        stopDebounce: Double = 1.0,
        notifiesVirtualDevices: Bool = false
    ) {
        self.source = source
        self.context = context
        self.stopDebounceNanoseconds = UInt64(stopDebounce * 1_000_000_000)
        self.notifiesVirtualDevices = notifiesVirtualDevices
    }

    /// Called when the setting changes, so it applies without a relaunch.
    public func apply(notifiesVirtualDevices: Bool) {
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
        pendingStops.values.forEach { $0.cancel() }
        pendingStops.removeAll()
    }

    private func handle(_ event: CameraSourceEvent) async {
        switch event {
        case .connected(let uid, let name, let detail):
            guard notifiesVirtualDevices || detail?.transport != "Virtual" else {
                suppressedVirtualUIDs.insert(uid)
                return
            }
            await context.notify(
                CameraEvent.connected.rawValue, subject: uid,
                title: "Camera Connected",
                body: await context.body([
                    .always(name),
                    .field(CameraField.transport.rawValue, "Transport", detail?.transport),
                    .field(CameraField.manufacturer.rawValue, "Manufacturer", detail?.manufacturer),
                    .field(CameraField.position.rawValue, "Position", detail?.position),
                    .field(CameraField.maxResolution.rawValue, "Max resolution", detail?.maxResolution),
                    .field(CameraField.maxFrameRate.rawValue, "Max frame rate", detail?.maxFrameRate),
                    .field(CameraField.continuityCamera.rawValue, "Continuity Camera", detail?.continuityNote),
                    .field(CameraField.deskView.rawValue, "Desk View companion", detail?.deskViewNote),
                    .field(CameraField.centerStage.rawValue, "Center Stage", detail?.centerStageNote),
                    .field(CameraField.systemPreferred.rawValue, "System Preferred Camera", detail?.systemPreferredNote),
                    .field(CameraField.linkedDevices.rawValue, "Linked devices", detail?.linkedDevices)
                ]),
                icon: .asset("CameraMonitor-Icon", in: .module)
            )

        case .disconnected(let uid, let name):
            pendingStops.removeValue(forKey: uid)?.cancel()
            lastNotifiedRunning.remove(uid)
            guard suppressedVirtualUIDs.remove(uid) == nil else { return }
            await context.notify(
                CameraEvent.disconnected.rawValue, subject: uid,
                title: "Camera Disconnected", body: name,
                icon: .asset("CameraMonitor-Icon", in: .module)
            )

        case .runningStateChanged(let running):
            currentlyRunning = Set(running.keys)
            runningNames = running
            if !hasRunningBaseline {
                hasRunningBaseline = true
                lastNotifiedRunning = currentlyRunning
                return
            }
            await refreshRunningNotifications()

        case .videoEffectChanged(let effect, let enabled):
            await reportEffectChange(effect, enabled: enabled)
        }
    }

    private func refreshRunningNotifications() async {
        // A UID running again cancels its pending "stopped" re-check — nothing new to
        // announce, since the user was already told "Started" and nothing since
        // contradicted that.
        for uid in currentlyRunning {
            pendingStops.removeValue(forKey: uid)?.cancel()
        }

        for uid in currentlyRunning where !lastNotifiedRunning.contains(uid) {
            lastNotifiedRunning.insert(uid)
            await notifyInUseChanged(uid: uid, running: true)
        }

        let droppedOut = lastNotifiedRunning.subtracting(currentlyRunning)
        for uid in droppedOut where pendingStops[uid] == nil {
            pendingStops[uid] = Task { [stopDebounceNanoseconds] in
                try? await Task.sleep(nanoseconds: stopDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                await self.confirmStop(uid: uid)
            }
        }
    }

    private func confirmStop(uid: String) async {
        pendingStops.removeValue(forKey: uid)
        guard !currentlyRunning.contains(uid) else { return }
        lastNotifiedRunning.remove(uid)
        await notifyInUseChanged(uid: uid, running: false)
    }

    private func notifyInUseChanged(uid: String, running: Bool) async {
        let name = runningNames[uid] ?? "Camera"
        // A distinct subject per transition, not just per device — a stable per-device
        // subject would make the system notification center treat "Stopped" as an update
        // to the still-displayed "Started" banner instead of a fresh one.
        await context.notify(
            CameraEvent.inUseChanged.rawValue,
            subject: "\(uid)-\(running ? "started" : "stopped")",
            title: running ? "Camera Started Being Used" : "Camera Stopped Being Used",
            body: name,
            icon: .asset(running ? "CameraMonitor-Icon-InUse" : "CameraMonitor-Icon", in: .module)
        )
    }

    private func reportEffectChange(_ effect: CameraVideoEffect, enabled: Bool) async {
        let event = CameraEvent.forEffect(effect)
        await context.notify(
            event.rawValue,
            subject: event.rawValue,
            title: "\(Self.label(for: effect)) \(enabled ? "Enabled" : "Disabled")",
            body: "Control Center video effect changed system-wide",
            icon: .asset("CameraMonitor-Icon", in: .module)
        )
    }

    private static func label(for effect: CameraVideoEffect) -> String {
        switch effect {
        case .portraitEffect: return "Portrait Effect"
        case .studioLight: return "Studio Light"
        case .reactions: return "Reactions"
        case .backgroundReplacement: return "Background Replacement"
        }
    }
}
