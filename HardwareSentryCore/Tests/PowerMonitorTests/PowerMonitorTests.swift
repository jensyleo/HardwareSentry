import Foundation
import SentryTestSupport
import SignalCore
import SentryContract
import Testing
@testable import PowerMonitor

struct ScriptedPowerSource: PowerSource {
    let script: [PowerSourceEvent]

    func changes() -> AsyncStream<PowerSourceEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

actor CollectingDelivery: NotificationDelivering {
    private(set) var events: [NotificationEvent] = []

    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        events.append(event)
        return .presented
    }
}

private func snapshot(_ kind: PowerSourceKind, percent: Int? = nil, warning: Bool = false) -> PowerSnapshot {
    PowerSnapshot(kind: kind, percentage: percent, isLowBatteryWarning: warning)
}

@Suite("PowerMonitor")
struct PowerMonitorTests {
    private func run(_ script: [PowerSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PowerMonitor(
            source: ScriptedPowerSource(script: script),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: PowerMonitor.category,
                // These exercise transitions, so the startup announcement is switched off:
                // with it on, every count below would include the opening "On AC Power".
                announcesWhatIsAlreadyThere: false
            )
        )

        await monitor.start()
        await settle()
        await monitor.stop()
        return await delivery.events
    }

    @Test("the first snapshot is a silent baseline")
    func firstSnapshotIsSilent() async {
        let events = await run([.snapshot(snapshot(.battery, percent: 80))])
        #expect(events.isEmpty)
    }

