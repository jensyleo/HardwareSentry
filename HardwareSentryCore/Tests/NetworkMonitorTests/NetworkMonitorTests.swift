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
            context: MonitorContext(
                dispatcher: dispatcher,
                category: NetworkMonitor.category,
                // These exercise what happens when something *changes*, so the startup
                // sweep is switched off: with it on, the first snapshot is announced and
                // every count below would be measuring the sweep as well as the change.
                announcesWhatIsAlreadyThere: false
            )
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
        let events = await run([.wifiConnected(ssid: "CasaWiFi"), .wifiDisconnected()])

        #expect(events[0].name == "AirportConnected")
        #expect(events[0].subject == "CasaWiFi")
        #expect(events[1].name == "AirportDisconnected")
    }

    @Test("the first link snapshot is a silent baseline")
    func linkBaselineIsSilent() async {
        let events = await run([.linkSnapshot(["en0": LinkState(isActive: true, kind: .wired)])])
        #expect(events.isEmpty)
    }

    @Test("a link coming up and going down fires distinct events, per interface")
    func linkUpAndDown() async {
        let events = await run([
            .linkSnapshot(["en0": LinkState(isActive: false, kind: .wired)]),
            .linkSnapshot(["en0": LinkState(isActive: true, kind: .wired)]),
            .linkSnapshot(["en0": LinkState(isActive: false, kind: .wired)])
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "NetworkLinkUp")
        #expect(events[0].subject == "en0")
        #expect(events[1].name == "NetworkLinkDown")
    }

    @Test("a Wi-Fi link uses the Wi-Fi icon, a wired one the Ethernet icon")
    func linkIconMatchesTheInterfaceKind() async {
        let events = await run([
            .linkSnapshot([
                "en0": LinkState(isActive: false, kind: .wired),
                "en1": LinkState(isActive: false, kind: .wifi)
            ]),
            .linkSnapshot([
                "en0": LinkState(isActive: true, kind: .wired),
                "en1": LinkState(isActive: true, kind: .wifi)
            ])
        ])

        #expect(events.count == 2)
        let wired = events.first { $0.subject == "en0" }
        let wifi = events.first { $0.subject == "en1" }
        #expect(wired?.title == "Wired Link Up")
        #expect(wifi?.title == "Wi-Fi Link Up")
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
            "PrimaryInterfaceChanged": false,
            "NetworkDHCPLeaseRenewed": false,
            "NetworkHostnameChanged": false,
            "IPAddressChange": true
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
        #expect(defaults == [
            NetworkField.signal.rawValue, NetworkField.channel.rawValue,
            NetworkField.dns.rawValue, NetworkField.ipv6.rawValue
        ])

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
        Wi-Fi Generation:\tWi-Fi 6 (802.11ax)
        Security:\tWPA3
        Signal:\t-47 dBm (excellent)
        Quality:\t45 dB signal-to-noise
        Link Rate:\t867 Mbps
        Regulatory country/region:\tES
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

@Suite("SystemNetworkSource key parsing")
struct NetworkLinkKeyTests {
    @Test("the interface name is read out of the SCDynamicStore key")
    func nameIsTheFourthComponent() {
        // "State:" is a component of its own once split on "/", so the name is the fourth
        // piece. Taking the third returned the literal word "Interface" for every
        // interface on the machine, which meant they all shared one name — a second link
        // coming up then looked like the first one changing.
        #expect(SystemNetworkSource.interfaceName(fromLinkKey: "State:/Network/Interface/en0/Link") == "en0")
        #expect(SystemNetworkSource.interfaceName(fromLinkKey: "State:/Network/Interface/utun3/Link") == "utun3")
    }

    @Test("two interfaces do not come back with the same name")
    func namesAreDistinct() {
        let a = SystemNetworkSource.interfaceName(fromLinkKey: "State:/Network/Interface/en0/Link")
        let b = SystemNetworkSource.interfaceName(fromLinkKey: "State:/Network/Interface/en1/Link")
        #expect(a != b)
    }

