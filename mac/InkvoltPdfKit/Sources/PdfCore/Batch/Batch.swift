import Foundation

/// A file of a batch (the Windows app's `BatchFile`).
public struct BatchFile: Equatable, Sendable {
    /// Its full path.
    public var path: String
    /// The folder below an added folder it was found in ("" at the top or when added on its own): with
    /// `BatchPlan.keepSubfolders` its results go to the same folder below the output folder.
    public var relativeFolder: String
    /// Where the file came from when it is worked on elsewhere (a watched folder's file, moved aside while it runs):
    /// names (<<folder>>) come from there. Nil: `path`.
    public var origin: String?

    public init(_ path: String, relativeFolder: String = "", origin: String? = nil) {
        self.path = path
        self.relativeFolder = relativeFolder
        self.origin = origin
    }

    public var isImage: Bool { BatchFiles.isImage(path) }

    /// The path result names are made from.
    public var namedAs: String { origin ?? path }
}

/// The files a batch can take: PDFs, and images (made into a PDF first).
public enum BatchFiles {
    public static let imageExtensions = ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "gif"]

    public static func isImage(_ path: String) -> Bool { imageExtensions.contains((path as NSString).pathExtension.lowercased()) }

    public static func isSupported(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "pdf" || isImage(path) }

    /// The PDFs and images among `paths` (files as given; folders as the files in them, in name order, with `recursive`
    /// their subfolders too), each once. Hidden files, and anything inside `excludeFolder` (the output folder, so results
    /// aren't read back in), are left out of folders.
    public static func expand(_ paths: [String], recursive: Bool, excludeFolder: String? = nil) -> [BatchFile] {
        var seen = Set<String>()
        var result: [BatchFile] = []
        let exclude = excludeFolder.flatMap { $0.isEmpty ? nil : folder($0) }
        let fm = FileManager.default
        for raw in paths {
            let path = (raw as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if isSupported(path) && seen.insert(path.lowercased()).inserted { result.append(BatchFile(path)) }
                continue
            }
            var found: [(path: String, relative: String)] = []
            let root = URL(fileURLWithPath: path)
            let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: options) {
                for case let url as URL in e {
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true, isSupported(url.path) else { continue }
                    let full = url.standardizedFileURL.path
                    if let exclude, full.lowercased().hasPrefix(exclude) { continue }
                    let parent = (full as NSString).deletingLastPathComponent
                    let relative = parent.count > path.count ? String(parent.dropFirst(path.count + 1)) : ""
                    found.append((full, relative))
                }
            }
            found.sort {
                let f = $0.relative.localizedCaseInsensitiveCompare($1.relative)
                return f == .orderedSame ? ($0.path as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1.path as NSString).lastPathComponent) == .orderedAscending : f == .orderedAscending
            }
            for (file, relative) in found where seen.insert(file.lowercased()).inserted { result.append(BatchFile(file, relativeFolder: relative)) }
        }
        return result
    }

    private static func folder(_ path: String) -> String {
        var p = (path as NSString).standardizingPath.lowercased()
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p + "/"
    }
}

/// Output names: a template with tokens, made into a valid file name (without extension), one Windows accepts too.
public enum BatchNames {
    public static let defaultTemplate = "<<name>>"
    /// Longest name made (folders and extension come on top), well inside Windows' path limits.
    public static let maxLength = 120
    /// <<name>> the file's name, <<n>> its place in the list (<<n:3>> padded to 3 digits), <<date>> (yyyy-MM-dd, or a
    /// format after a colon), <<folder>> the folder it is in.
    public static let tokens = ["<<name>>", "<<n>>", "<<date>>", "<<folder>>"]

    private static let deviceNames: Set<String> = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
                                                   "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
    private static let tokenPattern = try! NSRegularExpression(pattern: #"<<\s*(name|n|date|folder)\s*(?::([^<>]*))?>>"#, options: [.caseInsensitive])
    private static let invalid = Set("<>:\"/\\|?*")

    /// An error for a template that can't make names, else nil.
    public static func validate(_ template: String) -> String? {
        template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type a name for the results, for example <<name>>." : nil
    }

    /// `number`: the file's place in the batch, from 1.
    public static func expand(_ template: String, _ sourcePath: String, _ number: Int, _ date: Date) -> String {
        let name = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let ns = template as NSString
        var out = ""
        var last = 0
        for m in tokenPattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let format = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces) : ""
            switch ns.substring(with: m.range(at: 1)).lowercased() {
            case "name":
                out += name
            case "n":
                if let digits = Int(format), digits > 0, digits <= 9, format.allSatisfy(\.isNumber) {
                    out += String(format: "%0\(digits)d", number)
                } else {
                    out += String(number)
                }
            case "date":
                out += HeaderFooter.formatDate(date, format.isEmpty ? "yyyy-MM-dd" : format, HeaderFooter.invariant)
            default:
                out += ((sourcePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
            }
            last = m.range.location + m.range.length
        }
        return clean(out + ns.substring(from: last), name)
    }

    /// `text` as a file name: characters Windows refuses become "_", trailing dots and spaces go.
    private static func clean(_ text: String, _ fallback: String) -> String {
        var s = String(text.map { invalid.contains($0) || ($0.asciiValue.map { $0 < 32 } ?? false) ? "_" : $0 })
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxLength { s = String(s.prefix(maxLength)) }
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        if s.isEmpty { s = fallback.isEmpty ? "file" : fallback }
        // CON, NUL, COM1 ... can't be file names on Windows, with or without an extension.
        let stem = s.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? s
        if deviceNames.contains(stem.trimmingCharacters(in: .whitespaces).uppercased()) { s = "_" + s }
        return s
    }
}

// ───────────────────────────── actions ─────────────────────────────

/// AES-256 protection. Passwords are kept out of the step's title (no log ever shows them). A password that is "" is
/// wanted but not given yet: a preset (`BatchPresets`) keeps which passwords are set, never the passwords.
public struct ProtectStep: Equatable, Sendable {
    public var userPassword: String?
    public var ownerPassword: String?
    public var permissions: PdfPermissions
    public var method: EncryptionMethod

