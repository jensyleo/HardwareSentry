import SignalCore

/// What this monitor can tell you about.
public enum CameraEvent: String, NotificationEventKey {
    case connected = "CameraConnected"
    case disconnected = "CameraDisconnected"
    case inUseChanged = "CameraInUseChanged"
    case portraitEffectChanged = "CameraPortraitEffectChanged"
    case studioLightChanged = "CameraStudioLightChanged"
    case reactionsChanged = "CameraReactionsChanged"
    case backgroundReplacementChanged = "CameraBackgroundReplacementChanged"

    public static let category: NotificationCategory = "Camera"

    static func forEffect(_ effect: CameraVideoEffect) -> CameraEvent {
        switch effect {
        case .portraitEffect: return .portraitEffectChanged
        case .studioLight: return .studioLightChanged
        case .reactions: return .reactionsChanged
        case .backgroundReplacement: return .backgroundReplacementChanged
        }
    }
}
