import CCups
import Foundation
import PrintCore

/// A job that couldn't be sent, in plain words.
public struct PrintJobSendError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// What cupsd holds for one job (Get-Job-Attributes): its state and the photo options it took.
public struct SentJob: Equatable, Sendable {
    public var state: Int
    public var reasons: [String]
    public var attributes: [String: String]
}

/// Print Photos' jobs, sent straight to the printer's queue (as the Windows app sends them with its print ticket) rather
/// than through the print panel, so the paper type, quality and color picked in the Photos window are the job's.
extension LibCups {
    /// The queue's paper types, qualities and color modes, with its defaults (`cupsCopyDestInfo`); none when cupsd can't say.
    public func jobOptions(_ queue: String) async -> QueueJobOptions {
        await Self.run {
            guard let dest = cupsGetNamedDest(nil, queue, nil) else { return .none }
            defer { cupsFreeDests(1, dest) }
            guard let info = cupsCopyDestInfo(nil, dest) else { return .none }
            defer { cupsFreeDestInfo(info) }
            func strings(_ attr: OpaquePointer?) -> [String] {
                guard let attr else { return [] }
                return (0..<ippGetCount(attr)).compactMap { i in ippGetString(attr, i, nil).map { String(cString: $0) } }
            }
            func integers(_ attr: OpaquePointer?) -> [Int] {
                guard let attr else { return [] }
                return (0..<ippGetCount(attr)).map { Int(ippGetInteger(attr, $0)) }
            }
            let quality = integers(cupsFindDestDefault(nil, dest, info, "print-quality")).first
            return QueueJobOptions(
                mediaTypes: strings(cupsFindDestSupported(nil, dest, info, "media-type")),
                defaultMediaType: strings(cupsFindDestDefault(nil, dest, info, "media-type")).first,
                qualities: integers(cupsFindDestSupported(nil, dest, info, "print-quality")),
                defaultQuality: quality,
                colorModes: strings(cupsFindDestSupported(nil, dest, info, "print-color-mode")),
                defaultColorMode: strings(cupsFindDestDefault(nil, dest, info, "print-color-mode")).first)
        }
    }

    /// Sends a PDF to the queue on `media` with `options` (CUPS option names and values), over cupsd's socket; `hold`
    /// keeps it held (`job-hold-until` indefinite) so it can be read back and cancelled without printing. Returns the job's id.
    public func printPdf(_ queue: String, _ pdf: Data, title: String, media: QueueMedia?, options: [(name: String, value: String)],
                         hold: Bool = false) async throws -> Int {
        let all = options + (hold ? [("job-hold-until", "indefinite")] : [])
        let sent: Result<Int, PrintJobSendError> = await Self.run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            let words = { cupsLastErrorString().map { String(cString: $0) } ?? "macOS's printing system refused the job." }
            var list: UnsafeMutablePointer<cups_option_t>?
            var count: Int32 = 0
            for o in all { count = cupsAddOption(o.name, o.value, count, &list) }
            if let media { count = Self.addMedia(media, queue: queue, count, &list) }
            defer { cupsFreeOptions(count, list) }
            let job = cupsCreateJob(nil, queue, title, count, list)
            guard job > 0 else { return .failure(PrintJobSendError(words())) }
            guard cupsStartDocument(nil, queue, job, title, "application/pdf", 1) == HTTP_STATUS_CONTINUE else {
                cupsCancelJob2(nil, queue, job, 0)
                return .failure(PrintJobSendError(words()))
            }
            let wrote = pdf.withUnsafeBytes { raw in
                cupsWriteRequestData(nil, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
            }
            let finished = cupsFinishDocument(nil, queue)
            guard wrote == HTTP_STATUS_CONTINUE, finished.rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else {
                cupsCancelJob2(nil, queue, job, 0)
                return .failure(PrintJobSendError(words()))
            }
            return .success(Int(job))
        }
        return try sent.get()
    }

