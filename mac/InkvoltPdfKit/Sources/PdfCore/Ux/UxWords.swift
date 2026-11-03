import Foundation

/// The words the Mac's dialogs and status show a person (UX review, round 2), kept here so they are tested: an error's
/// text without debug dumps, Go to Page's problem, the window's page-and-zoom subtitle, and the plain-words notes on
/// the menu commands whose names are jargon (the names themselves are the Windows app's, kept until both apps rename).
public enum ErrorWords {
    /// What to say when the system's words are a debug description, not a sentence for a person.
    public static let fallback = "Something unexpected stopped it. Try again; if it happens again, Help › Report a Problem… "
        + "collects what's needed to fix it."

    /// The error's own description, with the reason and the suggestion when the system has them; `fallback` when the
    /// description is Foundation's "The operation couldn't be completed. (Module.Type error 1.)" or a dump.
    public static func plain(description: String, reason: String? = nil, suggestion: String? = nil, isCocoa: Bool = false) -> String {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || isDump(text) { return [reason, suggestion].compactMap(clean).first.map { $0 } ?? fallback }
        var parts = [text]
        for extra in [reason, suggestion].compactMap(clean) where !text.localizedCaseInsensitiveContains(extra.trimmingCharacters(in: .punctuationCharacters)) {
            parts.append(extra)
        }
        return parts.joined(separator: " ")
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !isDump(t) else { return nil }
        return t
    }

    /// A description meant for a programmer: a type name in brackets, an error domain, a code, a struct dump.
    public static func isDump(_ text: String) -> Bool {
        let markers = ["Error Domain=", "error 0.)", "error 1.)", "error 2.)", "(PdfCore.", "UserInfo=", "Swift.", "NSUnderlyingError"]
        if markers.contains(where: text.contains) { return true }
        if text.range(of: #"^[A-Za-z]+Error(\(.*\))?$"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"couldn.t be completed\. \([^)]*error -?\d+\.\)"#, options: .regularExpression) != nil
    }
}

public enum GoToPageWords {
    /// The question's own words before anything is typed.
    public static let prompt = "Type a page number, or the page's label as the document shows it (such as iv)."

    /// Why `typed` went nowhere, and what to type instead.
    public static func problem(typed: String, pageCount: Int) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = pageCount == 1 ? "This document has 1 page." : "Type a page from 1 to \(pageCount)."
        return t.isEmpty ? range : "There's no page “\(t.prefix(20))”. \(range)"
    }
}

public enum WindowStatus {
    /// The document window's subtitle, as Preview's: "Page 2 of 14 · 125%", the zoom only when it isn't 100% (calm by
    /// default), and "Fit Width" or "Fit Page" when the zoom follows the window.
    public static func subtitle(page: Int, pageCount: Int, zoom: Double, fit: String? = nil) -> String {
        guard pageCount > 0 else { return "No pages" }
        let where_ = "Page \(min(max(page, 1), pageCount)) of \(pageCount)"
        if let fit { return "\(where_) · \(fit)" }
        let percent = Int((zoom * 100).rounded())
        return percent == 100 ? where_ : "\(where_) · \(percent)%"
    }
}

/// The commands whose names Mac users may stumble on, each with a plain note shown as the menu item's tooltip and the
/// command palette's subtitle; and the renames proposed to the owner (both apps rename together; not applied).
public enum PlainWords {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let note: String
        public let proposed: String
    }

    public static let entries: [Entry] = [
        Entry(name: "Save as PDF/A-2b…", note: "Saves a copy made to be kept for years: fonts and colors inside the file, nothing that can change.",
              proposed: "Save as Archive Copy (PDF/A)…"),
        Entry(name: "Save as PDF/A-2a (Accessible Archive)…", note: "An archive copy that also keeps the reading order and headings for screen readers.",
              proposed: "Save as Accessible Archive Copy (PDF/A)…"),
        Entry(name: "Flatten…", note: "Draws comments and form fields into the pages, so nobody can move or change them.",
              proposed: "Make Comments & Fields Permanent…"),
        Entry(name: "Sanitize Document…", note: "Removes what the file carries besides its pages: hidden text, attachments, scripts, authors and dates.",
              proposed: "Remove Hidden Information…"),
        Entry(name: "Review Suspect Words", note: "Words the text recognition wasn't sure of, to check against the scan.",
              proposed: "Check Uncertain Words"),
        Entry(name: "Calibrate Scale from a Known Length", note: "Draw along something whose real length you know, so measurements show real sizes.",
              proposed: "Set Scale from a Known Length…"),
    ]

    /// The note for a menu command's title, if it has one.
    public static func note(for title: String) -> String? { entries.first { $0.name == title }?.note }

    /// Words a note must never use: the jargon it explains.
    public static let jargon = ["PDF/A", "flatten", "sanitize", "OCR", "XMP", "metadata", "calibrate", "suspect"]
}

/// The sidebar's list text at the system's sidebar size (1 small, 2 medium, 3 large: AppKit's table row size, set by
/// System Settings › Appearance › Sidebar icon size, and by Accessibility › Display › Text size for app sidebars). Medium
/// is the size the comment list always had.
public enum SidebarText {
    public static func points(sizeMode: Int) -> (title: Double, detail: Double) {
        switch sizeMode {
        case ...1: (10, 10)
        case 2: (11, 11)
        default: (14, 13)
        }
    }
}

/// A value read from the file for Document Properties' read-only rows (creator, producer…): control characters and line
/// breaks made spaces, runs of spaces made one, cut to `maxLength` with "…" (a hostile file's 2 MB Producer made the
/// sheet taller than any screen, its buttons out of reach).
public enum PropertyText {
    public static let maxLength = 300

    public static func shown(_ value: String) -> String {
        var out = ""
        var space = false
        for ch in value {
            if out.count >= maxLength { return out.trimmingCharacters(in: .whitespaces) + "…" }
            if ch.isWhitespace || ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                space = !out.isEmpty
                continue
            }
            if space { out.append(" ") }
            space = false
            out.append(ch)
        }
        return out
    }
}

/// A number typed in a dialog's box ("12", "12,5", " 3.5 "): nil when it isn't one, or isn't finite. Swift's Double
/// reads "nan", "inf" and "1e999" too; one of those kept as Add Watermark's picture width crashed the dialog the next time
/// it opened (Int(inf)), and as a crop margin went into the file.
public enum TypedNumber {
    public static func parse(_ text: String) -> Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return v
    }
}

