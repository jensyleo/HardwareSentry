import Foundation

/// One consumable a printer reports about itself.
///
/// CUPS publishes these as four parallel comma-separated lists — names, levels, types and
/// each one's own low mark — which is why they are parsed together and never separately: a
/// level with no name beside it is a number nobody can act on.
public struct PrinterSupply: Sendable, Equatable {
    public let name: String
    /// The IPP marker type — "toner", "ink", "staples", "waste-toner".
    public let type: String?
    /// How full it is, as a percentage. Nil when the printer declined to say: CUPS reports
    /// -1, -2 and -3 for unknown, unavailable and unknown-remaining, and any of those
    /// shown as a number would be a printer apparently at minus one percent.
    public let percentage: Int?
    /// The printer's own idea of low, when it publishes one.
    public let lowMark: Int?

    public init(name: String, type: String? = nil, percentage: Int? = nil, lowMark: Int? = nil) {
        self.name = name
        self.type = type
        self.percentage = percentage
        self.lowMark = lowMark
    }

    /// "Black Toner: 8%".
    var levelNote: String? {
        guard let percentage else { return nil }
        return "\(name): \(percentage)%"
    }

    /// Whether this supply counts as low, given a fallback threshold for printers that do
    /// not publish one of their own.
    ///
    /// The printer's own mark wins when it has one: a manufacturer knows better than this
    /// application how much of its own toner is left at "low", and some report a low mark
    /// far above ten percent because the last of it prints badly.
    func isLow(fallbackThreshold: Int) -> Bool {
        guard let percentage else { return false }
        return percentage <= (lowMark ?? fallbackThreshold)
    }

    /// Whether it has recovered — cartridge replaced, or refilled.
    ///
    /// Deliberately a higher bar than `isLow`, so a supply hovering on the line does not
    /// report low, recovered, low, recovered as the printer's own estimate wobbles. The
    /// same shape as the volume monitor's free-space hysteresis, and for the same reason.
    func hasRecovered(fallbackThreshold: Int, margin: Int) -> Bool {
        guard let percentage else { return false }
        return percentage >= (lowMark ?? fallbackThreshold) + margin
    }
}

extension PrinterSupply {
    /// Reads CUPS's four parallel lists into supplies.
    ///
    /// Parsed here rather than in the source so it can be tested without a printer: this
    /// is the part with the sharp edges — lists of different lengths, unknown levels
    /// encoded as negative numbers, and a supply named with a comma inside it.
    static func parse(
        names: String?,
        levels: String?,
        types: String?,
        lowLevels: String?
    ) -> [PrinterSupply] {
        let nameList = split(names)
        let levelList = split(levels).map { Int($0) }
        let typeList = split(types)
        let lowList = split(lowLevels).map { Int($0) }

        // Driven by the names, not by the longest list: a level with no name is a number
        // with nothing to attach it to, and reporting "supply 3 is at 8%" helps nobody.
        return nameList.enumerated().map { index, name in
            PrinterSupply(
                name: name,
                type: index < typeList.count ? typeList[index] : nil,
                // Negative is CUPS's way of declining to answer, not a level.
                percentage: index < levelList.count ? levelList[index].flatMap { $0 >= 0 ? $0 : nil } : nil,
                lowMark: index < lowList.count ? lowList[index].flatMap { $0 > 0 ? $0 : nil } : nil
            )
        }
    }

    /// Splits one of the lists, honouring the quotes CUPS puts around a value containing a
    /// comma — a cartridge called "Black, High Yield" would otherwise become two supplies.
    private static func split(_ list: String?) -> [String] {
        guard let list, !list.isEmpty else { return [] }

        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for character in list {
            switch character {
            case "'", "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields.filter { !$0.isEmpty }
    }
}
