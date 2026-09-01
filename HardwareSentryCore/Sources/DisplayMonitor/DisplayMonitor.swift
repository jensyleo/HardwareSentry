import Foundation
import SentryContract
import SignalCore

/// Says when a display connects or disconnects, changes resolution/refresh rate/rotation,
/// changes role (Main/Extended/Mirrored), sleeps or wakes, or when any display's ICC color
/// profile changes system-wide.
public actor DisplayMonitor: Monitor {
    public static let category = DisplayEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: DisplayEvent.connected.rawValue, title: "Display connected"),
        .init(name: DisplayEvent.disconnected.rawValue, title: "Display disconnected"),
        .init(name: DisplayEvent.modeChanged.rawValue, title: "Resolution/refresh rate/rotation changed"),
        .init(name: DisplayEvent.roleChanged.rawValue, title: "Role changed (Main/Extended/Mirrored)"),
        .init(name: DisplayEvent.sleepChanged.rawValue, title: "Display slept/woke"),
        .init(name: DisplayEvent.colorProfileChanged.rawValue, title: "Color profile changed", enabledByDefault: false)
    ]

    public static let fields: [MonitorFieldDescription] = [
        .init(name: DisplayField.resolution.rawValue, title: "Resolution"),
        .init(name: DisplayField.refreshRate.rawValue, title: "Refresh rate"),
        .init(name: DisplayField.rotation.rawValue, title: "Rotation"),
        .init(name: DisplayField.role.rawValue, title: "Role (Main/Extended/Mirrored)")
    ]

    private let source: any DisplaySource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?
    private var known: [String: DisplaySnapshot] = [:]
    private var hasBaseline = false

    public init(source: any DisplaySource, context: MonitorContext) {
        self.source = source
        self.context = context
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
    }

    private func handle(_ event: DisplaySourceEvent) async {
        switch event {
        case .snapshot(let displays):
            await handleSnapshot(displays)
        case .colorProfileChanged:
            await context.notify(
                DisplayEvent.colorProfileChanged.rawValue,
                subject: "ColorProfile",
                title: "Display Color Profile Changed",
                body: "A display's ICC color profile changed (System Settings, Night Shift/True Tone, or a calibration tool)",
                icon: .asset("Display-On", in: .module)
            )
        }
    }

    private func handleSnapshot(_ displays: [DisplaySnapshot]) async {
        let current = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })

        if !hasBaseline {
            hasBaseline = true
            known = current
            return
        }

        let currentIDs = Set(current.keys)
        let knownIDs = Set(known.keys)

        for id in currentIDs.subtracting(knownIDs) {
            let display = current[id]!
            await context.notify(
                DisplayEvent.connected.rawValue,
                subject: id,
                title: "Display Connected",
                body: await context.body([
                    .always(display.name),
                    .field(DisplayField.resolution.rawValue, "Resolution", Self.resolutionDetail(display)),
                    .field(DisplayField.refreshRate.rawValue, "Refresh rate", Self.refreshDetail(display)),
                    .field(DisplayField.rotation.rawValue, "Rotation", Self.rotationDetail(display)),
                    .field(DisplayField.role.rawValue, "Role", Self.label(for: display.role))
                ]),
                icon: .asset("Display-On", in: .module)
            )
        }
        for id in knownIDs.subtracting(currentIDs) {
            let name = known[id]?.name ?? "External Display"
            await context.notify(
                DisplayEvent.disconnected.rawValue,
                subject: id,
                title: "Display Disconnected",
                body: name,
                icon: .asset("Display-Off", in: .module)
            )
        }

        for id in currentIDs.intersection(knownIDs) {
            guard let previous = known[id], let latest = current[id] else { continue }

            if previous.modeSignature != latest.modeSignature {
                await context.notify(
                    DisplayEvent.modeChanged.rawValue,
                    subject: id,
                    title: "Display Mode Changed",
                    body: "\(latest.name)\n\(Self.describeModeChange(from: previous, to: latest))",
                    icon: .asset("Display-On", in: .module)
                )
            }
            if previous.role != latest.role {
                await context.notify(
                    DisplayEvent.roleChanged.rawValue,
                    subject: id,
                    title: "Display Role Changed",
                    body: "\(latest.name)\nRole:\t\(Self.label(for: previous.role)) → \(Self.label(for: latest.role))",
                    icon: .asset("Display-On", in: .module)
                )
            }
            if previous.isAsleep != latest.isAsleep {
                await context.notify(
                    DisplayEvent.sleepChanged.rawValue,
                    subject: id,
                    title: latest.isAsleep ? "Display Slept" : "Display Woke",
                    body: latest.name,
                    icon: .asset(latest.isAsleep ? "Display-Off" : "Display-On", in: .module)
                )
            }
        }

        known = current
    }

    /// Each of these is nil when the display had nothing to report — a mode that could not
    /// be read comes back as zero, and "0×0" is noise, not information.
    static func resolutionDetail(_ display: DisplaySnapshot) -> String? {
        guard display.width > 0, display.height > 0 else { return nil }
        return "\(display.width)×\(display.height)"
    }

    static func refreshDetail(_ display: DisplaySnapshot) -> String? {
        guard display.refreshHz > 0 else { return nil }
        return "\(Int(display.refreshHz.rounded())) Hz"
    }

    /// Only worth a line when the display is actually turned; nobody needs telling that a
    /// monitor is the right way up.
    static func rotationDetail(_ display: DisplaySnapshot) -> String? {
        guard display.rotation.rounded() != 0 else { return nil }
        return "\(Int(display.rotation.rounded()))°"
    }

    static func describeModeChange(from previous: DisplaySnapshot, to latest: DisplaySnapshot) -> String {
        var lines: [String] = []
        if previous.width != latest.width || previous.height != latest.height {
            lines.append("Resolution:\t\(previous.width)×\(previous.height) → \(latest.width)×\(latest.height)")
        }
        if previous.refreshHz.rounded() != latest.refreshHz.rounded() {
            lines.append("Refresh rate:\t\(Int(previous.refreshHz.rounded())) Hz → \(Int(latest.refreshHz.rounded())) Hz")
        }
        if previous.rotation.rounded() != latest.rotation.rounded() {
            lines.append("Rotation:\t\(Int(previous.rotation.rounded()))° → \(Int(latest.rotation.rounded()))°")
        }
        return lines.joined(separator: "\n")
    }

    static func label(for role: DisplayRole) -> String {
        switch role {
        case .main: return "Main display"
        case .mirrored: return "Mirrored"
        case .extended: return "Extended"
        }
    }
}
