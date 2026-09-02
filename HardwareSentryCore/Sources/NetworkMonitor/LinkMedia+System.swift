import Foundation

/// Reads what a wired interface negotiated, straight from the kernel.
///
/// `SIOCGIFMEDIA` is the only way to ask: `SCNetworkInterface` describes what an interface
/// *is*, not what its link currently agreed to. Untested for the same reason the rest of
/// the sources are — it needs a real cable in a real port. The deciding built on top of it
/// lives in `LinkMedia` and `NetworkMonitor`, and is tested there.
extension LinkMedia {
    static func read(interface bsdName: String) -> LinkMedia? {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        defer { close(socketDescriptor) }

        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { name in
            _ = bsdName.utf8CString.withUnsafeBytes { source in
                memcpy(name.baseAddress!, source.baseAddress!, min(name.count, source.count))
            }
        }

        // Asked twice on purpose: the first call fills in how many media types the
        // interface supports, which is what says how much room the second one needs.
        guard ioctl(socketDescriptor, Self.getMediaRequest, &request) >= 0 else { return nil }

        var supported: [Int32] = []
        if request.ifm_count > 0 {
            supported = [Int32](repeating: 0, count: Int(request.ifm_count))
            supported.withUnsafeMutableBufferPointer { buffer in
                request.ifm_ulist = buffer.baseAddress
                _ = ioctl(socketDescriptor, Self.getMediaRequest, &request)
            }
            request.ifm_ulist = nil
        }

        return LinkMedia(
            speed: Self.subtypeName(request.ifm_active),
            mode: Self.duplexName(request.ifm_active),
            maximumSpeed: supported.compactMap(Self.subtypeName).last
        )
    }

    /// `SIOCGIFMEDIA`, worked out rather than imported.
    ///
    /// The constant is defined as `_IOWR('i', 56, struct ifmediareq)`, and neither that
    /// macro nor the `_IOC` arithmetic behind it survives into Swift. Computing it from
    /// `MemoryLayout` is not a guess: the size of the struct is exactly what the macro
    /// encodes, so this tracks the real ABI rather than freezing a number that would
    /// silently become wrong if the struct ever grew.
    private static var getMediaRequest: UInt {
        let inOut: UInt = 0xC000_0000                      // IOC_INOUT
        let parameterMask: UInt = 0x1FFF                   // IOCPARM_MASK
        let size = UInt(MemoryLayout<ifmediareq>.size) & parameterMask
        return inOut | (size << 16) | (UInt(UInt8(ascii: "i")) << 8) | 56
    }

    /// The Ethernet media subtypes worth naming, from `net/if_media.h`.
    ///
    /// Written out rather than read from the header's description tables: those are C
    /// arrays of `struct ifmedia_description`, which Swift cannot import, and the values
    /// themselves are fixed by the kernel ABI.
    private static func subtypeName(_ media: Int32) -> String? {
        switch media & Int32(IFM_TMASK_COMPAT) {
        case IFM_10_T: return "10baseT/UTP"
        case IFM_100_TX: return "100baseTX"
        case IFM_1000_T: return "1000baseT"
        case IFM_1000_SX: return "1000baseSX"
        case IFM_2500_T: return "2500Base-T"
        case IFM_5000_T: return "5000Base-T"
        case IFM_10G_T: return "10Gbase-T"
        case IFM_10G_SR: return "10Gbase-SR"
        case IFM_10G_LR: return "10Gbase-LR"
        default: return nil
        }
    }

    private static func duplexName(_ media: Int32) -> String? {
        if media & Int32(IFM_FDX) != 0 { return "full-duplex" }
        if media & Int32(IFM_HDX) != 0 { return "half-duplex" }
        return nil
    }
}
