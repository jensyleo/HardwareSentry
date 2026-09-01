import Foundation
import SignalCore
import SentryContract
import Testing
@testable import NetworkMonitor

struct ScriptedNetworkSource: NetworkSource {
    let script: [NetworkSourceEvent]

    func changes() -> AsyncStream<NetworkSourceEvent> {
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

@Suite("NetworkMonitor")
struct NetworkMonitorTests {
    private func run(_ script: [NetworkSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: NetworkMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the first reachability reading is a silent baseline")
    func reachabilityBaselineIsSilent() async {
        let events = await run([.reachability(isReachable: true)])
        #expect(events.isEmpty)
    }

    @Test("a real reachability transition is announced")
    func reachabilityTransitionIsAnnounced() async {
        let events = await run([.reachability(isReachable: true), .reachability(isReachable: false)])

        #expect(events.count == 1)
        #expect(events.first?.name == "NetworkReachabilityChanged")
        #expect(events.first?.title == "Internet Unreachable")
    }

    @Test("joining and leaving Wi-Fi fire distinct events")
    func wifiConnectAndDisconnect() async {
        let events = await run([.wifiConnected(ssid: "CasaWiFi"), .wifiDisconnected])

        #expect(events[0].name == "AirportConnected")
        #expect(events[0].subject == "CasaWiFi")
        #expect(events[1].name == "AirportDisconnected")
    }

    @Test("the first link snapshot is a silent baseline")
    func linkBaselineIsSilent() async {
        let events = await run([.linkSnapshot(["en0": true])])
        #expect(events.isEmpty)
    }

    @Test("a link coming up and going down fires distinct events, per interface")
    func linkUpAndDown() async {
        let events = await run([
            .linkSnapshot(["en0": false]),
            .linkSnapshot(["en0": true]),
            .linkSnapshot(["en0": false])
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "NetworkLinkUp")
        #expect(events[0].subject == "en0")
        #expect(events[1].name == "NetworkLinkDown")
    }

    @Test("the first primary interface reading is a silent baseline")
    func primaryInterfaceBaselineIsSilent() async {
        let events = await run([.primaryInterfaceSnapshot("en0")])
        #expect(events.isEmpty)
    }

    @Test("a real primary interface change is announced with old and new")
    func primaryInterfaceChangeIsAnnounced() async {
        let events = await run([.primaryInterfaceSnapshot("en0"), .primaryInterfaceSnapshot("en1")])

        #expect(events.count == 1)
        #expect(events.first?.name == "PrimaryInterfaceChanged")
        #expect(events.first?.body == "en0 → en1")
    }

    @Test("a nil primary interface reading is ignored, not treated as a change")
    func nilPrimaryInterfaceIsIgnored() async {
        let events = await run([.primaryInterfaceSnapshot("en0"), .primaryInterfaceSnapshot(nil), .primaryInterfaceSnapshot("en1")])

        #expect(events.count == 1)
        #expect(events.first?.body == "en0 → en1")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: NetworkMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "NetworkReachabilityChanged": false,
            "AirportConnected": true,
            "AirportDisconnected": true,
            "NetworkLinkUp": true,
            "NetworkLinkDown": true,
            "PrimaryInterfaceChanged": false
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: NetworkMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
