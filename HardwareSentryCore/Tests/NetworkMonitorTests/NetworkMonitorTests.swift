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

private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>
    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

@Suite("WiFiDetail")
struct WiFiDetailTests {
    @Test("signal is said in dBm and in words")
    func rssiIsSpelledOut() {
        #expect(WiFiDetail(rssi: -45).rssiNote == "-45 dBm (excellent)")
        #expect(WiFiDetail(rssi: -55).rssiNote == "-55 dBm (good)")
        #expect(WiFiDetail(rssi: -65).rssiNote == "-65 dBm (fair)")
        #expect(WiFiDetail(rssi: -85).rssiNote == "-85 dBm (weak)")
        #expect(WiFiDetail(rssi: 0).rssiNote == nil)
    }

    @Test("signal-to-noise is worked out, since neither figure gives it alone")
    func qualityCombinesTheTwoReadings() {
        #expect(WiFiDetail(rssi: -55, noise: -92).qualityNote == "37 dB signal-to-noise")
    }

    @Test("a missing noise reading means no quality line rather than a wrong one")
    func qualityNeedsBothReadings() {
        #expect(WiFiDetail(rssi: -55).qualityNote == nil)
        #expect(WiFiDetail(rssi: -55, noise: 0).qualityNote == nil)
    }

    @Test("a rate of zero is an interface that has not settled, not a dead link")
    func zeroRateIsOmitted() {
        #expect(WiFiDetail(transmitRate: 0).rateNote == nil)
        #expect(WiFiDetail(transmitRate: 866.7).rateNote == "867 Mbps")
    }
}

@Suite("NetworkPathDetail")
struct NetworkPathDetailTests {
    @Test("the two IP protocols read as one line")
    func protocolsAreOneLine() {
        // The interesting case is one of them missing; two lines saying "both fine" is
        // two lines wasted.
        #expect(NetworkPathDetail(supportsIPv4: true, supportsIPv6: true).protocolsNote == "IPv4 and IPv6")
        #expect(NetworkPathDetail(supportsIPv4: true).protocolsNote == "IPv4 only")
        #expect(NetworkPathDetail(supportsIPv6: true).protocolsNote == "IPv6 only")
        #expect(NetworkPathDetail().protocolsNote == nil)
    }

    @Test("DNS is only mentioned when it is missing")
    func dnsIsWarnedAboutOnly() {
        // A path that reaches the Internet but cannot resolve names looks exactly like a
        // broken Internet to whoever is using it.
        #expect(NetworkPathDetail(supportsDNS: false).dnsNote == "No DNS on this path")
        #expect(NetworkPathDetail(supportsDNS: true).dnsNote == nil)
    }

    @Test("an ordinary connection says nothing about cost")
    func costIsPresentOnly() {
        #expect(NetworkPathDetail(isExpensive: true).expensiveNote == "Yes — billed by usage")
        #expect(NetworkPathDetail(isExpensive: false).expensiveNote == nil)
        #expect(NetworkPathDetail(isConstrained: true).constrainedNote == "Yes — Low Data Mode")
        #expect(NetworkPathDetail(isConstrained: false).constrainedNote == nil)
    }
}

@Suite("NetworkMonitor optional fields")
struct NetworkMonitorFieldTests {
    private static let wifi = WiFiDetail(
        bssid: "aa:bb:cc:dd:ee:ff",
        channel: "5 GHz, channel 44 (80 MHz)",
        generation: "Wi-Fi 6 (802.11ax)",
        security: "WPA3",
        rssi: -47,
        noise: -92,
        transmitRate: 866.7,
        countryCode: "ES",
        interfaceName: "en0"
    )

