import Foundation
import SentryContract
import SignalCore

/// Says when the power source changes (AC/battery/UPS), when the battery finishes charging,
/// when the system's own low-battery warning kicks in, when the system or displays sleep or
/// wake, and when Low Power Mode toggles.
public actor PowerMonitor: Monitor {
    public static let category = PowerEvent.category

    /// In the original's order: the adapter, then every rung of the gauge draining and
    /// charging, then the states that are about the battery rather than its level, then
    /// the system's own sleeping and waking.
    public static let events: [MonitorEventDescription] = [
        .init(name: PowerEvent.pluggedIn.rawValue, title: "Plugged In", icon: .asset("Power-Plugged", in: .module))
    ] + PowerRung.all.map { rung in
        .init(
            name: rung.event.rawValue,
            title: rung.settingsTitle,
            icon: .asset(rung.iconBaseName, in: .module)
        )
    } + [
        .init(name: PowerEvent.batteryFailure.rawValue, title: "Battery Failure", icon: .asset("Power-BatteryFailure", in: .module)),
        .init(name: PowerEvent.noBattery.rawValue, title: "No Battery", icon: .asset("Power-NoBattery", in: .module)),
        .init(name: PowerEvent.lowPowerModeChanged.rawValue, title: "Low Power Mode", icon: .asset("Power-LowPowerMode", in: .module)),
        .init(name: PowerEvent.adapterChanged.rawValue, title: "Adapter Changed", icon: .asset("Power-AdapterChanged", in: .module)),
        .init(name: PowerEvent.systemSleep.rawValue, title: "System Sleep", icon: .asset("Power-LowPowerMode", in: .module)),
        .init(name: PowerEvent.systemWake.rawValue, title: "System Wake", icon: .asset("Power-AdapterChanged", in: .module)),
        .init(name: PowerEvent.screensSleep.rawValue, title: "Display(s) Sleep", icon: .asset("Power-LowPowerMode", in: .module)),
        .init(name: PowerEvent.screensWake.rawValue, title: "Display(s) Wake", icon: .asset("Power-AdapterChanged", in: .module)),
        // Two of this application's own, which the original does not have as rows.
        .init(name: PowerEvent.sourceChanged.rawValue, title: "Power source changed", icon: .asset("Power-Plugged", in: .module)),
        .init(name: PowerEvent.fullyCharged.rawValue, title: "Battery fully charged", icon: .asset("Power-100", in: .module)),
        .init(name: PowerEvent.lowBatteryWarning.rawValue, title: "Battery low", icon: .asset("Power-10", in: .module)),
        .init(name: PowerEvent.batteryHealth.rawValue, title: "Battery health report", icon: .asset("Power-BatteryFailure", in: .module))
    ]

    /// Said outright: the first row is the adapter, and this module is about more.
    public static let icon: NotificationIcon = .asset("Power-Plugged", in: .module)

    public static let fields: [MonitorFieldDescription] = PowerField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any PowerSource
    private let context: MonitorContext
    private var refire: PowerRefireSettings
    private var healthCheck: PowerHealthCheckSettings
    private let healthStore: any PowerHealthStore
    private var watching: Task<Void, Never>?
    private var refiring: Task<Void, Never>?
    private var checkingHealth: Task<Void, Never>?

    private var lastKind: PowerSourceKind?
    private var lastSnapshot: PowerSnapshot?
    private var lastAdapter: PowerAdapterDetail?
    private var sawFirstAdapter = false
    private var announcedFullyCharged = false
    private var lastWarnState = false
    private var lastLowPowerMode: Bool?

    public init(
        source: any PowerSource,
        context: MonitorContext,
        refire: PowerRefireSettings = .off,
        healthCheck: PowerHealthCheckSettings = PowerHealthCheckSettings(),
        healthStore: any PowerHealthStore = EphemeralPowerHealthStore()
    ) {
        self.source = source
        self.context = context
        self.refire = refire
        self.healthCheck = healthCheck
        self.healthStore = healthStore
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source] in
            for await event in source.changes() {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
        }

        startRefireTimer()
        startHealthTimer()
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
        refiring?.cancel()
        refiring = nil
        checkingHealth?.cancel()
        checkingHealth = nil
    }

    /// Takes a changed setting without restarting anything else.
    ///
    /// The alternative — rebuilding the monitors when a number changes — would replay the
    /// whole "here is what is plugged in" announcement every time somebody dragged a
    /// slider. Only the timers are affected by these, so only the timers are restarted.
    public func apply(refire newRefire: PowerRefireSettings, healthCheck newHealthCheck: PowerHealthCheckSettings) async {
        let wasRunning = watching != nil
        refire = newRefire
        healthCheck = newHealthCheck

        refiring?.cancel()
        refiring = nil
        checkingHealth?.cancel()
        checkingHealth = nil

        guard wasRunning else { return }
        startRefireTimer()
        startHealthTimer()
    }

    // MARK: - Saying it again

    private func startRefireTimer() {
        guard refire.isEnabled, refiring == nil else { return }
        refiring = Task { [interval = refire.interval] in
            while !Task.isCancelled {
                // Waits first: firing the moment the timer starts would double up with the
                // launch announcement that has just gone out.
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self.refireNow()
            }
        }
    }

    /// Says the current power status again, without pretending anything changed.
    ///
    /// Separated out and left reachable so a test can ask for the repeat directly instead
    /// of waiting half an hour for the timer, and so the wording can be checked: the
    /// "from → to" line is deliberately absent here, because nothing moved.
    func refireNow() async {
        guard let snapshot = lastSnapshot else { return }
        if refire.onlyOnBattery, snapshot.kind == .ac { return }

        await context.notify(
            PowerEvent.sourceChanged.rawValue,
            subject: "Source",
            title: "On \(Self.localizedName(for: snapshot.kind))",
            body: await body(for: snapshot),
            icon: .asset(Self.iconName(for: snapshot), in: .module)
        )
    }

    // MARK: - Battery health

    private func startHealthTimer() {
        guard healthCheck.isEnabled, checkingHealth == nil else { return }
        checkingHealth = Task { [interval = healthCheck.interval, healthStore] in
            // How long is left of the interval, not the whole of it: a Mac that is shut
            // down every night would otherwise never reach a weekly check at all.
            if let last = await healthStore.lastCheck() {
                let elapsed = Duration.seconds(Date().timeIntervalSince(last))
                if elapsed < interval { try? await Task.sleep(for: interval - elapsed) }
            }

            while !Task.isCancelled {
                await self.checkBatteryHealthNow(force: false)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Reads the battery's condition and reports it if there is news.
    ///
    /// `force` is what the "Check Now" button asks for: an explicit check should always
    /// answer, even when the answer is the same as last week — a button that appears to do
    /// nothing is worse than a repeated message. The scheduled check stays quiet unless
    /// the reading actually moved, because a weekly "your battery is still fine" is a
    /// weekly interruption that teaches people to ignore the one that matters.
    public func checkBatteryHealthNow(force: Bool) async {
        guard let health = await source.readBatteryHealth(), !health.isEmpty else { return }

        let now = Date()
        let summary = Self.summary(of: health)
        let previous = await healthStore.lastReportedSummary()

        guard force || summary != previous else {
            await healthStore.recordCheck(at: now)
            return
        }

        await healthStore.record(summary: summary, at: now)
        await context.notify(
            PowerEvent.batteryHealth.rawValue,
            subject: "BatteryHealth",
            title: Self.healthTitle(for: health),
            body: await context.body([
                .field(PowerField.cycleCount.rawValue, "Cycles", health.cycleNote),
                .field(PowerField.batteryHealthPercent.rawValue, "Health", health.healthNote),
                .field(PowerField.batteryCondition.rawValue, "Condition", health.conditionNote),
                .field(PowerField.batteryHealthCoarse.rawValue, "Overall", health.coarseNote),
                .field(PowerField.batteryCapacity.rawValue, "Capacity", health.capacityNote),
                .field(PowerField.batteryErrorMargin.rawValue, "Margin", health.errorMarginNote),
                // Switchable like everything else, and on by default. They only ever
                // appear when something is wrong, so they cost nothing when it is not.
                .field(PowerField.batteryFailureModes.rawValue, "Faults", health.failuresNote),
                .field(PowerField.batteryInternalFailure.rawValue, "Warning", health.internalFailureNote)
            ]),
            icon: .asset(Self.healthIconName(for: health), in: .module),
            priority: health.hasInternalFailure || !health.failureModes.isEmpty ? .high : .normal
        )
    }

    /// A battery that wants attention says so in the title, where it will be read even if
    /// the message body is collapsed.
    private static func healthTitle(for health: BatteryHealthDetail) -> String {
        if health.hasInternalFailure { return "Battery Failure" }
        if !health.failureModes.isEmpty { return "Battery Needs Attention" }
        if let condition = health.condition, condition.localizedCaseInsensitiveContains("service") {
            return "Battery Service Recommended"
        }
        return "Battery Health"
    }

    private static func healthIconName(for health: BatteryHealthDetail) -> String {
        health.hasInternalFailure || !health.failureModes.isEmpty || health.condition?.localizedCaseInsensitiveContains("service") == true
            ? "Power-BatteryFailure"
            : "Power-100"
    }

    /// What counts as "the same reading as last time".
    ///
    /// Capacity in mAh is left out on purpose: it drifts by a few milliamp-hours between
    /// any two reads, so including it would make every scheduled check look like news.
    static func summary(of health: BatteryHealthDetail) -> String {
        [
            health.cycleCount.map(String.init) ?? "-",
            health.healthPercent.map(String.init) ?? "-",
            health.condition ?? "-",
            health.coarseHealth ?? "-",
            health.failureModes.sorted().joined(separator: "|"),
            health.hasInternalFailure ? "failed" : "ok"
        ].joined(separator: "/")
    }

    private func handle(_ event: PowerSourceEvent) async {
        switch event {
        case .snapshot(let snapshot):
            await handleSnapshot(snapshot)
        case .systemWillSleep:
            await context.notify(PowerEvent.systemSleep.rawValue, subject: "System", title: "System Going to Sleep", body: "", icon: .asset("Power-LowPowerMode", in: .module))
        case .systemDidWake:
            await context.notify(PowerEvent.systemWake.rawValue, subject: "System", title: "System Woke Up", body: "", icon: .asset("Power-AdapterChanged", in: .module))
        case .screensDidSleep:
            await context.notify(PowerEvent.screensSleep.rawValue, subject: "Screens", title: "Display(s) Went to Sleep", body: "", icon: .asset("Power-LowPowerMode", in: .module))
        case .screensDidWake:
            await context.notify(PowerEvent.screensWake.rawValue, subject: "Screens", title: "Display(s) Woke Up", body: "", icon: .asset("Power-AdapterChanged", in: .module))
        case .lowPowerModeChanged(let enabled):
            await handleLowPowerMode(enabled)
        case .adapter(let adapter):
            await handleAdapter(adapter)
        }
    }

    /// Everything a power message can say about the state it is describing.
    ///
    /// One builder for the launch announcement, the source change, the low-battery warning
    /// and the repeat, so a field switched on appears on all four rather than on whichever
    /// of them somebody remembered to wire it into.
    private func body(for snapshot: PowerSnapshot, leading: [BodyLine] = []) async -> String {
        var lines = leading
        lines.append(.field(PowerField.chargeLevel.rawValue, "Charge", Self.chargeDetail(snapshot)))

        for detail in snapshot.sources {
            // Read together rather than field by field: the three parts make one sentence
            // ("Battery: Charging at 85%"), so they are assembled before the body filter
            // sees them, using the same switches it would have applied.
            let status = detail.statusLine(
                showType: await context.isFieldEnabled(PowerField.sourceType.rawValue),
                showState: await context.isFieldEnabled(PowerField.chargeState.rawValue),
                showPercentage: await context.isFieldEnabled(PowerField.chargeLevel.rawValue)
            )
            lines.append(.always(status ?? ""))
            lines.append(.field(PowerField.timeRemaining.rawValue, "Time", detail.timeNote))
            lines.append(.field(PowerField.diagnostics.rawValue, "Detail", detail.diagnosticsNote))
        }

        return await context.body(lines)
    }

    private func handleAdapter(_ adapter: PowerAdapterDetail?) async {
        defer { lastAdapter = adapter }

        // The first reading is the baseline. Announcing it would mean saying "the adapter
        // changed" about the adapter that was already plugged in when the application
        // started — which is what the launch announcement is for, and it says it better.
        guard sawFirstAdapter else {
            sawFirstAdapter = true
            return
        }
        guard adapter != lastAdapter else { return }

        // An adapter being unplugged is already reported, as the switch to battery power;
        // saying "no adapter" alongside it would be the same news twice.
        guard let adapter else { return }

        await context.notify(
            PowerEvent.adapterChanged.rawValue,
            subject: "Adapter",
            title: "Power Adapter Changed",
            body: await context.body([
                .field(PowerField.adapterWattage.rawValue, "Adapter", adapter.wattageLabel),
                .field(PowerField.adapterIdentity.rawValue, "Family", adapter.family),
                .field(PowerField.adapterIdentity.rawValue, "ID", adapter.adapterID),
                .field(PowerField.adapterIdentity.rawValue, "Serial", adapter.serialNumber)
            ]),
            icon: .asset("Power-AdapterChanged", in: .module)
        )
    }

    private func handleSnapshot(_ snapshot: PowerSnapshot) async {
        lastSnapshot = snapshot
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
                    body: await body(for: snapshot),
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
                body: await body(for: snapshot),
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
                body: await body(
                    for: snapshot,
                    leading: [.always("Battery Low, Please plug the computer in now")]
                ),
                icon: .asset(Self.iconName(for: snapshot), in: .module)
            )
        } else if changedKind {
            await context.notify(
                PowerEvent.sourceChanged.rawValue,
                subject: "Source",
                title: "On \(Self.localizedName(for: snapshot.kind))",
                body: await body(
                    for: snapshot,
                    leading: [.field(
                        PowerField.sourceChangeArrow.rawValue,
                        "Source",
                        "\(Self.localizedName(for: previousKind)) → \(Self.localizedName(for: snapshot.kind))"
                    )]
                ),
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
        case .unknown: return "Unknown Power Source"
        }
    }
}