    public init(_ userPassword: String?, _ ownerPassword: String?, _ permissions: PdfPermissions = .all, _ method: EncryptionMethod = .aes256) {
        self.userPassword = userPassword
        self.ownerPassword = ownerPassword
        self.permissions = permissions
        self.method = method
    }

    /// A password is wanted but not given (a step read from a preset).
    public var needsPasswords: Bool { userPassword == "" || ownerPassword == "" }
}

public enum BatchExportFormat: String, CaseIterable, Sendable {
    case word, excel, text, png, jpeg
    /// Form data (`FormEditor.exportData`).
    case formDataXfdf, formDataFdf
}

/// One action of a batch, applied to each file in turn (the order matters; the Windows app's `BatchStep` records).
public enum BatchStep: Equatable, Sendable {
    case optimize(OptimizeOptions)
    case protect(ProtectStep)
    case unprotect
    case sanitize(Set<SanitizeItem>)
    /// Redaction by pattern on every page, applied at once (the pages with matches become images, as in the app).
    case redactPatterns(RedactionPatternOptions)
    /// Redaction check (`RedactionCheck`): the file fails when anything recoverable is found (it isn't saved). After
    /// Redact Patterns, what that action redacted is looked for everywhere in the file.
    case checkRedaction
    /// What's in this PDF (`DocumentInventory`): its report is saved beside the result as a web page and as JSON. Never
    /// fails a file: it reports, it doesn't judge.
    case reportContents
    case watermark(WatermarkOptions)
    /// `continueBates`: Bates numbers run on from one file to the next (in list order), instead of starting again.
    case headerFooter(HeaderFooterOptions, continueBates: Bool)
    /// A multiple of 90, positive clockwise.
    case rotate(Int)
    case flatten(FlattenOptions)
    /// Text recognition of pages without text, added as an invisible text layer (the recognizer comes from `BatchHost.recognize`).
    case ocr
    /// `dpi`: resolution of page images (PNG, JPEG).
    case export(BatchExportFormat, dpi: Int)

    /// The action changes the PDF (an export only reads it).
    public var changesPdf: Bool {
        switch self {
        case .checkRedaction, .reportContents, .export: false
        default: true
        }
    }

    /// What the action is called in the list.
    public var title: String {
        switch self {
        case .optimize: "Reduce file size"
        case .protect: "Protect with a password"
        case .unprotect: "Remove password protection"
        case .sanitize: "Sanitize"
        case .redactPatterns: "Redact patterns"
        case .checkRedaction: "Check redaction"
        case .reportContents: "Report contents"
        case .watermark: "Add watermark"
        case .headerFooter(let o, _): o.bates != nil ? "Add header, footer & Bates numbers" : "Add header & footer"
        case .rotate: "Rotate pages"
        case .flatten: "Flatten"
        case .ocr: "Recognize text (OCR)"
        case .export(let format, _):
            switch format {
            case .word: "Export to Word"
            case .excel: "Export tables to Excel"
            case .text: "Export as plain text"
            case .formDataXfdf: "Export form data (XFDF)"
            case .formDataFdf: "Export form data (FDF)"
            case .png: "Export pages as PNG images"
            case .jpeg: "Export pages as JPEG images"
            }
        }
    }

    public var exportFormat: BatchExportFormat? {
        if case .export(let f, _) = self { return f }
        return nil
    }

    /// Page images at a resolution.
    public var isImageExport: Bool { exportFormat == .png || exportFormat == .jpeg }

    /// Form data (not the pages' content).
    public var isReviewExport: Bool { exportFormat == .formDataXfdf || exportFormat == .formDataFdf }

    public var isProtect: Bool {
        if case .protect = self { return true }
        return false
    }
}

public enum SignedFilePolicy: String, Sendable, CaseIterable {
    /// Signed PDFs are left alone (exports still read them).
    case skip
    /// Signed PDFs are changed too; their signatures may show as changed or stop verifying.
    case edit
}

public enum PasswordPolicy: String, Sendable, CaseIterable { case ask, skip }

/// What a batch does with each file and where the results go.
public struct BatchPlan: Sendable {
    public var steps: [BatchStep]
    public var outputFolder: String
    public var nameTemplate = BatchNames.defaultTemplate
    /// A result whose name is taken gets a number ("report (2).pdf") instead of replacing the file. Inputs are never
    /// replaced either way.
    public var neverOverwrite = true
    /// Results of files found in subfolders go to the same subfolders below `outputFolder`.
    public var keepSubfolders = true
    public var signedFiles = SignedFilePolicy.skip
    public var passwords = PasswordPolicy.ask
    /// The page size images are put on when they are made into a PDF.
    public var imagePageSize = PageSizeOption.fitImage
    /// Files worked on at the same time (also limited by `memoryBudget`).
    public var maxParallel = BatchPlan.defaultParallel
    /// Bytes of estimated working memory the files being worked on may take together.
    public var memoryBudget = BatchPlan.defaultMemoryBudget
    /// For <<date>> in names.
    public var date = Date()

