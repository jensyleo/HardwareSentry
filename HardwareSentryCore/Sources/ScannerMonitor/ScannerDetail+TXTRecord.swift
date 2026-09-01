import Foundation

/// Reads a scanner's Bonjour TXT record into something a person can read.
///
/// The keys come from the Mopria/AirScan eSCL specification, which is what every
/// AirScan-capable scanner advertises under `_uscan._tcp`. A `_scanner._tcp` (WSD) device
/// advertises far less, so most of this simply comes back nil for one — which is the point
/// of every field being optional rather than defaulted to a guess.
///
/// This one IS tested: unlike the AVFoundation and GameController readers, a TXT record is
/// just a dictionary of bytes, and a real scanner's is easy to write down.
extension ScannerDetail {
    /// - Parameters:
    ///   - txt: the TXT record, already decoded from `NetService.dictionary(fromTXTRecord:)`.
    ///   - serviceType: the Bonjour type the device was found under.
    init(txt: [String: Data], serviceType: String, host: String?, port: Int?) {
        func string(_ key: String) -> String? {
            // Keys are matched case-insensitively: the specification writes `UUID` and
            // `ty`, but real firmware is inconsistent about case, and a field that
            // silently vanishes on one vendor's scanner is worse than no field.
            guard let data = txt.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
                  let value = String(data: data, encoding: .utf8)
            else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// Several TXT values are comma-separated lists with no spaces after the commas.
        func list(_ key: String, transform: (String) -> String? = { $0 }) -> String? {
            guard let raw = string(key) else { return nil }
            let items = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .compactMap(transform)
                .filter { !$0.isEmpty }
            return items.isEmpty ? nil : items.joined(separator: ", ")
        }

        self.init(
            model: string("ty") ?? string("mdl"),
            location: string("note") ?? string("location"),
            // Bonjour host names come back fully qualified, with the root dot still on
            // the end. Trimmed here rather than at the call site so the rule is covered
            // by tests — the source that calls this cannot be.
            host: host.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 },
            port: port,
            scanProtocol: Self.describeProtocol(serviceType),
            inputSources: list("is") { Self.inputSourceNames[$0.lowercased()] ?? $0 },
            // `duplex=T`, and some firmware writes the whole word.
            supportsDuplex: (string("duplex")?.lowercased()).map { $0 == "t" || $0 == "true" } ?? false,
            formats: list("pdl") { Self.formatNames[$0.lowercased()] ?? $0 },
            colorModes: list("cs") { $0.capitalized },
            adminURL: string("adminurl")
        )
    }

    private static func describeProtocol(_ serviceType: String) -> String? {
        if serviceType.contains("_uscan") { return "AirScan (eSCL)" }
        if serviceType.contains("_scanner") { return "WSD" }
        return nil
    }

    /// The spec's abbreviations, spelled out. Anything unrecognised is passed through
    /// as-is rather than dropped — an unfamiliar source is still worth naming.
    private static let inputSourceNames: [String: String] = [
        "platen": "Flatbed",
        "adf": "Document feeder",
        "camera": "Camera"
    ]

    /// MIME types, shortened to the names people use for them.
    private static let formatNames: [String: String] = [
        "application/pdf": "PDF",
        "image/jpeg": "JPEG",
        "image/png": "PNG",
        "image/tiff": "TIFF",
        "application/octet-stream": "Raw"
    ]
}
