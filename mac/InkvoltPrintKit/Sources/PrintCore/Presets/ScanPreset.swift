import Foundation

/// A stored setting with a few named values, kept as its number (as the Windows app stores them), so a value from a newer
/// version can't make the file unreadable; `isKnown` tells, and `ScanPresets.normalize` repairs it.
public protocol StoredChoice: RawRepresentable, Codable, Hashable, Sendable where RawValue == Int {
    static var known: [Self] { get }
}

extension StoredChoice {
    public var isKnown: Bool { Self.known.contains(self) }
}

/// Where a preset scans from. Auto: the feeder when it holds pages, else the glass.
public struct PresetSource: StoredChoice {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let auto = PresetSource(rawValue: 0), glass = PresetSource(rawValue: 1), feeder = PresetSource(rawValue: 2)
    public static let known = [auto, glass, feeder]
}

public struct PresetFileType: StoredChoice {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let pdf = PresetFileType(rawValue: 0), searchablePdf = PresetFileType(rawValue: 1), jpeg = PresetFileType(rawValue: 2)
    public static let known = [pdf, searchablePdf, jpeg]
}

/// The folder a preset saves into; sync folders (iCloud Drive, OneDrive, Dropbox) are `custom` paths.
public struct PresetFolder: StoredChoice {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let documents = PresetFolder(rawValue: 0), pictures = PresetFolder(rawValue: 1), custom = PresetFolder(rawValue: 2)
    public static let known = [documents, pictures, custom]
}

/// What happens once the file is saved.
public struct PresetAfter: StoredChoice {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let none = PresetAfter(rawValue: 0), openInInkvoltPdf = PresetAfter(rawValue: 1), print = PresetAfter(rawValue: 2),
        email = PresetAfter(rawValue: 3)
    public static let known = [none, openInInkvoltPdf, print, email]
}

/// Batch scanning: where one feeder run starts a new file.
public struct SplitAt: StoredChoice {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let none = SplitAt(rawValue: 0), patchCode = SplitAt(rawValue: 1), blankPage = SplitAt(rawValue: 2),
        patchCodeOrBlankPage = SplitAt(rawValue: 3)
    public static let known = [none, patchCode, blankPage, patchCodeOrBlankPage]
}

/// A named set of scan settings plus where the file goes and what it's called: one click scans and saves. Settings are
/// wishes, matched to each scanner when it runs (`PresetPlan`). Stored in the app's settings with the Windows app's field
/// names, so the two read each other's presets.
public struct ScanPreset: Equatable, Sendable, Codable {
    public var id = ""
    public var name = ""
    public var source = PresetSource.auto

    /// Both sides of each page, when the feeder is used and can.
    public var twoSided = false
    public var color = true
    public var resolution = 300

    /// `ScanChoices.pageSizes` key; nil = Letter or A4 by region.
    public var pageSize: String?
    public var fileType = PresetFileType.searchablePdf

    /// Stop on the scan review (turn, crop, reorder) before saving; off saves right away.
    public var review = false
    public var skipBlank = true
    public var straighten = true

    /// Batch scanning: one feeder run saved as several files, a new one at each separator sheet.
    public var splitAt = SplitAt.none

    /// Separator sheets stay in (as the first page of the file they start) instead of being left out.
    public var keepSeparators = false

    /// Several photos on the glass: each found and saved by itself, cut out straight (glass scans only).
    public var findPhotos = false
    public var folder = PresetFolder.documents

    /// The folder for `.custom`.
    public var folderPath: String?

    /// Template for a folder inside `folder` ("" = none), e.g. `Receipts/{date:yyyy}`.
    public var subfolder = ""

    /// File-name template (`FileNameTemplate`).
    public var fileName = ScanPresets.defaultFileName
    public var after = PresetAfter.none

    /// The next `{n}`; goes up by one with every scan saved with this preset (`ScanPresets.reserve`).
    public var nextNumber = 1

    /// Fields this version doesn't know (written by a newer one), kept as they were so saving doesn't drop them.
    public var unknown: [String: Json]?

