import Foundation

/// A supply's name in the interface's language (Windows' `SupplyNames.FromEnglish`). The parsers write LEDM's and CDM's
/// names in English from a colour code and a kind ("Black toner", "Tri-color ink cartridge"), and the supply history and
/// alerts are keyed by them, so the name is turned into Spanish only where it is shown: "Black toner" reads "Tóner negro"
/// (the kind first, the colour after it, feminine after "tinta"). Any other name (most IPP and SNMP printers send their
/// own) stays as it is. A Mac difference: Windows turns only the names it wrote; here a printer's own English name in the
/// same words ("Black Toner") reads in Spanish too, as the two can't be told apart once read.
public enum SupplyNames {
    /// `english` as the interface shows it.
    public static func display(_ english: String) -> String {
        guard CoreLanguage.table != nil else { return english }
        if let whole = wholeName(english) { return whole }
        for kind in knownKinds {
            if english.caseInsensitiveCompare(kind) == .orderedSame { return capitalized(kindWord(kind)) }
            guard english.count > kind.count + 1, english.lowercased().hasSuffix(" " + kind) else { continue }
            let colorPart = String(english.dropLast(kind.count + 1))
            guard let color = colorWord(colorPart, feminine: feminine(kind)) else { return english }
            return capitalized(loc("{0} {1}", context: "supply color and kind", color, kindWord(kind)))
        }
        return english
    }

    /// The names Inkvolt Print writes whole: an SNMP supply without a description of its own (`PrinterMib.supplyName`)
    /// and the boxes LEDM and CDM name.
    private static func wholeName(_ english: String) -> String? {
        switch english {
        case "Toner": loc("Toner", context: "supply name")
        case "Matte toner": loc("Matte toner", context: "supply name")
        case "Waste toner box": loc("Waste toner box", context: "supply name")
        case "Ink": loc("Ink", context: "supply name")
        case "Matte ink": loc("Matte ink", context: "supply name")
        case "Ink ribbon": loc("Ink ribbon", context: "supply name")
        case "Waste ink box": loc("Waste ink box", context: "supply name")
        case "Drum": loc("Drum", context: "supply name")
        case "Developer": loc("Developer", context: "supply name")
        case "Fuser": loc("Fuser", context: "supply name")
        case "Cleaner unit": loc("Cleaner unit", context: "supply name")
        case "Transfer unit": loc("Transfer unit", context: "supply name")
        case "Staples": loc("Staples", context: "supply name")
        case "Supply": loc("Supply", context: "supply name")
        case "Maintenance box": loc("Maintenance box", context: "supply name")
        case "Printhead": loc("Printhead", context: "supply name")
        default: nil
        }
    }

    // The longest first: "ink cartridge" before "ink".
    private static let knownKinds = ["ink cartridge", "ink tank", "printhead", "toner", "drum", "supply", "ink"]

    private static func kindWord(_ kind: String) -> String {
        switch kind {
        case "toner": loc("toner", context: "supply kind")
        case "ink": loc("ink", context: "supply kind")
        case "ink cartridge": loc("ink cartridge", context: "supply kind")
        case "ink tank": loc("ink tank", context: "supply kind")
        case "printhead": loc("printhead", context: "supply kind")
        case "drum": loc("drum", context: "supply kind")
        case "supply": loc("supply", context: "supply kind")
        default: kind
        }
    }

    private static func colorWord(_ english: String, feminine: Bool) -> String? {
        switch english.lowercased() {
        case "black": feminine ? loc("Black", context: "supply color, feminine") : loc("Black", context: "supply color")
        case "cyan": loc("Cyan", context: "supply color")
        case "magenta": loc("Magenta", context: "supply color")
        case "yellow": feminine ? loc("Yellow", context: "supply color, feminine") : loc("Yellow", context: "supply color")
        case "tri-color": loc("Tri-color", context: "supply color")
        case "photo black": loc("Photo black", context: "supply color")
        case "matte black": loc("Matte black", context: "supply color")
        case "gray": loc("Gray", context: "supply color")
        default: nil
        }
    }

    /// Kinds whose word takes the feminine form of a colour in Spanish ("tinta negra").
    private static func feminine(_ kind: String) -> Bool { kind == "ink" }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