    public init(steps: [BatchStep], outputFolder: String) {
        self.steps = steps
        self.outputFolder = outputFolder
    }

    public static var defaultParallel: Int { min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 1), 4) }

    /// A quarter of the Mac's memory, between 256 MB and 3 GB.
    public static var defaultMemoryBudget: Int { min(max(Int(ProcessInfo.processInfo.physicalMemory / 4), 256 << 20), 3 << 30) }

    /// The PDF itself is saved: something changes it, or the file was an image made into one.
    public func writesPdf(_ file: BatchFile) -> Bool { file.isImage || steps.contains { $0.changesPdf } }

    /// Some action renders pages (page images, OCR, redaction), which takes far more memory than the file's size says.
    public var rendersPages: Bool {
        steps.contains {
            switch $0 {
            case .ocr, .redactPatterns, .checkRedaction: true
            default: $0.isImageExport
            }
        }
    }

    /// Bates numbers run on across files, so the files are done one at a time, in order.
    public var isSequential: Bool {
        steps.contains {
            if case .headerFooter(let o, let continueBates) = $0 { return continueBates && o.bates != nil }
            return false
        }
    }

    /// What is wrong with the plan (for the dialog), or nil.
    public func validate(ocrAvailable: Bool) -> String? {
        if steps.isEmpty { return "Add at least one action." }
        if outputFolder.trimmingCharacters(in: .whitespaces).isEmpty || !outputFolder.hasPrefix("/") { return "Choose a folder for the results." }
        if let nameError = BatchNames.validate(nameTemplate) { return nameError }
        if let protect = steps.firstIndex(where: \.isProtect), steps[(protect + 1)...].contains(where: \.changesPdf) {
            return "Put \"Protect with a password\" after the other changes: they would need its password."
        }
        for case .protect(let p) in steps {
            if p.needsPasswords { return "Protect with a password needs its passwords (a preset doesn't keep them): choose it and Change… to type them." }
            if (p.userPassword ?? "").isEmpty && (p.ownerPassword ?? "").isEmpty { return "Protect with a password needs an open password, a permissions password, or both." }
        }
        var formats = Set<BatchExportFormat>()
        for s in steps {
            if let f = s.exportFormat, !formats.insert(f).inserted { return "\"\(s.title)\" is in the list twice." }
        }
        for case .redactPatterns(let r) in steps {
            if r.isEmpty { return "Redact patterns has nothing to look for: choose a kind of text, a phrase or a pattern." }
            if let e = RedactionPatterns.validateExpression(r.expression) { return e }
        }
        if !ocrAvailable && steps.contains(.ocr) { return "Text recognition isn't available on this Mac." }
        return nil
    }
}

// ───────────────────────────── running ─────────────────────────────

public enum BatchPasswordKind: Sendable {
    /// The file needs a password to open.
    case open
    /// The file is restricted: changing it needs its permissions (owner) password.
    case permissions
}

public struct BatchPasswordRequest: Sendable {
    public var file: BatchFile
    public var kind: BatchPasswordKind
    public var wrong: Bool
}

/// What the app gives a batch: password prompts and text recognition.
public struct BatchHost: Sendable {
    /// Asks for a file's password (one prompt at a time); nil skips the file. Unset: files that need one are skipped.
    public var askPassword: (@Sendable (BatchPasswordRequest, CancelToken?) async -> String?)?
    /// Recognizes a page's words (page points, top-left origin); called from worker threads.
    public var recognize: Recognizer?

    public init(askPassword: (@Sendable (BatchPasswordRequest, CancelToken?) async -> String?)? = nil, recognize: Recognizer? = nil) {
        self.askPassword = askPassword
        self.recognize = recognize
    }
}

public enum BatchItemState: String, Sendable { case waiting, running, done, skipped, failed, cancelled }

/// `outputs`: files written (also for a file that failed in a later action); `notes`: what else happened (pages
/// recognized, nothing to export, ...).
public struct BatchItemResult: Equatable, Sendable {
    public var file: BatchFile
    public var state: BatchItemState
    public var message: String
    public var outputs: [String]
    public var notes: [String]

    public init(_ file: BatchFile, _ state: BatchItemState, _ message: String, _ outputs: [String] = [], _ notes: [String] = []) {
        self.file = file
        self.state = state
        self.message = message
        self.outputs = outputs
        self.notes = notes
    }
}

/// `index`: the file's place in the list; `fraction`: how far this file is (0..1); `result`: set once the file is finished.
public struct BatchProgress: Sendable {
    public var index: Int
    public var state: BatchItemState
    public var message: String
    public var fraction: Double
    public var result: BatchItemResult?
}

public struct BatchSummary: Equatable, Sendable {
    public var items: [BatchItemResult]

    public init(_ items: [BatchItemResult]) { self.items = items }

    public var done: Int { items.filter { $0.state == .done }.count }
    public var skipped: Int { items.filter { $0.state == .skipped }.count }
    public var failed: Int { items.filter { $0.state == .failed }.count }
    public var cancelled: Int { items.filter { $0.state == .cancelled }.count }