    public init() {}

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let names = ["Id", "Name", "Source", "TwoSided", "Color", "Resolution", "PageSize", "FileType", "Review", "SkipBlank", "Straighten",
                                "SplitAt", "KeepSeparators", "FindPhotos", "Folder", "FolderPath", "Subfolder", "FileName", "After", "NextNumber"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func get<T: Decodable>(_ name: String, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: Key(name))) ?? fallback }
        id = get("Id", "")
        name = get("Name", "")
        source = get("Source", .auto)
        twoSided = get("TwoSided", false)
        color = get("Color", true)
        resolution = get("Resolution", 300)
        pageSize = get("PageSize", nil as String?)
        fileType = get("FileType", .searchablePdf)
        review = get("Review", false)
        skipBlank = get("SkipBlank", true)
        straighten = get("Straighten", true)
        splitAt = get("SplitAt", .none)
        keepSeparators = get("KeepSeparators", false)
        findPhotos = get("FindPhotos", false)
        folder = get("Folder", .documents)
        folderPath = get("FolderPath", nil as String?)
        subfolder = get("Subfolder", "")
        fileName = get("FileName", ScanPresets.defaultFileName)
        after = get("After", .none)
        nextNumber = get("NextNumber", 1)
        var extra: [String: Json] = [:]
        for key in c.allKeys where !Self.names.contains(key.stringValue) { extra[key.stringValue] = try c.decode(Json.self, forKey: key) }
        unknown = extra.isEmpty ? nil : extra
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: Key("Id"))
        try c.encode(name, forKey: Key("Name"))
        try c.encode(source, forKey: Key("Source"))
        try c.encode(twoSided, forKey: Key("TwoSided"))
        try c.encode(color, forKey: Key("Color"))
        try c.encode(resolution, forKey: Key("Resolution"))
        try c.encode(pageSize, forKey: Key("PageSize"))
        try c.encode(fileType, forKey: Key("FileType"))
        try c.encode(review, forKey: Key("Review"))
        try c.encode(skipBlank, forKey: Key("SkipBlank"))
        try c.encode(straighten, forKey: Key("Straighten"))
        try c.encode(splitAt, forKey: Key("SplitAt"))
        try c.encode(keepSeparators, forKey: Key("KeepSeparators"))
        try c.encode(findPhotos, forKey: Key("FindPhotos"))
        try c.encode(folder, forKey: Key("Folder"))
        try c.encode(folderPath, forKey: Key("FolderPath"))
        try c.encode(subfolder, forKey: Key("Subfolder"))
        try c.encode(fileName, forKey: Key("FileName"))
        try c.encode(after, forKey: Key("After"))
        try c.encode(nextNumber, forKey: Key("NextNumber"))
        for (key, value) in unknown ?? [:] { try c.encode(value, forKey: Key(key)) }
    }
}

/// The presets as stored: `version` says which shape the list was written in.
public struct ScanPresetSettings: Equatable, Sendable, Codable {
    public var version = ScanPresets.currentVersion
    public var items: [ScanPreset?]?

    /// Fields a newer version added, kept as they were.
    public var unknown: [String: Json]?

    public init(version: Int = ScanPresets.currentVersion, items: [ScanPreset?]? = nil) {
        self.version = version
        self.items = items
    }

    /// Written by a newer Inkvolt Print: usable, but this version doesn't write over it.
    public var isNewer: Bool { version > ScanPresets.currentVersion }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: Key("Version"))) ?? ScanPresets.currentVersion
        items = try c.decodeIfPresent([ScanPreset?].self, forKey: Key("Items"))
        var extra: [String: Json] = [:]
        for key in c.allKeys where key.stringValue != "Version" && key.stringValue != "Items" {
            extra[key.stringValue] = try c.decode(Json.self, forKey: key)
        }
        unknown = extra.isEmpty ? nil : extra
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(version, forKey: Key("Version"))
        try c.encodeIfPresent(items, forKey: Key("Items"))
        for (key, value) in unknown ?? [:] { try c.encode(value, forKey: Key(key)) }
    }
}

