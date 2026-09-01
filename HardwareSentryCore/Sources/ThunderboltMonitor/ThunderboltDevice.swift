import Foundation

/// A Thunderbolt/PCI device, as much of one as is worth telling someone about.
///
/// `baseClass` is the PCI-SIG base class byte (top byte of the registry's 3-byte
/// "class-code" property) — `0x03` ("Display Controller") is, in practice, always an
/// external GPU on this hardware, since an internal Apple Silicon GPU never enumerates as
/// a post-launch add/remove.
public struct ThunderboltDevice: Sendable, Equatable {
    public let name: String
    public let baseClass: UInt8?

    public init(name: String, baseClass: UInt8? = nil) {
        self.name = name
        self.baseClass = baseClass
    }

    public var isDisplayController: Bool { baseClass == 0x03 }
}

public enum ThunderboltDeviceChange: Sendable, Equatable {
    case attached(ThunderboltDevice)
    /// Registry properties are frequently unreadable from an already-terminating entry by
    /// the time a removal is reported, so a departure carries only the name — the monitor
    /// itself remembers what it saw at connect time, the same way `USBMonitor`'s subject
    /// choice keeps a flapping device recognisable as one thing.
    case detached(name: String)
}

/// Where news of Thunderbolt/PCI devices comes from.
public protocol ThunderboltDeviceSource: Sendable {
    func changes() -> AsyncStream<ThunderboltDeviceChange>
}
