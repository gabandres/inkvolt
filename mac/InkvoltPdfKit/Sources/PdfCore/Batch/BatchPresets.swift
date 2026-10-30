import Foundation

/// A saved batch: its actions, in order, and how the results are saved (the Windows app's `BatchPreset`).
public struct BatchPreset: Sendable {
    public var name: String
    public var steps: [BatchStep]
    /// Where the results go; nil: chosen when it runs (the Batch window's folder, `--out`, a watched folder's "results").
    public var outputFolder: String?
    public var nameTemplate = BatchNames.defaultTemplate
    public var neverOverwrite = true
    public var keepSubfolders = true
    public var signedFiles = SignedFilePolicy.skip
    public var passwords = PasswordPolicy.ask
    public var imagePageSize = PageSizeOption.fitImage

    public init(name: String, steps: [BatchStep], outputFolder: String? = nil) {
        self.name = name
        self.steps = steps
        self.outputFolder = outputFolder
    }

    /// The preset of a plan (its output folder kept or not).
    public static func from(_ name: String, _ plan: BatchPlan, keepFolder: Bool) -> BatchPreset {
        var p = BatchPreset(name: name, steps: plan.steps)
        p.outputFolder = keepFolder && !plan.outputFolder.trimmingCharacters(in: .whitespaces).isEmpty && plan.outputFolder.hasPrefix("/") ? plan.outputFolder : nil
        p.nameTemplate = plan.nameTemplate
        p.neverOverwrite = plan.neverOverwrite
        p.keepSubfolders = plan.keepSubfolders
        p.signedFiles = plan.signedFiles
        p.passwords = plan.passwords
        p.imagePageSize = plan.imagePageSize
        return p
    }

    /// A plan that runs the preset now, its results in `outputFolder`.
    public func toPlan(_ outputFolder: String) -> BatchPlan {
        var plan = BatchPlan(steps: steps, outputFolder: outputFolder)
        plan.nameTemplate = nameTemplate
        plan.neverOverwrite = neverOverwrite
        plan.keepSubfolders = keepSubfolders
        plan.signedFiles = signedFiles
        plan.passwords = passwords
        plan.imagePageSize = imagePageSize
        plan.date = Date()
        return plan
    }
}

