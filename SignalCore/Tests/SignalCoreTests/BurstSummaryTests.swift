import Foundation
import Testing
@testable import SignalCore

@Suite("BurstSummary")
struct BurstSummaryTests {
    private func event(_ title: String, body: String = "", module: String = "USB", badge: IconBadge? = nil, sticky: Bool = false, priority: NotificationEvent.Priority = .normal) -> NotificationEvent {
        NotificationEvent(name: title, category: NotificationCategory(module), title: title, body: body, iconBadge: badge, priority: priority, isSticky: sticky)
    }

    @Test("grouping is off out of the box, so every notice stays on its own")
    func offByDefault() {
        let standard = BannerAppearance.standard
        #expect(!standard.coalescesBursts)
        #expect(standard.burstThreshold == 4)
        #expect(standard.burstWindow == 2)
    }

    @Test("plain news may be grouped; anything needing attention, critical, sticky or urgent may not")
    func onlyPlainNewsIsGroupable() {
        #expect(BurstSummary.isGroupable(event("a")))
        #expect(BurstSummary.isGroupable(event("a", badge: .positive)))
        #expect(BurstSummary.isGroupable(event("a", badge: .negative)))
        #expect(!BurstSummary.isGroupable(event("a", badge: .warning)))
        #expect(!BurstSummary.isGroupable(event("a", badge: .critical)))
        #expect(!BurstSummary.isGroupable(event("a", sticky: true)))
        #expect(!BurstSummary.isGroupable(event("a", priority: .high)))
    }

    @Test("a summary names how many notices it holds and lists them")
    func summaryListsWhatItHolds() {
        let events = (1...3).map { n in event("Device \(n)", body: "Serial \(n)") }
        let summary = BurstSummary.summary(of: events)

        #expect(summary.title == "3 notices from USB")
        #expect(summary.body.split(separator: "\n").count == 3)
        #expect(summary.body.contains("Device 2 — Serial 2"))
    }

    @Test("notices from several modules are counted without naming one module")
    func mixedModules() {
        let summary = BurstSummary.summary(of: [event("a", module: "USB"), event("b", module: "Audio")])
        #expect(summary.title == "2 notices at once")
    }

    @Test("a long burst lists only the first few and counts the rest")
    func longBurstIsCapped() {
        let events = (1...9).map { n in event("Device \(n)") }
        let lines = BurstSummary.summary(of: events).body.split(separator: "\n").map(String.init)

        #expect(lines.count == BurstSummary.listedLimit + 1)
        #expect(lines.last == "and 4 more")
    }

    @Test("whoever raised a notice still hears how the summary ended")
    func interactionReachesEveryNotice() {
        final class Box: @unchecked Sendable { var heard: [NotificationInteraction] = [] }
        let box = Box()
        var a = event("a"); a.onInteraction = { box.heard.append($0) }
        var b = event("b"); b.onInteraction = { box.heard.append($0) }

        BurstSummary.summary(of: [a, b]).onInteraction?(.dismissed)

        #expect(box.heard.count == 2)
    }

    @Test("the burst settings are remembered and kept in range")
    @MainActor
    func settingsSurviveARelaunch() {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "BurstTests.\(id)")!
        let store = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")
        store.appearance.coalescesBursts = true
        store.appearance.burstThreshold = 6
        store.appearance.burstWindow = 3
        store.appearance.burstThreshold = 99

        let reopened = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")
        #expect(reopened.appearance.coalescesBursts)
        #expect(reopened.appearance.burstThreshold == BannerAppearance.burstThresholdRange.upperBound)
        #expect(reopened.appearance.burstWindow == 3)
    }
}
