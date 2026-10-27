import Foundation
import MuPDFShim

/// A document needs a password to open (the Windows app's `PasswordRequiredException`); `wrongPassword` when one was
/// given and didn't open it.
public struct PasswordRequired: Error, Equatable, Sendable {
    public var wrongPassword: Bool
}

/// MuPDF couldn't do it: its own message.
public struct PdfEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// A page drawn: RGB, three bytes a pixel, rows packed (the Windows `RenderedImage`, there BGRA).
public struct RenderedImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]
}

/// One open PDF through MuPDF (the Windows app's `PdfEngine`). A MuPDF context and its document belong to one thread at
/// a time, so every call takes the engine's lock. D0: open, pages, drawing and text; D1 ports the rest with
/// EngineTests.
public final class PdfEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let ctx: UnsafeMutableRawPointer
    private let doc: OpaquePointer

    /// Opens a PDF from its bytes, with its password when it has one.
    public static func open(_ data: [UInt8], password: String? = nil) throws -> PdfEngine {
        guard let ctx = inkv_new_context() else { throw PdfEngineError(message: "MuPDF couldn't start.") }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard let doc = data.withUnsafeBufferPointer({ inkv_open_pdf(ctx, $0.baseAddress, $0.count, &err) }) else {
            inkv_drop_context(ctx)
            throw PdfEngineError(message: Self.text(err))
        }
        if inkv_needs_password(ctx, doc) != 0 {
            guard let password, inkv_authenticate(ctx, doc, password) != 0 else {
                inkv_drop_doc(ctx, doc)
                inkv_drop_context(ctx)
                throw PasswordRequired(wrongPassword: password != nil)
            }
        }
        return PdfEngine(ctx: ctx, doc: doc)
    }

    private init(ctx: UnsafeMutableRawPointer, doc: OpaquePointer) {
        self.ctx = ctx
        self.doc = doc
    }

    deinit {
        inkv_drop_doc(ctx, doc)
        inkv_drop_context(ctx)
    }

    public var pageCount: Int {
        get throws {
            try call { err in
                let n = inkv_count_pages(ctx, doc, err)
                return n < 0 ? nil : Int(n)
            }
        }
    }

    /// The page's size in points as drawn (its rotation applied).
    public func pageSize(_ page: Int) throws -> (width: Double, height: Double) {
        try call { err in
            var r = [Float](repeating: 0, count: 4)
            guard inkv_page_bounds(ctx, doc, Int32(page), &r, err) != 0 else { return nil }
            return (Double(r[2] - r[0]), Double(r[3] - r[1]))
        }
    }

    /// The page drawn at `scale` (1: 72 dpi).
    public func render(_ page: Int, scale: Double) throws -> RenderedImage {
        try call { err in
            var pixels: UnsafeMutablePointer<UInt8>?
            var width: Int32 = 0, height: Int32 = 0
            guard inkv_render_rgb(ctx, doc, Int32(page), Float(scale), &pixels, &width, &height, err) != 0, let pixels else { return nil }
            defer { inkv_free(pixels) }
            let count = Int(width) * Int(height) * 3
            return RenderedImage(width: Int(width), height: Int(height), pixels: Array(UnsafeBufferPointer(start: pixels, count: count)))
        }
    }

    /// The page's text, lines separated by newlines.
    public func text(_ page: Int) throws -> String {
        try call { err in
            guard let text = inkv_page_text(ctx, doc, Int32(page), err) else { return nil }
            defer { inkv_free(text) }
            return String(cString: text)
        }
    }

    /// One shim call under the lock: nil from `body` is MuPDF's error, thrown with its message.
    private func call<T>(_ body: (UnsafeMutablePointer<CChar>) -> T?) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let result = err.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
        guard let result else { throw PdfEngineError(message: Self.text(err)) }
        return result
    }

    private static func text(_ err: [CChar]) -> String {
        let bytes = err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? "MuPDF failed." : String(decoding: bytes, as: UTF8.self)
    }
}
