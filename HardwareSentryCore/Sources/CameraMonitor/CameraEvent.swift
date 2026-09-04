import SignalCore

/// What this monitor can tell you about.
public enum CameraEvent: String, NotificationEventKey {
    case connected = "CameraConnected"
    case disconnected = "CameraDisconnected"
    /// A camera arriving or leaving over USB — the "webcam" wording and its own switch,
    /// independent of the one above. Reported live: with USB Monitor's own generic notice
    /// folded away for a kind Camera already covers, "Camera Connected" was the only
    /// wording left for what is, in hand, a webcam — and the one place that word used to
    /// come from was the very notice being folded away. Split into its own event, the
    /// same way USB Monitor gives a hub or a keyboard its own row rather than one shared
    /// "Connected": someone who wants to know about a built-in camera changing but not
    /// about a webcam being plugged in and out all day can say so.
    case webcamConnected = "CameraWebcamConnected"
    case webcamDisconnected = "CameraWebcamDisconnected"
    /// An iPhone or iPad standing in as a camera over Continuity Camera. Its own row and
    /// its own wording, for the same reason the webcam pair has theirs.
    case continuityConnected = "CameraContinuityConnected"
    case continuityDisconnected = "CameraContinuityDisconnected"
    /// The overhead, table-level view Continuity Camera can also provide — a distinct
    /// mode from the ordinary one, and named as such.
    case deskViewConnected = "CameraDeskViewConnected"
    case deskViewDisconnected = "CameraDeskViewDisconnected"
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
