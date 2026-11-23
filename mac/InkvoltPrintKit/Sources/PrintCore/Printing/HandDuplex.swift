import Foundation

/// Which way up printed sheets land in a printer's output tray.
public enum OutputFace: String, Sendable, CaseIterable {
    /// Printed side down, the last sheet on top (most laser printers: the paper turns over on its way out).
    case down
    /// Printed side up, the last sheet on top (most inkjets with a tray at the back, a straight paper path).
    case up
}

/// What the person is told between the fronts and the backs (the app's words come from it).
public struct HandDuplexReload: Equatable, Sendable {
    /// Which way up the fronts came out, as the person confirmed or the printer said.
    public var face: OutputFace
    /// How many sheets the fronts printed on.
    public var sheets: Int
    /// The stack goes back turned over like a page (face up: the printed side has to face down in the tray); false: as it came
    /// out, without turning it over (face down).
    public var turnOver: Bool
    /// The last sheet has nothing on its back: it lies on top of the output stack and is set aside before the stack goes back,
    /// then put at the end of the finished stack.
    public var setAside: Bool
    /// Sheets in the stack whose back is blank (copies of an odd page count): they go through again with nothing printed.
    public var blankBacks: Int
    /// The number of the sheet set aside's page, for the words ("page 7"), or nil.
    public var lastPage: Int?

    public init(_ face: OutputFace, _ sheets: Int, turnOver: Bool, setAside: Bool, blankBacks: Int, lastPage: Int?) {
        self.face = face
        self.sheets = sheets
        self.turnOver = turnOver
        self.setAside = setAside
        self.blankBacks = blankBacks
        self.lastPage = lastPage
    }
}

/// Two-sided printing by hand (roadmap 4.2, print/GLOSSARY.md "two-sided by hand"; Windows' `HandDuplexPlan`): the sides of
/// each sheet, in reading order, as `fronts` to print first and `backs(_:)` to print once the stack is back in the tray. A
/// sheet's back is −1 when it has nothing on it. The backs' order depends on how the stack goes back (`OutputFace`): printed
/// face down, it goes back as it came out and the backs go last sheet first; face up, it's turned over like a page and they go
/// in order. The last sheet with no back is set aside rather than sent through blank, so a driver that drops a blank page
/// can't shift every back.
public struct HandDuplexPlan: Equatable, Sendable {
    /// Each sheet's front, first sheet first: what's printed first.
    public let fronts: [Int]
    /// Each sheet's back, first sheet first (−1: nothing on it).
    public let sheetBacks: [Int]
    /// The document's page number on each sheet's front (for "page 7"), as the caller numbers its sides.
    let sheetPages: [Int]

    public var sheets: Int { fronts.count }

    /// The last sheet has no back: it's set aside, not sent through.
    public var setAside: Bool { (sheetBacks.last ?? 0) < 0 }

    /// There's something to print on the backs at all (one page alone has none).
    public var hasBacks: Bool { sheetBacks.contains { $0 >= 0 } }

    /// The backs in the order the reloaded stack feeds them (−1: a blank pass for a sheet in the middle whose back is empty).
    public func backs(_ face: OutputFace) -> [Int] {
        let sent = setAside ? Array(sheetBacks.dropLast()) : sheetBacks
        return face == .down ? sent.reversed() : sent
    }

    public func reload(_ face: OutputFace) -> HandDuplexReload {
        HandDuplexReload(face, sheets, turnOver: face == .up, setAside: setAside, blankBacks: backs(face).filter { $0 < 0 }.count,
                         lastPage: setAside ? sheetPages.last : nil)
    }

    /// The plan for `order`, the sides of one copy in reading order (−1: a blank side), times `copies`: each copy starts on a
    /// sheet of its own (an odd copy ends on a blank back), so no two copies share a sheet. `pageNumber` gives the document's
    /// page number a side shows (pages 2, 4 and 6 printed: side 2 is page 6); by default the side plus one.
    public static func plan(_ order: [Int], copies: Int = 1, pageNumber: ((Int) -> Int)? = nil) -> HandDuplexPlan {
        let copies = max(1, min(copies, 999))
        let number = pageNumber ?? { $0 + 1 }
        var sequence: [Int] = []
        sequence.reserveCapacity(order.count * copies + copies)
        for _ in 0..<copies {
            sequence += order
            if order.count % 2 == 1 { sequence.append(-1) }
        }
        var fronts: [Int] = [], backs: [Int] = [], pages: [Int] = []
        for i in stride(from: 0, to: sequence.count, by: 2) {
            fronts.append(sequence[i])
            backs.append(i + 1 < sequence.count ? sequence[i + 1] : -1)
            pages.append(sequence[i] < 0 ? 0 : number(sequence[i]))
        }
        return HandDuplexPlan(fronts: fronts, sheetBacks: backs, sheetPages: pages)
    }
}

/// Whether to offer two-sided by hand, and which way up a printer delivers its sheets.
public enum HandDuplex {
    /// Two-sided by hand is offered where the printer (or its queue) said it can't print both sides: never while that isn't
    /// known yet, never beside the printer's own two-sided.
    public static func offered(_ printerTwoSided: Bool?) -> Bool { printerTwoSided == false }

    /// The face its sheets land: the default output tray's `pagedelivery` in `printer-output-tray` (PWG 5100.13) when it says
    /// `faceUp` or `faceDown`, else `output-bin-default` when it's `face-up` or `face-down` (RFC 8011's keywords); nil when it
    /// says neither (the app then asks with face down chosen, the common case). Values are the printer's: 16 trays and 1 KB
    /// each at most are looked at.
    public static func faceOf(_ outputBinDefault: String?, _ outputTrays: [String]) -> OutputFace? {
        let trays = outputTrays.prefix(16).filter { $0.utf16.count <= 1024 }.map(fields)
        let tray = trays.first { t in outputBinDefault.map { t["name"]?.lowercased() == $0.lowercased() } ?? false } ?? (trays.count == 1 ? trays[0] : nil)
        if let delivery = tray?["pagedelivery"]?.lowercased() {
            if delivery.hasPrefix("faceup") { return .up }
            if delivery.hasPrefix("facedown") { return .down }
        }
        switch outputBinDefault?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "face-up": return .up
        case "face-down": return .down
        default: return nil
        }
    }

    /// The face from a printer's Get-Printer-Attributes answer (`faceOf(_:_:)`).
    public static func faceOf(_ printer: IppResponse?) -> OutputFace? {
        guard let printer else { return nil }
        return faceOf(printer.str("output-bin-default"), printer.strs("printer-output-tray"))
    }

    /// A tray's `key=value;…` fields, keys without regard to case, the first of each kept; 32 fields at most.
    private static func fields(_ tray: String) -> [String: String] {
        var out: [String: String] = [:]
        for field in tray.split(separator: ";", omittingEmptySubsequences: true).prefix(32) {
            let kv = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            if out[key] == nil { out[key] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }
}
