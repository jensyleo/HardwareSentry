import SignalCore

/// What this monitor can tell you about.
///
/// The experimental early-link-detection feature (`DisplayLinkDetected`, off by default in
/// HG4MAC — scrapes free-form kernel log text with no stability contract, see its own long
/// doc comment there) is deliberately not ported at all; see the porting notes for why.
public enum DisplayEvent: String, NotificationEventKey {
    case connected = "DisplayConnected"
    case disconnected = "DisplayDisconnected"
    case modeChanged = "DisplayModeChanged"
    case roleChanged = "DisplayRoleChanged"
    case sleepChanged = "DisplaySleepChanged"
    case colorProfileChanged = "DisplayColorProfileChanged"

    public static let category: NotificationCategory = "Display"
}

/// The optional details this monitor can add to a connect notification.
public enum DisplayField: String, CaseIterable {
    case resolution = "Resolution"
    case refreshRate = "RefreshRate"
    case rotation = "Rotation"
    case role = "Role"
    case uuid = "UUID"
    case physicalSize = "PhysicalSize"
    case density = "Density"
    case colorSpace = "ColorSpace"
    case builtIn = "BuiltIn"
    case mirrorSource = "MirrorSource"
    case identity = "Identity"
    case refreshRange = "RefreshRange"
    case dynamicRange = "DynamicRange"
    case notch = "Notch"
    case stereo = "Stereo"
    case scaling = "Scaling"
    case wideColor = "WideColor"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .resolution: return "Resolution"
        case .refreshRate: return "Refresh rate"
        case .rotation: return "Rotation"
        case .role: return "Role (Main/Extended/Mirrored)"
        case .uuid: return "Stable identifier (UUID)"
        case .physicalSize: return "Physical size"
        case .density: return "Pixel density (ppi)"
        case .colorSpace: return "Colour space"
        case .builtIn: return "Is the built-in display"
        case .mirrorSource: return "Which display it mirrors"
        case .identity: return "Vendor, model and serial"
        case .refreshRange: return "Variable refresh range"
        case .dynamicRange: return "Extended dynamic range headroom"
        case .notch: return "Has a notch"
        case .stereo: return "Is a stereo (3D) display"
        case .scaling: return "Scaling (HiDPI or scaled mode)"
        case .wideColor: return "Covers Display P3"
        }
    }

    /// The ones that answer "which display is this, and how is it running".
    ///
    /// Size is on because it is how anybody identifies a monitor in a sentence; scaling is
    /// on because a scaled mode is the usual answer to "why does text look soft". The
    /// identity line and the UUID are off — they are for telling two identical monitors
    /// apart, which is a real need and a rare one.
    var shownByDefault: Bool {
        switch self {
        case .resolution, .refreshRate, .rotation, .role, .physicalSize, .scaling,
             .mirrorSource, .refreshRange, .notch, .stereo:
            return true
        case .uuid, .density, .colorSpace, .builtIn, .identity, .dynamicRange, .wideColor:
            return false
        }
    }
}