    /// "3 done, 1 skipped, 2 failed."
    public var text: String {
        var parts: [String] = []
        if done > 0 { parts.append("\(done) done") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.isEmpty ? "No files." : parts.joined(separator: ", ") + "."
    }
}

/// The file is left out, with the reason (a password not given, a signed file).
struct BatchSkip: Error { var reason: String }

/// A check found something: the file fails.
struct BatchCheckFailed: Error { var message: String }

/// A batch (the Windows app's `BatchRunner`): a list of actions done to each of many files, the results saved in an
/// output folder (the originals stay as they are). Files run on worker tasks, a few at a time (`BatchPlan.maxParallel`,
/// and only as many as fit `BatchPlan.memoryBudget`: a large file runs alone). A file that fails or is skipped is listed
/// with the reason and the batch goes on; nothing is written for it (each result is written whole, through a temporary
/// file). Passwords are asked through the host, one prompt at a time; encrypted files keep their protection, and signed
/// files are skipped unless the plan says otherwise.
public enum BatchRunner {
    /// Estimated working memory per byte of file (the bytes, MuPDF, a copy per action).
    private static let memoryPerByte = 8
    private static let minWeight = 32 << 20

    /// - Throws: `PdfEditError` when the plan isn't valid (see `BatchPlan.validate`).
    public static func run(_ files: [BatchFile], _ plan: BatchPlan, _ host: BatchHost, progress: (@Sendable (BatchProgress) -> Void)? = nil,
                           cancel: CancelToken? = nil) async throws -> BatchSummary {
        if let error = plan.validate(ocrAvailable: host.recognize != nil) { throw PdfEditError(error) }
        let results = Results(files.count)
        let names = OutputNames(overwrite: !plan.neverOverwrite, inputs: files.map(\.path))
        let prompts = AsyncSemaphore(1)
        let gate = WeightedGate(plan.memoryBudget)
        let parallel = plan.isSequential ? 1 : max(1, plan.maxParallel)
        let slots = AsyncSemaphore(parallel)
        var bates = 0 // pages numbered so far, when Bates numbers run on (sequential)

        await withTaskGroup(of: Void.self) { group in
            for (index, file) in files.enumerated() {
                do { try await slots.wait(cancel) } catch { break }
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                let weight = weight(size, plan.rendersPages ? largestPage(file) : nil, plan)
                do {
                    try await gate.enter(weight, cancel)
                } catch {
                    slots.signal()
                    break
                }
                let job = Job(file, index, plan, host, names, prompts, progress, cancel, batesOffset: bates)
                group.addTask {
                    let result = await job.run()
                    results.set(index, result)
                    progress?(BatchProgress(index: index, state: result.state, message: result.message, fraction: 1, result: result))
                    gate.release(weight)
                    slots.signal()
                }
                if plan.isSequential {
                    await group.next()
                    bates += job.pageCount
                }
            }
        }
        var items = results.all()
        for i in items.indices where items[i] == nil {
            items[i] = BatchItemResult(files[i], .cancelled, "Cancelled")
            progress?(BatchProgress(index: i, state: .cancelled, message: "Cancelled", fraction: 0, result: items[i]))
        }
        return BatchSummary(items.map { $0! })
    }

    /// The results as they finish, from any task.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [BatchItemResult?]
        init(_ count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ r: BatchItemResult) {
            lock.lock()
            items[index] = r
            lock.unlock()
        }
        func all() -> [BatchItemResult?] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// OCR renders pages at this resolution (see the app's recognizer), within this many pixels.
    private static let ocrDpi = 300.0, ocrMaxPixels = 60_000_000.0
    /// Redacted pages are drawn again at this resolution (`Redaction.apply`'s), whole.
    private static let redactDpi = 300.0
    /// The redaction check draws every page at this resolution (`RedactionCheck`'s first look).
    private static let checkDpi = 54.0

    /// Estimated working memory of a file: its bytes (and the copies its actions make), plus, when the plan renders pages
    /// (page images, OCR), the largest page's pixels at the highest resolution asked, 4 bytes each. `largestPage`: the
    /// largest page in points (nil: unknown, a Letter page is assumed).
    static func weight(_ fileSize: Int, _ largestPage: (width: Double, height: Double)?, _ plan: BatchPlan) -> Int {
        let weight = max(minWeight, fileSize * memoryPerByte)
        if !plan.rendersPages { return weight }
        let (w, h) = largestPage ?? (612, 792)
        var pixels = 0.0
        for step in plan.steps {
            let (dpi, maxPixels): (Double, Double)
            switch step {
            case .export(_, let d) where step.isImageExport: (dpi, maxPixels) = (Double(d), PageImages.maxPixels)
            case .ocr: (dpi, maxPixels) = (ocrDpi, ocrMaxPixels)
            case .redactPatterns: (dpi, maxPixels) = (redactDpi, .greatestFiniteMagnitude)
            case .checkRedaction: (dpi, maxPixels) = (checkDpi, .greatestFiniteMagnitude)
            default: (dpi, maxPixels) = (0, 0)
            }
            pixels = max(pixels, min(maxPixels, w / 72 * dpi * (h / 72 * dpi)))
        }
        return weight + Int(pixels * 4)
    }

