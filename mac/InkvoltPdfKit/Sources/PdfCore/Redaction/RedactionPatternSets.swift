import CryptoKit
import Foundation
import PrintCore

/// A named set of what to look for, saved on this Mac.
public struct RedactionPatternSet: Equatable, Sendable {
    public var name: String
    public var options: RedactionPatternOptions
    /// The file it was read from (nil: not saved yet), which Delete removes whatever it is called.
    public var path: String?

    public init(_ name: String, _ options: RedactionPatternOptions, path: String? = nil) {
        self.name = name
        self.options = options
        self.path = path
    }
}

/// A saved pattern set can't be read; the message says why in plain words.
public struct RedactionPatternSetError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// Saved pattern sets (the Windows Core's `RedactionPatternSets`): one small JSON file per set in a folder on this Mac, in
/// the same format as Windows' (a set copied from a PC reads here). Nothing but the app reads them, but anything can write
/// them, so reading is strict and all or nothing: a set with a kind this version doesn't know, a wrong type, too many or
/// too long phrases or a pattern that doesn't compile is refused with a reason, never half used (half a set would look like
/// a search that found nothing). The words in a set are the person's own and stay as plain text on this Mac. The pattern
/// is ICU's syntax here and .NET's on Windows: one written on the other platform can read differently, or be refused.
public enum RedactionPatternSets {
    public static let version = 1
    public static let format = "Inkvolt PDF redaction patterns"
    public static let ext = ".json"
    /// Largest set file read, and the longest name kept.
    public static let maxBytes = 2 << 20, maxNameLength = 80
    /// Most sets listed: a folder filled by something else mustn't stall the dialog.
    static let maxListed = 500

    private static let words = ["socialSecurity", "phone", "email", "paymentCard", "date", "iban", "ipAddress", "zipCode"]
    private static let kinds: [RedactionPattern] = [.socialSecurity, .phone, .email, .paymentCard, .date, .iban, .ipAddress, .zipCode]

