import Foundation
import Testing
@testable import SignalCore

@Suite("Settling out of the opening rush")
struct SettleToSteadyTests {
    private func makeDispatcher() -> (NotificationDispatcher, RecordingDelivery) {
        let delivery = RecordingDelivery()
        return (NotificationDispatcher(delivery: delivery, phase: .launching), delivery)
    }

    @Test("an application with nothing to report does not sit in the opening phase")
    func nothingRaisedSettlesAtOnce() async {
        let (dispatcher, delivery) = makeDispatcher()

        await dispatcher.settleToSteady(afterQuiet: .milliseconds(50), checkingEvery: .milliseconds(10))
        await dispatcher.fire(makeEvent(name: "After"))

        #expect(await delivery.presented.first?.context.phase == .steady)
    }

    @Test("it waits for the burst to stop before calling the start-up over")
    func waitsForQuiet() async {
        let (dispatcher, delivery) = makeDispatcher()

        // Something still arriving while the settle is running.
        let noise = Task {
            for i in 0..<4 {
                await dispatcher.fire(makeEvent(name: "burst\(i)"))
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        await dispatcher.settleToSteady(afterQuiet: .milliseconds(100), checkingEvery: .milliseconds(10))
        await noise.value

        // Everything raised during the burst was stamped as opening, which is what the
        // queue limits and duplicate suppression are tuned for.
        let burst = await delivery.presented.filter { $0.event.name.hasPrefix("burst") }
        #expect(burst.count == 4)
        #expect(burst.allSatisfy { $0.context.phase == .launching })

        await dispatcher.fire(makeEvent(name: "later"))
        #expect(await delivery.presented.last?.context.phase == .steady)
    }

    @Test("a machine that never goes quiet is still declared settled, rather than never")
    func timeoutIsABackstop() async {
        let (dispatcher, delivery) = makeDispatcher()

        let forever = Task {
            for i in 0..<100 {
                await dispatcher.fire(makeEvent(name: "endless\(i)"))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        // Quiet never arrives, so only the backstop can end this.
        await dispatcher.settleToSteady(
            afterQuiet: .milliseconds(500),
            timeout: .milliseconds(150),
            checkingEvery: .milliseconds(10)
        )
        forever.cancel()

        await dispatcher.fire(makeEvent(name: "after timeout"))
        #expect(await delivery.presented.last?.context.phase == .steady)
    }
}
