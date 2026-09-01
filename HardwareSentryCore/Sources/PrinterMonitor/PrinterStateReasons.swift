import Foundation

/// Reads IPP `printer-state-reasons` (RFC 8011 §5.4.12): a comma-separated list of
/// keywords, each carrying its own severity as a suffix — `-error` (blocks printing),
/// `-warning` (degraded but still working), or no suffix at all (`-report`, purely
/// informational, e.g. `connecting-to-device` — a normal part of sending a job over
/// network/Wi-Fi, not something to flag). Only `-error`/`-warning` count as a real problem;
/// treating every non-"none" reason as one produced false "Needs Attention"/"OK" pairs
/// around ordinary network printing, confirmed live in HG4MAC's own history.
public enum PrinterStateReasons {
    public static func indicatesProblem(_ reasons: String) -> Bool {
        guard !reasons.isEmpty, reasons != "none" else { return false }
        return reasons.split(separator: ",").contains { reason in
            reason.hasSuffix("-error") || reason.hasSuffix("-warning")
        }
    }

    /// "Out of paper, Cover open" instead of the raw "media-empty-error,cover-open-warning"
    /// — nil if there's nothing to show (shouldn't happen when `indicatesProblem` said yes).
    public static func friendlyDescription(_ reasons: String) -> String? {
        guard !reasons.isEmpty, reasons != "none" else { return nil }
        let labels = reasons.split(separator: ",").compactMap { reason -> String? in
            guard reason.hasSuffix("-error") || reason.hasSuffix("-warning") else { return nil }
            return friendlyLabel(for: String(reason))
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    static func friendlyLabel(for reasonWithSuffix: String) -> String {
        var base = reasonWithSuffix
        for suffix in ["-error", "-warning", "-report"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        if let friendly = table[base] { return friendly }
        let spaced = base.replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return base }
        return first.uppercased() + spaced.dropFirst()
    }

    private static let table: [String: String] = [
        "media-empty": "Out of paper",
        "media-jam": "Paper jam",
        "media-low": "Paper low",
        "media-needed": "Wrong paper loaded",
        "door-open": "Door open",
        "cover-open": "Cover open",
        "interlock-open": "Interlock open",
        "toner-low": "Toner low",
        "toner-empty": "Toner empty",
        "marker-supply-low": "Ink/toner low",
        "marker-supply-empty": "Ink/toner empty",
        "marker-waste-almost-full": "Waste tank almost full",
        "marker-waste-full": "Waste tank full",
        "input-tray-missing": "Paper tray missing",
        "output-tray-missing": "Output tray missing",
        "output-area-almost-full": "Output tray almost full",
        "output-area-full": "Output tray full",
        "paused": "Paused",
        "shutdown": "Shutting down",
        "stopped-partly": "Partially stopped",
        "stopping": "Stopping",
        "timed-out": "Not responding",
        "offline": "Offline",
        "fuser-over-temp": "Fuser overheating",
        "fuser-under-temp": "Fuser too cold",
        "spool-area-full": "Spool area full"
    ]
}
