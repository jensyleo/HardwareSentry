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
        .init(name: NetworkEvent.primaryInterfaceChanged.rawValue, title: "Primary interface changed", enabledByDefault: false, icon: .asset("Network-PrimaryInterface-On", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = NetworkField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any NetworkSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    private var knownLinks: [String: Bool] = [:]
    private var hasLinkBaseline = false
    private var lastKnownPrimaryInterface: String?
    private var hasPrimaryBaseline = false
    private var lastKnownReachable: Bool?

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

    private func handleLinkSnapshot(_ links: [String: Bool]) async {
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

        for (interfaceName, isActive) in links {
            let wasActive = knownLinks[interfaceName] ?? false
            if isActive, !wasActive {
                await context.notify(NetworkEvent.linkUp.rawValue, subject: interfaceName, title: "Network Link Up", body: "Interface:\t\(interfaceName)", icon: .asset("Network-Ethernet-On", in: .module))
            } else if !isActive, wasActive {
                await context.notify(NetworkEvent.linkDown.rawValue, subject: interfaceName, title: "Network Link Down", body: "Interface:\t\(interfaceName)", icon: .asset("Network-Ethernet-Off", in: .module))
            }
        }
        knownLinks = links
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
