import Foundation

/// One save of scanned pages (roadmap 4.15; Windows' `RecentScan`): the files it wrote (one PDF, a set of JPEGs, a batch's
/// PDFs, a Word or text file), when, how many pages, and the printer and preset it came from. Kept on this Mac only, in the
/// app's state; nothing is sent.
public struct RecentScan: Equatable, Sendable, Codable {
    /// Full paths, the first being the one named in the list.
    public var files: [String]
    public var savedAt: Date
    public var pages: Int
    /// The scanner's name as the list showed it, or nil.
    public var printer: String?
    /// The preset it was saved with, or nil for Save….
    public var preset: String?
    /// Mac only: an app-scoped security bookmark of the folder the files were saved in (or of the one file a save panel
    /// named), the sandbox's way back to them in a later run. Nil where none could be made (the demo, a test).
    public var access: Data?

    public init(files: [String], savedAt: Date, pages: Int, printer: String? = nil, preset: String? = nil, access: Data? = nil) {
        self.files = files
        self.savedAt = savedAt
        self.pages = pages
        self.printer = printer
        self.preset = preset
        self.access = access
    }

    public init(from decoder: any Decoder) throws {
        // As read from the state file: a missing or mistyped field is left out, and `RecentScans.clean` judges what's left.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = (try? c.decodeIfPresent([String].self, forKey: .files)) ?? []
        savedAt = (try? c.decodeIfPresent(Date.self, forKey: .savedAt)) ?? Date(timeIntervalSince1970: 0)
        pages = (try? c.decodeIfPresent(Int.self, forKey: .pages)) ?? 0
        printer = try? c.decodeIfPresent(String.self, forKey: .printer)
        preset = try? c.decodeIfPresent(String.self, forKey: .preset)
        access = try? c.decodeIfPresent(Data.self, forKey: .access)
    }

    /// Every file is a PDF: Print prints it as one (several, one after another); else the pictures go to Print photos.
    public var isPdf: Bool { !files.isEmpty && files.allSatisfy { RecentScans.fileExtension($0) == ".pdf" } }

    /// The first file's name, for the list.
    public var name: String { RecentScans.fileName(files.first ?? "") }
}

/// Which day a scan was saved, as the list says it.
public enum RecentScanDay: Sendable { case today, yesterday, earlier }

/// The list of recent scans (print/GLOSSARY.md, "recent scans"): the last `max` saves, newest first. A file saved again moves
/// its entry to the top rather than listing it twice; an entry whose files are all gone (deleted, moved, a disk away) drops
/// out when the list is shown. What's read back from the state file is hostile input: entries, files, paths, names and
/// bookmarks are bounded, and a path that isn't a plain full path (relative, a device, a web address) is left out.
/// Paths compare without regard to case (APFS's and HFS+'s default, as Windows' NTFS).
public enum RecentScans {
    /// Entries kept.
    public static let max = 20
    /// Files kept per entry (a batch of many files keeps its first ones).
    public static let maxFiles = 100
    public static let maxPath = 1024, maxText = 128, maxPages = 100_000
    /// Mac only: a bookmark's size at most (one is about a kilobyte).
    public static let maxAccess = 16 * 1024

    /// The kinds of file a scan saves. Open hands a file to Finder, so an entry naming anything else (an app or script planted
    /// in the state file) is left out rather than opened.
    public static let extensions: [String] = [".pdf", ".jpg", ".jpeg", ".docx", ".txt"]

    /// `scan` at the top: any entry sharing one of its files goes (saved again), and the oldest past `max`.
    public static func add(_ list: [RecentScan]?, _ scan: RecentScan) -> [RecentScan] {
        guard let clean = clean(scan) else { return Self.clean(list) }
        let files = Set(clean.files.map(key))
        return [clean] + Self.clean(list).filter { !$0.files.contains { files.contains(key($0)) } }.prefix(max - 1)
    }

    /// The list as read from the state file: nils and unusable entries out, each bounded, at most `max`.
    public static func clean(_ stored: [RecentScan?]?) -> [RecentScan] {
        guard let stored else { return [] }
        return Array(stored.prefix(max * 4).compactMap(clean).prefix(max))
    }

    public static func clean(_ stored: [RecentScan]?) -> [RecentScan] { clean(stored?.map { Optional($0) }) }

    /// Each entry with only the files still there (asked through `exists`); an entry with none left drops out. A check that
    /// throws counts as gone.
    public static func present(_ list: [RecentScan], _ exists: (String) throws -> Bool) -> [RecentScan] {
        list.compactMap { r in
            var r = r
            r.files = r.files.filter { (try? exists($0)) ?? false }
            return r.files.isEmpty ? nil : r
        }
    }

    /// The list without `scan` (matched by its first file).
    public static func remove(_ list: [RecentScan], _ scan: RecentScan) -> [RecentScan] {
        let first = scan.files.first.map(key)
        return list.filter { $0.files.first.map(key) != first }
    }

    public static func day(_ savedAt: Date, now: Date, calendar: Calendar = .current) -> RecentScanDay {
        let (day, today) = (calendar.startOfDay(for: savedAt), calendar.startOfDay(for: now))
        if day == today { return .today }
        return calendar.date(byAdding: .day, value: -1, to: today) == day ? .yesterday : .earlier
    }

    /// A usable entry, bounded, or nil.
    static func clean(_ scan: RecentScan?) -> RecentScan? {
        guard let scan else { return nil }
        var seen = Set<String>()
        let files = Array(scan.files.prefix(maxFiles * 4).filter { usable($0) && seen.insert(key($0)).inserted }.prefix(maxFiles))
        if files.isEmpty { return nil }
        let access = scan.access.flatMap { $0.isEmpty || $0.count > maxAccess ? nil : $0 }
        return RecentScan(files: files, savedAt: scan.savedAt, pages: Swift.max(0, Swift.min(scan.pages, maxPages)),
                          printer: text(scan.printer), preset: text(scan.preset), access: access)
    }

    /// A full path (`/Users/…`, `/Volumes/…`) to one of a scan's kinds of file: not relative, not a device, not a web address,
    /// no `.` or `..` part, no control character, not too long.
    static func usable(_ path: String?) -> Bool {
        guard let path, path.hasPrefix("/"), path.utf8.count <= maxPath else { return false }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        if path.hasPrefix("/dev/") || path.contains("://") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return false }
        let name = fileName(path)
        return !name.isEmpty && extensions.contains(fileExtension(path))
    }

    /// The last part of a path.
    static func fileName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The name's extension with its dot, lower case ("" when there is none), as .NET's `Path.GetExtension`.
    public static func fileExtension(_ path: String) -> String {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[dot...]).lowercased()
    }

    private static func key(_ path: String) -> String { path.lowercased() }

    private static func text(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.generalCategory.isControl }))
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }
        return line.count > maxText ? String(line.prefix(maxText)) : line
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool { self == .control }
}
