import Foundation

/// A list can't be used; the message says why. `servers`: the other computers it reaches, when that is all it needs a yes for.
public struct BatchListError: Error, Equatable, Sendable {
    public var message: String
    public var servers: [String]

    public init(_ message: String, servers: [String] = []) {
        self.message = message
        self.servers = servers
    }

    /// It only needs the person's say-so to open files on other computers.
    public var needsNetwork: Bool { !servers.isEmpty }
}

/// A line of a list: a file or a folder (its printable files in the Finder's order), and how they print.
public struct BatchListEntry: Equatable, Sendable {
    public var path: String
    public var settings: BatchPrintSettings

    public init(_ path: String, _ settings: BatchPrintSettings) {
        self.path = path
        self.settings = settings
    }
}

/// A list line's path, checked: `full` nil and `why` when it's refused; `server` names the other computer it's on.
public struct BatchListPath: Equatable, Sendable {
    public var full: String?
    public var server: String?
    public var why: String?
}

/// A saved batch (roadmap 2.4, Pro; Windows' `BatchPrintList`): plain JSON a person or a script can write. Passwords are never
/// in it. A list is treated as something that may have come from anywhere: every path is checked before the disk or the
/// network is touched. Relative paths are from the list's own folder and stay below it; devices, web addresses and anything
/// but a PDF, a picture or a folder are refused; another computer's files need the person's say-so. A bad value (copies
/// 9999) refuses the list rather than being changed quietly. Nothing is ever printed by opening a list.
///
/// Mac differences: devices are /dev and /.vol; another computer is reached through the automounter (/net/<host>,
/// /Network/Servers/<host>), which connects to a host by its name alone, where Windows has \\server\share (a share already
/// mounted under /Volumes is this Mac's to open, as a mapped drive is the PC's); a colon is refused anywhere (macOS has no
/// drive letters; a colon is a web address or smb://); a backslash reads as a separator, so a list written on Windows with
/// relative paths reads here.
public enum BatchPrintList {
    public static let fileExtension = ".inkvoltlist"
    static let version = 1
    static let maxFileBytes = 4 << 20
    static let maxRange = 1000
    static let maxDepth = 8

    /// Writes the list whole or not at all: full paths, default values left out, no passwords (the entries don't carry any).
    public static func save(_ path: String, _ entries: [BatchListEntry]) throws {
        var files: [String] = []
        for e in entries {
            var fields = ["\"path\": \(quoted(e.path))"]
            if e.settings.copies != 1 { fields.append("\"copies\": \(e.settings.copies)") }
            if let range = e.settings.range, !range.trimmingCharacters(in: .whitespaces).isEmpty { fields.append("\"range\": \(quoted(range))") }
            if e.settings.twoSided { fields.append("\"twoSided\": true") }
            if let paper = e.settings.paper { fields.append("\"paper\": \(quoted(paper))") }
            files.append("    { " + fields.joined(separator: ", ") + " }")
        }
        let text = "{\n  \"version\": \(version),\n  \"files\": [\n" + files.joined(separator: ",\n") + (files.isEmpty ? "" : "\n") + "  ]\n}\n"
        try writeWhole(path, Data(text.utf8))
    }

