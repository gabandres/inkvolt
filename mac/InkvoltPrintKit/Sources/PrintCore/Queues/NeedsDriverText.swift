import Foundation

/// Every word "Plugged in, needs its driver" shows (the Windows app's `NeedsDriverText`): the interface's through `loc`
/// (English and Spanish), the command line's, `status --all`'s and the report's in English. Never a serial: only the name,
/// the kind and the USB ids. Windows' sentences where the Mac says the same, "macOS" where Windows said "Windows".
public enum NeedsDriverText {
    /// The accessible name of the sidebar's list of them.
    public static var listName: String { loc("Printers and scanners that need their driver") }

    public static func listStatus(_ p: NeedsDriverPrinter) -> String {
        p.isScanner ? loc("Plugged in, needs its driver", context: "scanner") : loc("Plugged in, needs its driver", context: "printer")
    }

    /// The page's heading under the name.
    public static func headline(_ p: NeedsDriverPrinter) -> String {
        p.isScanner ? loc("macOS found this scanner but has no driver for it, so nothing can scan with it yet.")
            : loc("macOS found this printer but has no driver for it, so nothing can print to it yet.")
    }

    public static func whyMakersDriver(_ p: NeedsDriverPrinter) -> String {
        p.isScanner ? loc("Most scanners only work with their maker's driver: macOS has none of its own for them. Once it's installed, the scanner shows in the printer list and the Scan tab.")
            : loc("Some printers, often older USB lasers, only work with their maker's driver: macOS has no driver of its own for them, and Inkvolt Print can't print to them without one.")
    }

    public static var stepsTitle: String { loc("What to do") }

    public static func stepGetDriver(_ p: NeedsDriverPrinter) -> String {
        if let maker = p.maker, DriverHelp.hasDriverPage(maker) {
            return p.isScanner ? loc("Get the driver for the {0} from {1}'s website: choose your version of macOS.", context: "scanner", p.name, maker)
                : loc("Get the driver for the {0} from {1}'s website: choose your version of macOS.", context: "printer", p.name, maker)
        }
        return p.isScanner ? loc("Get the driver for the {0} from its maker's website: choose your version of macOS.", context: "scanner", p.name)
            : loc("Get the driver for the {0} from its maker's website: choose your version of macOS.", context: "printer", p.name)
    }

    public static func stepPlugIn(_ p: NeedsDriverPrinter) -> String {
        p.isScanner ? loc("Plug the scanner in.") : loc("Plug the printer in and switch it on.")
    }

    public static func stepInstall(_ p: NeedsDriverPrinter) -> String {
        p.isScanner ? loc("Run the driver's installer, then unplug the scanner and plug it back in. Inkvolt Print lists it by itself.")
            : loc("Run the driver's installer. Once macOS has set the printer up, Inkvolt Print lists it by itself.")
    }

    /// The Scan tab's line about a scanner plugged in that needs its driver.
    public static func scanTabLine(_ p: NeedsDriverPrinter) -> String { loc("{0} is plugged in, but macOS has no driver for it yet.", p.name) }

    public static func makerButton(_ p: NeedsDriverPrinter) -> String {
        if let maker = p.maker, DriverHelp.hasDriverPage(maker) { return loc("Open {0}'s driver page", maker) }
        return loc("Search the web for its driver")
    }

    public static var otherWaysTitle: String { loc("Other ways") }
    public static var printersButton: String { loc("Open Printers & Scanners") }
    public static var printersNote: String {
        loc("System Settings › Printers & Scanners, where macOS can add it with a driver it has, or offer one from Apple's Software Update.")
    }

    public static func demo(_ p: NeedsDriverPrinter) -> String {
        p.isScanner ? loc("Demo: a made-up scanner. Nothing is opened, downloaded or installed.")
            : loc("Demo: a made-up printer. Nothing is opened, installed or set up.")
    }

    // MARK: The command line, status --all and the report (English)

    public static let englishStatus = "plugged in, needs its driver"

    private static func englishKind(_ p: NeedsDriverPrinter) -> String { p.isScanner ? "scanner" : "printer" }

    /// "Epson Perfection V19 | USB 04B8:013C | maker Epson | plugged in, needs its driver".
    public static func line(_ p: NeedsDriverPrinter) -> String {
        "\(p.name) | USB\(p.usbId.map { " " + $0 } ?? "") | maker \(p.maker ?? "unknown") | \(englishKind(p)) | \(englishStatus)"
    }

    /// status --all's note: the printer list shows it, the fleet has nothing to read from it.
    public static func statusNote(_ p: NeedsDriverPrinter) -> String {
        "\(p.name) (USB): \(englishStatus), so it can't be \(p.isScanner ? "scanned with" : "read or printed to")."
    }

    /// The report's line: how many, and each one's name and kind.
    public static func reportLine(_ list: [NeedsDriverPrinter]) -> String {
        list.isEmpty ? "none" : "\(list.count): " + list.map { "\($0.name) (\(englishKind($0))), \(englishStatus)" }.joined(separator: ", ")
    }
}

/// Where to get a printer's driver, by its maker; a web search for the rest (the Windows app's `DriverHelp`).
public enum DriverHelp {
    static let pages: [String: String] = [
        "hp": "https://support.hp.com/drivers",
        "samsung": "https://support.hp.com/drivers", // Samsung's printers are HP's now
        "brother": "https://support.brother.com/",
        "lexmark": "https://support.lexmark.com/",
        "xerox": "https://www.support.xerox.com/",
        "epson": "https://epson.com/Support/sl/s",
        "canon": "https://www.usa.canon.com/support",
        "fujitsu": "https://www.pfu.ricoh.com/global/scanners/downloads/",
        "plustek": "https://plustek.com/us/support/",
        "visioneer": "https://www.visioneer.com/support/",
    ]

    public static func hasDriverPage(_ maker: String) -> Bool { pages[maker.lowercased()] != nil }

    /// The model's own support page when a lookup found one, else the maker's driver page, else a web search for
    /// "<model> driver".
    public static func page(for p: NeedsDriverPrinter, modelPage: URL? = nil) -> URL {
        if let modelPage { return modelPage }
        if let maker = p.maker, let page = pages[maker.lowercased()], let url = URL(string: page) { return url }
        var c = URLComponents(string: "https://www.bing.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(p.name) driver")]
        return c.url!
    }
}
