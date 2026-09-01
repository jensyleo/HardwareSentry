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
    public init() {}

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

    public func changes() -> AsyncStream<NetworkSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

private let linkKeyPattern = "State:/Network/Interface/[^/]+/Link"
private let globalIPv4Key = "State:/Network/Global/IPv4"

private final class Watcher: NSObject, CWEventDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<NetworkSourceEvent>.Continuation
    private var pathMonitor: NWPathMonitor?
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

    init(continuation: AsyncStream<NetworkSourceEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        startReachability()
        startDynamicStore()
        startWiFi()
    }

    func stop() {
        pathMonitor?.cancel()
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        CWWiFiClient.shared().delegate = nil
        try? CWWiFiClient.shared().stopMonitoringAllEvents()
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

        SCDynamicStoreSetNotificationKeys(store, [globalIPv4Key as CFString] as CFArray, [linkKeyPattern as CFString] as CFArray)
        guard let source = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, store, 0) else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        emitDynamicStoreSnapshots()
    }

    private func emitDynamicStoreSnapshots() {
        guard let dynamicStore else { return }

        var links: [String: Bool] = [:]
        if let keys = SCDynamicStoreCopyKeyList(dynamicStore, linkKeyPattern as CFString) as? [String] {
            for key in keys {
                guard let interfaceName = SystemNetworkSource.interfaceName(fromLinkKey: key) else { continue }
                let active = (SCDynamicStoreCopyValue(dynamicStore, key as CFString) as? [String: AnyObject])?[kSCPropNetLinkActive as String] as? Bool
                links[interfaceName] = active ?? false
            }
        }
        continuation.yield(.linkSnapshot(links))

        let global = SCDynamicStoreCopyValue(dynamicStore, globalIPv4Key as CFString) as? [String: AnyObject]
        continuation.yield(.primaryInterfaceSnapshot(global?[kSCDynamicStorePropNetPrimaryInterface as String] as? String))
    }


    // MARK: Wi-Fi (CoreWLAN)

    private func startWiFi() {
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        if let interface = CWWiFiClient.shared().interface(withName: interfaceName),
           let ssid = interface.ssid() {
            continuation.yield(.wifiConnected(ssid: ssid, detail: WiFiDetail(interface: interface)))
        } else {
            continuation.yield(.wifiDisconnected)
        }
    }
}
