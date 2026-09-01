import Foundation
import SentryContract
import SignalCore

/// Says when the power source changes (AC/battery/UPS), when the battery finishes charging,
/// when the system's own low-battery warning kicks in, when the system or displays sleep or
/// wake, and when Low Power Mode toggles.
public actor PowerMonitor: Monitor {
    public static let category = PowerEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: PowerEvent.sourceChanged.rawValue, title: "Power source changed"),
        .init(name: PowerEvent.fullyCharged.rawValue, title: "Battery fully charged"),
        .init(name: PowerEvent.lowBatteryWarning.rawValue, title: "Battery low"),
        .init(name: PowerEvent.systemSleep.rawValue, title: "System going to sleep", enabledByDefault: false),
        .init(name: PowerEvent.systemWake.rawValue, title: "System woke up", enabledByDefault: false),
        .init(name: PowerEvent.screensSleep.rawValue, title: "Display(s) went to sleep", enabledByDefault: false),
        .init(name: PowerEvent.screensWake.rawValue, title: "Display(s) woke up", enabledByDefault: false),
        .init(name: PowerEvent.lowPowerModeChanged.rawValue, title: "Low Power Mode toggled", enabledByDefault: false)
    ]

    public static let fields: [MonitorFieldDescription] = [
        .init(name: PowerField.chargeLevel.rawValue, title: "Charge level")
    ]

    private let source: any PowerSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    private var lastKind: PowerSourceKind?
    private var announcedFullyCharged = false
    private var lastWarnState = false
    private var lastLowPowerMode: Bool?

    public init(source: any PowerSource, context: MonitorContext) {
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

    private func handle(_ event: PowerSourceEvent) async {
        switch event {
        case .snapshot(let snapshot):
            await handleSnapshot(snapshot)
        case .systemWillSleep:
            await context.notify(PowerEvent.systemSleep.rawValue, subject: "System", title: "System Going to Sleep", body: "")
        case .systemDidWake:
            await context.notify(PowerEvent.systemWake.rawValue, subject: "System", title: "System Woke Up", body: "")
        case .screensDidSleep:
            await context.notify(PowerEvent.screensSleep.rawValue, subject: "Screens", title: "Display(s) Went to Sleep", body: "")
        case .screensDidWake:
            await context.notify(PowerEvent.screensWake.rawValue, subject: "Screens", title: "Display(s) Woke Up", body: "")
        case .lowPowerModeChanged(let enabled):
            await handleLowPowerMode(enabled)
        }
    }

    private func handleSnapshot(_ snapshot: PowerSnapshot) async {
        let isFull = snapshot.kind == .ac && (snapshot.percentage ?? 0) >= 100

        guard let previousKind = lastKind else {
            // First sighting — baseline only. Reaching 100% before this app ever saw the
            // battery isn't a transition worth announcing, only a later one is.
            lastKind = snapshot.kind
            announcedFullyCharged = isFull
            lastWarnState = snapshot.isLowBatteryWarning
            return
        }

        let changedKind = snapshot.kind != previousKind
        lastKind = snapshot.kind

        if isFull, !announcedFullyCharged {
            announcedFullyCharged = true
            await context.notify(
                PowerEvent.fullyCharged.rawValue,
                subject: "Battery",
                title: "Battery Fully Charged",
                body: ""
            )
        } else if !isFull {
            announcedFullyCharged = false
        }

        // Edge-triggered: fires once when the warning turns on, stays silent while it
        // remains on, and clears when it turns off — never spams while genuinely low.
        let justStartedWarning = snapshot.isLowBatteryWarning && !lastWarnState
        lastWarnState = snapshot.isLowBatteryWarning

        if justStartedWarning {
            await context.notify(
                PowerEvent.lowBatteryWarning.rawValue,
                subject: "Battery",
                title: "Battery Low!",
                body: await context.body([
                    .always("Battery Low, Please plug the computer in now"),
                    .field(PowerField.chargeLevel.rawValue, "Charge", Self.chargeDetail(snapshot))
                ])
            )
        } else if changedKind {
            await context.notify(
                PowerEvent.sourceChanged.rawValue,
                subject: "Source",
                title: "On \(Self.localizedName(for: snapshot.kind))",
                body: await context.body([
                    .always("Source:\t\(Self.localizedName(for: previousKind)) → \(Self.localizedName(for: snapshot.kind))"),
                    .field(PowerField.chargeLevel.rawValue, "Charge", Self.chargeDetail(snapshot))
                ])
            )
        }
    }

    private func handleLowPowerMode(_ enabled: Bool) async {
        let previous = lastLowPowerMode
        lastLowPowerMode = enabled
        guard let previous, previous != enabled else { return } // first sighting — baseline only

        await context.notify(
            PowerEvent.lowPowerModeChanged.rawValue,
            subject: "LowPowerMode",
            title: enabled ? "Low Power Mode Enabled" : "Low Power Mode Disabled",
            body: ""
        )
    }

    /// Nil on a Mac with no battery at all, where a charge level would be a fiction.
    static func chargeDetail(_ snapshot: PowerSnapshot) -> String? {
        snapshot.percentage.map { "\($0)%" }
    }

    private static func localizedName(for kind: PowerSourceKind) -> String {
        switch kind {
        case .ac: return "AC Power"
        case .battery: return "Battery Power"
        case .ups: return "UPS Power"
        case .unknown: return "Unknown Power"
        }
    }
}
