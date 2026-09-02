import CoreLocation
import CoreWLAN
import Foundation
import Network
import SystemConfiguration

/// Watches `NWPathMonitor` for general Internet reachability, `SCDynamicStore` for link
/// state and the primary interface, and CoreWLAN for Wi-Fi joining/leaving a network.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without a real network event. Everything worth reasoning about lives in
/// `NetworkMonitor`, behind `NetworkSource`.
public struct SystemNetworkSource: NetworkSource {
    /// How often to read the Wi-Fi signal, and how long to wait between saying anything
    /// about it.
    ///
    /// Configurable because the right answer depends on what somebody wants from it: on a
    /// desk where the signal never moves, checking every twelve seconds is wasted work;
    /// carrying a laptop around a building, a minute is too slow to be useful. Clamped
    /// rather than trusted — a stored zero would spin, and a stored hour would look broken.
    public struct SignalPolling: Sendable, Equatable {
        public var interval: TimeInterval
        public var cooldown: TimeInterval

        public static let intervalRange: ClosedRange<TimeInterval> = 5...60
        public static let cooldownRange: ClosedRange<TimeInterval> = 0...60

        public init(interval: TimeInterval = 12, cooldown: TimeInterval = 10) {
            self.interval = interval.clamped(to: Self.intervalRange)
            self.cooldown = cooldown.clamped(to: Self.cooldownRange)
        }
    }

    private let signalPolling: SignalPolling

    public init(signalPolling: SignalPolling = SignalPolling()) {
        self.signalPolling = signalPolling
    }

    /// "State:/Network/Interface/en0/Link" → "en0".
    ///
    /// The leading "State:" is a component of its own once the string is split on "/", so
    /// the interface name is the fourth piece, not the third. Taking the third gave the
    /// literal word "Interface" for every interface on the machine — which read as
    /// "Interface: Interface" in the message and, worse, made every interface share one
    /// name, so a second link coming up looked like the first one changing.
    static func interfaceName(fromLinkKey key: String) -> String? {
        let parts = key.split(separator: "/")
        guard parts.count >= 5 else { return nil }
        return String(parts[3])
    }

    /// "State:/Network/Interface/en0/DHCP" → "en0". Same shape and same off-by-one
    /// mistake to avoid as `interfaceName(fromLinkKey:)`.
    static func interfaceName(fromDHCPKey key: String) -> String? {
        interfaceName(fromLinkKey: key)
    }

    public func changes() -> AsyncStream<NetworkSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation, signalPolling: signalPolling)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private let linkKeyPattern = "State:/Network/Interface/[^/]+/Link"
private let dhcpKeyPattern = "State:/Network/Interface/[^/]+/DHCP"
private let computerNameKey = "Setup:/System"
private let globalDNSKey = "State:/Network/Global/DNS"
private let globalProxiesKey = "State:/Network/Global/Proxies"
private let setupRootKey = "Setup:"
private let setupIPv4Key = "Setup:/Network/Global/IPv4"

extension SystemNetworkSource {
    /// Every interface `SCNetworkInterfaceCopyAll` lists, by BSD name, classified into
    /// what it actually is.
    ///
    /// Untested, for the same reason the rest of this file is: it needs the real
    /// interfaces of a real Mac. The classification itself — turning the type string this
    /// reads into a `NetworkInterfaceKind` — is what `NetworkInterfaceKind.classify` does,
    /// and that half is tested without any of this.
    static func realInterfaceKinds() -> [String: NetworkInterfaceKind] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var kinds: [String: NetworkInterfaceKind] = [:]
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let type = (SCNetworkInterfaceGetInterfaceType(interface) as String?) ?? ""
            kinds[name] = NetworkInterfaceKind.classify(scInterfaceType: type)
        }
        return kinds
    }
}
private let globalIPv4Key = "State:/Network/Global/IPv4"