    /// The largest page of a file (points), read in place; nil when it can't be told (encrypted, damaged).
    private static func largestPage(_ file: BatchFile) -> (width: Double, height: Double)? {
        guard let engine = try? PdfEngine.openPreview(path: file.path), engine.pageCount > 0 else { return nil }
        defer { engine.close() }
        let largest = (0..<engine.pageCount).map { engine.page($0) }.max { $0.width * $0.height < $1.width * $1.height }!
        return (largest.width, largest.height)
    }

    /// One file's run through the plan.
    private final class Job: @unchecked Sendable {
        let file: BatchFile
        let index: Int
        let plan: BatchPlan
        let host: BatchHost
        let names: OutputNames
        let prompts: AsyncSemaphore
        let progress: (@Sendable (BatchProgress) -> Void)?
        let cancel: CancelToken?
        let batesOffset: Int
        private(set) var pageCount = 0

        private var outputs: [String] = []
        private var notes: [String] = []
        private var password: String? // opens / edits the file (owner password once known)
        private var openPassword: String? // the open password (kept through edits)
        private var baseName = ""
        private var folder = ""
        /// What Redact Patterns removed (the text, the areas) and the file before it: for a later check.
        private var redactedValues: [String] = []
        private var redactedAreas: [Int: [RectD]] = [:]
        private var beforeRedaction: [UInt8]?

        init(_ file: BatchFile, _ index: Int, _ plan: BatchPlan, _ host: BatchHost, _ names: OutputNames, _ prompts: AsyncSemaphore,
             _ progress: (@Sendable (BatchProgress) -> Void)?, _ cancel: CancelToken?, batesOffset: Int) {
            self.file = file
            self.index = index
            self.plan = plan
            self.host = host
            self.names = names
            self.prompts = prompts
            self.progress = progress
            self.cancel = cancel
            self.batesOffset = batesOffset
        }

        private func report(_ message: String, _ fraction: Double) {
            progress?(BatchProgress(index: index, state: .running, message: message, fraction: fraction, result: nil))
        }

        private func result(_ state: BatchItemState, _ message: String) -> BatchItemResult { BatchItemResult(file, state, message, outputs, notes) }

        func run() async -> BatchItemResult {
            do {
                try cancel.check()
                report("Reading…", 0)
                baseName = BatchNames.expand(plan.nameTemplate, file.namedAs, index + 1, plan.date)
                folder = plan.keepSubfolders && !file.relativeFolder.isEmpty ? (plan.outputFolder as NSString).appendingPathComponent(file.relativeFolder) : plan.outputFolder
                var data = Array(try Data(contentsOf: URL(fileURLWithPath: file.path)))
                if file.isImage {
                    report("Making a PDF of the image…", 0)
                    data = try ImageImport.imagesToPdf([(data, (file.path as NSString).lastPathComponent)], pageSize: plan.imagePageSize)
                } else {
                    if !BatchRunner.looksLikePdf(data) { return result(.failed, "This file isn't a PDF.") }
                    if PdfSecurity.needsOpenPassword(data) { try await unlock(data) }
                }
                let changes = plan.steps.contains { $0.changesPdf }
                // A signed file is left as it is (its signatures stay valid); its exports are still made from it.
                let keepSigned = changes && plan.signedFiles == .skip && BatchRunner.isSigned(data, password)
                if keepSigned && plan.steps.allSatisfy({ $0.changesPdf }) {
                    return result(.skipped, "Signed: left as it is so its signatures stay valid")
                }
                if keepSigned { notes.append("Signed: only exported, the PDF left as it is so its signatures stay valid") }
                pageCount = try pages(data)
                if pageCount == 0 { return result(.failed, "This PDF has no pages.") }

                for (s, step) in plan.steps.enumerated() {
                    try cancel.check()
                    if keepSigned && step.changesPdf { continue }
                    report("\(step.title)…", Double(s) / Double(plan.steps.count))
                    switch step {
                    case .export(let format, let dpi):
                        try export(data, format, dpi)
                    case .checkRedaction:
                        try checkRedaction(data)
                    case .reportContents:
                        try reportContents(data)
                    case .ocr:
                        let words = try recognize(data)
                        if !words.isEmpty { data = try await edit(data) { d, pw in try TextLayer.addInvisibleText(d, pw, words) } }
                    default:
                        data = try await edit(data) { d, pw in try self.apply(step, d, pw) }
                        afterStep(step)
                    }
                }
                try cancel.check()
                if plan.writesPdf(file) && !keepSigned {
                    let bytes = data
                    outputs.insert(try names.place(folder, baseName + ".pdf") { try Data(bytes).write(to: URL(fileURLWithPath: $0)) }, at: 0)
                }
                return result(.done, outputs.isEmpty ? "Done (nothing to save)" : "Done")
            } catch is CancellationError {
                return result(.cancelled, "Cancelled")
            } catch let skip as BatchSkip {
                return result(.skipped, skip.reason)
            } catch let failed as BatchCheckFailed {
                return result(.failed, failed.message)
            } catch {
                return result(.failed, BatchRunner.describe(error))
            }
        }

        /// Asks for the open password until it opens the file (or the user skips it).
        private func unlock(_ data: [UInt8]) async throws {
            var wrong = false
            while true {
                guard let given = await ask(.open, wrong) else { throw BatchSkip(reason: "Needs a password to open (skipped)") }
                do {
                    try PdfEngine.open(data, password: given).close()
                    password = given
                    openPassword = PdfSecurity.isOpenPassword(data, given) ? given : nil
                    return
                } catch is PasswordRequired {
                    wrong = true
                }
            }
        }

