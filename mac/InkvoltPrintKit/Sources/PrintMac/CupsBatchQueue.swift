import CCups
import CoreGraphics
import Foundation
import ImageIO
import PrintCore

/// Batch print's queue on the Mac (Windows' `WindowsBatchQueue`): the printer's macOS print queue, through libcups over cupsd's
/// socket. What it takes is read from cupsd's own answer for the queue (`cupsCopyDestInfo`: its papers by IPP name, two-sided
/// from `sides-supported`, the default paper), whatever its driver is (IPP Everywhere or a PPD). A job's pages are drawn into
/// a PDF on this Mac's disk first, then handed over as one job **held** (`job-hold-until=indefinite`); cupsd's answer to
/// Get-Job-Attributes (copies, sides, media) is compared with what was asked (`BatchTicketCheck`, as Windows compares the
/// driver's validated ticket), and only a job that kept everything is released to print; one that didn't is cancelled
/// before any paper moves. `holdOnly` (the report's check against a test queue) cancels every job instead of releasing it.
public final class CupsBatchQueue: BatchQueue {
    public let queue: String
    public let holdOnly: Bool
    /// Each job's id as cupsd took it, for the report.
    private let jobIds = LockedList<Int>()

    public init(queue: String, holdOnly: Bool = false) {
        self.queue = queue
        self.holdOnly = holdOnly
    }

    public var heldJobs: [Int] { jobIds.all }

    /// The queue called `name` on this Mac (its CUPS name, or its shown name, the queue's `printer-info`), or nil.
    public static func named(_ name: String) async -> CupsBatchQueue? {
        let destinations = await LibCups().destinations() ?? []
        let found = destinations.first { $0.name == name } ?? destinations.first { $0.options["printer-info"]?.caseInsensitiveCompare(name) == .orderedSame }
        return found.map { CupsBatchQueue(queue: $0.name) }
    }

