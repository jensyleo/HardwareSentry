import Foundation
import SentryContract
import SignalCore
import Testing

/// A monitor that records whether it is currently running, so a registry's decision to
/// start or stop it can be observed rather than assumed.
private actor RecordingMonitor: Monitor {
    static let category: NotificationCategory = "Recording"
    static let events: [MonitorEventDescription] = []

    private(set) var isRunning = false
    private(set) var startCount = 0

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }

    func stop() async { isRunning = false }
}

private actor OptInMonitor: Monitor {
    static let category: NotificationCategory = "OptIn"
    static let events: [MonitorEventDescription] = []
    static let enabledByDefault = false

    func start() async {}
    func stop() async {}
}

@Suite("Monitor defaults")
struct MonitorDefaultsTests {
    @Test("a monitor is on for someone who has never chosen, unless it says otherwise")
    func defaultIsOnUnlessDeclaredOtherwise() {
        #expect(RecordingMonitor.enabledByDefault)
        #expect(!OptInMonitor.enabledByDefault)
    }

    @Test("starting is idempotent, so a registry can call it again without keeping score")
    func startingTwiceRunsOnce() async {
        let monitor = RecordingMonitor()

        await monitor.start()
        await monitor.start()

        #expect(await monitor.startCount == 1)
        #expect(await monitor.isRunning)
    }

    @Test("a monitor that was stopped can be started again")
    func stoppingAndRestarting() async {
        let monitor = RecordingMonitor()

        await monitor.start()
        await monitor.stop()
        #expect(await monitor.isRunning == false)

        await monitor.start()
        #expect(await monitor.isRunning)
        #expect(await monitor.startCount == 2)
    }

    @Test("stopping one that never ran is harmless")
    func stoppingUnstartedIsHarmless() async {
        let monitor = RecordingMonitor()
        await monitor.stop()
        #expect(await monitor.isRunning == false)
    }
}
