import Foundation

/// One of Control Center's system-wide video effects.
public enum CameraVideoEffect: Sendable, Equatable {
    case portraitEffect
    case studioLight
    case reactions
    case backgroundReplacement
}

/// What the system told this monitor just happened.
///
/// `runningStateChanged` carries the FULL current snapshot of which cameras are in use,
/// not a delta — CoreMediaIO's own listener callback carries no detail either, so every
/// firing means "go re-read what's running now", and the monitor is what turns that into
/// started/stopped per device.
public enum CameraSourceEvent: Sendable, Equatable {
    case connected(uid: String, name: String)
    case disconnected(uid: String, name: String)
    /// uid → name, for every camera currently in use by any app.
    case runningStateChanged(running: [String: String])
    case videoEffectChanged(CameraVideoEffect, enabled: Bool)
}

/// Where news of cameras comes from.
public protocol CameraSource: Sendable {
    func changes() -> AsyncStream<CameraSourceEvent>
}
