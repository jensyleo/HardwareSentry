import Foundation

/// What a camera could be described as when it arrived.
///
/// Read at connect and carried only on the connect event. Everything here is a fixed
/// property of the device — how it attaches, what it can resolve, who made it — so
/// repeating it every time an app starts or stops using the camera would be the same
/// sentence over and over. The in-use notification stays short on purpose: it is the
/// privacy signal, and it is read at a glance.
public struct CameraDetail: Sendable, Equatable {
    /// How the camera attaches — "Built-in", "USB", "Continuity", and so on.
    public let transport: String?
    public let manufacturer: String?
    /// "Front" or "Back" for a camera that faces a definite way; nil for one that doesn't.
    public let position: String?
    /// The largest the camera can shoot, across every format it offers — not the format
    /// it happens to be using right now.
    public let maxResolution: String?
    public let maxFrameRate: String?
    public let isContinuityCamera: Bool
    public let isDeskViewCamera: Bool
    public let isCenterStageActive: Bool
    /// Whether macOS would pick this camera by default.
    public let isSystemPreferred: Bool
    /// Other cameras the system considers physically part of the same unit — an iPhone's
    /// main camera and its Desk View, for instance.
    public let linkedDevices: String?

    public init(
        transport: String? = nil,
        manufacturer: String? = nil,
        position: String? = nil,
        maxResolution: String? = nil,
        maxFrameRate: String? = nil,
        isContinuityCamera: Bool = false,
        isDeskViewCamera: Bool = false,
        isCenterStageActive: Bool = false,
        isSystemPreferred: Bool = false,
        linkedDevices: String? = nil
    ) {
        self.transport = transport
        self.manufacturer = manufacturer
        self.position = position
        self.maxResolution = maxResolution
        self.maxFrameRate = maxFrameRate
        self.isContinuityCamera = isContinuityCamera
        self.isDeskViewCamera = isDeskViewCamera
        self.isCenterStageActive = isCenterStageActive
        self.isSystemPreferred = isSystemPreferred
        self.linkedDevices = linkedDevices
    }

    /// Present-only, for the same reason the gamepad capability lines are: telling someone
    /// their built-in webcam is not a Continuity Camera is not news.
    var continuityNote: String? { isContinuityCamera ? "Yes" : nil }
    var deskViewNote: String? { isDeskViewCamera ? "Yes" : nil }
    var centerStageNote: String? { isCenterStageActive ? "Active" : nil }
    var systemPreferredNote: String? { isSystemPreferred ? "Yes" : nil }
}

/// The optional details this monitor can add.
public enum CameraField: String, CaseIterable {
    case transport = "Transport"
    case manufacturer = "Manufacturer"
    case position = "Position"
    case maxResolution = "MaxResolution"
    case maxFrameRate = "MaxFrameRate"
    case continuityCamera = "ContinuityCamera"
    case deskView = "DeskView"
    case centerStage = "CenterStage"
    case systemPreferred = "SystemPreferred"
    case linkedDevices = "LinkedDevices"
}

extension CameraField {
    /// Four are on: what a camera is attached by, how big it can shoot, whether it is an
    /// iPhone standing in as a webcam, and whether auto-framing is on. Those are the
    /// answers to "which camera is this and what is it doing"; the rest are specification.
    var shownByDefault: Bool {
        switch self {
        case .transport, .maxResolution, .continuityCamera, .deskView, .centerStage: return true
        default: return false
        }
    }

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .transport: return "How it attaches"
        case .manufacturer: return "Manufacturer"
        case .position: return "Which way it faces"
        case .maxResolution: return "Highest resolution"
        case .maxFrameRate: return "Highest frame rate"
        case .continuityCamera: return "Is a Continuity Camera"
        case .deskView: return "Is a Desk View camera"
        case .centerStage: return "Center Stage is active"
        case .systemPreferred: return "Is the system's preferred camera"
        case .linkedDevices: return "Linked cameras"
        }
    }
}
