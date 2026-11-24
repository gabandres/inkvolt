import Foundation

// `SplitAt` (what starts a new file in a batch scan) is a stored preset setting: Presets/ScanPreset.swift.

/// How a page came to be a separator: a patch code, a QR code or barcode saying PATCHT, a blank page, or marked in the review.
public enum SeparatorKind: String, Hashable, Sendable, Codable {
    case none, patchCode, blankPage, byHand, sheetBack, qrCode, barcode
}

/// A separator sheet found on a page: what kind, and for a patch code, which.
public struct SeparatorFound: Equatable, Sendable, Codable {
    public var kind: SeparatorKind
    public var code: PatchCode?

    public init(_ kind: SeparatorKind, code: PatchCode? = nil) {
        self.kind = kind
        self.code = code
    }

    public static let none = SeparatorFound(.none)

    public var isSeparator: Bool { kind != .none }

    /// A sheet printed to separate (a patch code, or a code saying PATCHT): in a two-sided scan its other side is part of it.
    public var isSheet: Bool { kind == .patchCode || kind == .qrCode || kind == .barcode }

    /// "Patch T sheet", "blank page", or "".
    public var description: String {
        switch kind {
        case .patchCode: loc("{0} sheet", context: "patch code", PatchCodes.name(code ?? .patchT))
        case .blankPage: loc("blank page")
        case .byHand: loc("marked by hand")
        case .sheetBack: loc("back of the patch sheet")
        case .qrCode: loc("QR code sheet")
        case .barcode: loc("barcode sheet")
        case .none: ""
        }
    }
}

/// Separator sheets: a page with a separating patch code (`PatchCodes`) or a code saying PATCHT (`SeparatorCodes`, read by
/// `codes`; split at patch codes, it finds both), or a blank page (`BlankPage`).
public enum Separators {
    /// - Parameter codes: reads QR codes and barcodes (Vision in the app); nil: patch codes only.
    public static func detect(_ img: GrayImage, pixelsPerInch: Double, splitAt: SplitAt, codes: (any SeparatorCodeReader)? = nil) -> SeparatorFound {
        if splitAt == .patchCode || splitAt == .patchCodeOrBlankPage {
            // An image-control patch (1, 4 or 6) separates nothing, whatever else is on its sheet.
            if let code = PatchCodes.find(img, pixelsPerInch: pixelsPerInch) {
                return PatchCodes.separates(code) ? SeparatorFound(.patchCode, code: code) : .none
            }
            if let kind = SeparatorCodes.find(img, reader: codes) { return SeparatorFound(kind) }
        }
        if splitAt == .blankPage || splitAt == .patchCodeOrBlankPage, BlankPage.isBlank(img) {
            return SeparatorFound(.blankPage)
        }
        return .none
    }

    public static func label(_ splitAt: SplitAt) -> String {
        switch splitAt {
        case .patchCode: loc("Patch or QR codes")
        case .blankPage: loc("Blank pages")
        case .patchCodeOrBlankPage: loc("Patch or QR codes, or blank pages")
        default: loc("Don't split")
        }
    }
}

/// A page of a batch as the split sees it.
public struct BatchPage: Equatable, Sendable {
    /// A separator sheet: a new file starts after it.
    public var separator: Bool
    /// Marked by hand: a new file starts with this page.
    public var startsFile: Bool
    /// Left out (a blank page when blank pages aren't separators).
    public var skipped: Bool

    public init(separator: Bool = false, startsFile: Bool = false, skipped: Bool = false) {
        self.separator = separator
        self.startsFile = startsFile
        self.skipped = skipped
    }
}

/// One feeder run split into files: a new file starts after each separator sheet and at each page marked by hand. Separators
/// are left out, or kept as the first page of the file they start (like a cover sheet; the ones after the last page end the
/// last file). Skipped pages are left out, and no file is made of separators alone, so separators at the start or end, or
/// several in a row (both sides of a sheet), never make an empty file.
public enum BatchSplit {
    /// The files, each as the indexes of its pages in order.
    public static func parts(_ pages: [BatchPage], keepSeparators: Bool) -> [[Int]] {
        var parts: [[Int]] = []
        var current: [Int] = []
        var hasContent = false
        var pending: [Int] = [] // kept separators waiting for the next page

        func close() {
            if !hasContent { return }
            parts.append(current)
            current = []
            hasContent = false
        }

        for (i, page) in pages.enumerated() {
            if page.separator {
                close()
                if keepSeparators { pending.append(i) }
                continue
            }
            if page.skipped { continue }
            if page.startsFile { close() }
            current += pending
            pending.removeAll()
            current.append(i)
            hasContent = true
        }
        close()
        if !pending.isEmpty && !parts.isEmpty { parts[parts.count - 1] += pending }
        return parts
    }

    /// A two-sided scan's pages come front, back, front, back…: the other side of each separator sheet (a patch code, or a
    /// code saying PATCHT: `SeparatorFound.isSheet`) belongs to the sheet.
    /// When the run has an even number of pages that order holds, so the other side is the sheet's whatever is on it (light
    /// through a thin sheet can make its back look printed); with an odd number (a scanner that dropped a side) only an other
    /// side that looks blank is taken. Returns the indexes to treat as separators too.
    /// - Parameters:
    ///   - patch: Each page is a separator sheet (`SeparatorFound.isSheet`).
    ///   - blank: Each page looks blank.
    public static func duplexSeparatorBacks(patch: [Bool], blank: [Bool]) -> [Int] {
        let paired = patch.count % 2 == 0
        var backs: [Int] = []
        for i in patch.indices where patch[i] {
            let other = i % 2 == 0 ? i + 1 : i - 1
            if other < patch.count && !patch[other] && (paired || blank[other]) && !backs.contains(other) { backs.append(other) }
        }
        return backs.sorted()
    }

    /// For each page, the file (1-based) it is the first page of; 0 for every other page.
    public static func fileStarts(_ pages: [BatchPage], keepSeparators: Bool) -> [Int] {
        var starts = [Int](repeating: 0, count: pages.count)
        for (p, part) in parts(pages, keepSeparators: keepSeparators).enumerated() { starts[part[0]] = p + 1 }
        return starts
    }
}
