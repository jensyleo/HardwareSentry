import Foundation

/// How one member of a link-aggregation bond is faring.
///
/// Worth reporting because a bond hides its own failures: pull one of two cables and
/// everything keeps working at half the speed, with nothing else in the system saying so.
/// The bond is fine; the member is not.
public enum BondMemberStatus: Int, Sendable, Equatable, CaseIterable {
    case ok = 0
    case linkInvalid = 1
    case noPartner = 2
    case notInActiveGroup = 3

    /// The system's own aggregation-status number, which is a bitmask of what is wrong.
    ///
    /// Zero means nothing is wrong, which is why it is checked first rather than as a
    /// fallback: any other value has at least one problem bit set.
    public init(aggregationStatus: Int) {
        switch aggregationStatus {
        case 0: self = .ok
        case let value where value & 0x1 != 0: self = .linkInvalid
        case let value where value & 0x2 != 0: self = .noPartner
        default: self = .notInActiveGroup
        }
    }

    public var label: String {
        switch self {
        case .ok: return "OK"
        case .linkInvalid: return "Link invalid (down/half-duplex/wrong speed)"
        case .noPartner: return "No 802.3ad partner on switch port"
        case .notInActiveGroup: return "Not in the active aggregation group"
        }
    }
}