    /// The job as cupsd holds it: state, reasons, and the photo options it took (`media`, `media-type`, `print-quality`,
    /// `print-color-mode`, `job-hold-until`, as IPP words them; `media-col` too); nil when cupsd doesn't know it.
    public func sentJob(_ job: Int) async -> SentJob? {
        await Self.run {
            guard let request = ippNewRequest(IPP_OP_GET_JOB_ATTRIBUTES) else { return nil }
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "job-uri", nil, "ipp://localhost/jobs/\(job)")
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
            guard let response = cupsDoRequest(nil, request, "/") else { return nil }
            defer { ippDelete(response) }
            guard ippGetStatusCode(response).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else { return nil }
            func text(_ name: String) -> String? {
                guard let attr = ippFindAttribute(response, name, IPP_TAG_ZERO) else { return nil }
                var buffer = [CChar](repeating: 0, count: 1024)
                ippAttributeString(attr, &buffer, buffer.count)
                return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            var attributes: [String: String] = [:]
            for name in ["media", "media-col", "media-type", "print-quality", "print-color-mode", "job-hold-until"] {
                if let value = text(name) { attributes[name] = value }
            }
            var reasons: [String] = []
            if let attr = ippFindAttribute(response, "job-state-reasons", IPP_TAG_KEYWORD) {
                reasons = (0..<ippGetCount(attr)).compactMap { ippGetString(attr, $0, nil).map { String(cString: $0) } }
            }
            let state = ippFindAttribute(response, "job-state", IPP_TAG_ENUM).map { Int(ippGetInteger($0, 0)) } ?? 0
            return SentJob(state: state, reasons: reasons, attributes: attributes)
        }
    }

    /// The paper as libcups words it for this queue (`media-col`: its size and the margins, zero for borderless): the
    /// queue's own entry by name and borderlessness, else its nearest by size; plain `media` when cupsd can't say.
    /// `cupsAddDestMediaOptions` adds nothing on the default connection, so it gets one of its own to cupsd's socket.
    private static func addMedia(_ media: QueueMedia, queue: String, _ count: Int32,
                                 _ list: inout UnsafeMutablePointer<cups_option_t>?) -> Int32 {
        guard let http = httpConnect2(cupsServer(), ippPort(), nil, AF_UNSPEC, cupsEncryption(), 1, 30000, nil) else {
            return cupsAddOption("media", media.name, count, &list)
        }
        defer { httpClose(http) }
        guard let dest = cupsGetNamedDest(http, queue, nil) else { return cupsAddOption("media", media.name, count, &list) }
        defer { cupsFreeDests(1, dest) }
        guard let info = cupsCopyDestInfo(http, dest) else { return cupsAddOption("media", media.name, count, &list) }
        defer { cupsFreeDestInfo(info) }
        let flags = UInt32(media.isBorderless ? CUPS_MEDIA_FLAGS_BORDERLESS : CUPS_MEDIA_FLAGS_DEFAULT)
        var size = cups_size_t()
        var found = false
        for i in 0..<cupsGetDestMediaCount(http, dest, info, UInt32(CUPS_MEDIA_FLAGS_DEFAULT)) where !found {
            guard cupsGetDestMediaByIndex(http, dest, info, i, UInt32(CUPS_MEDIA_FLAGS_DEFAULT), &size) != 0 else { continue }
            let name = withUnsafeBytes(of: size.media) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            let borderless = size.left == 0 && size.right == 0 && size.top == 0 && size.bottom == 0
            found = name == media.name && borderless == media.isBorderless
        }
        if !found {
            let width = Int32((media.width * 2540).rounded()), length = Int32((media.height * 2540).rounded())
            found = cupsGetDestMediaBySize(http, dest, info, width, length, flags, &size) != 0
        }
        guard found else { return cupsAddOption("media", media.name, count, &list) }
        let added = cupsAddDestMediaOptions(http, dest, info, flags, &size, count, &list)
        return added > count ? added : cupsAddOption("media", media.name, count, &list)
    }
}