    @Test("a key that is not a link key yields nothing rather than a wrong name")
    func shortKeysAreRejected() {
        #expect(SystemNetworkSource.interfaceName(fromLinkKey: "State:/Network/Global/IPv4") == nil)
        #expect(SystemNetworkSource.interfaceName(fromLinkKey: "") == nil)
    }
}

@Suite("NetworkInterfaceKind")
struct NetworkInterfaceKindTests {
    @Test("Wi-Fi and Ethernet are told apart by the type SCNetworkInterface reports")
    func classifiesTheCommonCases() {
        #expect(NetworkInterfaceKind.classify(scInterfaceType: "IEEE80211") == .wifi)
        #expect(NetworkInterfaceKind.classify(scInterfaceType: "Ethernet") == .wired)
        #expect(NetworkInterfaceKind.classify(scInterfaceType: "FireWire") == .wired)
    }

    @Test("an interface type nobody named specifically still gets an icon")
    func unfamiliarTypesFallBackToOther() {
        #expect(NetworkInterfaceKind.classify(scInterfaceType: "Bluetooth") == .other)
        #expect(NetworkInterfaceKind.classify(scInterfaceType: "PPP") == .other)
        #expect(NetworkInterfaceKind.classify(scInterfaceType: "") == .other)
    }

    @Test("only Wi-Fi looks like Wi-Fi; everything else reuses the wired icon")
    func iconsFollowTheKind() {
        #expect(NetworkInterfaceKind.wifi.icon(active: true) == "Network-Wifi-4")
        #expect(NetworkInterfaceKind.wifi.icon(active: false) == "Network-Wifi-Off")
        #expect(NetworkInterfaceKind.wired.icon(active: true) == "Network-Ethernet-On")
        #expect(NetworkInterfaceKind.other.icon(active: true) == "Network-Ethernet-On")
    }
}


@Suite("SystemNetworkSource DHCP key parsing")
struct NetworkDHCPKeyTests {
    @Test("the DHCP key uses the same shape as the link key")
    func nameIsTheFourthComponent() {
        #expect(SystemNetworkSource.interfaceName(fromDHCPKey: "State:/Network/Interface/en0/DHCP") == "en0")
    }
}

@Suite("NetworkMonitor DHCP and hostname")
struct NetworkMonitorDHCPHostnameTests {
    private func run(_ script: [NetworkSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: NetworkMonitor.category
            )
        )
        await monitor.start()
        for _ in 0..<200 where await delivery.events.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
        await monitor.stop()
        return await delivery.events
    }

    @Test("an interface already holding a lease at launch is not a renewal")
    func firstLeaseSightingIsSilent() async {
        // DHCP finished normally at some point before this was watching — not a renewal
        // of anything, regardless of whether the startup sweep is announcing devices.
        let events = await run([.dhcpLeaseSnapshot(["en0": Date(timeIntervalSince1970: 1000)])])
        #expect(events.isEmpty)
    }

    @Test("a later, different lease start on a known interface is a renewal")
    func laterLeaseIsARenewal() async {
        let events = await run([
            .dhcpLeaseSnapshot(["en0": Date(timeIntervalSince1970: 1000)]),
            .dhcpLeaseSnapshot(["en0": Date(timeIntervalSince1970: 2000)])
        ])
        #expect(events.count == 1)
        #expect(events.first?.name == "NetworkDHCPLeaseRenewed")
        #expect(events.first?.subject == "en0")
    }

    @Test("the same lease start seen again is not announced twice")
    func unchangedLeaseIsSilent() async {
        let events = await run([
            .dhcpLeaseSnapshot(["en0": Date(timeIntervalSince1970: 1000)]),
            .dhcpLeaseSnapshot(["en0": Date(timeIntervalSince1970: 1000)])
        ])
        #expect(events.isEmpty)
    }

    @Test("the computer name already set at launch is not a change")
    func firstNameSightingIsSilent() async {
        let events = await run([.computerNameSnapshot("Jensy's Mac")])
        #expect(events.isEmpty)
    }

    @Test("the computer name changing says what it changed from and to")
    func nameChangeIsAnnounced() async {
        let events = await run([.computerNameSnapshot("Jensy's Mac"), .computerNameSnapshot("Office Mac")])
        #expect(events.count == 1)
        #expect(events.first?.name == "NetworkHostnameChanged")
        #expect(events.first?.body == "Jensy's Mac → Office Mac")
    }
}