        private func ask(_ kind: BatchPasswordKind, _ wrong: Bool) async -> String? {
            guard plan.passwords == .ask, let askPassword = host.askPassword else { return nil }
            do { try await prompts.wait(cancel) } catch { return nil }
            defer { prompts.signal() }
            if cancel?.isCancelled == true { return nil }
            return await askPassword(BatchPasswordRequest(file: file, kind: kind, wrong: wrong), cancel)
        }

        /// Runs an edit the way the app's edits run (keeping the protection, appending to a signed file when it can, else
        /// rewriting it as the plan allows), asking for the permissions password when the file is restricted.
        private func edit(_ data: [UInt8], _ edit: @escaping ([UInt8], String?) throws -> [UInt8]) async throws -> [UInt8] {
            let allowRewrite = plan.signedFiles == .edit
            while true {
                let pw = password, open = openPassword
                do {
                    return try KeptProtection.run(openPassword: open, dropOpenPassword: false) {
                        try SignedEdits.run({ try edit(data, pw) }, allowRewrite: allowRewrite).0
                    }
                } catch let e as OwnerPasswordRequired {
                    guard let given = await ask(.permissions, e.wrongPassword && pw != nil) else {
                        throw BatchSkip(reason: "Restricted: needs its permissions password to be changed (skipped)")
                    }
                    password = given
                }
            }
        }

        private func apply(_ step: BatchStep, _ d: [UInt8], _ pw: String?) throws -> [UInt8] {
            let all = Array(0..<pageCount)
            switch step {
            case .optimize(let o):
                let r = try Optimizer.optimize(d, pw, o)
                if r.isWorthIt { return r.data }
                notes.append("Already compact: size left as it was")
                return d
            case .protect(let p):
                return try PdfSecurity.protect(d, pw, userPassword: p.userPassword, ownerPassword: p.ownerPassword, permissions: p.permissions, method: p.method)
            case .unprotect:
                return try PdfSecurity.unprotect(d, pw)
            case .sanitize(let items):
                return try Sanitizer.sanitize(d, pw, items).data
            case .redactPatterns(let options):
                let (redacted, matches) = try RedactionPatterns.redact(d, pw, options, cancel: cancel)
                let pages = Set(matches.map(\.page)).count
                if !matches.isEmpty {
                    if beforeRedaction == nil { beforeRedaction = d }
                    redactedValues += matches.map(\.text)
                    for (page, areas) in RedactionPatterns.areas(matches) { redactedAreas[page, default: []] += areas }
                }
                notes.append(matches.isEmpty
                    ? "Redact patterns: nothing found, left as it was"
                    : "Redacted \(matches.count) \(matches.count == 1 ? "match" : "matches") on \(pages) \(pages == 1 ? "page" : "pages") (\(RedactionPatterns.summary(matches)))")
                return redacted
            case .watermark(let w):
                return try Watermarks.apply(d, pw, all, w)
            case .headerFooter(let h, let continueBates):
                var options = h
                options.fileName = (file.namedAs as NSString).lastPathComponent
                options.batesOffset = continueBates ? batesOffset : 0
                return try HeaderFooter.apply(d, pw, all, options)
            case .rotate(let degrees):
                return try PageEditor.rotate(d, pw, all, degrees)
            case .flatten(let f):
                return try Flattener.flatten(d, pw, f)
            default:
                throw PdfEditError("\(step.title) isn't an action that changes the file.")
            }
        }

        /// The passwords that open and edit the result of `step`.
        private func afterStep(_ step: BatchStep) {
            switch step {
            case .protect(let p):
                password = (p.ownerPassword ?? "").isEmpty ? p.userPassword : p.ownerPassword
                openPassword = (p.userPassword ?? "").isEmpty ? nil : p.userPassword
            case .unprotect:
                password = nil
                openPassword = nil
            default:
                break
            }
        }

        /// The redaction check: anything found fails the file (the first findings go in its notes).
        private func checkRedaction(_ data: [UInt8]) throws {
            let report = try RedactionCheck.run(data, password, RedactionCheckOptions(values: redactedValues, areas: redactedAreas, original: beforeRedaction),
                                                progress: { [self] done, total in self.report("Checking redaction…", Double(done) / Double(max(1, total))) }, cancel: cancel)
            if report.isClean { return }
            for f in report.findings.prefix(10) { notes.append("\(f.place): \(RedactionCheck.name(f.kind))") }
            if report.findings.count > 10 { notes.append("… and \(report.findings.count - 10) more") }
            throw BatchCheckFailed(message: "Redaction check: \(report.summary)")
        }

        /// What's in this PDF: its report beside the result, as a web page and as JSON.
        private func reportContents(_ data: [UInt8]) throws {
            let report = try DocumentInventory.run(data, password, progress: { [self] done, total in
                self.report("Looking through the file…", Double(done) / Double(max(1, total)))
            }, cancel: cancel)
            let name = (file.namedAs as NSString).lastPathComponent
            let now = Date()
            let html = InventoryReportFiles.html(report, name, madeAt: now)
            let json = InventoryReportFiles.json(report, name, madeAt: now)
            outputs.append(try names.place(folder, baseName + " contents.html") { try html.write(toFile: $0, atomically: false, encoding: .utf8) })
            outputs.append(try names.place(folder, baseName + " contents.json") { try json.write(toFile: $0, atomically: false, encoding: .utf8) })
            if !report.isEmpty { notes.append("Contents: \(report.summary)") }
        }

