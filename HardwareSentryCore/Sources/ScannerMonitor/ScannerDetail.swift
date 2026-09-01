import Foundation

/// What Bonjour said about a scanner beyond its name.
///
/// None of this exists in HG4MAC, which reports the service name and nothing else. The
/// name alone is often something like "HP Color LaserJet MFP [A1B2C3]", which says which
/// box it is but not where it stands or what it can do — and on a network with several,
/// where it stands is usually the question being asked.
public struct ScannerDetail: Sendable, Equatable {
    /// The advertised model, which is usually friendlier than the service name.
    public let model: String?
    /// Where the owner said it is — "Room 3", "Second floor". Free text, often empty.
    public let location: String?
    public let host: String?
    public let port: Int?
    /// "AirScan (eSCL)" or "WSD", from which Bonjour service type announced it.
    public let scanProtocol: String?
    /// "Flatbed", "Document feeder", or both.
    public let inputSources: String?
    public let supportsDuplex: Bool
    /// File formats it will hand back — PDF, JPEG, and so on.
    public let formats: String?
    public let colorModes: String?
    public let adminURL: String?

    public init(
        model: String? = nil,
        location: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        scanProtocol: String? = nil,
        inputSources: String? = nil,
        supportsDuplex: Bool = false,
        formats: String? = nil,
        colorModes: String? = nil,
        adminURL: String? = nil
    ) {
        self.model = model
        self.location = location
        self.host = host
        self.port = port
        self.scanProtocol = scanProtocol
        self.inputSources = inputSources
        self.supportsDuplex = supportsDuplex
        self.formats = formats
        self.colorModes = colorModes
        self.adminURL = adminURL
    }

    /// Host and port read as one thing, so turning the line on doesn't produce two.
    var addressNote: String? {
        guard let host else { return nil }
        return port.map { "\(host):\($0)" } ?? host
    }

    /// Present-only: a scanner that cannot do double-sided is the ordinary case, and
    /// saying so every time would be noise.
    var duplexNote: String? { supportsDuplex ? "Yes" : nil }
}

/// The optional details this monitor can add.
public enum ScannerField: String, CaseIterable {
    case model = "Model"
    case location = "Location"
    case address = "Address"
    case scanProtocol = "Protocol"
    case inputSources = "InputSources"
    case duplex = "Duplex"
    case formats = "Formats"
    case colorModes = "ColorModes"
    case adminURL = "AdminURL"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .model: return "Model"
        case .location: return "Where it is"
        case .address: return "Address on the network"
        case .scanProtocol: return "Which protocol it speaks"
        case .inputSources: return "Flatbed or document feeder"
        case .duplex: return "Can scan both sides"
        case .formats: return "File formats it produces"
        case .colorModes: return "Colour modes"
        case .adminURL: return "Web administration page"
        }
    }

    /// Model and location are on because together they answer "which scanner is this?",
    /// which is the reason to read the notification at all. The rest are capabilities that
    /// never change for a given device, so after the first sighting they repeat verbatim.
    var shownByDefault: Bool {
        self == .model || self == .location
    }
}