    private func bodies(_ script: [NetworkSourceEvent], expecting: Int, allowing allowed: Set<String>) async -> [String] {
        let delivery = CollectingDelivery()
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: NetworkMonitor.category,
                preferences: ChosenFields(allowed: allowed)
            )
        )
        await monitor.start()
        // Polled with a real wait rather than bare `Task.yield()`: building a body awaits
        // the preferences for every field, so the notification can take more hops than a
        // yield loop reliably gives it.
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events.map(\.body)
    }

    @Test("out of the box, joining a network says the channel and the signal")
    func defaultsAreChannelSignalAndTheDNSWarning() async {
        let defaults = Set(NetworkMonitor.fields.filter(\.shownByDefault).map(\.name))
        #expect(defaults == [NetworkField.signal.rawValue, NetworkField.channel.rawValue, NetworkField.dns.rawValue])

        let bodies = await bodies([.wifiConnected(ssid: "Casa", detail: Self.wifi)], expecting: 1, allowing: defaults)
        #expect(bodies.first == "Joined network.\nSSID:\tCasa\nChannel:\t5 GHz, channel 44 (80 MHz)\nSignal:\t-47 dBm (excellent)")
    }

    @Test("with everything switched on, the Wi-Fi details read in the declared order")
    func fullWiFiDetailReadsInOrder() async {
        let bodies = await bodies(
            [.wifiConnected(ssid: "Casa", detail: Self.wifi)],
            expecting: 1,
            allowing: Set(NetworkField.allCases.map(\.rawValue))
        )

        #expect(bodies.first == """
        Joined network.
        SSID:\tCasa
        BSSID:\taa:bb:cc:dd:ee:ff
        Channel:\t5 GHz, channel 44 (80 MHz)
        Standard:\tWi-Fi 6 (802.11ax)
        Security:\tWPA3
        Signal:\t-47 dBm (excellent)
        Quality:\t45 dB signal-to-noise
        Rate:\t867 Mbps
        Country:\tES
        Interface:\ten0
        """)
    }

    @Test("without Location access the message is shorter, not broken")
    func missingBSSIDIsJustAMissingLine() async {
        // macOS treats a BSSID as a location, because it is one, and this app does not ask
        // for that permission — so in practice this is the usual case, not the odd one.
        let noBSSID = WiFiDetail(channel: "2.4 GHz, channel 6 (20 MHz)", rssi: -65)
        let bodies = await bodies(
            [.wifiConnected(ssid: "Casa", detail: noBSSID)],
            expecting: 1,
            allowing: Set(NetworkField.allCases.map(\.rawValue))
        )

        #expect(bodies.first == "Joined network.\nSSID:\tCasa\nChannel:\t2.4 GHz, channel 6 (20 MHz)\nSignal:\t-65 dBm (fair)")
    }

    @Test("the Internet coming back says how it came back")
    func reachabilityCarriesThePathDetail() async {
        let path = NetworkPathDetail(
            interfaceType: "Cellular", isExpensive: true, isConstrained: true,
            supportsIPv4: true, supportsIPv6: false, supportsDNS: true
        )
        let bodies = await bodies(
            [.reachability(isReachable: false), .reachability(isReachable: true, detail: path)],
            expecting: 1,
            allowing: Set(NetworkField.allCases.map(\.rawValue))
        )

        #expect(bodies.first == """
        General Internet connectivity was restored
        Over:\tCellular
        Metered:\tYes — billed by usage
        Constrained:\tYes — Low Data Mode
        Protocols:\tIPv4 only
        """)
    }

    @Test("losing the Internet describes nothing, because there is no path left to describe")
    func losingReachabilityStaysShort() async {
        let path = NetworkPathDetail(interfaceType: "Wi-Fi", supportsIPv4: true, supportsIPv6: true, supportsDNS: true)
        let bodies = await bodies(
            [.reachability(isReachable: true, detail: path), .reachability(isReachable: false, detail: path)],
            expecting: 1,
            allowing: Set(NetworkField.allCases.map(\.rawValue))
        )

        #expect(bodies.first == "General Internet connectivity was lost")
    }
}