    public func read() async throws -> BatchQueueInfo? {
        let queue = queue
        return await LibCups.run {
            guard let dest = cupsGetNamedDest(nil, queue, nil) else { return nil }
            defer { cupsFreeDests(1, dest) }
            let shown = Self.option(dest, "printer-info") ?? queue
            guard let info = cupsCopyDestInfo(nil, dest) else { return BatchQueueInfo(shown, [], nil, canTwoSided: false) }
            defer { cupsFreeDestInfo(info) }
            var papers: [BatchPaper] = []
            let flags = UInt32(CUPS_MEDIA_FLAGS_DEFAULT)
            for i in 0..<cupsGetDestMediaCount(nil, dest, info, flags) {
                var size = cups_size_t()
                guard cupsGetDestMediaByIndex(nil, dest, info, i, flags, &size) != 0 else { continue }
                let name = withUnsafeBytes(of: size.media) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
                // One choice per paper: a borderless variant of the same size prints as the same sheet.
                guard !name.isEmpty, !name.contains(".borderless"), !papers.contains(where: { $0.key == name }) else { continue }
                let words = cupsLocalizeDestMedia(nil, dest, info, flags, &size).map { String(cString: $0) }
                papers.append(BatchPaper(name, BatchQueueReading.label(name, localized: words)))
            }
            let twoSided = cupsCheckDestSupported(nil, dest, info, "sides", "two-sided-long-edge") != 0
            var fallback = cups_size_t()
            let defaultPaper = cupsGetDestMediaDefault(nil, dest, info, flags, &fallback) != 0
                ? withUnsafeBytes(of: fallback.media) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) } : nil
            return BatchQueueInfo(shown, papers, defaultPaper, canTwoSided: twoSided)
        }
    }

    private static func option(_ dest: UnsafeMutablePointer<cups_dest_t>, _ name: String) -> String? {
        cupsGetOption(name, dest.pointee.num_options, dest.pointee.options).map { String(cString: $0) }
    }

    public func problem() async throws -> String? {
        let queue = queue
        let state = await LibCups.run { Self.state(queue) }
        return BatchQueueReading.problem(state: state?.state, accepting: state?.accepting, reasons: state?.reasons ?? [])
    }

    /// The queue's `printer-state`, `printer-is-accepting-jobs` and `printer-state-reasons`; nil when cupsd has no such queue.
    private static func state(_ queue: String) -> (state: Int, accepting: Bool, reasons: [String])? {
        cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
        guard let request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES) else { return nil }
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/" + queue)
        let names = ["printer-state", "printer-is-accepting-jobs", "printer-state-reasons"]
        _ = names.withCStringArray { ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", Int32(names.count), nil, $0) }
        guard let response = cupsDoRequest(nil, request, "/") else { return nil }
        defer { ippDelete(response) }
        guard ippGetStatusCode(response).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue,
              let state = ippFindAttribute(response, "printer-state", IPP_TAG_ENUM) else { return nil }
        let accepting = ippFindAttribute(response, "printer-is-accepting-jobs", IPP_TAG_BOOLEAN).map { ippGetBoolean($0, 0) != 0 } ?? true
        var reasons: [String] = []
        if let attr = ippFindAttribute(response, "printer-state-reasons", IPP_TAG_KEYWORD) {
            reasons = (0..<ippGetCount(attr)).compactMap { ippGetString(attr, $0, nil).map { String(cString: $0) } }
        }
        return (Int(ippGetInteger(state, 0)), accepting, reasons)
    }

    public func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?, onSpooling: @escaping @Sendable () -> Void,
                     _ stop: BatchStop) async throws -> BatchReceipt {
        guard let info = try await read() else { throw BatchQueueError("macOS has no print queue \(queue) now.", mayHaveSent: false) }
        var asked: (width: Double, height: Double)?
        if let paper = job.paper {
            guard info.papers.contains(where: { $0.key == paper }) else { throw BatchSettingRefused("\(info.name) doesn't offer that paper now.") }
            asked = BatchQueueReading.size(paper)
            if asked == nil { asked = await Self.mediaSize(queue, paper) }
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-batch-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.checkRoom(file, pages: job.pages.count)
        let pages = try await Self.draw(document, job, into: file, progress: progress, stop)
        try stop.check()

        // Handed over held: nothing prints until the job's options are read back and kept.
        progress?("Handing it to macOS…")
        let options = Self.options(job, document.sizing)
        let id: Int
        do {
            id = try await Self.holdJob(queue, file, title: job.name, options)
        } catch let e as PrintJobSendError {
            throw BatchQueueError("macOS's print queue didn't take it: \(e.message)", mayHaveSent: false)
        }
        jobIds.append(id)
        let cups = LibCups()
        func cancel() async { try? await cups.cancel(queue, job: id) }
        guard let ticket = await Self.ticket(id) else {
            await cancel()
            throw BatchQueueError("macOS's print queue doesn't say what it took: the job was cancelled before printing.", mayHaveSent: false)
        }
        let gotPaper = ticket.mediaCol.flatMap(BatchQueueReading.mediaColSize) ?? ticket.media.flatMap(BatchQueueReading.size)
        if let problem = BatchTicketCheck.problem(job.copies, job.twoSided, asked, ticket.copies, BatchQueueReading.twoSided(ticket.sides), gotPaper) {
            await cancel()
            throw BatchSettingRefused(problem)
        }
        if stop.isStopped {
            await cancel()
            throw CancellationError()
        }
        if holdOnly {
            await cancel()
            return BatchReceipt(pages: pages, sheets: BatchPrintSettings.sheets(pages, job.copies, job.twoSided))
        }

        // From here the job belongs to cupsd.
        onSpooling()
        progress?("Sending it to the printer…")
        if let refused = await Self.release(queue, id) {
            throw BatchQueueError("macOS's print queue didn't let the job go: \(refused)", mayHaveSent: true)
        }
        return BatchReceipt(pages: pages, sheets: BatchPrintSettings.sheets(pages, job.copies, job.twoSided))
    }

    /// The job's options as cupsd words them.
    static func options(_ job: BatchPrintJob, _ sizing: PageSizing) -> [(name: String, value: String)] {
        var o: [(name: String, value: String)] = [
            ("copies", String(job.copies)),
            ("sides", job.twoSided ? "two-sided-long-edge" : "one-sided"),
            ("multiple-document-handling", "separate-documents-collated-copies"),
            // A PDF page at its size, only shrunk when larger than the paper; a picture fills it (Windows' PageSizing).
            ("print-scaling", sizing == .fitToPaper ? "fit" : "auto-fit"),
        ]
        if let paper = job.paper { o.append(("media", paper)) }
        return o
    }

    /// A drive with no room for the job's pages (about 2 MB a page) says so before anything is drawn.
    private static func checkRoom(_ file: URL, pages: Int) throws {
        let folder = file.deletingLastPathComponent()
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Int64(pages) * (2 << 20) {
            throw BatchFileError("This Mac's disk has no room to prepare the file's pages.")
        }
    }

    /// Draws each page and writes it into a PDF at its size, one page in memory at a time. Returns the pages written.
    private static func draw(_ document: any BatchDocument, _ job: BatchPrintJob, into file: URL, progress: (@Sendable (String) -> Void)?,
                             _ stop: BatchStop) async throws -> Int {
        guard let consumer = CGDataConsumer(url: file as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw BatchFileError("The file's pages can't be prepared on this Mac's disk.")
        }
        var written = 0
        var closed = false
        defer { if !closed { pdf.closePDF() } }
        for (i, number) in job.pages.enumerated() {
            try stop.check()
            progress?("Getting page \(i + 1) of \(job.pages.count) ready…")
            let page = try await document.render(number, stop)
            guard let source = CGImageSourceCreateWithData(Data(page.jpeg) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BatchFileError("Page \(number) can't be drawn.") }
            var box = CGRect(x: 0, y: 0, width: page.widthInches * 72, height: page.heightInches * 72)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(image, in: box)
            pdf.endPage()
            written += 1
        }
        pdf.closePDF()
        closed = true
        if written != job.pages.count { throw BatchFileError("Fewer pages were drawn than the file has: not printed.") }
        return written
    }

    /// The size of a paper the queue names without dimensions (a PPD's "Letter"), from cupsd's media list.
    private static func mediaSize(_ queue: String, _ paper: String) async -> (width: Double, height: Double)? {
        await LibCups().media(queue).first { $0.name == paper }.map { ($0.width * 72, $0.height * 72) }
    }

    /// Creates the job held and writes the PDF into it in pieces. Returns its id.
    private static func holdJob(_ queue: String, _ file: URL, title: String, _ options: [(name: String, value: String)]) async throws -> Int {
        let sent: Result<Int, PrintJobSendError> = await LibCups.run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            let words = { cupsLastErrorString().map { String(cString: $0) } ?? "macOS's printing system refused the job." }
            var list: UnsafeMutablePointer<cups_option_t>?
            var count: Int32 = 0
            for o in options + [("job-hold-until", "indefinite")] { count = cupsAddOption(o.name, o.value, count, &list) }
            defer { cupsFreeOptions(count, list) }
            let job = cupsCreateJob(nil, queue, title, count, list)
            guard job > 0 else { return .failure(PrintJobSendError(words())) }
            func fail() -> Result<Int, PrintJobSendError> {
                let said = words()
                cupsCancelJob2(nil, queue, job, 0)
                return .failure(PrintJobSendError(said))
            }
            guard let handle = try? FileHandle(forReadingFrom: file) else { return fail() }
            defer { try? handle.close() }
            guard cupsStartDocument(nil, queue, job, title, "application/pdf", 1) == HTTP_STATUS_CONTINUE else { return fail() }
            while true {
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: 1 << 16) ?? Data() // nil: the end of the file
                } catch {
                    _ = cupsFinishDocument(nil, queue)
                    return fail()
                }
                if chunk.isEmpty { break }
                let wrote = chunk.withUnsafeBytes { raw in cupsWriteRequestData(nil, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count) }
                if wrote != HTTP_STATUS_CONTINUE {
                    _ = cupsFinishDocument(nil, queue)
                    return fail()
                }
            }
            guard cupsFinishDocument(nil, queue).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else { return fail() }
            return .success(Int(job))
        }
        return try sent.get()
    }

    /// What cupsd keeps for the job: its copies, sides and paper (Get-Job-Attributes).
    struct Ticket {
        var copies: Int?
        var sides: String?
        var media: String?
        var mediaCol: String?
    }

    static func ticket(_ job: Int) async -> Ticket? {
        await LibCups.run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            guard let request = ippNewRequest(IPP_OP_GET_JOB_ATTRIBUTES) else { return nil }
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "job-uri", nil, "ipp://localhost/jobs/\(job)")
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
            guard let response = cupsDoRequest(nil, request, "/") else { return nil }
            defer { ippDelete(response) }
            guard ippGetStatusCode(response).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else { return nil }
            func text(_ name: String) -> String? {
                guard let attr = ippFindAttribute(response, name, IPP_TAG_ZERO) else { return nil }
                var buffer = [CChar](repeating: 0, count: 2048)
                ippAttributeString(attr, &buffer, buffer.count)
                return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            let copies = ippFindAttribute(response, "copies", IPP_TAG_INTEGER).map { Int(ippGetInteger($0, 0)) }
            return Ticket(copies: copies, sides: text("sides"), media: text("media"), mediaCol: text("media-col"))
        }
    }

    /// Lets a held job print (Release-Job). Nil when cupsd took it; else its words.
    private static func release(_ queue: String, _ job: Int) async -> String? {
        await LibCups.run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            guard let request = ippNewRequest(IPP_OP_RELEASE_JOB) else { return "macOS's printing system couldn't be asked." }
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "job-uri", nil, "ipp://localhost/jobs/\(job)")
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
            let response = cupsDoRequest(nil, request, "/")
            defer { if let response { ippDelete(response) } }
            guard let response, ippGetStatusCode(response).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else {
                return cupsLastErrorString().map { String(cString: $0) } ?? "refused"
            }
            return nil
        }
    }
}

/// A list several threads add to.
final class LockedList<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

extension Array where Element == String {
    /// The strings as C strings for one call.
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies = map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
