import Foundation
import SentryContract
import SignalCore

/// Says whether the Internet is generally reachable, when Wi-Fi joins or leaves a network,
/// when a link (wired or otherwise) comes up or down, and which interface carries default
/// traffic.
public actor NetworkMonitor: Monitor {
    public static let category = NetworkEvent.category

    /// Said outright rather than taken from the first event, which is a Wi-Fi one.
    ///
    /// This module covers Wi-Fi, wired links, VPN, DNS and the rest; letting the list icon
    /// fall out of whichever event happens to be declared first made the whole of
    /// networking look like Wi-Fi the moment the events were reordered into groups.
    public static let icon: NotificationIcon = .asset("Network-Generic-On", in: .module)

    public static let events: [MonitorEventDescription] = [
        .init(name: NetworkEvent.ipAddressChanged.rawValue, title: "IP addresses updated", icon: .asset("Network-Generic-On", in: .module), group: Group.addresses),
        .init(name: NetworkEvent.dhcpRenewed.rawValue, title: "DHCP lease renewed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.addresses),
        .init(name: NetworkEvent.primaryInterfaceChanged.rawValue, title: "Primary interface changed", enabledByDefault: false, icon: .asset("Network-PrimaryInterface-On", in: .module), group: Group.addresses),
        .init(name: NetworkEvent.linkUp.rawValue, title: "Network link up", icon: .asset("Network-Ethernet-On", in: .module), group: Group.wired),
        .init(name: NetworkEvent.linkDown.rawValue, title: "Network link down", icon: .asset("Network-Ethernet-Off", in: .module), group: Group.wired),
        .init(name: NetworkEvent.linkSpeedChanged.rawValue, title: "Link speed or duplex changed", enabledByDefault: false, icon: .asset("Network-Ethernet-Speed", in: .module), group: Group.wired),
        .init(name: NetworkEvent.adapterAttaching.rawValue, title: "Network adapter plugged in", icon: .asset("Network-Interface-On", in: .module), group: Group.wired),
        .init(name: NetworkEvent.adapterDetaching.rawValue, title: "Network adapter unplugged", icon: .asset("Network-Interface-Off", in: .module), group: Group.wired),
        .init(name: NetworkEvent.bondMemberStatusChanged.rawValue, title: "Bonded link member changed", enabledByDefault: false, icon: .asset("Network-Ethernet-On", in: .module), group: Group.wired),
        .init(name: NetworkEvent.wifiConnected.rawValue, title: "Joined a Wi-Fi network", icon: .asset("Network-Wifi-4", in: .module), group: Group.wifi),
        .init(name: NetworkEvent.wifiDisconnected.rawValue, title: "Left a Wi-Fi network", icon: .asset("Network-Wifi-Off", in: .module), group: Group.wifi),
        .init(name: NetworkEvent.wifiRadioOn.rawValue, title: "Wi-Fi radio turned on", icon: .asset("Network-Wifi-Radio-On", in: .module), group: Group.wifi),
        .init(name: NetworkEvent.wifiRadioOff.rawValue, title: "Wi-Fi radio turned off", icon: .asset("Network-Wifi-Radio-Off", in: .module), group: Group.wifi),
        .init(name: NetworkEvent.wifiHostAPModeChanged.rawValue, title: "Internet Sharing started/stopped", enabledByDefault: false, icon: .asset("Network-Wifi-Radio-On", in: .module), group: Group.wifi),
        .init(name: NetworkEvent.wifiSignalExcellent.rawValue, title: WiFiSignalLevel.excellent.settingsTitle, icon: .asset(WiFiSignalLevel.excellent.iconName, in: .module), group: Group.signal),
        .init(name: NetworkEvent.wifiSignalGood.rawValue, title: WiFiSignalLevel.good.settingsTitle, icon: .asset(WiFiSignalLevel.good.iconName, in: .module), group: Group.signal),
        .init(name: NetworkEvent.wifiSignalFair.rawValue, title: WiFiSignalLevel.fair.settingsTitle, icon: .asset(WiFiSignalLevel.fair.iconName, in: .module), group: Group.signal),
        .init(name: NetworkEvent.wifiSignalWeak.rawValue, title: WiFiSignalLevel.weak.settingsTitle, icon: .asset(WiFiSignalLevel.weak.iconName, in: .module), group: Group.signal),
        .init(name: NetworkEvent.wifiSignalNone.rawValue, title: WiFiSignalLevel.none.settingsTitle, icon: .asset(WiFiSignalLevel.none.iconName, in: .module), group: Group.signal),
        .init(name: NetworkEvent.vpnConnected.rawValue, title: "VPN connected", icon: .asset("Network-VPN-On", in: .module), group: Group.vpn),
        .init(name: NetworkEvent.vpnDisconnected.rawValue, title: "VPN disconnected", icon: .asset("Network-VPN-Off", in: .module), group: Group.vpn),
        .init(name: NetworkEvent.reachabilityChanged.rawValue, title: "Internet reachability changed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.internet),
        .init(name: NetworkEvent.pathStatusChanged.rawValue, title: "Network path status changed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.internet),
        .init(name: NetworkEvent.pathExpensiveChanged.rawValue, title: "Connection became metered/unmetered", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.internet),
        .init(name: NetworkEvent.pathConstrainedChanged.rawValue, title: "Low Data Mode turned on/off", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.internet),
        .init(name: NetworkEvent.pathQualityChanged.rawValue, title: "Network path became usable/blocked", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.internet),
        .init(name: NetworkEvent.dnsServersChanged.rawValue, title: "DNS servers changed", enabledByDefault: false, icon: .asset("Network-DNS-On", in: .module), group: Group.system),
        .init(name: NetworkEvent.proxyConfigChanged.rawValue, title: "Proxy configuration changed", enabledByDefault: false, icon: .asset("Network-Proxy-On", in: .module), group: Group.system),
        .init(name: NetworkEvent.locationChanged.rawValue, title: "Network location changed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.system),
        .init(name: NetworkEvent.serviceOrderChanged.rawValue, title: "Service order changed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.system),
        .init(name: NetworkEvent.hostnameChanged.rawValue, title: "Computer name changed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module), group: Group.system),
        .init(name: NetworkEvent.promiscuousModeChanged.rawValue, title: "Interface started capturing packets", icon: .asset("Network-Interface-On", in: .module), group: Group.system)
    ]

    /// The headings its rows sit under. Named once so an event and the field that goes
    /// with it cannot drift into two differently-spelled groups that render as two.
    /// The original's own six, in the original's order, so somebody moving between the
    /// two applications finds the same tabs in the same places.
    enum Group {
        static let addresses = "IP"
        static let wired = "Ethernet"
        static let wifi = "Wi-Fi"
        static let signal = "Wi-Fi"
        static let vpn = "VPN"
        static let internet = "Other"
        static let system = "Other"
    }

    public static let fields: [MonitorFieldDescription] = NetworkField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault, group: $0.group)
    }

    private let source: any NetworkSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    private var knownLinks: [String: LinkState] = [:]
    private var hasLinkBaseline = false
    private var lastKnownPrimaryInterface: String?
    private var hasPrimaryBaseline = false
    private var lastKnownReachable: Bool?
    private var knownLeaseStarts: [String: Date] = [:]
    private var hasLeaseBaseline = false
    private var lastKnownComputerName: String?
    private var lastKnownGlobalState: NetworkGlobalState?
    private var lastKnownWiFiRadioOn: Bool?
    private var signalWatcher: WiFiSignalWatcher
    /// The network and the access point last announced as joined.
    ///
    /// Both halves matter. CoreWLAN reports its SSID-changed event more than once for a
    /// single join, so without the pair a normal connection announces itself twice; and
    /// comparing the name alone would hide roaming, which is a real move between two
    /// access points and worth saying.
    private var announcedNetwork: (ssid: String, bssid: String?)?
    /// What the IP message last actually said. Compared as text rather than as addresses,
    /// because that is what decides whether re-showing it would tell anyone anything new:
    /// an address changing behind a switched-off IPv6 line changes nothing visible.
    private var lastShownIPBody: String?
    private var lastIPReport: IPAddressReport?
    private var knownPromiscuous: Set<String>?
    private var knownBondMembers: [String: BondMemberStatus]?
    private var lastKnownInterfaceMode: String?
    private var lastKnownPath: NetworkPathDetail?
    private var hadIPAddresses = false

    /// - Parameter signalCooldown: how long after reporting a signal level before another
    ///   is reported. Ten seconds, the original's figure, clamped to its range — zero is a
    ///   real choice there and means "report every level change", so only the upper bound
    ///   and negatives are corrected.
    public init(source: any NetworkSource, context: MonitorContext, signalCooldown: TimeInterval = 10) {
        self.source = source
        self.context = context
        self.signalWatcher = WiFiSignalWatcher(cooldown: min(60, max(0, signalCooldown)))
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

    private func handle(_ event: NetworkSourceEvent) async {
        switch event {
        case .reachability(let isReachable, let detail):
            await handleReachability(isReachable, detail: detail)
        case .wifiConnected(let ssid, let detail):
            // Repeated reports of the same join are dropped here rather than left to the
            // duplicate filter: that works on a time window, and CoreWLAN's repeats are
            // not reliably close together.
            if let announced = announcedNetwork,
               announced.ssid == ssid,
               announced.bssid == detail?.bssid {
                return
            }
            announcedNetwork = (ssid, detail?.bssid)

            // Baselined from the reading that came with joining, so the first real
            // movement is caught one poll sooner than it would be otherwise.
            // Only from a reading that exists. A zero is the interface declining to
            // answer, and baselining at "no signal" would make the very next poll look
            // like the signal had leapt from nothing to whatever it always was — a
            // notification about joining, dressed as a change. The original guards this
            // the same way, by leaving its baseline unset rather than storing zero bars.
            if let rssi = detail?.rssi, rssi != 0 {
                signalWatcher.baseline(WiFiSignalLevel(rssi: rssi))
            } else {
                signalWatcher.reset()
            }
            await context.notify(
                NetworkEvent.wifiConnected.rawValue, subject: ssid,
                title: "AirPort Connected",
                body: await context.body([
                    .always("Joined network."),
                    .field(NetworkField.ssid.rawValue, "SSID", ssid),
                    .field(NetworkField.bssid.rawValue, "BSSID", detail?.bssid),
                    .field(NetworkField.band.rawValue, "Band", detail?.band),
                    .field(NetworkField.channel.rawValue, "Channel", detail?.channel),
                    .field(NetworkField.generation.rawValue, "Wi-Fi Generation", detail?.generation),
                    .field(NetworkField.security.rawValue, "Security", detail?.security),
                    .field(NetworkField.signal.rawValue, "Signal", detail?.rssiNote),
                    .field(NetworkField.quality.rawValue, "Quality", detail?.qualityNote),
                    .field(NetworkField.transmitRate.rawValue, "Link Rate", detail?.rateNote),
                    .field(NetworkField.countryCode.rawValue, "Regulatory country/region", detail?.countryCode),
                    .field(NetworkField.wifiInterface.rawValue, "Interface", detail?.interfaceName),
                    .field(NetworkField.transmitPower.rawValue, "Transmit power", detail?.transmitPowerNote),
                    .field(NetworkField.wifiHardwareAddress.rawValue, "Wi-Fi hardware address", detail?.hardwareAddress),
                    .field(NetworkField.interfaceMode.rawValue, "Interface mode", detail?.interfaceMode)
                ]),
                // The bars for the signal it actually joined with, the way the original
                // does it — a fixed four-bar icon on every connection is a strength
                // indicator that indicates nothing.
                icon: .asset(WiFiSignalLevel(rssi: detail?.rssi ?? 0).iconName, in: .module)
            )
        case .wifiDisconnected(let ssid):
            // Forgotten rather than kept: comparing the next network's signal against
            // this one's level would report a change that never happened.
            signalWatcher.reset()
            announcedNetwork = nil
            await context.notify(
                NetworkEvent.wifiDisconnected.rawValue, subject: "WiFi",
                title: "AirPort Disconnected",
                body: ssid.map { "No longer connected to \($0)." } ?? "",
                icon: .asset("Network-Wifi-Off", in: .module)
            )
        case .linkSnapshot(let links):
            await handleLinkSnapshot(links)
        case .primaryInterfaceSnapshot(let name):
            await handlePrimaryInterface(name)
        case .dhcpLeaseSnapshot(let leases):
            await handleDHCPLeaseSnapshot(leases)
        case .computerNameSnapshot(let name):
            await handleComputerName(name)
        case .ipAddressSnapshot(let report):
            await handleIPAddresses(report)
        case .globalState(let state):
            await handleGlobalState(state)
        case .wifiRadioPower(let isOn):
            await handleWiFiRadioPower(isOn)
        case .promiscuousSnapshot(let interfaces):
            await handlePromiscuous(interfaces)
        case .bondMemberSnapshot(let members):
            await handleBondMembers(members)
        case .wifiInterfaceMode(let mode):
            await handleInterfaceMode(mode)
        case .adapterAttaching(let interfaceName):
            await context.notify(
                NetworkEvent.adapterAttaching.rawValue, subject: interfaceName,
                title: "Network Adapter Detected", body: interfaceName,
                icon: .asset("Network-Interface-On", in: .module)
            )
        case .adapterDetaching(let interfaceName):
            await context.notify(
                NetworkEvent.adapterDetaching.rawValue, subject: interfaceName,
                title: "Network Adapter Being Removed", body: interfaceName,
                icon: .asset("Network-Interface-Off", in: .module)
            )
        case .wifiSignal(let rssi, let ssid):
            await handleWiFiSignal(rssi: rssi, ssid: ssid)
        case .wifiSignalUnavailable:
            // Nothing is said. The level is simply forgotten, so the next network to be
            // joined is baselined afresh rather than compared with this one's.
            signalWatcher.reset()
        }
    }

    private func handleReachability(_ isReachable: Bool, detail: NetworkPathDetail?) async {
        if let detail { await handlePathFacts(detail) }

        let previous = lastKnownReachable
        lastKnownReachable = isReachable
        guard let previous, previous != isReachable else { return } // first sighting — baseline only

        await context.notify(
            NetworkEvent.reachabilityChanged.rawValue,
            subject: "Internet",
            title: isReachable ? "Internet Reachable" : "Internet Unreachable",
            body: await context.body([
                .always(isReachable ? "General Internet connectivity was restored" : "General Internet connectivity was lost"),
                // Only worth saying about a path that works. Which connection carries the
                // traffic and what it costs are answers about a live path; on the way
                // down there is no path left to describe.
                .field(NetworkField.pathInterface.rawValue, "Over", isReachable ? detail?.interfaceType : nil),
                .field(NetworkField.expensive.rawValue, "Metered", isReachable ? detail?.expensiveNote : nil),
                .field(NetworkField.constrained.rawValue, "Constrained", isReachable ? detail?.constrainedNote : nil),
                .field(NetworkField.ipProtocols.rawValue, "Protocols", isReachable ? detail?.protocolsNote : nil),
                .field(NetworkField.dns.rawValue, "Warning", isReachable ? detail?.dnsNote : nil)
            ]),
            icon: .asset(isReachable ? "Network-Generic-On" : "Network-Generic-Off", in: .module)
        )
    }

    private func handleLinkSnapshot(_ links: [String: LinkState]) async {
        if !hasLinkBaseline {
            hasLinkBaseline = true
            // Falls through with nothing "known" when the startup sweep is meant to
            // speak: every item then reads as newly arrived, which is exactly what
            // "here is what is plugged in" means.
            guard context.announcesWhatIsAlreadyThere else {
                knownLinks = links
                return
            }
        }

        // Off by default, and the original's default too. The Wi-Fi interface's carrier
        // coming up is the same event as joining a network, which "AirPort Connected"
        // already reports in full — so reporting it again as "Wi-Fi Link Up / Interface:
        // en0" is the same news twice, and the second telling is the one that says
        // nothing. AWDL (AirDrop, Handoff, Continuity) is worse: it flaps constantly in
        // the background and nobody plugged anything in.
        let reportsWiFiLinks = await context.isFieldEnabled(NetworkField.allLinks.rawValue)

        for (interfaceName, state) in links {
            let was = knownLinks[interfaceName]

            guard state.kind != .wifi || reportsWiFiLinks else {
                // Still remembered, so switching the option on later compares against
                // what is actually there rather than announcing every link afresh.
                continue
            }

            // A VPN tunnel coming up is its own kind of news, not a link event: nobody
            // plugged anything in, and "utun4 Link Up" says nothing a person can use.
            if isVPNInterfaceName(interfaceName) {
                if state.isActive, was?.isActive != true {
                    await context.notify(
                        NetworkEvent.vpnConnected.rawValue, subject: interfaceName,
                        title: "VPN Connected", body: "Interface:\t\(interfaceName)",
                        icon: .asset("Network-VPN-On", in: .module)
                    )
                } else if !state.isActive, was?.isActive == true {
                    await context.notify(
                        NetworkEvent.vpnDisconnected.rawValue, subject: interfaceName,
                        title: "VPN Disconnected", body: "Interface:\t\(interfaceName)",
                        icon: .asset("Network-VPN-Off", in: .module)
                    )
                }
                continue
            }

            if state.isActive, was?.isActive != true {
                await context.notify(
                    NetworkEvent.linkUp.rawValue, subject: interfaceName,
                    title: "\(state.kind.label) Link Up",
                    body: await context.body([
                        .field(NetworkField.linkInterface.rawValue, "Interface", interfaceName),
                        .field(NetworkField.linkSpeed.rawValue, "Speed", state.media?.speed),
                        .field(NetworkField.linkMode.rawValue, "Mode", state.media?.mode),
                        .field(NetworkField.linkNegotiated.rawValue, "Negotiated", state.media?.negotiatedNote)
                    ]),
                    icon: .asset(state.kind.icon(active: true), in: .module)
                )
            } else if state.isActive, was?.isActive == true,
                      let now = state.media?.speed, let before = was?.media?.speed, now != before {
                // A cable degrading — a bad connector, a switch port dropping to 100 Mb/s
                // — never takes the link down, so nothing else would ever mention it.
                await context.notify(
                    NetworkEvent.linkSpeedChanged.rawValue, subject: interfaceName,
                    title: "Ethernet Speed Changed",
                    body: "\(interfaceName):\t\(before) → \(now)",
                    icon: .asset("Network-Ethernet-Speed", in: .module)
                )
            } else if !state.isActive, was?.isActive == true {
                await context.notify(
                    NetworkEvent.linkDown.rawValue, subject: interfaceName,
                    title: "\(state.kind.label) Link Down", body: "Interface:\t\(interfaceName)",
                    icon: .asset(state.kind.icon(active: false), in: .module)
                )
            }
        }
        knownLinks = links
    }

    /// Always a silent baseline, regardless of `announcesWhatIsAlreadyThere`: an interface
    /// already holding a lease when the application launches is DHCP having finished
    /// normally, at some point before anyone was watching — not a renewal of anything, and
    /// not news the way an already-connected device is.
    private func handleDHCPLeaseSnapshot(_ leases: [String: Date]) async {
        for (interfaceName, start) in leases {
            guard let previousStart = knownLeaseStarts[interfaceName], previousStart != start else { continue }
            await context.notify(
                NetworkEvent.dhcpRenewed.rawValue, subject: interfaceName,
                title: "DHCP Lease Renewed", body: "Interface:\t\(interfaceName)",
                icon: .asset("Network-Generic-On", in: .module)
            )
        }
        knownLeaseStarts = leases
    }

    /// Also always a silent baseline: the name the machine already had is not a change,
    /// however this application first learns of it.
    private func handleComputerName(_ name: String?) async {
        guard let name else { return }
        defer { lastKnownComputerName = name }
        guard let previous = lastKnownComputerName, previous != name else { return }

        await context.notify(
            NetworkEvent.hostnameChanged.rawValue, subject: "ComputerName",
            title: "Computer Name Changed", body: "\(previous) → \(name)",
            icon: .asset("Network-Generic-On", in: .module)
        )
    }

    /// One message for the whole machine, not one per interface: addresses arrive
    /// together — DHCP finishing hands out an IPv4 and one or more IPv6 addresses in the
    /// same breath — and a banner each would be one event told four times.
    private func handleIPAddresses(_ report: IPAddressReport) async {
        var detail = IPAddressReport.Detail()
        detail.ipv4 = await context.isFieldEnabled(NetworkField.ipv4.rawValue)
        detail.ipv6 = await context.isFieldEnabled(NetworkField.ipv6.rawValue)
        detail.nonRoutableTag = await context.isFieldEnabled(NetworkField.nonRoutableTag.rawValue)
        detail.friendlyNames = await context.isFieldEnabled(NetworkField.friendlyNames.rawValue)
        detail.gateway = await context.isFieldEnabled(NetworkField.gateway.rawValue)
        detail.configurationMethod = await context.isFieldEnabled(NetworkField.ipConfigMethod.rawValue)
        detail.mtu = await context.isFieldEnabled(NetworkField.mtu.rawValue)
        detail.macAddress = await context.isFieldEnabled(NetworkField.macAddress.rawValue)
        detail.searchDomains = await context.isFieldEnabled(NetworkField.dnsSearchDomains.rawValue)
        detail.previousAddress = await context.isFieldEnabled(NetworkField.previousAddress.rawValue)
        detail.dhcpLease = await context.isFieldEnabled(NetworkField.dhcpLease.rawValue)
        detail.baudrate = await context.isFieldEnabled(NetworkField.baudrate.rawValue)
        detail.decodedType = await context.isFieldEnabled(NetworkField.decodedType.rawValue)

        let body = report.body(detail: detail, previous: lastIPReport)
        defer { lastIPReport = report }
        let hasAddresses = report.hasAddresses

        // A launch with no connection at all, or a release already reported. Either way
        // there is nothing to say and nothing has changed since the last time it was said.
        if !hasAddresses, !hadIPAddresses { return }
        // Addresses are up but the visible text is identical — re-showing it would be the
        // same message twice.
        if hasAddresses, body == lastShownIPBody { return }

        hadIPAddresses = hasAddresses
        lastShownIPBody = hasAddresses ? body : nil

        await context.notify(
            NetworkEvent.ipAddressChanged.rawValue,
            subject: "IPAddresses",
            title: "IP Addresses Updated",
            body: hasAddresses ? (body.isEmpty ? "IP address updated" : body) : "IP address released",
            // A machine holding only self-assigned addresses has an address and no
            // connection; the icon should not read as success.
            icon: .asset(report.hasRoutableAddress ? "Network-Generic-On" : "Network-Generic-Off", in: .module)
        )
    }

    /// Reports each system-wide setting that actually moved.
    ///
    /// Always a silent baseline, whatever the startup sweep is set to: these are settings
    /// somebody chose at some point in the past, not devices that just showed up, and
    /// announcing the state they were already in would be announcing a change that did
    /// not happen.
    private func handleGlobalState(_ state: NetworkGlobalState) async {
        defer { lastKnownGlobalState = state }
        guard let previous = lastKnownGlobalState else { return }

        if previous.dnsServers != state.dnsServers {
            await context.notify(
                NetworkEvent.dnsServersChanged.rawValue, subject: "DNS",
                title: "DNS Servers Changed",
                body: "\(NetworkGlobalState.describe(previous.dnsServers)) → \(NetworkGlobalState.describe(state.dnsServers))",
                icon: .asset("Network-DNS-On", in: .module)
            )
        }

        if previous.proxy != state.proxy {
            await context.notify(
                NetworkEvent.proxyConfigChanged.rawValue, subject: "Proxy",
                title: "Proxy Configuration Changed",
                body: state.proxy.summary,
                icon: .asset("Network-Proxy-On", in: .module)
            )
        }

        if let was = previous.locationName, let now = state.locationName, was != now {
            await context.notify(
                NetworkEvent.locationChanged.rawValue, subject: "Location",
                title: "Network Location Changed",
                body: "\(was) → \(now)",
                icon: .asset("Network-Generic-On", in: .module)
            )
        }

        // Only a reorder counts. A service being added or removed changes the array too,
        // and that is a different piece of news than "the order you try them in changed".
        if previous.serviceOrder != state.serviceOrder,
           Set(previous.serviceOrder) == Set(state.serviceOrder),
           !state.serviceOrder.isEmpty {
            await context.notify(
                NetworkEvent.serviceOrderChanged.rawValue, subject: "ServiceOrder",
                title: "Network Service Order Changed",
                body: NetworkGlobalState.describe(order: state.serviceOrder),
                icon: .asset("Network-Generic-On", in: .module)
            )
        }
    }

    /// The radio's own power, which is a different fact from being on a network: the radio
    /// can be on with nothing joined, and turning it off is what explains every other
    /// network notification that follows.
    /// Reports the signal moving between levels, and nothing else.
    ///
    /// The deciding lives in `WiFiSignalWatcher`, which is where the reasoning about
    /// thresholds and the cooldown is written down and tested.
    private func handleWiFiSignal(rssi: Int, ssid: String?) async {
        guard let change = signalWatcher.consider(WiFiSignalLevel(rssi: rssi)) else { return }

        await context.notify(
            // The event is the level it landed on, so each bar can be switched on or off
            // by itself: "tell me when it drops to one bar and leave me alone otherwise"
            // is the thing people actually want, and one switch cannot express it.
            change.level.event.rawValue,
            // Per network, not one shared subject: moving between two networks whose
            // signal both wander should not read as one flapping thing.
            subject: ssid ?? "WiFiSignal",
            title: "Wi-Fi Signal Changed",
            body: [ssid, change.summary].compactMap { $0 }.joined(separator: "\n"),
            icon: .asset(change.level.iconName, in: .module)
        )
    }

    /// Says when an interface starts capturing every packet on its network.
    ///
    /// Only ever reported on the way in. Something switching an interface into promiscuous
    /// mode is worth knowing about; it switching back out is housekeeping, and pairing the
    /// two would make the notification a running commentary on whatever tool is running.
    private func handlePromiscuous(_ interfaces: Set<String>) async {
        defer { knownPromiscuous = interfaces }
        guard let previous = knownPromiscuous else { return }

        for interfaceName in interfaces.subtracting(previous).sorted() {
            await context.notify(
                NetworkEvent.promiscuousModeChanged.rawValue, subject: interfaceName,
                title: "Promiscuous Mode Enabled", body: interfaceName,
                icon: .asset("Network-Interface-On", in: .module)
            )
        }
    }

    /// Reports a bond member whose standing changed.
    ///
    /// Reported in both directions, unlike promiscuous mode: a member recovering is the
    /// news that the redundancy is back, which matters as much as losing it.
    private func handleBondMembers(_ members: [String: BondMemberStatus]) async {
        defer { knownBondMembers = members }
        guard let previous = knownBondMembers else { return }

        for (interfaceName, status) in members.sorted(by: { $0.key < $1.key })
        where previous[interfaceName] != nil && previous[interfaceName] != status {
            await context.notify(
                NetworkEvent.bondMemberStatusChanged.rawValue, subject: interfaceName,
                title: "Link Aggregation Member Status Changed",
                body: "\(interfaceName): \(status.label)",
                icon: .asset("Network-Interface-On", in: .module)
            )
        }
    }

    /// The Mac's Wi-Fi interface changing what it is doing — client, ad-hoc, or acting as
    /// an access point for Internet Sharing.
    private func handleInterfaceMode(_ mode: String?) async {
        guard let mode else { return }
        defer { lastKnownInterfaceMode = mode }
        guard let previous = lastKnownInterfaceMode, previous != mode else { return }

        await context.notify(
            NetworkEvent.wifiHostAPModeChanged.rawValue, subject: "WiFiMode",
            title: "Wi-Fi Interface Mode Changed",
            body: "\(previous) → \(mode)",
            icon: .asset("Network-Wifi-Radio-On", in: .module)
        )
    }

    /// The path facts moving on their own, without connectivity itself changing.
    ///
    /// Separate from `handleReachability`, which describes the path at the moment
    /// connectivity moved. A hotspot becoming metered while the Internet stays up is not
    /// a reachability change, and these are the notifications for exactly that.
    private func handlePathFacts(_ detail: NetworkPathDetail) async {
        defer { lastKnownPath = detail }
        guard let previous = lastKnownPath else { return }

        if previous.isExpensive != detail.isExpensive {
            await context.notify(
                NetworkEvent.pathExpensiveChanged.rawValue, subject: "PathExpensive",
                title: detail.isExpensive ? "Network Path Is Now Costly" : "Network Path No Longer Costly",
                body: "e.g. an iPhone Personal Hotspot or metered connection",
                icon: .asset("Network-Generic-On", in: .module)
            )
        }
        if previous.isConstrained != detail.isConstrained {
            await context.notify(
                NetworkEvent.pathConstrainedChanged.rawValue, subject: "PathConstrained",
                title: detail.isConstrained ? "Network Path Is Now Constrained" : "Network Path No Longer Constrained",
                body: "Low Data Mode is active for this path",
                icon: .asset("Network-Generic-On", in: .module)
            )
        }
        if previous.interfaceType != detail.interfaceType,
           let was = previous.interfaceType, let now = detail.interfaceType {
            await context.notify(
                NetworkEvent.pathStatusChanged.rawValue, subject: "PathStatus",
                title: "Network Path Status Changed",
                body: "\(was) → \(now)",
                icon: .asset("Network-Generic-On", in: .module)
            )
        }
        if previous.linkQuality != detail.linkQuality,
           let was = previous.linkQuality, let now = detail.linkQuality {
            await context.notify(
                NetworkEvent.pathQualityChanged.rawValue, subject: "PathQuality",
                title: "Network Link Quality Changed",
                body: "\(was) → \(now)",
                icon: .asset("Network-Generic-On", in: .module)
            )
        }
    }

    private func handleWiFiRadioPower(_ isOn: Bool) async {
        defer { lastKnownWiFiRadioOn = isOn }
        guard let previous = lastKnownWiFiRadioOn, previous != isOn else { return }

        await context.notify(
            (isOn ? NetworkEvent.wifiRadioOn : NetworkEvent.wifiRadioOff).rawValue,
            subject: "WiFiRadio",
            title: isOn ? "Wi-Fi Turned On" : "Wi-Fi Turned Off",
            body: "",
            icon: .asset(isOn ? "Network-Wifi-Radio-On" : "Network-Wifi-Radio-Off", in: .module)
        )
    }

    private func handlePrimaryInterface(_ name: String?) async {
        guard let name else { return }

        guard hasPrimaryBaseline else {
            hasPrimaryBaseline = true
            lastKnownPrimaryInterface = name
            return
        }

        let previous = lastKnownPrimaryInterface
        lastKnownPrimaryInterface = name
        guard let previous, previous != name else { return }

        await context.notify(
            NetworkEvent.primaryInterfaceChanged.rawValue,
            subject: "PrimaryInterface",
            title: "Primary Network Interface Changed",
            body: "\(previous) → \(name)",
            icon: .asset("Network-PrimaryInterface-On", in: .module)
        )
    }
}