    /// Where the app keeps them: Application Support/Inkvolt PDF/Redaction patterns.
    public static var defaultFolder: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Inkvolt PDF/Redaction patterns").path
    }

    /// A set's name as shown: no control or invisible characters, not over-long.
    public static func cleanName(_ name: String) -> String {
        RedactionPatterns.displayable(name, maxNameLength).trimmingCharacters(in: .whitespaces)
    }

    /// A file name for a set: letters, digits, spaces, dashes and underscores from its name, never a device name or a path;
    /// a hash of the name is added when anything had to go, so two names don't land on one file.
    public static func fileName(_ name: String) -> String {
        let clean = cleanName(name)
        var safe = String(String.UnicodeScalarView(clean.unicodeScalars.map { c -> Unicode.Scalar in
            c.properties.isAlphabetic || c.properties.numericType == .decimal || c == " " || c == "-" || c == "_" ? c : "_"
        }))
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if safe.unicodeScalars.count > 60 {
            safe = String(String.UnicodeScalarView(safe.unicodeScalars.prefix(60)))
            while let last = safe.last, last == " " || last == "." { safe.removeLast() }
        }
        let device = ReservedFileNames.isDevice(safe + ext)
        if safe != clean || safe.isEmpty || device {
            let hash = SHA256.hash(data: Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
            safe = "\(safe.isEmpty || device ? "set" : safe) \(hash)"
        }
        return safe + ext
    }

    /// The sets in `folder` by name, and the files that couldn't be read with the reason for each.
    public static func list(_ folder: String) -> (sets: [RedactionPatternSet], problems: [String]) {
        var sets: [RedactionPatternSet] = []
        var problems: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return ([], []) }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: folder).filter { $0.lowercased().hasSuffix(ext) }
        } catch {
            return ([], [loc("The saved sets can't be read: {0}", error.localizedDescription)])
        }
        for name in names.sorted(by: { $0.lowercased() < $1.lowercased() }).prefix(maxListed) {
            do {
                sets.append(try load((folder as NSString).appendingPathComponent(name)))
            } catch let e as RedactionPatternSetError {
                problems.append(e.message)
            } catch {
                problems.append(loc("The saved set {0} can't be read: {1}", name, error.localizedDescription))
            }
        }
        sets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (sets, problems)
    }

    /// - Throws: `RedactionPatternSetError`: the file can't be read, or isn't a set this version can use whole.
    public static func load(_ path: String) throws -> RedactionPatternSet {
        let name = (path as NSString).lastPathComponent
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw RedactionPatternSetError(message: loc("The saved set {0} isn't there any more.", name)) }
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes { throw RedactionPatternSetError(message: loc("{0} is too large to be a saved set.", name)) }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw RedactionPatternSetError(message: loc("The saved set {0} can't be read: {1}", name, error.localizedDescription))
        }
        if data.count > maxBytes { throw RedactionPatternSetError(message: loc("{0} is too large to be a saved set.", name)) }
        guard let json = String(data: data, encoding: .utf8) else {
            throw RedactionPatternSetError(message: loc("The saved set {0} can't be used: it holds text that can't be read.", name))
        }
        var set = try read(json, name)
        set.path = path
        return set
    }

    /// Saves a set whole (through a temporary file), in place of one with the same name; returns the file written.
    /// - Throws: `RedactionPatternSetError` when the set isn't valid or its name is empty; the file system's errors.
    @discardableResult
    public static func save(_ set: RedactionPatternSet, _ folder: String) throws -> String {
        let name = cleanName(set.name)
        if name.isEmpty { throw RedactionPatternSetError(message: loc("Name the set.")) }
        if let problem = RedactionPatterns.validate(set.options) { throw RedactionPatternSetError(message: problem) }
        if set.options.isEmpty { throw RedactionPatternSetError(message: loc("Choose something to look for first.")) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(fileName(name))
        let temp = path + ".\(UUID().uuidString).tmp"
        defer { try? fm.removeItem(atPath: temp) }
        try Data(write(RedactionPatternSet(name, set.options)).utf8).write(to: URL(fileURLWithPath: temp))
        if fm.fileExists(atPath: path) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
        } else {
            try fm.moveItem(atPath: temp, toPath: path)
        }
        return path
    }

    public static func delete(_ name: String, _ folder: String) {
        try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(fileName(name)))
    }

    /// Deletes the file `set` was read from (a set copied in under another file name too).
    /// - Throws: the file system's error when it can't be removed.
    public static func delete(_ set: RedactionPatternSet) throws {
        guard let path = set.path else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    /// The set as its file holds it: pretty-printed JSON, keys in a fixed order, as Windows writes it.
    public static func write(_ set: RedactionPatternSet) -> String {
        let o = set.options
        func string(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            let text = String(decoding: data, as: UTF8.self)
            return String(text.dropFirst().dropLast())
        }
        func array(_ items: [String]) -> String {
            items.isEmpty ? "[]" : "[\n" + items.map { "    " + string($0) }.joined(separator: ",\n") + "\n  ]"
        }
        let kindWords = zip(kinds, words).filter { o.patterns.contains($0.0) }.map(\.1)
        let expression = (o.expression ?? "").isEmpty ? "null" : string(o.expression!)
        return """
        {
          "format": \(string(format)),
          "version": \(version),
          "name": \(string(set.name)),
          "kinds": \(array(kindWords)),
          "phrases": \(array(o.phrases)),
          "wholeWord": \(o.wholeWord),
          "matchCase": \(o.matchCase),
          "expression": \(expression)
        }

        """
    }

    /// A JSON value as read, its kinds kept apart (a number is never a true or false, nor the other way round).
    private indirect enum Json: Decodable {
        case null, bool(Bool), number(Double), string(String), array([Json]), object([String: Json])

        init(from decoder: Decoder) throws {
            if var list = try? decoder.unkeyedContainer() {
                var items: [Json] = []
                while !list.isAtEnd { items.append(try list.decode(Json.self)) }
                self = .array(items)
                return
            }
            if let keyed = try? decoder.container(keyedBy: Key.self) {
                var map: [String: Json] = [:]
                for k in keyed.allKeys { map[k.stringValue] = try keyed.decode(Json.self, forKey: k) }
                self = .object(map)
                return
            }
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let b = try? single.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? single.decode(Double.self) {
                self = .number(n)
            } else {
                self = .string(try single.decode(String.self))
            }
        }

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// Deepest nesting read (Windows' `MaxDepth`).
    static let maxDepth = 8

    /// How deep `json`'s arrays and objects nest, strings skipped.
    private static func depth(_ json: String) -> Int {
        var (depth, deepest, inString, escaped) = (0, 0, false, false)
        for u in json.utf16 {
            if inString {
                if escaped { escaped = false } else if u == 92 { escaped = true } else if u == 34 { inString = false }
                continue
            }
            switch u {
            case 34: inString = true
            case 91, 123:
                depth += 1
                deepest = max(deepest, depth)
            case 93, 125: depth -= 1
            default: break
            }
        }
        return deepest
    }

    /// Half a surrogate pair written as an escape ("\uD800" alone): JSON lets it through, and it isn't text.
    private static func hasLoneSurrogate(_ json: String) -> Bool {
        let u = Array(json.utf16)
        func escape(_ at: Int) -> UInt16? {
            guard at + 5 < u.count, u[at] == 92, u[at + 1] == 117 else { return nil } // \u
            return UInt16(String(decoding: u[(at + 2)...(at + 5)], as: UTF16.self), radix: 16)
        }
        var i = 0
        while i < u.count {
            if u[i] == 92, i + 1 < u.count, u[i + 1] != 117 {
                i += 2 // another escape (\\ \" ...): its second character isn't the start of one
                continue
            }
            if let v = escape(i) {
                if (0xD800...0xDBFF).contains(v) {
                    guard let low = escape(i + 6), (0xDC00...0xDFFF).contains(low) else { return true }
                    i += 12
                    continue
                }
                if (0xDC00...0xDFFF).contains(v) { return true }
                i += 6
                continue
            }
            i += 1
        }
        return false
    }

    /// - Throws: `RedactionPatternSetError` when it isn't a set this version can use whole.
    public static func read(_ json: String, _ fileName: String) throws -> RedactionPatternSet {
        func bad(_ why: String) -> RedactionPatternSetError { RedactionPatternSetError(message: loc("The saved set {0} can't be used: {1}", fileName, why)) }
        if hasLoneSurrogate(json) { throw RedactionPatternSetError(message: loc("The saved set {0} can't be used: it holds text that can't be read.", fileName)) }
        let parsed: Json
        do {
            // A set is two levels deep; a file nested thousands deep is refused before any parser recurses into it.
            if depth(json) > maxDepth { throw CocoaError(.coderReadCorrupt) }
            parsed = try JSONDecoder().decode(Json.self, from: Data(json.utf8))
        } catch {
            throw RedactionPatternSetError(message: loc("The saved set {0} can't be used: it isn't valid JSON.", fileName))
        }
        guard case .object(let root) = parsed else { throw bad(loc("it isn't a set.")) }
        func text(_ key: String, required: Bool) throws -> String {
            guard let e = root[key], !isNull(e) else {
                if required { throw bad(loc("\"{0}\" is missing.", key)) }
                return ""
            }
            guard case .string(let s) = e else { throw bad(loc("\"{0}\" should be text.", key)) }
            return s
        }
        func flag(_ key: String, _ otherwise: Bool) throws -> Bool {
            guard let e = root[key] else { return otherwise }
            guard case .bool(let b) = e else { throw bad(loc("\"{0}\" should be true or false.", key)) }
            return b
        }
        func list(_ key: String) throws -> [String] {
            guard let e = root[key] else { return [] }
            guard case .array(let items) = e else { throw bad(loc("\"{0}\" should be a list.", key)) }
            if items.count > RedactionPatterns.maxPhrases { throw bad(loc("\"{0}\" has too many items.", key)) }
            return try items.map { item in
                guard case .string(let s) = item else { throw bad(loc("\"{0}\" should list text.", key)) }
                return s
            }
        }

        if try text("format", required: true) != format { throw bad(loc("it isn't a set of redaction patterns.")) }
        guard case .number(let v)? = root["version"], v.isFinite, v == v.rounded(), v >= 1, v <= Double(Int32.max) else {
            throw bad(loc("its version is missing."))
        }
        if Int(v) > version { throw bad(loc("it comes from a newer version of Inkvolt PDF.")) }

        let name = cleanName(try text("name", required: true))
        if name.isEmpty { throw bad(loc("it has no name.")) }
        var found = Set<RedactionPattern>()
        for word in try list("kinds") {
            guard let i = words.firstIndex(of: word) else {
                throw bad(loc("it asks for a kind this version doesn't know ({0}).", RedactionPatterns.displayable(word, 40)))
            }
            found.insert(kinds[i])
        }
        let expression = try text("expression", required: false)
        let options = RedactionPatternOptions(patterns: found, phrases: try list("phrases"), wholeWord: try flag("wholeWord", true),
                                              matchCase: try flag("matchCase", false), expression: expression.isEmpty ? nil : expression, setName: name)
        if let problem = RedactionPatterns.validate(options) { throw bad(problem) }
        if options.isEmpty { throw bad(loc("it has nothing to look for.")) }
        return RedactionPatternSet(name, options)
    }

    private static func isNull(_ j: Json) -> Bool {
        if case .null = j { return true }
        return false
    }
}