/// A preset can't be read; the message says why in words (and where: the action, the setting).
public struct BatchPresetError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Batch presets as plain JSON files (the Windows app's `BatchPresets`), readable and diffable: a format marker, a
/// version, the name, the output settings, then the actions in order, each with every setting written out (fields always
/// in the same order, enum values as camelCase words, colors as #RRGGBB, a watermark picture as base64 PNG). Passwords are
/// never written: a Protect action keeps only which passwords it sets, and they are given when it runs. Reading is
/// strict, so a mistake made by hand is named rather than silently ignored (an unknown action or setting, a wrong type, a
/// value out of range), but settings left out take their defaults. A preset from a newer version is refused with a clear
/// message rather than half-read. The text written is byte for byte what the Windows app writes, so a preset moves
/// between the two. Version history: 1 (Inkvolt PDF 1.1, roadmap 1.2).
public enum BatchPresets {
    public static let version = 1
    public static let format = "Inkvolt PDF batch preset"
    public static let fileExtension = ".json"
    /// Largest preset file read (a watermark picture makes the biggest ones).
    public static let maxBytes = 32 << 20

    // ───────────────────────────── files ─────────────────────────────

    /// Reads a preset file; its name (without extension) names a preset that has none.
    /// - Throws: `BatchPresetError` when the file can't be read or isn't a preset this version knows.
    public static func load(_ path: String) throws -> BatchPreset {
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        guard fm.fileExists(atPath: path) else { throw BatchPresetError("There is no preset file at \(path).") }
        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int), size > maxBytes { throw BatchPresetError("\(name) is too large to be a batch preset.") }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw BatchPresetError("The preset \(name) can't be read: \(error.localizedDescription)")
        }
        guard let json = String(data: data, encoding: .utf8) else { throw BatchPresetError("This isn't a batch preset: it isn't valid JSON (it isn't UTF-8 text).") }
        return try read(json, fallbackName: (name as NSString).deletingPathExtension)
    }

    /// Writes a preset file whole (through a temporary file, so a reader never sees half of it).
    public static func save(_ preset: BatchPreset, _ path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temp = path + ".\(NewIds.hex()).tmp"
        defer { try? fm.removeItem(atPath: temp) }
        try write(preset).write(toFile: temp, atomically: false, encoding: .utf8)
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        try fm.moveItem(atPath: temp, toPath: path)
    }

    /// A file name for a preset called `name` ("Scans to archive.json").
    public static func fileName(_ name: String) -> String {
        BatchNames.expand(name.replacingOccurrences(of: "<<", with: "").replacingOccurrences(of: ">>", with: ""), "preset", 1, Date()) + fileExtension
    }

    /// The steps with the Protect action's wanted passwords given (`open`, `permissions`); a wanted password that is nil
    /// or empty stays wanted, and then `BatchPlan.validate` says so.
    public static func withPasswords(_ steps: [BatchStep], open: String?, permissions: String?) -> [BatchStep] {
        steps.map { s in
            guard case .protect(var p) = s else { return s }
            if p.userPassword == "", let open, !open.isEmpty { p.userPassword = open }
            if p.ownerPassword == "", let permissions, !permissions.isEmpty { p.ownerPassword = permissions }
            return .protect(p)
        }
    }

    // ───────────────────────────── writing ─────────────────────────────

    /// The preset as JSON (UTF-8 text, two-space indents, "\n" line ends, no passwords).
    public static func write(_ preset: BatchPreset) -> String {
        let w = Writer()
        w.object {
            w.string("format", format)
            w.number("version", Double(version))
            w.string("name", preset.name)
            w.object("output") {
                w.string("folder", preset.outputFolder)
                w.string("names", preset.nameTemplate)
                w.bool("neverOverwrite", preset.neverOverwrite)
                w.bool("keepSubfolders", preset.keepSubfolders)
                w.string("signedFiles", preset.signedFiles.rawValue)
                w.string("filesWithPasswords", preset.passwords.rawValue)
                w.string("imagePages", word(preset.imagePageSize))
            }
            w.array("actions") {
                for step in preset.steps { writeStep(w, step) }
            }
        }
        return w.text + "\n"
    }

    private static func writeStep(_ w: Writer, _ step: BatchStep) {
        w.object {
            w.string("action", actionName(step))
            switch step {
            case .optimize(let o):
                w.number("maxImageDpi", o.maxImageDpi)
                w.number("jpegQuality", Double(o.jpegQuality))
                w.bool("compressStreams", o.compressStreams)
                w.bool("deduplicateStreams", o.deduplicateStreams)
                w.bool("removeMetadata", o.removeMetadata)
                w.bool("removeThumbnails", o.removeThumbnails)
                w.bool("removePieceInfo", o.removePieceInfo)
            case .protect(let p):
                // Which passwords are set, never the passwords.
                w.bool("openPassword", p.userPassword != nil)
                w.bool("permissionsPassword", p.ownerPassword != nil)
                w.string("encryption", word(p.method))
                w.string("print", word(p.permissions.print))
                w.bool("copy", p.permissions.copy)
                w.bool("modify", p.permissions.modify)
                w.bool("annotate", p.permissions.annotate)
                w.bool("fillForms", p.permissions.fillForms)
                w.bool("assemble", p.permissions.assemble)
            case .sanitize(let items):
                w.array("remove") { for item in SanitizeItem.allCases where items.contains(item) { w.value(word(item)) } }
            case .redactPatterns(let r):
                w.array("patterns") { for kind in RedactionPatterns.builtIn where r.patterns.contains(kind) { w.value(word(kind)) } }
                w.array("phrases") { for phrase in r.phrases { w.value(phrase) } }
                w.bool("wholeWord", r.wholeWord)
                w.bool("matchCase", r.matchCase)
                w.string("expression", (r.expression ?? "").isEmpty ? nil : r.expression)
                if let pages = r.pages {
                    w.array("pages") { for page in pages { w.value(Double(page + 1)) } }
                } else {
                    w.null("pages")
                }
            case .watermark(let m):
                w.string("text", m.image == nil ? m.text : nil)
                w.string("imagePng", m.image.map { Data(png($0)).base64EncodedString() })
                w.number("fontSize", m.fontSize)
                w.string("color", hex(m.color))
                w.number("opacity", m.opacity)
                w.number("rotation", m.rotation)
                w.string("layout", word(m.layout))
                w.number("imageScale", m.imageScale)
                w.bool("behind", m.behind)
            case .headerFooter(let h, let continueBates):
                for slot in HeaderFooterSlot.allCases { w.string(word(slot), h.text(slot)) }
                w.number("fontSize", h.fontSize)
                w.string("color", hex(h.color))
                w.number("marginTop", h.marginTop)
                w.number("marginBottom", h.marginBottom)
                w.number("marginLeft", h.marginLeft)
                w.number("marginRight", h.marginRight)
                if let b = h.bates {
                    w.object("bates") {
                        w.string("prefix", b.prefix)
                        w.number("start", Double(b.start))
                        w.number("digits", Double(b.digits))
                        w.string("suffix", b.suffix)
                    }
                } else {
                    w.null("bates")
                }
                w.bool("continueBates", continueBates)
            case .rotate(let degrees):
                w.number("degrees", Double(degrees))
            case .flatten(let f):
                w.bool("annotations", f.annotations)
                w.bool("formFields", f.formFields)
                w.bool("links", f.links)
                w.bool("printableOnly", f.printableOnly)
            case .export(let format, let dpi):
                w.string("format", format.rawValue)
                w.number("dpi", Double(dpi))
            case .unprotect, .checkRedaction, .reportContents, .ocr:
                break
            }
        }
    }

    /// Each action's name in a preset, in the order the Batch window offers them (the Windows app's list; the actions it
    /// has that the Mac doesn't yet, checkAccessibility and saveAsPdfA, are refused by name).
    public static let actionNames = ["optimize", "protect", "unprotect", "sanitize", "redactPatterns", "checkRedaction", "reportContents", "watermark",
                                     "headerFooter", "rotate", "flatten", "ocr", "export"]
    static let windowsOnlyActions = ["checkAccessibility", "saveAsPdfA"]

    private static func actionName(_ step: BatchStep) -> String {
        switch step {
        case .optimize: "optimize"
        case .protect: "protect"
        case .unprotect: "unprotect"
        case .sanitize: "sanitize"
        case .redactPatterns: "redactPatterns"
        case .checkRedaction: "checkRedaction"
        case .reportContents: "reportContents"
        case .watermark: "watermark"
        case .headerFooter: "headerFooter"
        case .rotate: "rotate"
        case .flatten: "flatten"
        case .ocr: "ocr"
        case .export: "export"
        }
    }

    /// An enum value as a camelCase word ("highResolution"), as .NET's enum names become.
    static func word<T>(_ value: T) -> String {
        let name = "\(value)"
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    private static func hex(_ c: AnnotColor) -> String {
        String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
    }

    private static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    private static func png(_ image: StampImage) -> [UInt8] {
        let n = image.width * image.height
        guard let alpha = image.alpha else { return PngEncoder.encode(image.width, image.height, image.rgb, alpha: false) }
        var rgba = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            rgba[i * 4] = image.rgb[i * 3]
            rgba[i * 4 + 1] = image.rgb[i * 3 + 1]
            rgba[i * 4 + 2] = image.rgb[i * 3 + 2]
            rgba[i * 4 + 3] = alpha[i]
        }
        return PngEncoder.encode(image.width, image.height, rgba, alpha: true)
    }

    /// JSON as .NET's Utf8JsonWriter writes it indented: two spaces, "key": value, every array element on its own line,
    /// empty arrays as [], strings escaped only where JSON requires it.
    private final class Writer {
        private(set) var text = ""
        private var depth = 0
        private var first = true

        private func indent() { text += String(repeating: "  ", count: depth) }

        private func comma() {
            if !first { text += "," }
            text += "\n"
            indent()
            first = false
        }

        private func key(_ name: String) {
            comma()
            text += "\(quoted(name)): "
        }

        func object(_ name: String? = nil, _ body: () -> Void) {
            if let name { key(name) } else if !first { comma() }
            text += "{"
            depth += 1
            first = true
            body()
            depth -= 1
            if !first {
                text += "\n"
                indent()
            }
            text += "}"
            first = false
        }

        func array(_ name: String, _ body: () -> Void) {
            key(name)
            text += "["
            depth += 1
            first = true
            body()
            depth -= 1
            if !first {
                text += "\n"
                indent()
            }
            text += "]"
            first = false
        }

        func value(_ s: String) {
            comma()
            text += quoted(s)
        }

        func value(_ d: Double) {
            comma()
            text += Self.number(d)
        }

        func string(_ name: String, _ value: String?) {
            key(name)
            text += value.map(quoted) ?? "null"
        }

        func number(_ name: String, _ value: Double?) {
            key(name)
            text += value.map(Self.number) ?? "null"
        }

        func bool(_ name: String, _ value: Bool) {
            key(name)
            text += value ? "true" : "false"
        }

        func null(_ name: String) {
            key(name)
            text += "null"
        }

        private static func number(_ d: Double) -> String {
            d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : "\(d)"
        }

        private func quoted(_ s: String) -> String {
            var out = "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                default:
                    if u.value < 0x20 { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
                }
            }
            return out + "\""
        }
    }

    // ───────────────────────────── reading ─────────────────────────────

    /// Reads a preset (see the type's remarks); `fallbackName` names one that has no name.
    /// - Throws: `BatchPresetError` when it isn't JSON, isn't a preset, comes from a newer version, or a setting is wrong.
    public static func read(_ json: String, fallbackName: String? = nil) throws -> BatchPreset {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.json5Allowed, .fragmentsAllowed])
        } catch {
            let ns = error as NSError
            let where_ = (ns.userInfo["NSDebugDescription"] as? String).map { " (\($0))" } ?? ""
            throw BatchPresetError("This isn't a batch preset: it isn't valid JSON\(where_).")
        }
        guard let root = parsed as? [String: Any] else { throw BatchPresetError("This isn't a batch preset: it should be a JSON object { … }.") }
        if let format = root["format"], !(format is NSNull), (format as? String) != Self.format {
            throw BatchPresetError("This JSON file isn't an Inkvolt PDF batch preset (its \"format\" should be \"\(Self.format)\").")
        }
        guard let version = root["version"], !(version is NSNull) else { throw BatchPresetError("This JSON file isn't an Inkvolt PDF batch preset: it has no \"version\".") }
        guard let n = version as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), Double(truncating: n) == Double(truncating: n).rounded(), n.intValue >= 1 else {
            throw BatchPresetError("The preset's \"version\" (\(Fields.raw(version))) isn't one Inkvolt PDF knows: it should be \(Self.version).")
        }
        let v = n.intValue
        if v > Self.version {
            throw BatchPresetError("This preset was saved by a newer Inkvolt PDF (preset version \(v); this one reads version \(Self.version) and earlier). Update Inkvolt PDF to use it.")
        }

        let top = try Fields(root, "The preset")
        _ = try top.text("format", Self.format)
        _ = try top.int("version", Self.version, 1, Self.version)
        var name = try top.text("name", nil) ?? ""
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = (fallbackName ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Preset" : fallbackName! }
        var preset = BatchPreset(name: name.trimmingCharacters(in: .whitespaces), steps: [])
        if let output = try top.object("output") {
            let folder = try output.text("folder", nil)
            if let folder, !folder.isEmpty, !folder.hasPrefix("/"), !(folder.count > 2 && folder.dropFirst(1).hasPrefix(":\\")) {
                throw BatchPresetError("The preset's output \"folder\" should be a full path, such as /Users/me/Results (it is \"\(folder)\").")
            }
            let names = try output.text("names", BatchNames.defaultTemplate)!
            if let nameError = BatchNames.validate(names) { throw BatchPresetError("The preset's output \"names\": \(nameError)") }
            preset.outputFolder = (folder ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : folder
            preset.nameTemplate = names
            preset.neverOverwrite = try output.bool("neverOverwrite", true)
            preset.keepSubfolders = try output.bool("keepSubfolders", true)
            preset.signedFiles = try output.choice("signedFiles", SignedFilePolicy.skip, SignedFilePolicy.allCases)
            preset.passwords = try output.choice("filesWithPasswords", PasswordPolicy.ask, PasswordPolicy.allCases)
            preset.imagePageSize = try output.choice("imagePages", PageSizeOption.fitImage, [PageSizeOption.fitImage, .letter, .a4])
            try output.done()
        }
        guard let actions = try top.array("actions") else {
            throw BatchPresetError("The preset has no \"actions\": add at least one, such as { \"action\": \"optimize\" }.")
        }
        var steps: [BatchStep] = []
        for (i, item) in actions.enumerated() { steps.append(try readStep(item, i + 1)) }
        if steps.isEmpty { throw BatchPresetError("The preset's \"actions\" list is empty: add at least one.") }
        try top.done()
        preset.steps = steps
        return preset
    }

    private static func readStep(_ item: Any, _ n: Int) throws -> BatchStep {
        guard let dict = item as? [String: Any] else { throw BatchPresetError("Action \(n) should be an object such as { \"action\": \"ocr\" }.") }
        guard let name = dict["action"] as? String else {
            throw BatchPresetError("Action \(n) has no \"action\" saying what it does (one of \(actionNames.joined(separator: ", "))).")
        }
        if windowsOnlyActions.contains(name) {
            throw BatchPresetError("Action \(n): \"\(name)\" is an action of Inkvolt PDF for Windows that the Mac doesn't have yet (it knows \(actionNames.joined(separator: ", "))).")
        }
        if !actionNames.contains(name) {
            throw BatchPresetError("Action \(n): \"\(name)\" isn't an action Inkvolt PDF knows (it knows \(actionNames.joined(separator: ", "))).")
        }
        let f = try Fields(dict, "Action \(n) (\(name))")
        _ = try f.text("action", nil)
        let step: BatchStep
        switch name {
        case "optimize":
            step = .optimize(OptimizeOptions(
                compressStreams: try f.bool("compressStreams", true),
                deduplicateStreams: try f.bool("deduplicateStreams", true),
                removeMetadata: try f.bool("removeMetadata", false),
                removeThumbnails: try f.bool("removeThumbnails", true),
                removePieceInfo: try f.bool("removePieceInfo", true),
                maxImageDpi: try f.nullableNumber("maxImageDpi", OptimizeOptions().maxImageDpi, 36, 2400),
                jpegQuality: try f.int("jpegQuality", 75, 1, 100)))
        case "protect":
            step = try readProtect(f)
        case "unprotect":
            step = .unprotect
        case "sanitize":
            step = .sanitize(Set(try f.words("remove", SanitizeItem.allCases.filter { $0 != .signatures }, SanitizeItem.allCases)))
        case "redactPatterns":
            step = .redactPatterns(RedactionPatternOptions(
                patterns: Set(try f.words("patterns", Array(RedactionPatterns.defaults), RedactionPatterns.builtIn)),
                phrases: try f.texts("phrases"),
                wholeWord: try f.bool("wholeWord", true),
                matchCase: try f.bool("matchCase", false),
                expression: (try f.text("expression", nil)).flatMap { $0.isEmpty ? nil : $0 },
                pages: try f.pages("pages")))
        case "checkRedaction":
            step = .checkRedaction
        case "reportContents":
            step = .reportContents
        case "watermark":
            step = try readWatermark(f)
        case "headerFooter":
            step = try readHeaderFooter(f)
        case "rotate":
            let d = try f.int("degrees", 90, -270, 270)
            guard d % 90 == 0 && d != 0 else { throw BatchPresetError("Action \(n) (rotate): \"degrees\" should be 90, -90 or 180.") }
            step = .rotate(d)
        case "flatten":
            step = .flatten(FlattenOptions(annotations: try f.bool("annotations", true), formFields: try f.bool("formFields", true),
                                           links: try f.bool("links", false), printableOnly: try f.bool("printableOnly", false)))
        case "ocr":
            step = .ocr
        default:
            step = .export(try f.choice("format", BatchExportFormat.text, BatchExportFormat.allCases), dpi: try f.int("dpi", 150, 36, 1200))
        }
        try f.done()
        return step
    }

    private static func readProtect(_ f: Fields) throws -> BatchStep {
        let open = try f.bool("openPassword", false, passwordHint: true)
        let permissions = try f.bool("permissionsPassword", false, passwordHint: true)
        if !open && !permissions {
            throw BatchPresetError("\(f.where_): set \"openPassword\", \"permissionsPassword\" or both to true (the passwords themselves are given when it runs).")
        }
        let method = try f.choice("encryption", EncryptionMethod.aes256, [EncryptionMethod.aes256, .aes128])
        let perms = PdfPermissions(print: try f.choice("print", PrintPermission.highResolution, [PrintPermission.none, .lowResolution, .highResolution]),
                                   copy: try f.bool("copy", true), modify: try f.bool("modify", true), annotate: try f.bool("annotate", true),
                                   fillForms: try f.bool("fillForms", true), assemble: try f.bool("assemble", true))
        // "" = wanted, given when the batch runs (BatchPresets.withPasswords, the Batch window's Change…).
        return .protect(ProtectStep(open ? "" : nil, permissions ? "" : nil, permissions ? perms : .all, method))
    }

    private static func readWatermark(_ f: Fields) throws -> BatchStep {
        let text = try f.text("text", nil)
        let png = try f.text("imagePng", nil)
        var image: StampImage?
        if let png, !png.isEmpty {
            guard let bytes = Data(base64Encoded: png, options: [.ignoreUnknownCharacters]), let decoded = PngDecoder.decode(Array(bytes)) else {
                throw BatchPresetError("\(f.where_): \"imagePng\" isn't a PNG picture in base64")
            }
            image = decoded
        }
        if image == nil && (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw BatchPresetError("\(f.where_): give a \"text\" (or an \"imagePng\" picture).")
        }
        return .watermark(WatermarkOptions(
            text: image == nil ? text : nil,
            image: image,
            fontSize: try f.number("fontSize", 72, 1, 1000),
            color: try f.color("color", AnnotColor(0.5, 0.5, 0.5)),
            opacity: try f.number("opacity", 0.3, 0, 1),
            rotation: try f.number("rotation", 45, -360, 360),
            layout: try f.choice("layout", WatermarkLayout.center, WatermarkLayout.allCases),
            imageScale: try f.number("imageScale", 0.5, 0.01, 1),
            behind: try f.bool("behind", false)))
    }

    private static func readHeaderFooter(_ f: Fields) throws -> BatchStep {
        var options = HeaderFooterOptions()
        options.headerLeft = try f.text("headerLeft", "") ?? ""
        options.headerCenter = try f.text("headerCenter", "") ?? ""
        options.headerRight = try f.text("headerRight", "") ?? ""
        options.footerLeft = try f.text("footerLeft", "") ?? ""
        options.footerCenter = try f.text("footerCenter", "") ?? ""
        options.footerRight = try f.text("footerRight", "") ?? ""
        if let b = try f.object("bates") {
            options.bates = BatesFormat(try b.text("prefix", "") ?? "", Int64(try b.long("start", 1, 0, 999_999_999_999)), try b.int("digits", 6, 1, 18), try b.text("suffix", "") ?? "")
            try b.done()
        }
        options.fontSize = try f.number("fontSize", 10, 1, 200)
        options.color = try f.color("color", AnnotColor(0, 0, 0))
        options.marginTop = try f.number("marginTop", 36, 0, 1000)
        options.marginBottom = try f.number("marginBottom", 36, 0, 1000)
        options.marginLeft = try f.number("marginLeft", 72, 0, 1000)
        options.marginRight = try f.number("marginRight", 72, 0, 1000)
        if options.isEmpty { throw BatchPresetError("\(f.where_): every text is empty; give at least one, such as \"footerCenter\": \"Page <<page>> of <<pages>>\".") }
        return .headerFooter(options, continueBates: try f.bool("continueBates", false))
    }

    /// An object's settings, read one by one; `done` refuses any it didn't ask for (a typo, a setting of another version).
    private final class Fields {
        private let e: [String: Any]
        private var asked = Set<String>()
        let where_: String

        init(_ e: Any, _ where_: String) throws {
            guard let dict = e as? [String: Any] else { throw BatchPresetError("\(where_) should be an object { … }.") }
            self.e = dict
            self.where_ = where_
        }

        static func raw(_ v: Any) -> String {
            if let s = v as? String { return "\"\(s)\"" }
            if let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), let s = String(data: data, encoding: .utf8) { return s }
            return "\(v)"
        }

        private func get(_ name: String) -> Any? {
            asked.insert(name)
            guard let v = e[name], !(v is NSNull) else { return nil }
            return v
        }

        private func wrong(_ name: String, _ should: String) -> BatchPresetError { BatchPresetError("\(where_): \"\(name)\" should be \(should).") }

        private static func isBool(_ v: Any) -> Bool { v is Bool && (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? true }

        private static func isNumber(_ v: Any) -> Bool { v is NSNumber && !isBool(v) }

        func bool(_ name: String, _ fallback: Bool, passwordHint: Bool = false) throws -> Bool {
            guard let v = get(name) else { return fallback }
            if Self.isBool(v), let b = v as? Bool { return b }
            if passwordHint && v is String {
                throw BatchPresetError("\(where_): passwords aren't kept in presets; \"\(name)\" is true or false, and the password is given when the batch runs.")
            }
            throw wrong(name, "true or false")
        }

        func number(_ name: String, _ fallback: Double, _ min: Double, _ max: Double) throws -> Double {
            guard let v = get(name) else { return fallback }
            guard Self.isNumber(v), let d = (v as? NSNumber)?.doubleValue, d.isFinite else { throw wrong(name, "a number") }
            guard d >= min && d <= max else { throw wrong(name, "between \(Self.plain(min)) and \(Self.plain(max))") }
            return d
        }

        func nullableNumber(_ name: String, _ fallback: Double?, _ min: Double, _ max: Double) throws -> Double? {
            guard let v = e[name] else { return fallback }
            asked.insert(name)
            return v is NSNull ? nil : try number(name, 0, min, max)
        }

        func int(_ name: String, _ fallback: Int, _ min: Int, _ max: Int) throws -> Int { Int(try long(name, Int64(fallback), Int64(min), Int64(max))) }

        func long(_ name: String, _ fallback: Int64, _ min: Int64, _ max: Int64) throws -> Int64 {
            guard let v = get(name) else { return fallback }
            guard Self.isNumber(v), let n = v as? NSNumber, n.doubleValue == n.doubleValue.rounded() else { throw wrong(name, "a whole number") }
            let i = n.int64Value
            guard i >= min && i <= max else { throw wrong(name, "between \(min) and \(max)") }
            return i
        }

        func text(_ name: String, _ fallback: String?) throws -> String? {
            guard let v = get(name) else { return fallback }
            guard let s = v as? String else { throw wrong(name, "a text in quotes") }
            return s
        }

        func texts(_ name: String) throws -> [String] {
            guard let v = get(name) else { return [] }
            guard let list = v as? [Any] else { throw wrong(name, "a list of texts [\"…\", \"…\"]") }
            return try list.map { e in
                guard let s = e as? String else { throw wrong(name, "a list of texts [\"…\", \"…\"]") }
                return s
            }
        }

        /// An enum value from its camelCase word, among `choices`.
        func choice<T>(_ name: String, _ fallback: T, _ choices: [T]) throws -> T {
            guard let v = get(name) else { return fallback }
            let words = choices.map { "\"\(BatchPresets.word($0))\"" }.joined(separator: ", ")
            guard let given = v as? String else { throw wrong(name, "one of \(words)") }
            for c in choices where BatchPresets.word(c) == given { return c }
            throw wrong(name, "one of \(words) (it is \"\(given)\")")
        }

        /// A list of enum words; missing: `fallback`.
        func words<T>(_ name: String, _ fallback: [T], _ choices: [T]) throws -> [T] {
            guard let v = get(name) else { return fallback }
            let words = choices.map { "\"\(BatchPresets.word($0))\"" }.joined(separator: ", ")
            guard let list = v as? [Any] else { throw wrong(name, "a list of \(words)") }
            var result: [T] = []
            for e in list {
                let given = e as? String
                guard let given, let match = choices.first(where: { BatchPresets.word($0) == given }) else {
                    throw wrong(name, "a list of \(words) (\"\(given ?? Self.raw(e))\" isn't one)")
                }
                result.append(match)
            }
            return result
        }

        /// Page numbers from 1 (stored from 0); null or missing: every page.
        func pages(_ name: String) throws -> [Int]? {
            guard let v = get(name) else { return nil }
            guard let list = v as? [Any] else { throw wrong(name, "null (every page) or a list of page numbers [1, 2]") }
            return try list.map { e in
                guard Self.isNumber(e), let n = e as? NSNumber, n.doubleValue == n.doubleValue.rounded(), n.intValue >= 1 else {
                    throw wrong(name, "null (every page) or a list of page numbers from 1")
                }
                return n.intValue - 1
            }
        }

        func color(_ name: String, _ fallback: AnnotColor) throws -> AnnotColor {
            guard let text = try text(name, nil) else { return fallback }
            guard text.count == 7, text.hasPrefix("#"), let rgb = Int(text.dropFirst(), radix: 16) else { throw wrong(name, "a color such as \"#808080\"") }
            return AnnotColor(Double(rgb >> 16 & 0xFF) / 255, Double(rgb >> 8 & 0xFF) / 255, Double(rgb & 0xFF) / 255)
        }

        func object(_ name: String) throws -> Fields? {
            guard let v = get(name) else { return nil }
            return try Fields(v, "\(where_)'s \"\(name)\"")
        }

        func array(_ name: String) throws -> [Any]? {
            guard let v = get(name) else { return nil }
            guard let list = v as? [Any] else { throw wrong(name, "a list [ … ]") }
            return list
        }

        func done() throws {
            for p in e.keys.sorted() where !asked.contains(p) {
                throw BatchPresetError(p.lowercased().contains("password")
                    ? "\(where_): \"\(p)\" isn't a setting, and passwords are never kept in presets."
                    : "\(where_): \"\(p)\" isn't a setting Inkvolt PDF knows here.")
            }
        }

        private static func plain(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : "\(d)" }
    }
}