    /// Reads a list. Only the list file itself is touched; each line's path is checked by words alone.
    /// - Parameter allowNetwork: files on other computers may be opened (the person said so).
    /// - Throws: `BatchListError`: it can't be used, and says why; `needsNetwork` when it only needs that say-so.
    public static func load(_ path: String, allowNetwork: Bool) throws -> [BatchListEntry] {
        let shown = BatchPrintText.clean(path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw BatchListError(loc("There is no list file {0}.", shown))
        }
        let bytes: [UInt8]
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            if size > maxFileBytes { throw BatchListError(loc("This list file is too large.")) }
            bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch let e as BatchListError {
            throw e
        } catch {
            throw BatchListError(loc("The list file can't be read: {0}", BatchPrintText.describe(error)))
        }
        if bytes.count > maxFileBytes { throw BatchListError(loc("This list file is too large.")) }
        guard let text = plainText(bytes) else { throw BatchListError(loc("This isn't a batch list, or it's damaged.")) }
        guard let json = Json.parse(Array(text.utf8), handWritten: true, maxDepth: maxDepth) else {
            throw BatchListError(loc("This isn't a batch list, or it's damaged."))
        }
        if json == .null { throw BatchListError(loc("This isn't a batch list: it's empty.")) }
        guard let root = json.objectValue.map(lowered) else { throw BatchListError(loc("This isn't a batch list, or it's damaged.")) }

        let fileVersion = try int(root["version"]) ?? 0
        let defaults = try object(root["defaults"])
        let lines = try array(root["files"])
        if fileVersion > version { throw BatchListError(loc("This list was made by a newer Inkvolt Print: update it to open the list.")) }
        guard fileVersion >= 1, let lines else { throw BatchListError(loc("This isn't a batch list: it says no version or no files.")) }
        if lines.count > BatchPrintLimits.maxFiles {
            throw BatchListError(loc("This list has {0} lines: a batch takes at most {1} files.", FleetPage.grouped(lines.count), FleetPage.grouped(BatchPrintLimits.maxFiles)))
        }
        let defaultCopies = try int(defaults?["copies"])
        let defaultTwoSided = try bool(defaults?["twosided"])
        let defaultPaper = try string(defaults?["paper"])

        let folder = (absolute(path) as NSString).deletingLastPathComponent
        var entries: [BatchListEntry] = []
        var servers: [String] = []
        for (n, raw) in lines.enumerated() {
            func refuse(_ why: String) -> BatchListError { BatchListError(loc("Line {0} of the list: {1}", n + 1, why)) }
            guard case .object(let members) = raw else {
                if raw == .null { throw refuse(loc("it has no path, or too long a one.")) }
                throw BatchListError(loc("This isn't a batch list, or it's damaged."))
            }
            let line = lowered(members)
            let checked = checkPath(try string(line["path"]), folder)
            guard let full = checked.full else { throw refuse(checked.why ?? loc("it has no path, or too long a one.")) }
            if let server = checked.server, !servers.contains(where: { $0.caseInsensitiveCompare(server) == .orderedSame }) { servers.append(server) }
            let copies = try int(line["copies"]) ?? defaultCopies ?? 1
            if copies < 1 || copies > BatchPrintLimits.maxCopies {
                throw refuse(loc("copies must be 1 to {0} ({1} asked for).", BatchPrintLimits.maxCopies, copies))
            }
            let range = try string(line["range"])
            if let range, range.count > maxRange { throw refuse(loc("its pages are too long a text.")) }
            let paper = try string(line["paper"]) ?? defaultPaper
            if let paper, paper.count > 200 { throw refuse(loc("its paper is too long a text.")) }
            let twoSided = try bool(line["twosided"]) ?? defaultTwoSided ?? false
            entries.append(BatchListEntry(full, BatchPrintSettings(copies: copies, range: range, twoSided: twoSided, paper: paper)))
        }
        if !servers.isEmpty && !allowNetwork {
            let sorted = servers.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            throw BatchListError(loc("This list points at files on other computers ({0}).", sorted.map(BatchPrintText.clean).joined(separator: ", ")), servers: sorted)
        }
        return entries
    }