/// Built-in starters and the list operations the editor offers (create, duplicate, rename checks, reorder).
public enum ScanPresets {
    /// 1: the first shape. A file without presets (version 0, from before presets) gets the built-ins.
    public static let currentVersion = 1

    public static let defaultFileName = "{preset} {date} {time}"
    public static let maxNameLength = 60
    private static let maxResolution = 1200, minResolution = 75

    public static func builtIns() -> [ScanPreset] {
        var document = ScanPreset()
        document.id = "document"
        document.name = "Document to PDF"
        document.color = false
        document.subfolder = "Scans"
        document.fileName = "Document {date} {time}"

        var photo = ScanPreset()
        photo.id = "photo"
        photo.name = "Photo"
        photo.source = .glass
        photo.resolution = 600
        photo.pageSize = "full"
        photo.fileType = .jpeg
        photo.review = true
        photo.skipBlank = false
        photo.straighten = false
        photo.folder = .pictures
        photo.subfolder = "Scans"
        photo.fileName = "Photo {date} {time}"

        var receipt = ScanPreset()
        receipt.id = "receipt"
        receipt.name = "Receipt"
        receipt.source = .glass
        receipt.color = false
        receipt.pageSize = "full"
        receipt.subfolder = "Scans/Receipts/{date:yyyy}"
        receipt.fileName = "Receipt {date} {n:000}"
        return [document, photo, receipt]
    }

    /// The stored list made safe to use: nil or pre-preset settings get the built-ins (an emptied list stays empty);
    /// missing or repeated ids and names, unknown values (hand edits, newer versions) and out-of-range numbers are repaired.
    public static func normalize(_ stored: ScanPresetSettings?) -> [ScanPreset] {
        guard let stored, let items = stored.items, stored.version >= 1 else { return builtIns() }
        var list: [ScanPreset] = []
        var ids = Set<String>()
        for raw in items {
            guard var p = raw else { continue }
            if !isValidId(p.id) || ids.contains(p.id) { p.id = newId() }
            let trimmed = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            p.name = trimmed.isEmpty ? "Scan preset" : String(trimmed.prefix(maxNameLength))
            if !p.source.isKnown { p.source = .auto }
            if !p.fileType.isKnown { p.fileType = .pdf }
            if !p.after.isKnown { p.after = .none }
            if !p.splitAt.isKnown { p.splitAt = .none }
            let noCustomPath = p.folder == .custom && (p.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if !p.folder.isKnown || noCustomPath { p.folder = .documents }
            p.resolution = min(max(p.resolution, minResolution), maxResolution)
            if !ScanChoices.pageSizes.contains(where: { $0.key == p.pageSize }) { p.pageSize = nil }
            if p.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.fileName = defaultFileName }
            p.nextNumber = max(1, p.nextNumber)
            p.name = uniqueName(list.map(\.name), p.name)
            ids.insert(p.id)
            list.append(p)
        }
        return list
    }

