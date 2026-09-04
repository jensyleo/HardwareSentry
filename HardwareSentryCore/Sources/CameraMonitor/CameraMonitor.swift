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
        // One row per kind this monitor can tell apart, each with its own icon and its
        // own switch — the same reasoning USB Monitor's per-device-class rows rest on: a
        // Mac with a built-in camera and a webcam permanently attached should be able to
        // silence one without silencing the other. The icons here are `.symbol` — SF
        // Symbol placeholders, standing in until real artwork exists for each kind — and
        // are themselves the "System" default this row's Custom/System/Reset already
        // offers in Settings, so replacing them later touches only these lines.
        .init(name: CameraEvent.connected.rawValue, title: "Camera connected", icon: .asset("CameraMonitor-Icon", in: .module)),
        .init(name: CameraEvent.disconnected.rawValue, title: "Camera disconnected", icon: .asset("CameraMonitor-Icon", in: .module)),
        .init(name: CameraEvent.webcamConnected.rawValue, title: "Webcam connected", icon: .symbol("web.camera")),
        .init(name: CameraEvent.webcamDisconnected.rawValue, title: "Webcam disconnected", icon: .symbol("web.camera")),
        .init(name: CameraEvent.continuityConnected.rawValue, title: "Continuity Camera connected", icon: .symbol("iphone.radiowaves.left.and.right")),
        .init(name: CameraEvent.continuityDisconnected.rawValue, title: "Continuity Camera disconnected", icon: .symbol("iphone.radiowaves.left.and.right")),
        .init(name: CameraEvent.deskViewConnected.rawValue, title: "Desk View connected", icon: .symbol("table.furniture")),
        .init(name: CameraEvent.deskViewDisconnected.rawValue, title: "Desk View disconnected", icon: .symbol("table.furniture")),
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
    /// UIDs a connect was suppressed for — only ever because it was virtual — so the
    /// matching disconnect is suppressed too rather than reporting the departure of an
    /// arrival nobody was told about.
    private var suppressedUIDs: Set<String> = []
    /// What each connected camera is, remembered from its arrival.
    ///
    /// A disconnection carries no description of the device — by then there is nothing
    /// left to ask — so the wording and icon it goes out with (a webcam's departure has
    /// to say "Webcam", not "Camera") come from here rather than from the event itself.
    private var connectedDetail: [String: CameraDetail] = [:]

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

    /// Whether a transport description names USB, however it happens to be spelled.
    ///
    /// Compared without regard to case on purpose. Matching the exact string `"USB"` is
    /// what broke this switch in the first place: the source described a USB webcam as
    /// `"usb"`, taken from its raw four-character code, so the comparison never matched
    /// and the setting silently had no effect. The spelling is now fixed at the source as
    /// well; this makes the check survive it drifting again.
    private static func isUSB(_ transport: String?) -> Bool {
        transport?.caseInsensitiveCompare("USB") == .orderedSame
    }

    /// What to call this camera and which event it goes out as, from what it is rather
    /// than from any setting — a camera is always announced as what it actually is.
    ///
    /// Reported live: with USB Monitor's own generic notice folded away for a kind this
    /// module already names — a setting this module's own wording has to remain correct
    /// under, not conditional on — "Camera Connected" was the only wording left for what
    /// is, in hand, a webcam. USB Monitor's own generic notice used to be the only place a
    /// device like that was ever called a webcam; once that notice can be the one folded
    /// away for exactly this device, the word has to live here unconditionally, or it is
    /// lost rather than merely said twice.
    ///
    /// Desk View and Continuity are checked ahead of USB: an iPhone providing either is
    /// also reported with a USB-shaped transport by the system, and the more specific
    /// answer — what somebody actually plugged in or set up — is the useful one.
    private static func announcement(
        connecting: Bool,
        transport: String?,
        isDeskViewCamera: Bool,
        isContinuityCamera: Bool
    ) -> (event: CameraEvent, title: String) {
        let (event, word): (CameraEvent, String) = if isDeskViewCamera {
            (connecting ? .deskViewConnected : .deskViewDisconnected, "Desk View")
        } else if isContinuityCamera {
            (connecting ? .continuityConnected : .continuityDisconnected, "Continuity Camera")
        } else if isUSB(transport) {
            (connecting ? .webcamConnected : .webcamDisconnected, "Webcam")
        } else {
            (connecting ? .connected : .disconnected, "Camera")
        }
        return (event, "\(word) \(connecting ? "Connected" : "Disconnected")")
    }

    /// The icon for this camera's kind, matching whichever event `announcement(...)`
    /// chose — kept in step with it deliberately, since the two are shown together and a
    /// mismatch would read as one or the other being wrong. SF Symbol placeholders for the
    /// kinds that do not have artwork of their own yet.
    private static func icon(transport: String?, isDeskViewCamera: Bool, isContinuityCamera: Bool) -> NotificationIcon {
        if isDeskViewCamera { return .symbol("table.furniture") }
        if isContinuityCamera { return .symbol("iphone.radiowaves.left.and.right") }
        if isUSB(transport) { return .symbol("web.camera") }
        return .asset("CameraMonitor-Icon", in: .module)
    }

    /// Called when a setting changes, so it applies without a relaunch.
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
            if let detail { connectedDetail[uid] = detail }
            guard notifiesVirtualDevices || detail?.transport != "Virtual" else {
                suppressedUIDs.insert(uid)
                return
            }
            let announcement = Self.announcement(
                connecting: true,
                transport: detail?.transport,
                isDeskViewCamera: detail?.isDeskViewCamera ?? false,
                isContinuityCamera: detail?.isContinuityCamera ?? false
            )
            await context.notify(
                announcement.event.rawValue, subject: uid,
                title: announcement.title,
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
                icon: Self.icon(
                    transport: detail?.transport,
                    isDeskViewCamera: detail?.isDeskViewCamera ?? false,
                    isContinuityCamera: detail?.isContinuityCamera ?? false
                )
            )

        case .disconnected(let uid, let name):
            pendingStops.removeValue(forKey: uid)?.cancel()
            lastNotifiedRunning.remove(uid)
            let detail = connectedDetail.removeValue(forKey: uid)
            // Silent only if the arrival was suppressed — no stray departure for something
            // nobody was told about.
            guard suppressedUIDs.remove(uid) == nil else { return }
            let announcement = Self.announcement(
                connecting: false,
                transport: detail?.transport,
                isDeskViewCamera: detail?.isDeskViewCamera ?? false,
                isContinuityCamera: detail?.isContinuityCamera ?? false
            )
            await context.notify(
                announcement.event.rawValue, subject: uid,
                title: announcement.title, body: name,
                icon: Self.icon(
                    transport: detail?.transport,
                    isDeskViewCamera: detail?.isDeskViewCamera ?? false,
                    isContinuityCamera: detail?.isContinuityCamera ?? false
                )
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
