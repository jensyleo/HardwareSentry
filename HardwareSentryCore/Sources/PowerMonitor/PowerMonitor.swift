import Foundation
import SentryContract
import SignalCore

/// Says when the power source changes (AC/battery/UPS), when the battery finishes charging,
/// when the system's own low-battery warning kicks in, when the system or displays sleep or
/// wake, and when Low Power Mode toggles.
public actor PowerMonitor: Monitor {
    public static let category = PowerEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: PowerEvent.sourceChanged.rawValue, title: "Power source changed", icon: .asset("Power-Plugged", in: .module)),
        .init(name: PowerEvent.fullyCharged.rawValue, title: "Battery fully charged", icon: .asset("Power-100", in: .module)),
        .init(name: PowerEvent.lowBatteryWarning.rawValue, title: "Battery low", icon: .asset("Power-10", in: .module)),
        .init(name: PowerEvent.systemSleep.rawValue, title: "System going to sleep", enabledByDefault: false, icon: .asset("Power-NoBattery", in: .module)),
        .init(name: PowerEvent.systemWake.rawValue, title: "System woke up", enabledByDefault: false, icon: .asset("Power-Plugged", in: .module)),
        .init(name: PowerEvent.screensSleep.rawValue, title: "Display(s) went to sleep", enabledByDefault: false, icon: .asset("Power-NoBattery", in: .module)),
        .init(name: PowerEvent.screensWake.rawValue, title: "Display(s) woke up", enabledByDefault: false, icon: .asset("Power-Plugged", in: .module)),
        .init(name: PowerEvent.lowPowerModeChanged.rawValue, title: "Low Power Mode toggled", enabledByDefault: false, icon: .asset("Power-LowPowerMode", in: .module))
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
            lastKind = snapshot.kind
            // Remembered either way, so a battery that was already full when this started
            // is never announced as having just reached full. Reaching 100% before this
            // app ever saw the battery is not a transition; only a later one is.
            announcedFullyCharged = isFull
            lastWarnState = snapshot.isLowBatteryWarning

            // "On AC Power" / "On Battery Power" at launch is the one piece of state worth
            // stating outright rather than waiting for it to change — it is the answer to
            // "what is this machine running on right now", which is the question the
            // module exists for. Said without a "from → to" line, because nothing changed.
            if context.announcesWhatIsAlreadyThere {
                await context.notify(
                    PowerEvent.sourceChanged.rawValue,
                    subject: "Source",
                    title: "On \(Self.localizedName(for: snapshot.kind))",
                    body: await context.body([
                        .field(PowerField.chargeLevel.rawValue, "Charge", Self.chargeDetail(snapshot))
                    ]),
                    icon: .asset(Self.iconName(for: snapshot), in: .module)
                )
            }
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
                body: "",
                icon: .asset("Power-Plugged", in: .module)
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
                ]),
                icon: .asset(Self.iconName(for: snapshot), in: .module)
            )
        } else if changedKind {
            await context.notify(
                PowerEvent.sourceChanged.rawValue,
                subject: "Source",
                title: "On \(Self.localizedName(for: snapshot.kind))",
                body: await context.body([
                    .always("Source:\t\(Self.localizedName(for: previousKind)) → \(Self.localizedName(for: snapshot.kind))"),
                    .field(PowerField.chargeLevel.rawValue, "Charge", Self.chargeDetail(snapshot))
                ]),
                icon: .asset(Self.iconName(for: snapshot), in: .module)
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
            body: "",
            icon: .asset("Power-LowPowerMode", in: .module)
        )
    }

    /// Which battery icon matches the situation.
    ///
    /// Plugged in but not yet full uses the charging ramp rather than the plain "plugged"
    /// glyph, even at a low percentage — showing a full battery the moment a nearly-empty
    /// Mac is plugged in would be actively misleading.
    static func iconName(for snapshot: PowerSnapshot) -> String {
        switch snapshot.kind {
        case .ac:
            guard let percentage = snapshot.percentage, percentage < 100 else { return "Power-Plugged" }
            return "Power-Charging-\(rung(percentage))"
        case .battery, .ups:
            guard let percentage = snapshot.percentage else { return "Power-NoBattery" }
            return "Power-\(rung(percentage))"
        case .unknown:
            return "Power-BatteryFailure"
        }
    }

    /// Rounded to the nearest ten, which is the granularity the artwork comes in.
    private static func rung(_ percentage: Int) -> Int {
        min(100, max(0, Int((Double(percentage) / 10).rounded()) * 10))
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
