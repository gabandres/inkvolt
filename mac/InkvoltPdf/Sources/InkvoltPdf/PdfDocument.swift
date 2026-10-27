import AppKit
import PdfCore

/// One open PDF (read only in this slice): its bytes and the MuPDF engine over them. Open, Open Recent, Finder's Open
/// With and window tabs come from NSDocument; the engine is opened when the window is made, after asking for the
/// password if the file needs one.
@objc(PdfDocument)
final class PdfDocument: NSDocument {
    // Set by read(from:ofType:), which AppKit calls on the main thread (no concurrent reading) before any window.
    nonisolated(unsafe) private var bytes: [UInt8] = []
    private(set) var engine: PdfEngine?

    /// The file's bytes as read.
    var fileBytes: [UInt8] { bytes }

    override class var autosavesInPlace: Bool { false }

    /// The name shown for the document.
    var name: String { displayName ?? "This document" }

    override func read(from data: Data, ofType typeName: String) throws {
        bytes = [UInt8](data)
    }

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.featureUnsupported) // a viewer for now: nothing is saved
    }

    override func makeWindowControllers() {
        guard let engine = openEngine() else {
            // Cancelled or unreadable: the document goes away once AppKit has finished opening it.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.close() } }
            return
        }
        self.engine = engine
        addWindowController(DocumentWindowController(document: self, engine: engine))
    }

    override func close() {
        super.close()
        engine?.close()
        engine = nil
    }

    /// The engine over the file's bytes, with at least a page to show (a damaged file MuPDF repairs to no pages is an error).
    private func openEngine() -> PdfEngine? {
        guard let engine = openWithPassword() else { return nil }
        if engine.pageCount == 0 {
            engine.close()
            fail(NoPages())
            return nil
        }
        return engine
    }

    /// The engine over the file's bytes: with the report's password, else the user's, asked again after a wrong one.
    private func openWithPassword() -> PdfEngine? {
        do {
            return try PdfEngine.open(bytes, password: Report.password)
        } catch is PasswordRequired {
        } catch {
            fail(error)
            return nil
        }
        var wrong = false
        while let password = PasswordPrompt.ask(file: name, wrong: wrong) {
            do {
                return try PdfEngine.open(bytes, password: password)
            } catch is PasswordRequired {
                wrong = true
            } catch {
                fail(error)
                return nil
            }
        }
        return nil
    }

    private func fail(_ error: Error) {
        Report.failed(name, error)
        let alert = NSAlert()
        alert.messageText = "\(name) couldn't be opened."
        alert.informativeText = "\(error)"
        if !Report.isRunning { alert.runModal() }
    }
}

/// Asks for a document's open password.
@MainActor
enum PasswordPrompt {
    static func ask(file: String, wrong: Bool) -> String? {
        if Report.isRunning { return nil }
        let alert = NSAlert()
        alert.messageText = wrong ? "That password doesn't open \(file)." : "\(file) is protected with a password."
        alert.informativeText = "Type its password to open it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// A file that opened (MuPDF repaired it) with no page to show.
struct NoPages: Error, CustomStringConvertible {
    var description: String { "The file is damaged: no page of it could be read." }
}
