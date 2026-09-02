import Foundation

/// The system-wide network settings worth reporting a change to, read together because
/// they all come from the same place and change for the same reasons.
///
/// A plain value so the deciding — what counts as a change, and how to word it — can be
/// exercised without a Mac whose network settings are being edited underneath it.
public struct NetworkGlobalState: Sendable, Equatable {
    /// The resolvers in the order the system will try them.
    public let dnsServers: [String]
    /// Which proxies are switched on, and where they point. Compared as a whole because
    /// any part of it changing is one event: "the proxy configuration changed".
    public let proxy: ProxyConfiguration
    /// The name of the active network location — "Automatic", "Home", "Work".
    public let locationName: String?
    /// The order services are tried in, by name.
    public let serviceOrder: [String]

    public init(
        dnsServers: [String] = [],
        proxy: ProxyConfiguration = ProxyConfiguration(),
        locationName: String? = nil,
        serviceOrder: [String] = []
    ) {
        self.dnsServers = dnsServers
        self.proxy = proxy
        self.locationName = locationName
        self.serviceOrder = serviceOrder
    }
}

/// Which proxies are on and where they point.
public struct ProxyConfiguration: Sendable, Equatable {
    public let http: Bool
    public let https: Bool
    public let socks: Bool
    public let autoConfig: Bool
    /// Included in the comparison so moving to a different proxy server counts as a change
    /// even though the same boxes stay ticked.
    public let httpHost: String?
    public let autoConfigURL: String?

    public init(
        http: Bool = false,
        https: Bool = false,
        socks: Bool = false,
        autoConfig: Bool = false,
        httpHost: String? = nil,
        autoConfigURL: String? = nil
    ) {
        self.http = http
        self.https = https
        self.socks = socks
        self.autoConfig = autoConfig
        self.httpHost = httpHost
        self.autoConfigURL = autoConfigURL
    }

    /// The active proxies in words, or a sentence saying there are none.
    ///
    /// Names the kinds rather than the addresses: a proxy host can be a long internal
    /// name, and which kinds are in force is what a person is checking.
    public var summary: String {
        var active: [String] = []
        if http { active.append("HTTP") }
        if https { active.append("HTTPS") }
        if socks { active.append("SOCKS") }
        if autoConfig { active.append("Auto-Config (PAC)") }
        return active.isEmpty ? "No proxy configured" : "Active: \(active.joined(separator: ", "))"
    }
}

public extension NetworkGlobalState {
    /// How a list of resolvers reads in a message.
    static func describe(_ servers: [String]) -> String {
        servers.isEmpty ? "none" : servers.joined(separator: ", ")
    }

    /// How a service order reads in a message.
    static func describe(order: [String]) -> String {
        order.joined(separator: " → ")
    }
}
