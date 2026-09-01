import Foundation
import SentryContract
import SignalCore

/// Says when a camera not already covered by USB/Bluetooth Monitor connects or
/// disconnects, when one starts or stops being used by any app — a privacy-relevant
/// signal, the same fact macOS's own camera-in-use indicator reflects — and when a
/// Control Center video effect changes system-wide.
public actor CameraMonitor: Monitor {
    public static let category = CameraEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: CameraEvent.connected.rawValue, title: "Camera connected"),
        .init(name: CameraEvent.disconnected.rawValue, title: "Camera disconnected"),
        .init(name: CameraEvent.inUseChanged.rawValue, title: "Camera started/stopped being used"),
        .init(name: CameraEvent.portraitEffectChanged.rawValue, title: "Portrait Effect changed", enabledByDefault: false),
        .init(name: CameraEvent.studioLightChanged.rawValue, title: "Studio Light changed", enabledByDefault: false),
        .init(name: CameraEvent.reactionsChanged.rawValue, title: "Reactions changed", enabledByDefault: false),
        .init(name: CameraEvent.backgroundReplacementChanged.rawValue, title: "Background Replacement changed", enabledByDefault: false)
    ]

    private let source: any CameraSource
    private let context: MonitorContext
    /// How long a camera dropping out of the running set is held before being believed —
    /// activating a camera can briefly cycle CoreMediaIO's "running" state during stream
    /// setup, so a stop is only announced once it survives this wait. Configurable so
    /// tests don't have to wait a real second per case.
    private let stopDebounceNanoseconds: UInt64
    private var watching: Task<Void, Never>?

    private var currentlyRunning: Set<String> = []
    private var runningNames: [String: String] = [:]
    private var lastNotifiedRunning: Set<String> = []
    private var hasRunningBaseline = false
    private var pendingStops: [String: Task<Void, Never>] = [:]

    public init(source: any CameraSource, context: MonitorContext, stopDebounce: Double = 1.0) {
        self.source = source
        self.context = context
        self.stopDebounceNanoseconds = UInt64(stopDebounce * 1_000_000_000)
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
        case .connected(let uid, let name):
            await context.notify(CameraEvent.connected.rawValue, subject: uid, title: "Camera Connected", body: name)

        case .disconnected(let uid, let name):
            pendingStops.removeValue(forKey: uid)?.cancel()
            lastNotifiedRunning.remove(uid)
            await context.notify(CameraEvent.disconnected.rawValue, subject: uid, title: "Camera Disconnected", body: name)

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
            icon: running ? .symbol("web.camera.fill") : .symbol("web.camera")
        )
    }

    private func reportEffectChange(_ effect: CameraVideoEffect, enabled: Bool) async {
        let event = CameraEvent.forEffect(effect)
        await context.notify(
            event.rawValue,
            subject: event.rawValue,
            title: "\(Self.label(for: effect)) \(enabled ? "Enabled" : "Disabled")",
            body: "Control Center video effect changed system-wide"
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