private final class Watcher: NSObject, CWEventDelegate, CLLocationManagerDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<NetworkSourceEvent>.Continuation
    private var pathMonitor: NWPathMonitor?
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    /// Reading the SSID at all — not just the BSSID — has required Location authorization
    /// since macOS 10.14; without it `CWInterface.ssid()` silently returns nil, which is
    /// indistinguishable from not being on a network at all. Requesting authorization is
    /// all this needs: the location itself is never read, only the permission it unlocks.
    private var locationManager: CLLocationManager?
    private var lastKnownSSID: String?
    private var radioPollTask: Task<Void, Never>?
    private var interfaceKinds = InterfaceKindCache()
    private var signalPollTask: Task<Void, Never>?

    private let signalPolling: SystemNetworkSource.SignalPolling

    init(
        continuation: AsyncStream<NetworkSourceEvent>.Continuation,
        signalPolling: SystemNetworkSource.SignalPolling = .init()
    ) {
        self.continuation = continuation
        self.signalPolling = signalPolling
    }

    func start() {
        startReachability()
        startDynamicStore()
        startWiFi()
        pollForAddressesAtLaunch()
        // Sweeps the already-joined network itself, once it knows whether it is allowed
        // to name it — either immediately below (already granted from a previous launch)
        // or later, in `locationManagerDidChangeAuthorization`, once someone answers the
        // prompt this triggers.
        startLocationAuthorization()
    }

    /// Requests Location authorization if this is the first time, or if it was already
    /// granted from a previous launch. Only the authorization is used; nothing here ever
    /// asks for an actual location.
    private func startLocationAuthorization() {
        // On the main queue on purpose: `CLLocationManager` delivers its callbacks to the
        // run loop it was created on, and one created on a queue without a run loop never
        // shows the permission prompt and never calls back — it simply does nothing, which
        // is indistinguishable from permission having been refused.
        DispatchQueue.main.async { [self] in
            let manager = CLLocationManager()
            manager.delegate = self
            locationManager = manager
            requestOrSweep(manager)
        }
    }

    private func requestOrSweep(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            // Already granted from a previous launch — nothing to request, so the sweep
            // that could not run until now runs immediately.
            announceAlreadyJoinedWiFi()
        default:
            // Refused, or restricted. The SSID cannot be read at all, so there is nothing
            // to sweep and nothing worth asking twice for.
            break
        }
    }

    /// Fires once Location access is granted or denied. Only the transition into being
    /// granted matters here: a network already joined could not be named in the sweep that
    /// ran before permission existed, so it is announced again now that it can be.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways else { return }
        announceAlreadyJoinedWiFi()
    }

    /// `ssidDidChange` only fires for a network joined while this is listening, so without
    /// this the network already joined when the application launched — which is most
    /// networks, most of the time — is never mentioned at all.
    private func announceAlreadyJoinedWiFi() {
        for interface in CWWiFiClient.shared().interfaces() ?? [] {
            guard let ssid = interface.ssid() else { continue }
            continuation.yield(.wifiConnected(ssid: ssid, detail: WiFiDetail(interface: interface)))
        }
    }

    func stop() {
        pathMonitor?.cancel()
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        CWWiFiClient.shared().delegate = nil
        try? CWWiFiClient.shared().stopMonitoringAllEvents()
        locationManager?.delegate = nil
        radioPollTask?.cancel()
        signalPollTask?.cancel()
        continuation.finish()
    }

    // MARK: Reachability

    /// `NWPathMonitor`, not the older `SCNetworkReachability` C API (deprecated since
    /// macOS 14.4 in favor of exactly this) — same "general Internet reachability" fact,
    /// `.satisfied` standing in for "reachable".
    private func startReachability() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.continuation.yield(.reachability(isReachable: path.status == .satisfied, detail: NetworkPathDetail(path: path)))
        }
        monitor.start(queue: .main)
    }

    // MARK: Link + primary interface (SCDynamicStore)

    private func startDynamicStore() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var scContext = SCDynamicStoreContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(kCFAllocatorDefault, "com.jensyleo.hardwaresentry.network" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue().emitDynamicStoreSnapshots()
        }, &scContext) else { return }
        dynamicStore = store

        SCDynamicStoreSetNotificationKeys(
            store,
            [
                globalIPv4Key as CFString, computerNameKey as CFString,
                globalDNSKey as CFString, globalProxiesKey as CFString,
                setupRootKey as CFString, setupIPv4Key as CFString
            ] as CFArray,
            [linkKeyPattern as CFString, dhcpKeyPattern as CFString] as CFArray
        )
        guard let source = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, store, 0) else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        emitDynamicStoreSnapshots()
    }

    private func emitDynamicStoreSnapshots() {
        guard let dynamicStore else { return }

        // The same set System Settings › Network shows — real, user-facing interfaces —
        // rather than everything `SCDynamicStore` happens to have a Link key for, which
        // includes housekeeping interfaces (AirDrop's `awdl0`, `llw0`, loopback) nobody
        // would recognise in a notification.
        // Reconciled against what has been seen before, so an adapter already torn out of
        // the registry is still recognised as the interface it was — see
        // `InterfaceKindCache` for the bug this prevents.
        let kinds = interfaceKinds.reconcile(live: SystemNetworkSource.realInterfaceKinds())

        var links: [String: LinkState] = [:]
        if let keys = SCDynamicStoreCopyKeyList(dynamicStore, linkKeyPattern as CFString) as? [String] {
            for key in keys {
                guard let interfaceName = SystemNetworkSource.interfaceName(fromLinkKey: key),
                      let kind = kinds[interfaceName]
                else { continue }
                let active = (SCDynamicStoreCopyValue(dynamicStore, key as CFString) as? [String: AnyObject])?[kSCPropNetLinkActive as String] as? Bool
                links[interfaceName] = LinkState(
                    isActive: active ?? false,
                    kind: kind,
                    // Only asked of wired links: Wi-Fi negotiates a rate too, but that is
                    // the `Link Rate` line on the join notification, not a media type.
                    media: kind == .wired ? LinkMedia.read(interface: interfaceName) : nil
                )
            }
        }
        continuation.yield(.linkSnapshot(links))

        let global = SCDynamicStoreCopyValue(dynamicStore, globalIPv4Key as CFString) as? [String: AnyObject]
        continuation.yield(.primaryInterfaceSnapshot(global?[kSCDynamicStorePropNetPrimaryInterface as String] as? String))

        var leases: [String: Date] = [:]
        if let keys = SCDynamicStoreCopyKeyList(dynamicStore, dhcpKeyPattern as CFString) as? [String] {
            for key in keys {
                guard let interfaceName = SystemNetworkSource.interfaceName(fromDHCPKey: key),
                      let lease = SCDynamicStoreCopyValue(dynamicStore, key as CFString) as? [String: AnyObject],
                      let start = lease["LeaseStartTime"] as? Date
                else { continue }
                leases[interfaceName] = start
            }
        }
        continuation.yield(.dhcpLeaseSnapshot(leases))

        let system = SCDynamicStoreCopyValue(dynamicStore, computerNameKey as CFString) as? [String: AnyObject]
        continuation.yield(.computerNameSnapshot(system?[kSCPropSystemComputerName as String] as? String))

        continuation.yield(.globalState(readGlobalState(dynamicStore)))

        emitAddresses()
    }

    /// How long a "the address went away" reading is held back.
    ///
    /// Losing an address is the last thing in the chain: the radio goes off, the network
    /// is left, and only then does the address lapse. All three arrive at once and in no
    /// fixed order, so without this the banners can read backwards — address gone, then
    /// network left, then Wi-Fi off, which is the reverse of what happened.
    private static let addressReleaseDelay = Duration.milliseconds(800)

    private func emitAddresses() {
        let report = IPAddressReport.current(
            friendlyNames: SystemNetworkSource.friendlyInterfaceNames(),
            perInterface: readServiceDetails(),
            searchDomains: readSearchDomains()
        )

        guard report.hasAddresses else {
            // Only the losing case waits. An address arriving is not caused by anything
            // else this monitor reports, so delaying it would just make it late.
            Task { [continuation] in
                try? await Task.sleep(for: Self.addressReleaseDelay)
                continuation.yield(.ipAddressSnapshot(report))
            }
            return
        }
        continuation.yield(.ipAddressSnapshot(report))
    }

    /// The gateway and configuration method for each interface that has a service.
    ///
    /// Both live under `State:/Network/Service/<id>/IPv4`, keyed by an opaque service ID
    /// rather than by interface, so the interface name inside each one is what maps them
    /// back. There is no per-interface key to read directly.
    private func readServiceDetails() -> [String: ServiceDetail] {
        guard let store = dynamicStore,
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return [:] }

        var details: [String: ServiceDetail] = [:]
        for key in keys {
            guard let entry = SCDynamicStoreCopyValue(store, key as CFString) as? [String: AnyObject],
                  let interfaceName = entry[kSCPropInterfaceName as String] as? String
            else { continue }

            details[interfaceName] = ServiceDetail(
                gateway: entry[kSCPropNetIPv4Router as String] as? String,
                configurationMethod: entry[kSCPropNetIPv4ConfigMethod as String] as? String
            )
        }
        return details
    }

    private func readSearchDomains() -> [String] {
        guard let store = dynamicStore,
              let dns = SCDynamicStoreCopyValue(store, globalDNSKey as CFString) as? [String: AnyObject]
        else { return [] }
        return dns[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
    }

    /// Addresses do not exist the instant the application launches: DHCP is usually still
    /// negotiating, so reading once at t=0 reliably finds nothing and reports "no
    /// connection" on a machine that is about to have one. Re-read every couple of seconds
    /// until something shows up, then stop.
    private func pollForAddressesAtLaunch(elapsed: TimeInterval = 0) {
        guard elapsed <= Self.addressPollTimeout else { return }
        emitAddresses()
        guard !IPAddressReport.current().hasAddresses else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.addressPollInterval) { [weak self] in
            self?.pollForAddressesAtLaunch(elapsed: elapsed + Self.addressPollInterval)
        }
    }

    private static let addressPollInterval: TimeInterval = 2
    private static let addressPollTimeout: TimeInterval = 15


    /// Reads the system-wide settings that all live in `SCDynamicStore` dictionaries.
    private func readGlobalState(_ store: SCDynamicStore) -> NetworkGlobalState {
        let dns = SCDynamicStoreCopyValue(store, globalDNSKey as CFString) as? [String: AnyObject]
        let proxies = SCDynamicStoreCopyValue(store, globalProxiesKey as CFString) as? [String: AnyObject]
        let setupIPv4 = SCDynamicStoreCopyValue(store, setupIPv4Key as CFString) as? [String: AnyObject]

        return NetworkGlobalState(
            dnsServers: dns?["ServerAddresses"] as? [String] ?? [],
            proxy: ProxyConfiguration(
                http: proxies?["HTTPEnable"] as? Bool ?? false,
                https: proxies?["HTTPSEnable"] as? Bool ?? false,
                socks: proxies?["SOCKSEnable"] as? Bool ?? false,
                autoConfig: proxies?["ProxyAutoConfigEnable"] as? Bool ?? false,
                httpHost: proxies?["HTTPProxy"] as? String,
                autoConfigURL: proxies?["ProxyAutoConfigURLString"] as? String
            ),
            locationName: readLocationName(store),
            serviceOrder: setupIPv4?[kSCPropNetServiceOrder as String] as? [String] ?? []
        )
    }

    /// The active network location's name.
    ///
    /// Two reads: the root `Setup:` dictionary names which set is current, as a path, and
    /// the dictionary at that path carries the name somebody typed.
    private func readLocationName(_ store: SCDynamicStore) -> String? {
        guard let setup = SCDynamicStoreCopyValue(store, setupRootKey as CFString) as? [String: AnyObject],
              let currentSetPath = setup[kSCPrefCurrentSet as String] as? String,
              let set = SCDynamicStoreCopyValue(store, currentSetPath as CFString) as? [String: AnyObject]
        else { return nil }
        return set[kSCPropUserDefinedName as String] as? String
    }

    // MARK: Wi-Fi (CoreWLAN)

    private func startWiFi() {
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .powerDidChange)
        emitWiFiRadioPower()
        startWiFiRadioPoll()
        startWiFiSignalPoll()
        emitPromiscuousInterfaces()
    }

    /// Reads the radio's power and reports it.
    ///
    /// The monitor only speaks when the answer changes, so calling this often is free.
    private func emitWiFiRadioPower() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        continuation.yield(.wifiRadioPower(isOn: interface.powerOn()))
    }

    /// A slow backstop behind the push notification.
    ///
    /// `powerDidChange` is the right mechanism and usually arrives, but a missed one would
    /// otherwise leave the application permanently wrong about the radio — and every Wi-Fi
    /// notification after that reads as inexplicable. Thirty seconds, the original's
    /// figure, is cheap: reading a power flag is not work.
    private func startWiFiRadioPoll() {
        radioPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.emitWiFiRadioPower() }
            }
        }
    }

    /// Reads the signal strength on a timer.
    ///
    /// There is no notification for this — CoreWLAN will tell you the SSID changed but not
    /// that the signal moved, so it has to be asked. Twelve seconds is the original's
    /// figure: often enough to notice walking out of range, rare enough that a laptop
    /// sitting still is not doing constant work.
    private func startWiFiSignalPoll() {
        signalPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.signalPolling.interval ?? 12))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.emitWiFiSignal()
                    self?.emitPromiscuousInterfaces()
                }
            }
        }
    }

    /// Reads which interfaces are in promiscuous mode.
    ///
    /// No notification exists for this flag, so it has to be asked for. Rolled into the
    /// signal poll rather than given a timer of its own: both are cheap reads on the same
    /// cadence, and one timer is one thing to reason about.
    private func emitPromiscuousInterfaces() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }

        var capturing: Set<String> = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard (interface.ifa_flags & UInt32(IFF_PROMISC)) != 0 else { continue }
            capturing.insert(String(cString: interface.ifa_name))
        }
        continuation.yield(.promiscuousSnapshot(capturing))
    }

    private func emitWiFiSignal() {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return }
        let rssi = interface.rssiValue()
        // Zero means the interface had nothing to say, which is not the same as a signal
        // of zero strength — passing it on would be reporting a reading that does not exist.
        guard rssi != 0 else { return }
        continuation.yield(.wifiSignal(rssi: rssi, ssid: interface.ssid()))
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        emitWiFiRadioPower()
    }

    /// How long a "left the network" report is held back.
    ///
    /// Turning the radio off produces both a power change and an SSID change, and the
    /// order they arrive in is not fixed. Read in the wrong order the banners say the
    /// network was lost and then, inexplicably, that Wi-Fi was switched off. Holding the
    /// network notice for a moment lets the cause land before the effect.
    private static let disconnectDelay = Duration.milliseconds(400)

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        if let interface = CWWiFiClient.shared().interface(withName: interfaceName),
           let ssid = interface.ssid() {
            lastKnownSSID = ssid
            continuation.yield(.wifiConnected(ssid: ssid, detail: WiFiDetail(interface: interface)))
        } else {
            // The interface no longer knows the SSID by the time it reports leaving, so
            // the name comes from what was remembered on joining.
            let leftNetwork = lastKnownSSID
            lastKnownSSID = nil
            Task { [continuation] in
                try? await Task.sleep(for: Self.disconnectDelay)
                continuation.yield(.wifiDisconnected(ssid: leftNetwork))
            }
        }
    }
}

private extension Comparable {
    /// Brought back into range rather than trusted. A stored interval of zero would spin,
    /// and one of an hour would look like the feature was broken.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