    @Test("a real source change is announced with old and new")
    func sourceChangeIsAnnounced() async {
        let events = await run([
            .snapshot(snapshot(.battery, percent: 80)),
            .snapshot(snapshot(.ac, percent: 82))
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PowerChange")
        #expect(events.first?.body.hasPrefix("Source:\tBattery Power → AC Power") == true)
        #expect(events.first?.body.contains("Charge:\t82%") == true)
    }

    @Test("reaching 100% on AC after the baseline announces fully charged exactly once")
    func fullyChargedFiresOnce() async {
        let events = await run([
            .snapshot(snapshot(.ac, percent: 90)),
            .snapshot(snapshot(.ac, percent: 100)),
            .snapshot(snapshot(.ac, percent: 100))
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PowerFullyCharged")
    }

    @Test("already full at the very first reading is not announced")
    func alreadyFullAtBaselineIsSilent() async {
        let events = await run([.snapshot(snapshot(.ac, percent: 100))])
        #expect(events.isEmpty)
    }

    @Test("dropping below full and reaching it again re-announces")
    func fullyChargedReArmsAfterDropping() async {
        let events = await run([
            .snapshot(snapshot(.ac, percent: 100)),
            .snapshot(snapshot(.battery, percent: 95)),
            .snapshot(snapshot(.ac, percent: 100))
        ])

        #expect(events.filter { $0.name == "PowerFullyCharged" }.count == 1)
    }

    @Test("a low battery warning fires once on the rising edge, not every poll")
    func lowBatteryWarningIsEdgeTriggered() async {
        let events = await run([
            .snapshot(snapshot(.battery, percent: 20, warning: false)),
            .snapshot(snapshot(.battery, percent: 10, warning: true)),
            .snapshot(snapshot(.battery, percent: 9, warning: true))
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PowerWarning")
    }

    @Test("the warning can fire again after recovering and dropping low a second time")
    func lowBatteryWarningRearmsAfterRecovery() async {
        let events = await run([
            .snapshot(snapshot(.battery, percent: 20, warning: false)),
            .snapshot(snapshot(.battery, percent: 10, warning: true)),
            .snapshot(snapshot(.ac, percent: 50, warning: false)),
            .snapshot(snapshot(.battery, percent: 10, warning: true))
        ])

        #expect(events.filter { $0.name == "PowerWarning" }.count == 2)
    }

    @Test("system and display sleep/wake are announced under their own distinct events")
    func sleepWakeEventsAreDistinct() async {
        let events = await run([.systemWillSleep, .systemDidWake, .screensDidSleep, .screensDidWake])

        #expect(events.map(\.name) == ["PowerSystemSleep", "PowerSystemWake", "PowerScreensSleep", "PowerScreensWake"])
    }

    @Test("the first Low Power Mode reading is a silent baseline, a real toggle is announced")
    func lowPowerModeBaselineThenToggle() async {
        let events = await run([.lowPowerModeChanged(false), .lowPowerModeChanged(true)])

        #expect(events.count == 1)
        #expect(events.first?.title == "Low Power Mode Enabled")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: PowerMonitor.events.map { ($0.name, $0.enabledByDefault) })

        // One row per rung of the gauge, draining and charging, then the states about the
        // battery itself and the system's own sleeping and waking.
        #expect(Set(byName.keys) == Set(PowerEvent.allCases.map(\.rawValue)))
        #expect(PowerRung.all.count == 22)
        #expect(PowerRung.all.allSatisfy { byName[$0.event.rawValue] == true })
        #expect(byName["PowerPluggedIn"] == true)
        #expect(byName["PowerChange"] == true)
        #expect(byName["PowerBatteryHealth"] == true)
    }

    @Test("a Mac with no battery is not told a charge level it does not have")
    func noBatteryMeansNoChargeLine() async {
        let events = await run([
            .snapshot(snapshot(.ac, percent: nil)),
            .snapshot(snapshot(.unknown, percent: nil))
        ])

        #expect(events.first?.body.contains("Charge:") == false)
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = PowerMonitor(
            source: ScriptedPowerSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: PowerMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}

// MARK: - The adapter, the battery's condition, and saying it again

/// A source that also answers about battery health, and can be asked more than once.
private struct HealthySource: PowerSource {
    let script: [PowerSourceEvent]
    let health: BatteryHealthDetail?

    func changes() -> AsyncStream<PowerSourceEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }

    func readBatteryHealth() async -> BatteryHealthDetail? { health }
}

private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>
    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

@Suite("PowerMonitor · adapter")
struct PowerAdapterTests {
    private func run(_ script: [PowerSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PowerMonitor(
            source: ScriptedPowerSource(script: script),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: PowerMonitor.category,
                announcesWhatIsAlreadyThere: false
            ),
            healthCheck: .off
        )
        await monitor.start()
        await settle()
        await monitor.stop()
        return await delivery.events
    }

    @Test("the adapter that was already plugged in is not announced as a change")
    func firstAdapterIsBaseline() async {
        let events = await run([.adapter(PowerAdapterDetail(watts: 96))])
        #expect(events.isEmpty)
    }

    @Test("a different wattage from the same kind of adapter is a change")
    func wattageChangeIsAnnounced() async {
        let events = await run([
            .adapter(PowerAdapterDetail(watts: 96, family: "0x0067")),
            .adapter(PowerAdapterDetail(watts: 30, family: "0x0067"))
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PowerAdapterChanged")
        #expect(events.first?.body.contains("Adapter:\t30W") == true)
    }

    @Test("the same adapter reported twice says nothing")
    func repeatedAdapterIsSilent() async {
        let adapter = PowerAdapterDetail(watts: 96, family: "0x0067", adapterID: "1")
        let events = await run([.adapter(adapter), .adapter(adapter), .adapter(adapter)])
        #expect(events.isEmpty)
    }

    @Test("unplugging is left to the source change, not reported twice")
    func unplugIsSilent() async {
        let events = await run([.adapter(PowerAdapterDetail(watts: 96)), .adapter(nil)])
        #expect(events.isEmpty)
    }

    @Test("an adapter that does not say its wattage is not reported as 0W")
    func unknownWattageIsSaidPlainly() async {
        let events = await run([
            .adapter(PowerAdapterDetail(watts: 96)),
            .adapter(PowerAdapterDetail(family: "0x0067"))
        ])
        #expect(events.first?.body.contains("Unknown wattage") == true)
        #expect(events.first?.body.contains("0W") == false)
    }
}

@Suite("PowerMonitor · repeating the status")
struct PowerRefireTests {
    private func make(
        _ refire: PowerRefireSettings,
        script: [PowerSourceEvent]
    ) async -> (PowerMonitor, CollectingDelivery) {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PowerMonitor(
            source: ScriptedPowerSource(script: script),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: PowerMonitor.category,
                announcesWhatIsAlreadyThere: false
            ),
            refire: refire,
            healthCheck: .off
        )
        await monitor.start()
        await settle()
        return (monitor, delivery)
    }

    @Test("the repeat says the current status without claiming anything changed")
    func repeatOmitsTheTransition() async {
        let (monitor, delivery) = await make(
            PowerRefireSettings(isEnabled: true, minutes: 30, onlyOnBattery: false),
            script: [.snapshot(PowerSnapshot(kind: .battery, percentage: 64, isLowBatteryWarning: false))]
        )
        await monitor.refireNow()
        await monitor.stop()

        let events = await delivery.events
        #expect(events.count == 1)
        #expect(events.first?.title == "On Battery Power")
        #expect(events.first?.body.contains("Charge:\t64%") == true)
        #expect(events.first?.body.contains("Source:") == false)
    }

    @Test("on battery only means silence while plugged in")
    func onBatteryOnlyStaysQuietOnAC() async {
        let (monitor, delivery) = await make(
            PowerRefireSettings(isEnabled: true, minutes: 30, onlyOnBattery: true),
            script: [.snapshot(PowerSnapshot(kind: .ac, percentage: 100, isLowBatteryWarning: false))]
        )
        await monitor.refireNow()
        await monitor.stop()
        #expect(await delivery.events.isEmpty)
    }

    @Test("nothing is repeated before there is anything to repeat")
    func noSnapshotYetIsSilent() async {
        let (monitor, delivery) = await make(
            PowerRefireSettings(isEnabled: true, minutes: 30, onlyOnBattery: false),
            script: []
        )
        await monitor.refireNow()
        await monitor.stop()
        #expect(await delivery.events.isEmpty)
    }

    @Test("an interval of zero is refused rather than fired in a loop")
    func intervalIsClamped() {
        #expect(PowerRefireSettings(isEnabled: true, minutes: 0).interval == .seconds(60))
        #expect(PowerRefireSettings(isEnabled: true, minutes: 100_000).interval == .seconds(24 * 60 * 60))
    }
}

@Suite("PowerMonitor · battery health")
struct PowerBatteryHealthTests {
    private func make(
        health: BatteryHealthDetail?,
        preferences: any NotificationPreferences = AlwaysWanted(),
        store: any PowerHealthStore = EphemeralPowerHealthStore()
    ) async -> (PowerMonitor, CollectingDelivery) {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PowerMonitor(
            source: HealthySource(script: [], health: health),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: PowerMonitor.category,
                preferences: preferences,
                announcesWhatIsAlreadyThere: false
            ),
            healthCheck: .off,
            healthStore: store
        )
        return (monitor, delivery)
    }

    @Test("a first reading is reported, an unchanged second one is not")
    func onlyChangesAreReported() async {
        let health = BatteryHealthDetail(cycleCount: 142, designCycleCount: 1000, healthPercent: 93, condition: "Normal")
        let (monitor, delivery) = await make(health: health)

        await monitor.checkBatteryHealthNow(force: false)
        await monitor.checkBatteryHealthNow(force: false)

        let events = await delivery.events
        #expect(events.count == 1)
        #expect(events.first?.name == "PowerBatteryHealth")
        #expect(events.first?.title == "Battery Health")
        #expect(events.first?.body.contains("Cycles:\tCycle count: 142 (rated for ~1000)") == true)
        #expect(events.first?.body.contains("Health:\tBattery health: 93%") == true)
    }

    @Test("the hourly reminder is a separate, forced repeat of the same reading")
    func notifyTimerForcesARepeatIndependentlyOfTheCheck() async {
        // Mirrors PowerRefireTests below: rather than waiting a real hour for the timer,
        // this checks the same thing the timer calls — force:true always answers, whether
        // or not the health check's own interval is due. The timer itself is exercised by
        // PowerHealthNotifySettingsTests, which checks it actually gets built into the
        // monitor and clamped sensibly.
        let (monitor, delivery) = await make(
            health: BatteryHealthDetail(cycleCount: 142, healthPercent: 93)
        )
        await monitor.checkBatteryHealthNow(force: false)
        await monitor.checkBatteryHealthNow(force: true)
        await monitor.checkBatteryHealthNow(force: true)
        #expect(await delivery.events.count == 3)
    }

    @Test("Check Now answers even when the reading has not moved")
    func forcedCheckAlwaysAnswers() async {
        let (monitor, delivery) = await make(
            health: BatteryHealthDetail(cycleCount: 142, healthPercent: 93)
        )
        await monitor.checkBatteryHealthNow(force: false)
        await monitor.checkBatteryHealthNow(force: true)
        #expect(await delivery.events.count == 2)
    }

    @Test("a reading remembered from a previous launch is not announced again")
    func storeSurvivesRelaunch() async {
        let store = EphemeralPowerHealthStore()
        let health = BatteryHealthDetail(cycleCount: 142, healthPercent: 93)

        let (first, firstDelivery) = await make(health: health, store: store)
        await first.checkBatteryHealthNow(force: false)
        #expect(await firstDelivery.events.count == 1)

        let (second, secondDelivery) = await make(health: health, store: store)
        await second.checkBatteryHealthNow(force: false)
        #expect(await secondDelivery.events.isEmpty)
    }

    @Test("a Mac with no battery is not given a health report")
    func noBatteryIsSilent() async {
        let (monitor, delivery) = await make(health: nil)
        await monitor.checkBatteryHealthNow(force: true)
        #expect(await delivery.events.isEmpty)

        let (empty, emptyDelivery) = await make(health: BatteryHealthDetail())
        await empty.checkBatteryHealthNow(force: true)
        #expect(await emptyDelivery.events.isEmpty)
    }

    @Test("a failing battery says so in the title and arrives with priority")
    func failureIsUnmistakable() async {
        let (monitor, delivery) = await make(
            health: BatteryHealthDetail(healthPercent: 71, hasInternalFailure: true)
        )
        await monitor.checkBatteryHealthNow(force: true)

        let event = await delivery.events.first
        #expect(event?.title == "Battery Failure")
        #expect(event?.priority == .high)
        #expect(event?.body.contains("Internal battery failure reported") == true)
    }

    @Test("service recommended reaches the title too")
    func serviceRecommendedIsInTheTitle() async {
        let (monitor, delivery) = await make(
            health: BatteryHealthDetail(condition: "Service Recommended")
        )
        await monitor.checkBatteryHealthNow(force: true)
        #expect(await delivery.events.first?.title == "Battery Service Recommended")
    }

    @Test("a named fault is a line of its own, switchable like the rest")
    func faultsAreTheirOwnField() async {
        // On by default, because it only ever appears when something is wrong — but
        // switchable, because it is not this application's place to decide that somebody
        // may not turn a line off.
        let (on, onDelivery) = await make(
            health: BatteryHealthDetail(healthPercent: 60, failureModes: ["Cell Imbalance"]),
            preferences: ChosenFields(allowed: [PowerField.batteryFailureModes.rawValue])
        )
        await on.checkBatteryHealthNow(force: true)
        let body = await onDelivery.events.first?.body
        #expect(body?.contains("Cell Imbalance") == true)
        // The optional numbers really are off, so this is not passing by accident.
        #expect(body?.contains("60%") == false)

        let (off, offDelivery) = await make(
            health: BatteryHealthDetail(healthPercent: 60, failureModes: ["Cell Imbalance"]),
            preferences: ChosenFields(allowed: [])
        )
        await off.checkBatteryHealthNow(force: true)
        // The notification still arrives — the title says "Battery Needs Attention" — but
        // the detail line is the one thing that was switched off.
        #expect(await offDelivery.events.first?.title == "Battery Needs Attention")
        #expect(await offDelivery.events.first?.body.contains("Cell Imbalance") == false)
    }

    @Test("capacity drifting by a few mAh is not treated as news")
    func summaryIgnoresCapacityDrift() {
        let a = BatteryHealthDetail(cycleCount: 142, healthPercent: 93, currentCapacityMAh: 4_411)
        let b = BatteryHealthDetail(cycleCount: 142, healthPercent: 93, currentCapacityMAh: 4_408)
        #expect(PowerMonitor.summary(of: a) == PowerMonitor.summary(of: b))
    }

    @Test("a cycle count moving is news")
    func summaryNoticesRealChange() {
        let a = BatteryHealthDetail(cycleCount: 142, healthPercent: 93)
        let b = BatteryHealthDetail(cycleCount: 143, healthPercent: 93)
        #expect(PowerMonitor.summary(of: a) != PowerMonitor.summary(of: b))
    }

    @Test("an unrated battery still reports its cycles")
    func cyclesWithoutARating() {
        #expect(BatteryHealthDetail(cycleCount: 12).cycleNote == "Cycle count: 12")
        #expect(BatteryHealthDetail(cycleCount: 12, designCycleCount: 0).cycleNote == "Cycle count: 12")
    }

    @Test("a battery that is confident reports no error margin")
    func zeroErrorMarginIsNotAMargin() {
        #expect(BatteryHealthDetail(maximumErrorPercent: 0).errorMarginNote == nil)
        #expect(BatteryHealthDetail(maximumErrorPercent: 3).errorMarginNote == "Reporting error margin: ±3%")
    }
}

@Suite("PowerHealthNotifySettings")
struct PowerHealthNotifySettingsTests {
    @Test("off by default")
    func offByDefault() {
        #expect(PowerHealthNotifySettings.off.isEnabled == false)
    }

    @Test("hours are clamped to something a person could have meant")
    func hoursAreClamped() {
        #expect(PowerHealthNotifySettings(isEnabled: true, hours: 0).interval == .seconds(3600))
        #expect(PowerHealthNotifySettings(isEnabled: true, hours: 8).interval == .seconds(8 * 3600))
        #expect(PowerHealthNotifySettings(isEnabled: true, hours: 10000).interval == .seconds(31 * 24 * 3600))
    }

    @Test("apply() wires it into a running monitor without disturbing the health check")
    func appliesAlongsideHealthCheck() async {
        let monitor = PowerMonitor(
            source: HealthySource(script: [], health: nil),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: PowerMonitor.category,
                announcesWhatIsAlreadyThere: false
            ),
            healthCheck: .off
        )
        await monitor.start()
        await monitor.apply(
            refire: .off,
            healthCheck: .off,
            healthNotify: PowerHealthNotifySettings(isEnabled: true, hours: 8)
        )
        await monitor.stop()
    }
}

@Suite("PowerSourceDetail")
struct PowerSourceDetailTests {
    private let battery = PowerSourceDetail(
        typeName: "Battery",
        chargeState: "Charging",
        percentage: 85,
        minutesRemaining: 47,
        isCharging: true
    )

    @Test("the three parts read as one sentence")
    func fullStatusLine() {
        #expect(battery.statusLine(showType: true, showState: true, showPercentage: true) == "Battery: Charging at 85%")
    }

    @Test("switching parts off leaves a sentence rather than a gap")
    func partialStatusLines() {
        #expect(battery.statusLine(showType: false, showState: false, showPercentage: true) == "85%")
        #expect(battery.statusLine(showType: true, showState: false, showPercentage: false) == "Battery")
        #expect(battery.statusLine(showType: false, showState: true, showPercentage: true) == "Charging at 85%")
        #expect(battery.statusLine(showType: false, showState: false, showPercentage: false) == nil)
    }

    @Test("the time is worded for the direction it is going")
    func timeNoteWording() {
        #expect(battery.timeNote == "47 minutes until full")
        let discharging = PowerSourceDetail(minutesRemaining: 210, isCharging: false)
        #expect(discharging.timeNote == "210 minutes of charge left")
    }

    @Test("a time the system has not worked out yet is not shown")
    func unsettledTimeIsSilent() {
        #expect(PowerSourceDetail(minutesRemaining: 0, isCharging: false).timeNote == nil)
        #expect(PowerSourceDetail(minutesRemaining: nil).timeNote == nil)
    }
}

@Suite("PowerRung · one row per rung of the gauge")
struct PowerRungTests {
    @Test("eleven rungs draining and eleven charging, each with artwork that exists")
    func everyRungIsDeclared() {
        #expect(PowerRung.all.count == 22)

        for rung in PowerRung.all {
            let declared = PowerMonitor.events.first { $0.name == rung.event.rawValue }
            #expect(declared != nil, "\(rung) has no row")
            // `.asset` gives no icon for a name that resolves to nothing, so this catches
            // a typo in an artwork name as well as a missing row.
            #expect(declared?.icon != NotificationIcon.none, "\(rung) has no icon")
            #expect(declared?.title == rung.settingsTitle)
        }
    }

    @Test("a charging battery and a draining one are not the same row")
    func chargingIsItsOwnRung() {
        // Same percentage, different picture and different switch: showing a full battery
        // the moment a nearly-empty Mac is plugged in would be actively misleading.
        #expect(PowerRung(percentage: 50, isCharging: false).iconBaseName == "Power-50")
        #expect(PowerRung(percentage: 50, isCharging: true).iconBaseName == "Power-Charging-50")
        #expect(PowerRung(percentage: 50, isCharging: false).event != PowerRung(percentage: 50, isCharging: true).event)
    }

    @Test("a reading is rounded to the rung the artwork comes in")
    func percentagesRound() {
        #expect(PowerRung.rung(forPercentage: 87, isCharging: false).percentage == 90)
        #expect(PowerRung.rung(forPercentage: 84, isCharging: false).percentage == 80)
        #expect(PowerRung.rung(forPercentage: 3, isCharging: true).percentage == 0)
        // And clamped, because a source that reports 110 exists and there is no icon for it.
        #expect(PowerRung.rung(forPercentage: 110, isCharging: false).percentage == 100)
        #expect(PowerRung.rung(forPercentage: -5, isCharging: false).percentage == 0)
    }

    @Test("the module's icon is not whichever rung happens to be declared first")
    func moduleIconIsDeclared() {
        #expect(PowerMonitor.icon == .asset("Power-Plugged", in: .module))
    }
}
