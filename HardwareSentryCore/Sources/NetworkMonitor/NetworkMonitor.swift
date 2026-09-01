import Foundation
import SentryContract
import SignalCore

/// Says whether the Internet is generally reachable, when Wi-Fi joins or leaves a network,
/// when a link (wired or otherwise) comes up or down, and which interface carries default
/// traffic.
public actor NetworkMonitor: Monitor {
    public static let category = NetworkEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: NetworkEvent.reachabilityChanged.rawValue, title: "Internet reachability changed", enabledByDefault: false),
        .init(name: NetworkEvent.wifiConnected.rawValue, title: "Joined a Wi-Fi network"),
        .init(name: NetworkEvent.wifiDisconnected.rawValue, title: "Left a Wi-Fi network"),
        .init(name: NetworkEvent.linkUp.rawValue, title: "Network link up"),
        .init(name: NetworkEvent.linkDown.rawValue, title: "Network link down"),
        .init(name: NetworkEvent.primaryInterfaceChanged.rawValue, title: "Primary interface changed", enabledByDefault: false)
    ]

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
        case .reachability(let isReachable):
            await handleReachability(isReachable)
        case .wifiConnected(let ssid):
            await context.notify(NetworkEvent.wifiConnected.rawValue, subject: ssid, title: "AirPort Connected", body: "Joined network.\nSSID:\t\(ssid)")
        case .wifiDisconnected:
            await context.notify(NetworkEvent.wifiDisconnected.rawValue, subject: "WiFi", title: "AirPort Disconnected", body: "")
        case .linkSnapshot(let links):
            await handleLinkSnapshot(links)
        case .primaryInterfaceSnapshot(let name):
            await handlePrimaryInterface(name)
        }
    }

    private func handleReachability(_ isReachable: Bool) async {
        let previous = lastKnownReachable
        lastKnownReachable = isReachable
        guard let previous, previous != isReachable else { return } // first sighting — baseline only

        await context.notify(
            NetworkEvent.reachabilityChanged.rawValue,
            subject: "Internet",
            title: isReachable ? "Internet Reachable" : "Internet Unreachable",
            body: isReachable ? "General Internet connectivity was restored" : "General Internet connectivity was lost"
        )
    }

    private func handleLinkSnapshot(_ links: [String: Bool]) async {
        if !hasLinkBaseline {
            hasLinkBaseline = true
            knownLinks = links
            return
        }

        for (interfaceName, isActive) in links {
            let wasActive = knownLinks[interfaceName] ?? false
            if isActive, !wasActive {
                await context.notify(NetworkEvent.linkUp.rawValue, subject: interfaceName, title: "Network Link Up", body: "Interface:\t\(interfaceName)")
            } else if !isActive, wasActive {
                await context.notify(NetworkEvent.linkDown.rawValue, subject: interfaceName, title: "Network Link Down", body: "Interface:\t\(interfaceName)")
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
            body: "\(previous) → \(name)"
        )
    }
}
