import Foundation
import SentryContract
import SignalCore

/// Says when a display connects or disconnects, changes resolution/refresh rate/rotation,
/// changes role (Main/Extended/Mirrored), sleeps or wakes, or when any display's ICC color
/// profile changes system-wide.
public actor DisplayMonitor: Monitor {
    public static let category = DisplayEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: DisplayEvent.connected.rawValue, title: "Display connected", icon: .asset("Display-On", in: .module)),
        .init(name: DisplayEvent.disconnected.rawValue, title: "Display disconnected", icon: .asset("Display-Off", in: .module)),
        .init(name: DisplayEvent.modeChanged.rawValue, title: "Resolution/refresh rate/rotation changed", icon: .asset("Display-On", in: .module)),
        .init(name: DisplayEvent.roleChanged.rawValue, title: "Role changed (Main/Extended/Mirrored)", icon: .asset("Display-On", in: .module)),
        .init(name: DisplayEvent.sleepChanged.rawValue, title: "Display slept/woke", icon: .asset("Display-Off", in: .module)),
        .init(name: DisplayEvent.colorProfileChanged.rawValue, title: "Color profile changed", enabledByDefault: false, icon: .asset("Display-On", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = DisplayField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

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
        // An empty list is the framework saying "ask again", not "every screen was
        // unplugged". It happens mid-reconfiguration and while the Mac sleeps; believed
        // literally it announces every display disconnecting and then reconnecting.
        guard !displays.isEmpty else { return }

        let current = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })

        if !hasBaseline {
            hasBaseline = true
            // Falls through with nothing "known" when the startup sweep is meant to
            // speak: every item then reads as newly arrived, which is exactly what
            // "here is what is plugged in" means. The dispatcher's `.launching` phase is
            // what keeps that burst from being mistaken for a dozen separate events.
            guard context.announcesWhatIsAlreadyThere else {
                known = current
                return
            }
        }

        let currentIDs = Set(current.keys)
        let knownIDs = Set(known.keys)

        for id in currentIDs.subtracting(knownIDs) {
            let display = current[id]!
            await context.notify(
                DisplayEvent.connected.rawValue,
                subject: id,
                title: "Display Connected",
                body: await context.body(Self.connectLines(for: display)),
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
                let body = await context.body(Self.modeChangeLines(from: previous, to: latest))
                // Every part of what moved can be switched off, and with all three off
                // there is nothing left but the display's name — which would be a
                // notification that says a display changed without saying how. Silence is
                // the honest reading of "do not tell me about any of these".
                if body != latest.name {
                    await context.notify(
                        DisplayEvent.modeChanged.rawValue,
                        subject: id,
                        title: "Display Mode Changed",
                        body: body,
                        icon: .asset("Display-On", in: .module)
                    )
                }
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

    /// Everything the connect notification can say about a display.
    ///
    /// Ordered as somebody reads a display: what it is, then how big, then how it is
    /// running, then the identifiers that only matter when two monitors are identical.
    static func connectLines(for display: DisplaySnapshot) -> [BodyLine] {
        let detail = display.detail
        return [
            .always(display.name),
            .field(DisplayField.resolution.rawValue, "Resolution", resolutionDetail(display)),
            .field(DisplayField.refreshRate.rawValue, "Refresh rate", refreshDetail(display)),
            .field(DisplayField.refreshRange.rawValue, "Refresh range", detail?.refreshRangeNote),
            .field(DisplayField.rotation.rawValue, "Rotation", rotationDetail(display)),
            .field(DisplayField.role.rawValue, "Role", label(for: display.role)),
            .field(DisplayField.mirrorSource.rawValue, "Mirroring", detail?.mirrorNote),
            .field(DisplayField.physicalSize.rawValue, "Size", detail?.physicalSizeNote),
            .field(DisplayField.density.rawValue, "Density", detail?.densityNote(pixelWidth: display.width, pixelHeight: display.height)),
            .field(DisplayField.scaling.rawValue, "Scaling", detail?.scalingNote(pixelWidth: display.width, pixelHeight: display.height)),
            .field(DisplayField.colorSpace.rawValue, "Colour space", detail?.colorSpaceName),
            .field(DisplayField.wideColor.rawValue, "Wide colour", detail?.displayP3Note),
            .field(DisplayField.dynamicRange.rawValue, "Dynamic range", detail?.edrNote),
            .field(DisplayField.builtIn.rawValue, "Built in", detail?.builtInNote),
            .field(DisplayField.notch.rawValue, "Notch", detail?.notchNote),
            .field(DisplayField.stereo.rawValue, "Stereo", detail?.stereoNote),
            .field(DisplayField.identity.rawValue, "Identity", detail?.identityNote),
            .field(DisplayField.uuid.rawValue, "Identifier", detail?.uuid)
        ]
    }

    /// What moved, one switchable line each.
    ///
    /// Gated by the same three fields the connect notification uses, so somebody who does
    /// not want refresh rates does not get told about them here either — the alternative
    /// was a field switch that worked on one notification and not the other.
    static func modeChangeLines(from previous: DisplaySnapshot, to latest: DisplaySnapshot) -> [BodyLine] {
        var lines: [BodyLine] = [.always(latest.name)]
        if previous.width != latest.width || previous.height != latest.height {
            lines.append(.field(
                DisplayField.resolution.rawValue,
                "Resolution",
                "\(previous.width)×\(previous.height) → \(latest.width)×\(latest.height)"
            ))
        }
        if previous.refreshHz.rounded() != latest.refreshHz.rounded() {
            lines.append(.field(
                DisplayField.refreshRate.rawValue,
                "Refresh rate",
                "\(Int(previous.refreshHz.rounded())) Hz → \(Int(latest.refreshHz.rounded())) Hz"
            ))
        }
        if previous.rotation.rounded() != latest.rotation.rounded() {
            lines.append(.field(
                DisplayField.rotation.rawValue,
                "Rotation",
                "\(Int(previous.rotation.rounded()))° → \(Int(latest.rotation.rounded()))°"
            ))
        }
        return lines
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

    static func label(for role: DisplayRole) -> String {
        switch role {
        case .main: return "Main display"
        case .mirrored: return "Mirrored"
        case .extended: return "Extended"
        }
    }
}
