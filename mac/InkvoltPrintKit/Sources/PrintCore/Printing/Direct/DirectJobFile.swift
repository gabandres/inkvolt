import Foundation

/// Print-Job's body on disk (Windows' temporary raster file): the request's attributes, then the raster as it's drawn, page
/// by page, so a job is never held in memory; uploaded from the file (`IppClient.printJob(file:)`). The one who names the
/// file deletes it once the job is sent or given up. Mac difference: a job past `maxBytes` is refused before anything is
/// sent (Windows has no limit; its file is on disk as well, but nothing there bounds it).
public final class DirectJobFile {
    /// The most a job's body may hold: 1 GB (a 50-page photo PDF at 600 dpi on an inkjet is tens of GB uncompressed).
    public static let maxBytes = 1 << 30

    public let url: URL
    public private(set) var bytes: Int
    private let limit: Int
    private var handle: FileHandle?

    /// A new file at `url` (refused when one is there) starting with `request`.
    public init(_ url: URL, request: [UInt8], limit: Int = DirectJobFile.maxBytes) throws {
        (self.url, self.limit, bytes) = (url, limit, 0)
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        try append(request)
    }

    deinit { try? handle?.close() }

    /// The next bytes. Throws `DirectJob.tooLarge()` past the limit (nothing more is written; nothing was sent).
    public func append(_ more: [UInt8]) throws {
        guard !more.isEmpty else { return }
        guard more.count <= limit - bytes else { throw DirectJob.tooLarge() }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: more)
        bytes += more.count
    }

    /// Closes the file: what `DirectJob.send` uploads.
    public func finish() throws -> DirectJobUpload {
        try handle?.close()
        handle = nil
        return DirectJobUpload(url: url, bytes: bytes)
    }

    /// A file for a job in the temporary folder, named so no other job's is taken.
    public static func temporaryUrl() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-\(UUID().uuidString).ipp")
    }
}

/// A finished `DirectJobFile`: where it is and how long.
public struct DirectJobUpload: Sendable, Equatable {
    public let url: URL
    public let bytes: Int
}
