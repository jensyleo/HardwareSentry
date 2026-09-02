import Foundation

/// What an eSCL scanner says it is doing.
public enum ScannerState: String, Sendable, Equatable {
    case idle = "Idle"
    case processing = "Processing"
    case testing = "Testing"
    case stopped = "Stopped"
    case down = "Down"

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .processing: return "Scanning"
        case .testing: return "Testing"
        case .stopped: return "Stopped"
        case .down: return "Unavailable"
        }
    }
}

/// What the document feeder says about itself.
public enum AdfState: String, Sendable, Equatable {
    case loaded = "ScannerAdfLoaded"
    case empty = "ScannerAdfEmpty"
    case jam = "ScannerAdfJam"
    case doorOpen = "ScannerAdfDoorOpen"
    case processing = "ScannerAdfProcessing"

    /// How the change is worded in the notification's title.
    var title: String {
        switch self {
        case .loaded: return "Document Feeder Loaded"
        case .empty: return "Document Feeder Empty"
        case .jam: return "Document Feeder Jammed"
        case .doorOpen: return "Document Feeder Door Open"
        case .processing: return "Document Feeder Running"
        }
    }

    /// Whether this is a state somebody has to go and deal with.
    ///
    /// A jam or an open door will not clear itself, so those arrive with priority; a
    /// feeder that has simply run out of pages is the ordinary end of a scan.
    var needsAttention: Bool {
        self == .jam || self == .doorOpen
    }
}

/// One read of an eSCL scanner's status endpoint.
public struct ScannerStatus: Sendable, Equatable {
    public let state: ScannerState?
    /// Nil on a flatbed-only scanner, which has no feeder to report on.
    public let adfState: AdfState?
    /// Why it is stopped or down, when it says — "CoverOpen", "MediaJam".
    public let stateReasons: [String]

    public init(state: ScannerState? = nil, adfState: AdfState? = nil, stateReasons: [String] = []) {
        self.state = state
        self.adfState = adfState
        self.stateReasons = stateReasons
    }

    var reasonsNote: String? {
        stateReasons.isEmpty ? nil : stateReasons.joined(separator: ", ")
    }

    /// Nothing was understood — an endpoint that answered with something that was not a
    /// scanner status at all. Treated as no reading rather than as a scanner in an unknown
    /// state, so a proxy's error page cannot be reported as news.
    var isEmpty: Bool { state == nil && adfState == nil && stateReasons.isEmpty }
}

/// Reads one scanner's status, once.
///
/// A protocol so the monitor's behaviour — which transitions are news, which are not, and
/// what a failed read means — can be exercised without a scanner on the network.
public protocol ScannerStatusReading: Sendable {
    /// - Returns: the status, or nil when the scanner could not be reached or did not
    ///   answer with anything recognisable.
    func readStatus(host: String, port: Int) async -> ScannerStatus?
}

extension ScannerStatus {
    /// Parses an eSCL `ScannerStatus` document.
    ///
    /// Namespace prefixes are deliberately ignored and only the local element name is
    /// matched. The specification's own examples use `pwg:`, real scanners variously use
    /// `scan:`, `pwg:` and no prefix at all for the same elements, and a parser that
    /// insisted on one vendor's spelling would read every other vendor's scanner as
    /// having no status.
    public static func parse(escl xml: Data) -> ScannerStatus? {
        let parser = XMLParser(data: xml)
        let collector = StatusCollector()
        parser.delegate = collector
        guard parser.parse() else { return nil }

        let status = ScannerStatus(
            state: collector.state.flatMap(ScannerState.init(rawValue:)),
            adfState: collector.adfState.flatMap(AdfState.init(rawValue:)),
            stateReasons: collector.stateReasons
        )
        return status.isEmpty ? nil : status
    }
}

/// Gathers the three things worth reading out of the status document.
///
/// `XMLParser` needs a delegate object, and its callbacks are not actor-isolated — the
/// same shape the Bonjour browser's delegate uses, and for the same reason.
private final class StatusCollector: NSObject, XMLParserDelegate {
    private(set) var state: String?
    private(set) var adfState: String?
    private(set) var stateReasons: [String] = []

    private var current: String?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        current = Self.localName(of: elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { current = nil; text = "" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, Self.localName(of: elementName) == current else { return }

        switch current {
        // The scanner's own state and the feeder's are both spelled "State" in some
        // vendors' documents, distinguished only by their parent element — but "AdfState"
        // is unambiguous where it appears, and the top-level "State" is the only other
        // one, so the first "State" seen wins and later ones are ignored.
        case "State" where state == nil:
            state = value
        case "AdfState":
            adfState = value
        case "StateReason", "ScannerStateReason":
            stateReasons.append(value)
        default:
            break
        }
    }

    /// "pwg:AdfState" and "AdfState" are the same element.
    private static func localName(of elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }
}