        private func pages(_ data: [UInt8]) throws -> Int {
            let engine = try PdfEngine.open(data, password: password)
            defer { engine.close() }
            return engine.pageCount
        }

        private func recognize(_ data: [UInt8]) throws -> [Int: [OcrWord]] {
            var words: [Int: [OcrWord]] = [:]
            let engine = try PdfEngine.open(data, password: password)
            defer { engine.close() }
            var hadText = 0
            for p in 0..<engine.pageCount {
                try cancel.check()
                report("Recognizing text: page \(p + 1) of \(engine.pageCount)…", Double(p) / Double(engine.pageCount))
                if try TextLayer.hasText(engine, p, cancel: cancel) {
                    hadText += 1
                    continue
                }
                let found = try host.recognize!(engine, p, cancel)
                if !found.isEmpty { words[p] = found }
            }
            if !words.isEmpty { notes.append("Text recognized on \(BatchRunner.plural(words.count, "page"))") } else if hadText < engine.pageCount { notes.append("No text recognized") }
            return words
        }

        private func export(_ data: [UInt8], _ format: BatchExportFormat, _ dpi: Int) throws {
            if format == .formDataXfdf || format == .formDataFdf {
                try exportReview(data, format)
                return
            }
            let engine = try PdfEngine.open(data, password: password)
            defer { engine.close() }
            if format == .png || format == .jpeg {
                let jpeg = format == .jpeg
                for p in 0..<engine.pageCount {
                    try cancel.check()
                    report("Saving page \(p + 1) of \(engine.pageCount)…", Double(p) / Double(engine.pageCount))
                    let resolution = PageImages.clampDpi(engine.page(p), Double(dpi))
                    outputs.append(try names.place(folder, "\(baseName) - page \(p + 1).\(jpeg ? "jpg" : "png")") { temp in
                        try engine.saveImage(p, dpi: resolution, path: temp, jpeg: jpeg, cancel: cancel)
                    })
                }
                return
            }

            let exportFormat: ExportFormat = format == .word ? .word : format == .excel ? .excel : .text
            let sink = MemorySink()
            let report = try DocumentExport.export(engine, exportFormat, to: sink, options: ExportOptions(title: ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension), cancel: cancel)
            for problem in report.unreadable { notes.append("Page \(problem.page + 1) couldn't be read") }
            if !report.saved {
                notes.append(exportFormat == .word ? "Word: no text or pictures, nothing saved" : exportFormat == .excel ? "Excel: no tables found, nothing saved" : "Text: no text found, nothing saved")
                return
            }
            try cancel.check()
            let bytes = sink.bytes
            outputs.append(try names.place(folder, baseName + DocumentExport.fileExtension(exportFormat)) { try Data(bytes).write(to: URL(fileURLWithPath: $0)) })
        }

        /// Form data beside the result; a file without any gets a note, no file.
        private func exportReview(_ data: [UInt8], _ format: BatchExportFormat) throws {
            let name = (file.namedAs as NSString).lastPathComponent
            let dataFormat: FormDataFormat = format == .formDataXfdf ? .xfdf : .fdf
            guard !(try FormEditor.read(data, password)).isEmpty else {
                notes.append("Form data: no form fields, nothing saved")
                return
            }
            let bytes = try FormEditor.exportData(data, password, dataFormat, file: name)
            try cancel.check()
            outputs.append(try names.place(folder, baseName + (dataFormat == .xfdf ? ".xfdf" : ".fdf")) { try Data(bytes).write(to: URL(fileURLWithPath: $0)) })
        }
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

    static func looksLikePdf(_ data: [UInt8]) -> Bool { data.prefix(1024).firstRange(of: Array("%PDF-".utf8)) != nil }

    /// Files with a signature (not just an empty signature field).
    static func isSigned(_ data: [UInt8], _ password: String?) -> Bool {
        SignedEdits.looksSigned(data) && Signatures.verify(data, password).contains { $0.status != .unsigned }
    }

    /// Why a file failed, in words for the list.
    static func describe(_ error: Error) -> String {
        switch error {
        case is PasswordRequired: return "Needs a password to open"
        case let e as PdfEditError: return e.message
        case let e as PdfEngineError: return "This PDF is damaged and can't be read (\(e.message))"
        case let e as SignaturesWouldBreak: return e.description
        case let e as OwnerPasswordRequired: return e.description
        case let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile: return "The file isn't there any more"
        case let e as CocoaError where e.code == .fileReadNoPermission || e.code == .fileWriteNoPermission: return "No access: \(e.localizedDescription)"
        default:
            let text = "\(error)"
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? "\(type(of: error))" : text
        }
    }
}

/// Output paths for a batch, reserved so two files never get the same one. Existing files are kept (a number is added:
/// "report (2).pdf") unless overwriting is allowed; inputs of the batch are never overwritten.
final class OutputNames: @unchecked Sendable {
    private let lock = NSLock()
    private let overwrite: Bool
    private var taken: Set<String>
    private let inputs: Set<String>

    init(overwrite: Bool, inputs: [String]) {
        self.overwrite = overwrite
        let full = Set(inputs.map { ($0 as NSString).standardizingPath.lowercased() })
        taken = full
        self.inputs = full
    }