    /// The list's lines as files: a folder's printable files in order with the line's settings. A line whose file isn't there
    /// stays, and reads as gone like a file that vanished after the estimate. Anything else that isn't a PDF or a picture
    /// refuses the list.
    /// - Throws: `BatchListError`: a line names something else, or there are too many files.
    public static func expand(_ entries: [BatchListEntry]) throws -> [BatchListEntry] {
        var files: [BatchListEntry] = []
        for entry in entries {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isFolder), isFolder.boolValue {
                files += BatchPrintFiles.listFolder(entry.path, recursive: false).map { BatchListEntry($0, entry.settings) }
            } else if BatchPrintFiles.isSupported(entry.path) {
                files.append(entry)
            } else {
                throw BatchListError(loc("The list names {0}, which is neither a PDF, a picture nor a folder.", BatchPrintText.clean(entry.path)))
            }
            if files.count > BatchPrintLimits.maxFiles {
                throw BatchListError(loc("This list comes to more than {0} files, the most a batch takes.", FleetPage.grouped(BatchPrintLimits.maxFiles)))
            }
        }
        return files
    }

    /// A line's path made full and checked without touching anything.
    public static func checkPath(_ raw: String?, _ listFolder: String) -> BatchListPath {
        func refuse(_ why: String) -> BatchListPath { BatchListPath(full: nil, server: nil, why: why) }
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty, raw.count <= 4000 else { return refuse(loc("it has no path, or too long a one.")) }
        let shown = BatchPrintText.clean(raw)
        if raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || "<>\"|?*".unicodeScalars.contains($0) }) {
            return refuse(loc("\"{0}\" isn't a path a list may use.", shown))
        }
        let slashed = raw.replacingOccurrences(of: "\\", with: "/")
        #if os(Windows)
        // The Windows PC that also runs PrintCore's tests: its temporary folder has a drive.
        let drive = slashed.count >= 3 && slashed.first!.isLetter && Array(slashed)[1] == ":" && Array(slashed)[2] == "/" ? String(slashed.prefix(2)) : nil
        #else
        let drive: String? = nil
        #endif
        let rest = drive.map { String(slashed.dropFirst($0.count)) } ?? slashed
        // A colon is a web address (http:, smb:), never a file on this Mac.
        if rest.contains(":") { return refuse(loc("\"{0}\" isn't a file on this Mac.", shown)) }
        // The shell's ~ isn't this Mac's home to a list.
        if rest.hasPrefix("~") { return refuse(loc("\"{0}\" isn't a full path, or one from the list's folder.", shown)) }
        let isFull = rest.hasPrefix("/")

        var parts: [Substring] = []
        var cleanAlready = true
        let pieces = rest.split(separator: "/", omittingEmptySubsequences: false)
        for (k, part) in pieces.enumerated() {
            if part.isEmpty {
                if k != 0 && k != pieces.count - 1 { cleanAlready = false }
                continue
            }
            if part == "." {
                cleanAlready = false
                continue
            }
            if part == ".." {
                cleanAlready = false
                if parts.isEmpty {
                    if !isFull { return refuse(loc("\"{0}\" leaves the list's folder: use a full path for that.", shown)) }
                    continue
                }
                parts.removeLast()
                continue
            }
            parts.append(part)
        }
        if parts.isEmpty { return refuse(loc("\"{0}\" isn't a path a list may use.", shown)) }
        let full: String
        if isFull {
            #if os(Windows)
            let keep = cleanAlready
            #else
            let keep = cleanAlready && !raw.contains("\\")
            #endif
            full = keep ? raw : (drive ?? "") + "/" + parts.joined(separator: "/")
        } else {
            let base = listFolder.hasSuffix("/") || listFolder.hasSuffix("\\") ? String(listFolder.dropLast()) : listFolder
            full = base + "/" + parts.joined(separator: "/")
        }

        if isFull && drive == nil {
            let first = parts[0].lowercased()
            if first == "dev" || first == ".vol" { return refuse(loc("\"{0}\" names a device.", shown)) }
            var server: Substring?
            if first == "net" { server = parts.count > 1 ? parts[1] : "" }
            if first == "network", parts.count > 1, parts[1].lowercased() == "servers" { server = parts.count > 2 ? parts[2] : "" }
            if let server {
                if server.isEmpty || parts.count < (first == "net" ? 3 : 4) { return refuse(loc("\"{0}\" isn't a file on this Mac.", shown)) }
                return BatchListPath(full: full, server: String(server), why: nil)
            }
        }
        return BatchListPath(full: full, server: nil, why: nil)
    }

    // ------------------------------------------------------------------ reading the JSON

    /// The list as plain UTF-8: a Windows tool writes a byte order mark, and Windows PowerShell's > writes UTF-16. Nil: it
    /// isn't text.
    static func plainText(_ bytes: [UInt8]) -> String? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(validating: bytes.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) { return utf16(bytes.dropFirst(2), littleEndian: true) }
        if bytes.starts(with: [0xFE, 0xFF]) { return utf16(bytes.dropFirst(2), littleEndian: false) }
        return String(validating: bytes, as: UTF8.self)
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        let b = Array(bytes)
        let units = stride(from: 0, to: b.count, by: 2).map { littleEndian ? UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 : UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
        return String(validating: units, as: UTF16.self)
    }

    /// Names as .NET's `PropertyNameCaseInsensitive` reads them; the first of two that differ only in case wins.
    private static func lowered(_ members: [String: Json]) -> [String: Json] {
        var out: [String: Json] = [:]
        for key in members.keys.sorted() where out[key.lowercased()] == nil { out[key.lowercased()] = members[key] }
        return out
    }

    private static var damaged: BatchListError { BatchListError(loc("This isn't a batch list, or it's damaged.")) }

    private static func int(_ v: Json?) throws -> Int? {
        switch v {
        case nil, .null?: return nil
        case .number(let n)?:
            guard let i = Int(n), i >= Int(Int32.min), i <= Int(Int32.max) else { throw damaged }
            return i
        default: throw damaged
        }
    }

    private static func bool(_ v: Json?) throws -> Bool? {
        switch v {
        case nil, .null?: return nil
        case .bool(let b)?: return b
        default: throw damaged
        }
    }

    private static func string(_ v: Json?) throws -> String? {
        switch v {
        case nil, .null?: return nil
        case .string(let s)?: return s
        default: throw damaged
        }
    }

    private static func object(_ v: Json?) throws -> [String: Json]? {
        switch v {
        case nil, .null?: return nil
        case .object(let o)?: return lowered(o)
        default: throw damaged
        }
    }

    private static func array(_ v: Json?) throws -> [Json]? {
        switch v {
        case nil, .null?: return nil
        case .array(let a)?: return a
        default: throw damaged
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for s in text.unicodeScalars {
            switch s {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if s.value < 0x20 { out += String(format: "\\u%04X", s.value) } else { out.unicodeScalars.append(s) }
            }
        }
        return out + "\""
    }

    static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Written beside the file and moved over it, so nobody reads half a list.
    static func writeWhole(_ path: String, _ data: Data) throws {
        let temp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: temp))
        do {
            if FileManager.default.fileExists(atPath: path) {
                #if canImport(Darwin)
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
                #else
                // The tests on the Windows PC: its Foundation has no replaceItemAt.
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: temp, toPath: path)
                #endif
            } else {
                try FileManager.default.moveItem(atPath: temp, toPath: path)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw error
        }
    }
}