    /// Ids go on a command line or into a URL unquoted: letters, digits and '-' only, at most 64.
    public static func isValidId(_ id: String?) -> Bool {
        guard let id, (1...64).contains(id.count) else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Takes the next `{n}` of preset `id` in `list` and moves its counter on, in one step, so two scans saved with one
    /// preset never get the same number. Nil when the preset isn't in the list.
    public static func reserve(_ list: inout [ScanPreset], _ id: String) -> Int? {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let n = list[i].nextNumber
        list[i].nextNumber = n + 1
        return n
    }

    /// The editor's list with each preset's counter as it is in `current` now (scans may have been saved while the editor
    /// was open); new presets keep theirs.
    public static func keepCounters(_ edited: [ScanPreset], _ current: [ScanPreset]) -> [ScanPreset] {
        var counters: [String: Int] = [:]
        for p in current where counters[p.id] == nil { counters[p.id] = p.nextNumber }
        return edited.map { p in
            var p = p
            if let n = counters[p.id] { p.nextNumber = n }
            return p
        }
    }

    public static func create(_ existing: [ScanPreset]) -> ScanPreset {
        var p = ScanPreset()
        p.id = newId()
        p.name = uniqueName(existing.map(\.name), "New preset")
        return p
    }

    /// A copy under a new id and name ("Receipt copy"), with its own counter.
    public static func duplicate(_ existing: [ScanPreset], _ preset: ScanPreset) -> ScanPreset {
        var p = preset
        p.id = newId()
        p.name = uniqueName(existing.map(\.name), "\(preset.name) copy")
        p.nextNumber = 1
        return p
    }

    /// Why `name` can't be the name of preset `id`; nil when it can.
    public static func nameProblem(_ existing: [ScanPreset], _ id: String, _ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return "Give the preset a name." }
        if trimmed.count > maxNameLength { return "Names can be up to \(maxNameLength) characters." }
        if let other = existing.first(where: { $0.id != id && $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "Another preset is already called \"\(other.name)\"."
        }
        return nil
    }

    /// Moves the item at `from` to `to`; false when either is out of range or they're equal.
    public static func move<T>(_ list: inout [T], from: Int, to: Int) -> Bool {
        guard from >= 0, to >= 0, from < list.count, to < list.count, from != to else { return false }
        let item = list.remove(at: from)
        list.insert(item, at: to)
        return true
    }

    /// `wanted`, else "wanted (2)", "wanted (3)"… (names compared without case).
    public static func uniqueName(_ existing: [String], _ wanted: String) -> String {
        let taken = Set(existing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        if !taken.contains(wanted.lowercased()) { return wanted }
        var i = 2
        while taken.contains("\(wanted) (\(i))".lowercased()) { i += 1 }
        return "\(wanted) (\(i))"
    }

    private static func newId() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)) }
}

/// Words for presets in the UI (button tooltips, the Overview's scan card, the editor's lists).
public enum ScanPresetText {
    public static func fileType(_ t: PresetFileType) -> String {
        switch t {
        case .searchablePdf: "Searchable PDF"
        case .jpeg: "JPEG images"
        default: "PDF"
        }
    }

    public static func source(_ s: PresetSource, twoSided: Bool) -> String {
        switch s {
        case .glass: "glass"
        case .feeder: twoSided ? "feeder, both sides" : "feeder"
        default: twoSided ? "feeder (both sides) or glass" : "feeder or glass"
        }
    }

    public static func after(_ a: PresetAfter) -> String {
        switch a {
        case .openInInkvoltPdf: "open in Inkvolt PDF"
        case .print: "print a copy"
        case .email: "email it"
        default: "nothing else"
        }
    }

    /// The folder as the user knows it: Documents, Pictures, or the chosen folder's name; then the subfolder template.
    public static func folder(_ p: ScanPreset) -> String {
        var root = "Documents"
        if p.folder == .pictures {
            root = "Pictures"
        } else if p.folder == .custom, let path = p.folderPath, !path.isEmpty {
            let leaf = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            root = leaf.isEmpty ? path : leaf
        }
        let sub = p.subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        return p.subfolder.trimmingCharacters(in: .whitespaces).isEmpty ? root : "\(root)/\(sub)"
    }

    /// "patch code sheet", "blank page", "patch code sheet or blank page".
    public static func splitText(_ s: SplitAt) -> String {
        switch s {
        case .blankPage: "blank page"
        case .patchCodeOrBlankPage: "patch code sheet or blank page"
        default: "patch code sheet"
        }
    }

    /// "Searchable PDF · feeder or glass · grey, 300 dpi · Documents/Scans", plus the review step and what happens after saving.
    public static func summary(_ p: ScanPreset) -> String {
        var parts = [fileType(p.fileType), source(p.source, twoSided: p.twoSided), "\(p.color ? "color" : "grey"), \(p.resolution) dpi", folder(p)]
        if p.splitAt != .none { parts.append("a new file at each \(splitText(p.splitAt))") }
        if p.findPhotos { parts.append("each photo on the glass by itself") }
        if p.review { parts.append("review first") }
        if p.after != .none { parts.append("then \(after(p.after))") }
        return parts.joined(separator: " · ")
    }
}