    /// Writes a result: `write` fills a temporary file next to it, which is then moved to a free name for `fileName`.
    /// Without overwriting, the move never replaces a file: one that appeared since the name was picked (another program)
    /// makes it take the next name. Returns where it went; nothing is left behind on failure.
    func place(_ folder: String, _ fileName: String, _ write: (String) throws -> Void) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let temp = (folder as NSString).appendingPathComponent(".\((fileName as NSString).lastPathComponent).\(NewIds.hex()).tmp")
        defer { try? fm.removeItem(atPath: temp) }
        try write(temp)
        var attempt = 0
        while true {
            let path = reserve(folder, fileName)
            do {
                if overwrite && fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
                try fm.moveItem(atPath: temp, toPath: path)
                return path
            } catch {
                // taken in the meantime: reserve skips it now
                attempt += 1
                if overwrite || !fm.fileExists(atPath: path) || attempt >= 100 { throw error }
            }
        }
    }

    /// A free path for `fileName` in `folder` (created if missing).
    func reserve(_ folder: String, _ fileName: String) -> String {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        lock.lock()
        defer { lock.unlock() }
        var n = 1
        while true {
            let name = n == 1 ? fileName : (ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            let path = ((folder as NSString).appendingPathComponent(name) as NSString).standardizingPath
            let key = path.lowercased()
            n += 1
            if taken.contains(key) || inputs.contains(key) { continue }
            if !overwrite && FileManager.default.fileExists(atPath: path) { continue }
            taken.insert(key)
            return path
        }
    }
}

/// A counting semaphore for tasks, in arrival order; waiting ends when `cancel` fires.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var waiters: [(id: Int, cont: CheckedContinuation<Void, Error>)] = []
    private var nextId = 0

    init(_ count: Int) { self.count = count }

    /// Takes a count when one is free (nil), else the id to wait under.
    private func take() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if count > 0 {
            count -= 1
            return nil
        }
        nextId += 1
        return nextId
    }

    func wait(_ cancel: CancelToken?) async throws {
        try cancel.check()
        guard let id = take() else { return }
        var registration: Int?
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            waiters.append((id, cont))
            lock.unlock()
            registration = cancel?.register { [self] in
                lock.lock()
                guard let i = waiters.firstIndex(where: { $0.id == id }) else { return lock.unlock() }
                let w = waiters.remove(at: i)
                lock.unlock()
                w.cont.resume(throwing: CancellationError())
            }
        }
        cancel?.unregister(registration)
    }

    func signal() {
        lock.lock()
        if waiters.isEmpty {
            count += 1
            lock.unlock()
            return
        }
        let w = waiters.removeFirst()
        lock.unlock()
        w.cont.resume()
    }
}

/// An async gate with a weight budget (bytes of memory): a job enters when its weight fits beside those inside, in
/// arrival order. A job heavier than the whole budget enters when the gate is empty, and runs alone.
final class WeightedGate: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: Int
    private var waiting: [(weight: Int, id: Int, cont: CheckedContinuation<Void, Error>)] = []
    private var used = 0
    private var inside = 0
    private var nextId = 0

    init(_ budget: Int) { self.budget = budget }

    private func fits(_ weight: Int) -> Bool { inside == 0 || used + weight <= budget }

    func tryEnter(_ weight: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !waiting.isEmpty || !fits(weight) { return false }
        used += weight
        inside += 1
        return true
    }

    /// Enters when the weight fits now (nil), else the id to wait under.
    private func enterNow(_ weight: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if waiting.isEmpty && fits(weight) {
            used += weight
            inside += 1
            return nil
        }
        nextId += 1
        return nextId
    }

    func enter(_ weight: Int, _ cancel: CancelToken?) async throws {
        try cancel.check()
        guard let id = enterNow(weight) else { return }
        var registration: Int?
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            waiting.append((weight, id, cont))
            lock.unlock()
            registration = cancel?.register { [self] in
                lock.lock()
                guard let i = waiting.firstIndex(where: { $0.id == id }) else { return lock.unlock() } // already inside: the caller releases it
                let w = waiting.remove(at: i)
                lock.unlock()
                w.cont.resume(throwing: CancellationError())
                wake() // the jobs behind it may fit now
            }
        }
        cancel?.unregister(registration)
    }

    func release(_ weight: Int) {
        lock.lock()
        used -= weight
        inside -= 1
        lock.unlock()
        wake()
    }

    private func wake() {
        var ready: [CheckedContinuation<Void, Error>] = []
        lock.lock()
        while let next = waiting.first, fits(next.weight) {
            waiting.removeFirst()
            used += next.weight
            inside += 1
            ready.append(next.cont)
        }
        lock.unlock()
        for r in ready { r.resume() }
    }
}

/// Page images (Export Pages as Images, batch exports).
public enum PageImages {
    /// Largest image written, in pixels: A0 at 600 dpi would be ~560 MP (about 1.6 GB while rendering).
    public static let maxPixels = 64_000_000.0

    /// The requested dpi, lowered if the page would exceed `maxPixels` at that resolution.
    public static func clampDpi(_ g: PageGeometry, _ dpi: Double) -> Double {
        let squareInches = max(1e-6, g.width / 72 * (g.height / 72))
        return min(dpi, (maxPixels / squareInches).squareRoot().rounded(.down))
    }
}
