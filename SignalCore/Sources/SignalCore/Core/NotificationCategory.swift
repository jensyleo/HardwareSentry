import Foundation

/// Identifies the module/subsystem that emitted a notification event.
///
/// Consumers (e.g. each hardware monitor in HardwareSentry) declare their own
/// category value — there is no fixed enum here, since SignalCore is app-agnostic
/// and must not hardcode any particular app's set of modules.
public struct NotificationCategory: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension NotificationCategory: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension NotificationCategory: CustomStringConvertible {
    public var description: String { rawValue }
}