@Suite("IPAddressReport")
struct IPAddressReportTests {
    private static let wifi = InterfaceAddresses(
        bsdName: "en0", friendlyName: "Wi-Fi",
        ipv4: ["192.168.1.42"], ipv6: ["fe80::1c9d", "2a02:9000::5"]
    )

    @Test("addresses read one line each, named the way System Settings names them")
    func bodyListsEachAddress() {
        let report = IPAddressReport(interfaces: [Self.wifi])
        #expect(report.body() == """
        Wi-Fi — IPv4:\t192.168.1.42
        Wi-Fi — IPv6:\t2a02:9000::5
        Wi-Fi — IPv6:\tfe80::1c9d
        """)
    }

    @Test("switching IPv6 off leaves only the IPv4 lines")
    func ipv6CanBeLeftOut() {
        #expect(IPAddressReport(interfaces: [Self.wifi]).body(showIPv6: false) == "Wi-Fi — IPv4:\t192.168.1.42")
    }

    @Test("interfaces read in a stable order, so an unchanged message looks unchanged")
    func orderIsStable() {
        // getifaddrs does not promise an order; an unstable one would make the dedup
        // below think the message changed every time it was read.
        let a = InterfaceAddresses(bsdName: "en1", ipv4: ["10.0.0.2"])
        let b = InterfaceAddresses(bsdName: "en0", ipv4: ["10.0.0.1"])
        #expect(IPAddressReport(interfaces: [a, b]).body() == IPAddressReport(interfaces: [b, a]).body())
    }

    @Test("an interface with no friendly name falls back to its BSD name")
    func bsdNameIsTheFallback() {
        let report = IPAddressReport(interfaces: [InterfaceAddresses(bsdName: "utun4", ipv4: ["10.8.0.2"])])
        #expect(report.body() == "utun4 — IPv4:\t10.8.0.2")
    }

    @Test("a self-assigned address is marked as such")
    func selfAssignedIsMarked() {
        // 169.254.x.x is what an interface falls back to when DHCP never answered: an
        // address, and no connection. Saying so is the difference between the message
        // reading as success and reading as the truth.
        let report = IPAddressReport(interfaces: [InterfaceAddresses(bsdName: "en0", ipv4: ["169.254.13.7"])])
        #expect(report.body().contains("(self-assigned)"))
        #expect(!report.hasRoutableAddress)
        #expect(report.hasAddresses)
    }

    @Test("a link-local IPv6 address alone is not a working connection either")
    func linkLocalV6IsNotRoutable() {
        let report = IPAddressReport(interfaces: [InterfaceAddresses(bsdName: "en0", ipv6: ["fe80::1"])])
        #expect(!report.hasRoutableAddress)
    }

    @Test("nothing at all is nothing, not an empty success")
    func emptyReportHasNoAddresses() {
        #expect(!IPAddressReport(interfaces: []).hasAddresses)
        #expect(!IPAddressReport(interfaces: [InterfaceAddresses(bsdName: "en0")]).hasAddresses)
    }
}

@Suite("NetworkMonitor IP addresses")
struct NetworkMonitorIPTests {
    private func run(_ script: [NetworkSourceEvent], expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: NetworkMonitor.category
            )
        )
        await monitor.start()
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events
    }

    private static let connected = IPAddressReport(interfaces: [
        InterfaceAddresses(bsdName: "en0", friendlyName: "Wi-Fi", ipv4: ["192.168.1.42"])
    ])

    @Test("the addresses the machine already holds are announced once")
    func addressesAreAnnounced() async {
        let events = await run([.ipAddressSnapshot(Self.connected)], expecting: 1)
        #expect(events.count == 1)
        #expect(events.first?.name == "IPAddressChange")
        #expect(events.first?.title == "IP Addresses Updated")
        #expect(events.first?.body == "Wi-Fi — IPv4:\t192.168.1.42")
    }

    @Test("all the machine's addresses arrive as one message, not one per interface")
    func addressesAreCoalesced() async {
        // DHCP finishing hands out several addresses in the same breath; a banner each
        // would be one event told four times.
        let many = IPAddressReport(interfaces: [
            InterfaceAddresses(bsdName: "en0", friendlyName: "Wi-Fi", ipv4: ["192.168.1.42"], ipv6: ["2a02::5"]),
            InterfaceAddresses(bsdName: "en5", friendlyName: "Thunderbolt Bridge", ipv4: ["10.0.0.1"])
        ])
        let events = await run([.ipAddressSnapshot(many)], expecting: 1)
        #expect(events.count == 1)
        #expect(events.first?.body.split(separator: "\n").count == 3)
    }

    @Test("re-reading the same addresses says nothing")
    func unchangedAddressesAreSilent() async {
        let events = await run(
            [.ipAddressSnapshot(Self.connected), .ipAddressSnapshot(Self.connected)],
            expecting: 1
        )
        #expect(events.count == 1)
    }

    @Test("launching with no connection at all says nothing")
    func noAddressesAtLaunchIsSilent() async {
        // The startup poll reads before DHCP has finished; reporting "released" then would
        // announce a loss that never happened.
        let events = await run([.ipAddressSnapshot(IPAddressReport(interfaces: []))], expecting: 0)
        #expect(events.isEmpty)
    }

    @Test("losing every address is announced as a release, once")
    func releaseIsAnnouncedOnce() async {
        let events = await run([
            .ipAddressSnapshot(Self.connected),
            .ipAddressSnapshot(IPAddressReport(interfaces: [])),
            .ipAddressSnapshot(IPAddressReport(interfaces: []))
        ], expecting: 2)

        #expect(events.count == 2)
        #expect(events[1].body == "IP address released")
    }
}

@Suite("Network system-wide settings")
struct NetworkGlobalStateTests {
    private func run(_ script: [NetworkSourceEvent], expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: NetworkMonitor.category
            )
        )
        await monitor.start()
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the settings already in force at launch are not announced as changes")
    func firstReadingIsSilent() async {
        // Somebody chose these at some point in the past. Announcing the state they were
        // already in would be announcing a change that did not happen.
        let events = await run([.globalState(NetworkGlobalState(
            dnsServers: ["1.1.1.1"],
            locationName: "Automatic",
            serviceOrder: ["Wi-Fi", "Ethernet"]
        ))], expecting: 0)
        #expect(events.isEmpty)
    }

    @Test("changing the resolvers says which they were and which they are")
    func dnsChangeNamesBothSides() async {
        let events = await run([
            .globalState(NetworkGlobalState(dnsServers: ["192.168.1.1"])),
            .globalState(NetworkGlobalState(dnsServers: ["1.1.1.1", "1.0.0.1"]))
        ], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "DNSServersChanged")
        #expect(events.first?.title == "DNS Servers Changed")
        #expect(events.first?.body == "192.168.1.1 → 1.1.1.1, 1.0.0.1")
    }

    @Test("having no resolvers at all is said in words, not as an empty gap")
    func emptyResolverListReadsAsNone() async {
        let events = await run([
            .globalState(NetworkGlobalState(dnsServers: ["1.1.1.1"])),
            .globalState(NetworkGlobalState(dnsServers: []))
        ], expecting: 1)
        #expect(events.first?.body == "1.1.1.1 → none")
    }

    @Test("a proxy notice names which kinds are in force")
    func proxySummaryNamesTheKinds() async {
        let events = await run([
            .globalState(NetworkGlobalState()),
            .globalState(NetworkGlobalState(proxy: ProxyConfiguration(http: true, socks: true)))
        ], expecting: 1)

        #expect(events.first?.name == "ProxyConfigChanged")
        #expect(events.first?.body == "Active: HTTP, SOCKS")
    }

    @Test("switching every proxy off says so rather than saying nothing")
    func proxyOffIsStillNews() async {
        let events = await run([
            .globalState(NetworkGlobalState(proxy: ProxyConfiguration(http: true))),
            .globalState(NetworkGlobalState())
        ], expecting: 1)
        #expect(events.first?.body == "No proxy configured")
    }

    @Test("pointing the same proxy kind at a different server is a change")
    func movingProxyHostCounts() async {
        // The same boxes stay ticked, so comparing only the flags would miss it.
        let events = await run([
            .globalState(NetworkGlobalState(proxy: ProxyConfiguration(http: true, httpHost: "old.example"))),
            .globalState(NetworkGlobalState(proxy: ProxyConfiguration(http: true, httpHost: "new.example")))
        ], expecting: 1)
        #expect(events.first?.name == "ProxyConfigChanged")
    }

    @Test("reordering services is announced; adding or removing one is not")
    func onlyReorderCountsAsAReorder() async {
        let reordered = await run([
            .globalState(NetworkGlobalState(serviceOrder: ["Wi-Fi", "Ethernet"])),
            .globalState(NetworkGlobalState(serviceOrder: ["Ethernet", "Wi-Fi"]))
        ], expecting: 1)
        #expect(reordered.first?.name == "NetworkServiceOrderChanged")
        #expect(reordered.first?.body == "Ethernet → Wi-Fi")

        // A service appearing changes the array too, and that is different news than
        // "the order you try them in changed".
        let added = await run([
            .globalState(NetworkGlobalState(serviceOrder: ["Wi-Fi"])),
            .globalState(NetworkGlobalState(serviceOrder: ["Wi-Fi", "Thunderbolt Bridge"]))
        ], expecting: 0)
        #expect(added.isEmpty)
    }

    @Test("the network location is named on both sides of the change")
    func locationChangeNamesBothSides() async {
        let events = await run([
            .globalState(NetworkGlobalState(locationName: "Automatic")),
            .globalState(NetworkGlobalState(locationName: "Office"))
        ], expecting: 1)
        #expect(events.first?.name == "NetworkLocationChanged")
        #expect(events.first?.body == "Automatic → Office")
    }

    @Test("two settings moving at once produce two notices, not one merged one")
    func independentSettingsReportIndependently() async {
        let events = await run([
            .globalState(NetworkGlobalState(dnsServers: ["1.1.1.1"], locationName: "Home")),
            .globalState(NetworkGlobalState(dnsServers: ["8.8.8.8"], locationName: "Office"))
        ], expecting: 2)
        #expect(Set(events.map(\.name)) == ["DNSServersChanged", "NetworkLocationChanged"])
    }
}

@Suite("Wi-Fi radio power")
struct WiFiRadioPowerTests {
    private func run(_ script: [NetworkSourceEvent], expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: NetworkMonitor.category
            )
        )
        await monitor.start()
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the radio's state at launch is a baseline, not news")
    func firstReadingIsSilent() async {
        #expect(await run([.wifiRadioPower(isOn: true)], expecting: 0).isEmpty)
    }

    @Test("turning the radio off and on again uses the original's wording")
    func powerChangesUseTheExpectedTitles() async {
        let events = await run([
            .wifiRadioPower(isOn: true),
            .wifiRadioPower(isOn: false),
            .wifiRadioPower(isOn: true)
        ], expecting: 2)

        #expect(events.count == 2)
        #expect(events[0].name == "WifiRadioOff")
        #expect(events[0].title == "Wi-Fi Turned Off")
        #expect(events[1].name == "WifiRadioOn")
        #expect(events[1].title == "Wi-Fi Turned On")
    }

    @Test("the backstop poll reading the same answer says nothing")
    func repeatedReadingsAreSilent() async {
        // The poll behind the push notification runs every thirty seconds; it must be
        // free to report the same state forever.
        let events = await run([
            .wifiRadioPower(isOn: true),
            .wifiRadioPower(isOn: true),
            .wifiRadioPower(isOn: true)
        ], expecting: 0)
        #expect(events.isEmpty)
    }
}

@Suite("Wi-Fi signal levels")
struct WiFiSignalLevelTests {
    @Test("the thresholds are the ones macOS's own bars use")
    func thresholdsMatchTheSystem() {
        #expect(WiFiSignalLevel(rssi: -40) == .excellent)
        #expect(WiFiSignalLevel(rssi: -55) == .excellent)
        #expect(WiFiSignalLevel(rssi: -56) == .good)
        #expect(WiFiSignalLevel(rssi: -65) == .good)
        #expect(WiFiSignalLevel(rssi: -66) == .fair)
        #expect(WiFiSignalLevel(rssi: -73) == .fair)
        #expect(WiFiSignalLevel(rssi: -74) == .weak)
        #expect(WiFiSignalLevel(rssi: -80) == .weak)
        #expect(WiFiSignalLevel(rssi: -95) == .none)
    }

    @Test("a reading of zero is no answer, not a perfect signal")
    func zeroIsNotFullBars() {
        // The one value that must not be read literally: the interface uses it to say it
        // had nothing to report.
        #expect(WiFiSignalLevel(rssi: 0) == .none)
    }

    @Test("each level has its own artwork, and it is shipped")
    func everyLevelHasArtwork() {
        for level in WiFiSignalLevel.allCases {
            #expect(
                Bundle.module.url(forResource: level.iconName, withExtension: "png") != nil,
                "missing \(level.iconName)"
            )
        }
    }
}

@Suite("Wi-Fi signal watcher")
struct WiFiSignalWatcherTests {
    @Test("the first reading is a starting point, not news")
    func firstReadingIsSilent() {
        var watcher = WiFiSignalWatcher()
        #expect(watcher.consider(.good) == nil)
    }

    @Test("drifting within one level says nothing")
    func staysQuietWithinALevel() {
        // A stationary laptop's RSSI wanders several dBm on its own; notifying on the
        // number itself would notify forever.
        var watcher = WiFiSignalWatcher()
        _ = watcher.consider(WiFiSignalLevel(rssi: -60))
        #expect(watcher.consider(WiFiSignalLevel(rssi: -58)) == nil)
        #expect(watcher.consider(WiFiSignalLevel(rssi: -64)) == nil)
    }

    @Test("crossing a level says which way it went")
    func reportsDirection() {
        var watcher = WiFiSignalWatcher(cooldown: 0)
        _ = watcher.consider(.good)

        let worse = watcher.consider(.weak)
        #expect(worse?.isImproving == false)
        #expect(worse?.summary == "Signal ↓ degraded (1/4)")

        let better = watcher.consider(.excellent)
        #expect(better?.isImproving == true)
        #expect(better?.summary == "Signal ↑ improved (4/4)")
    }

    @Test("a signal sitting on a threshold does not notify every poll")
    func cooldownHoldsBackRepeats() {
        var watcher = WiFiSignalWatcher(cooldown: 10)
        let start = Date()
        _ = watcher.consider(.good, now: start)

        #expect(watcher.consider(.fair, now: start) != nil)
        #expect(watcher.consider(.good, now: start.addingTimeInterval(2)) == nil)
        #expect(watcher.consider(.fair, now: start.addingTimeInterval(5)) == nil)
    }

    @Test("news delayed by the cooldown is still delivered afterwards, not swallowed")
    func cooldownDelaysRatherThanDiscards() {
        // The baseline is deliberately not advanced during the cooldown. If it were, a
        // signal that drifted from good to none during a quiet spell would never be
        // reported at all.
        var watcher = WiFiSignalWatcher(cooldown: 10)
        let start = Date()
        _ = watcher.consider(.excellent, now: start)
        #expect(watcher.consider(.good, now: start) != nil)

        #expect(watcher.consider(.none, now: start.addingTimeInterval(3)) == nil)
        let afterwards = watcher.consider(.none, now: start.addingTimeInterval(11))
        #expect(afterwards?.level == WiFiSignalLevel.none)
        #expect(afterwards?.isImproving == false)
    }

    @Test("joining a network sets the starting point without announcing it")
    func baselineIsSilent() {
        var watcher = WiFiSignalWatcher(cooldown: 10)
        watcher.baseline(.excellent)
        #expect(watcher.consider(.excellent) == nil)
        // And the cooldown does not apply to the first real movement after joining.
        #expect(watcher.consider(.weak) != nil)
    }

    @Test("leaving a network forgets its level")
    func resetForgetsTheNetwork() {
        // Comparing the next network's signal against this one's level would report a
        // change that never happened.
        var watcher = WiFiSignalWatcher(cooldown: 0)
        _ = watcher.consider(.excellent)
        watcher.reset()
        #expect(watcher.consider(.weak) == nil)
    }
}

@Suite("VPN and interface classification")
struct NetworkInterfaceIdentityTests {
    @Test("the tunnel names macOS gives a VPN are recognised")
    func vpnPrefixesAreRecognised() {
        #expect(isVPNInterfaceName("utun4"))
        #expect(isVPNInterfaceName("ppp0"))
        #expect(isVPNInterfaceName("ipsec0"))
    }

    @Test("ordinary interfaces are not mistaken for a VPN")
    func ordinaryInterfacesAreNot() {
        for name in ["en0", "en1", "bridge100", "awdl0", "lo0"] {
            #expect(!isVPNInterfaceName(name), "\(name) read as a VPN")
        }
    }

    @Test("an interface torn out of the registry is still recognised as what it was")
    func cacheSurvivesTheInterfaceVanishing() {
        // The bug this prevents: unplugging a USB-Ethernet adapter removes it from the
        // registry before its link key changes, so a live lookup finds nothing, the
        // disconnect is dropped, and the stale state surfaces later as a phantom pair.
        var cache = InterfaceKindCache()
        _ = cache.reconcile(live: ["en5": .wired])

        let afterUnplug = cache.reconcile(live: [:])
        #expect(afterUnplug["en5"] == .wired)
    }

    @Test("the live answer wins, so reused names are classified afresh")
    func liveAnswerTakesPrecedence() {
        var cache = InterfaceKindCache()
        _ = cache.reconcile(live: ["en5": .wired])
        let now = cache.reconcile(live: ["en5": .wifi])
        #expect(now["en5"] == .wifi)
    }

    @Test("forgetting an interface lets much later hardware start from nothing")
    func forgettingClearsIt() {
        var cache = InterfaceKindCache()
        _ = cache.reconcile(live: ["en5": .wired])
        cache.forget("en5")
        #expect(cache.reconcile(live: [:])["en5"] == nil)
    }
}

@Suite("VPN routing in the link diff")
struct NetworkVPNRoutingTests {
    private func run(_ script: [NetworkSourceEvent], expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = NetworkMonitor(
            source: ScriptedNetworkSource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: NetworkMonitor.category
            )
        )
        await monitor.start()
        for _ in 0..<200 where await delivery.events.count < expecting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a tunnel coming up is a VPN notice, not a link notice")
    func tunnelReportsAsVPN() async {
        // Nobody plugged anything in, and "utun4 Link Up" says nothing a person can use.
        let events = await run([
            .linkSnapshot(["utun4": LinkState(isActive: false, kind: .other)]),
            .linkSnapshot(["utun4": LinkState(isActive: true, kind: .other)])
        ], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "VPNConnected")
        #expect(events.first?.title == "VPN Connected")
        #expect(events.first?.body == "Interface:\tutun4")
    }

    @Test("a tunnel already up at launch is announced, then its going away is too")
    func tunnelGoingDownReportsAsVPN() async {
        // The first snapshot is part of the launch inventory, and a VPN already carrying
        // your traffic is worth being told about — so this is two notices, not one.
        let events = await run([
            .linkSnapshot(["ipsec0": LinkState(isActive: true, kind: .other)]),
            .linkSnapshot(["ipsec0": LinkState(isActive: false, kind: .other)])
        ], expecting: 2)

        #expect(events.map(\.name) == ["VPNConnected", "VPNDisconnected"])
    }

    @Test("a real interface still reports as a link, alongside a tunnel")
    func realInterfacesAreUnaffected() async {
        let events = await run([
            .linkSnapshot([
                "en0": LinkState(isActive: false, kind: .wifi),
                "utun4": LinkState(isActive: false, kind: .other)
            ]),
            .linkSnapshot([
                "en0": LinkState(isActive: true, kind: .wifi),
                "utun4": LinkState(isActive: true, kind: .other)
            ])
        ], expecting: 2)

        #expect(Set(events.map(\.name)) == ["NetworkLinkUp", "VPNConnected"])
    }
}
