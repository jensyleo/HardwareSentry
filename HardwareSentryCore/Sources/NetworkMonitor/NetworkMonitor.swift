import Foundation
import SentryContract
import SignalCore

/// Says whether the Internet is generally reachable, when Wi-Fi joins or leaves a network,
/// when a link (wired or otherwise) comes up or down, and which interface carries default
/// traffic.
public actor NetworkMonitor: Monitor {
    public static let category = NetworkEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: NetworkEvent.reachabilityChanged.rawValue, title: "Internet reachability changed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module)),
        .init(name: NetworkEvent.wifiConnected.rawValue, title: "Joined a Wi-Fi network", icon: .asset("Network-Wifi-4", in: .module)),
        .init(name: NetworkEvent.wifiDisconnected.rawValue, title: "Left a Wi-Fi network", icon: .asset("Network-Wifi-Off", in: .module)),
        .init(name: NetworkEvent.linkUp.rawValue, title: "Network link up", icon: .asset("Network-Ethernet-On", in: .module)),
        .init(name: NetworkEvent.linkDown.rawValue, title: "Network link down", icon: .asset("Network-Ethernet-Off", in: .module)),
        .init(name: NetworkEvent.primaryInterfaceChanged.rawValue, title: "Primary interface changed", enabledByDefault: false, icon: .asset("Network-PrimaryInterface-On", in: .module)),
        .init(name: NetworkEvent.dhcpRenewed.rawValue, title: "DHCP lease renewed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module)),
        .init(name: NetworkEvent.hostnameChanged.rawValue, title: "Computer name changed", enabledByDefault: false, icon: .asset("Network-Generic-On", in: .module)),
        .init(name: NetworkEvent.ipAddressChanged.rawValue, title: "IP addresses updated", icon: .asset("Network-Generic-On", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = NetworkField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
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
    /// What the IP message last actually said. Compared as text rather than as addresses,
    /// because that is what decides whether re-showing it would tell anyone anything new:
    /// an address changing behind a switched-off IPv6 line changes nothing visible.
    private var lastShownIPBody: String?
    private var hadIPAddresses = false

    public init(source: any NetworkSource, context: MonitorContext) {
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

    private func handle(_ event: NetworkSourceEvent) async {
        switch event {
        case .reachability(let isReachable, let detail):
            await handleReachability(isReachable, detail: detail)
        case .wifiConnected(let ssid, let detail):
            await context.notify(
                NetworkEvent.wifiConnected.rawValue, subject: ssid,
                title: "AirPort Connected",
                body: await context.body([
                    .always("Joined network.\nSSID:\t\(ssid)"),
                    .field(NetworkField.bssid.rawValue, "BSSID", detail?.bssid),
                    .field(NetworkField.channel.rawValue, "Channel", detail?.channel),
                    .field(NetworkField.generation.rawValue, "Standard", detail?.generation),
                    .field(NetworkField.security.rawValue, "Security", detail?.security),
                    .field(NetworkField.signal.rawValue, "Signal", detail?.rssiNote),
                    .field(NetworkField.quality.rawValue, "Quality", detail?.qualityNote),
                    .field(NetworkField.transmitRate.rawValue, "Rate", detail?.rateNote),
                    .field(NetworkField.countryCode.rawValue, "Country", detail?.countryCode),
                    .field(NetworkField.wifiInterface.rawValue, "Interface", detail?.interfaceName)
                ]),
                icon: .asset("Network-Wifi-4", in: .module)
            )
        case .wifiDisconnected:
            await context.notify(NetworkEvent.wifiDisconnected.rawValue, subject: "WiFi", title: "AirPort Disconnected", body: "", icon: .asset("Network-Wifi-Off", in: .module))
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
        }
    }

    private func handleReachability(_ isReachable: Bool, detail: NetworkPathDetail?) async {
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

        for (interfaceName, state) in links {
            let was = knownLinks[interfaceName]
            if state.isActive, was?.isActive != true {
                await context.notify(
                    NetworkEvent.linkUp.rawValue, subject: interfaceName,
                    title: "\(state.kind.label) Link Up", body: "Interface:\t\(interfaceName)",
                    icon: .asset(state.kind.icon(active: true), in: .module)
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
        let showIPv6 = await context.isFieldEnabled(NetworkField.ipv6.rawValue)
        let body = report.body(showIPv6: showIPv6)
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
