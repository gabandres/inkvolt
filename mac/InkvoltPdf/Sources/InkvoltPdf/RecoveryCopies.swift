import AppKit
import PdfCore

/// Recovery copies of unsaved work (the core's `RecoveryStore`, as on Windows): every document with unsaved changes gets
/// a copy at most every 20 seconds after a change, written in the background as Save would write it; the copy goes when
/// the document is saved, undone back to its saved state or closed, and all of them on a normal quit. At launch, copies a
/// crashed or killed run left are offered back: Restore, Discard, or Not Now (asked again next time).
@MainActor
final class RecoveryCopies {
    static let shared = RecoveryCopies()

    private var store: RecoveryStore?
    private var root = ""
    /// Documents with a copy waiting to be written, and those that have one on disk.
    private var scheduled: Set<String> = []
    private var written: Set<String> = []
    private let writer = DispatchQueue(label: "inkvolt.pdf.recovery", qos: .utility)
    /// Seconds between a change and its copy (shorter in the self-test).
    var interval = 20.0
    /// Documents whose copy is on disk now (the self-test waits on it).
    private var onDisk: Set<String> = []
    /// Settings' Keep recovery copies: off, no copy is written and those written go.
    var enabled = true {
        didSet {
            guard !enabled else { return }
            scheduled.removeAll()
            for id in written { remove(id) }
        }
    }

    func hasCopy(_ document: PdfDocument) -> Bool { onDisk.contains(document.recoveryId) }

    /// The folder the copies live in (`--recovery-root` points the self-test elsewhere).
    static func defaultRoot() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("com.bermudezsystems.InkvoltPdf/Recovery").path
    }

    /// Finds what earlier runs left, starts this run's folder, then offers the left-overs back.
    func start(root: String, ask: Bool) {
        self.root = root
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        RecoveryStore.discardEmpty(root)
        let left = RecoveryStore.findLeftOver(root)
        store = try? RecoveryStore.start(root)
        guard !left.isEmpty else { return }
        if Report.restoresRecovery {
            restore(left)
            return
        }
        guard ask else { return }
        let alert = NSAlert()
        alert.messageText = left.count == 1
            ? "Inkvolt PDF closed before “\(left[0].info.displayName)” was saved."
            : "Inkvolt PDF closed before \(left.count) documents were saved."
        alert.informativeText = "Restore opens them with their changes. Discard deletes the copies; Not Now asks again next time."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn: restore(left)
        case .alertSecondButtonReturn: RecoveryStore.discard(left)
        default: break
        }
    }

    /// Opens each left-over copy as an unsaved document, back at its page.
    private func restore(_ left: [LeftOverDocument]) {
        for copy in left {
            guard let bytes = FileManager.default.contents(atPath: copy.pdfPath) else { continue } // held by something: kept
            let info = copy.info
            var stamp: DiskStamp?
            if let length = info.originalLength, let time = info.originalWriteTime { stamp = DiskStamp(length: length, writeTime: time) }
            var password: String?
            var wrong = false
            var session: DocumentSession?
            while session == nil {
                do {
                    session = try DocumentSession.recover([UInt8](bytes), originalPath: info.originalPath, info.displayName,
                                                          diskStamp: stamp, password: password)
                } catch is PasswordRequired {
                    guard let given = PasswordPrompt.ask(file: info.displayName, wrong: wrong) else { break }
                    password = given
                    wrong = true
                } catch {
                    RecoveryStore.remove(copy) // not a PDF: dropped as damaged
                    break
                }
            }
            guard let session else { continue }
            let document = PdfDocument(recovered: session, page: info.page, fileDate: info.originalWriteTime)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            RecoveryStore.remove(copy)
            Report.note("RECOVERED a document (\(session.engine.pageCount) pages, dirty: \(session.isDirty))")
        }
    }

    /// The document changed or was saved: a copy is due (unsaved changes), or its copy goes (saved, or back to saved).
    func changed(_ document: PdfDocument) {
        guard store != nil, let session = document.session else { return }
        let id = document.recoveryId
        if !session.isDirty || !enabled {
            remove(id)
            return
        }
        if scheduled.contains(id) { return }
        scheduled.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak document] in
            MainActor.assumeIsolated {
                self.scheduled.remove(id)
                if let document { self.write(document) }
            }
        }
    }

    private func write(_ document: PdfDocument) {
        guard enabled, let store, let session = document.session, session.isDirty else { return }
        let id = document.recoveryId
        let stamp = session.diskStampWhenRead
        let page = (document.windowControllers.first as? DocumentWindowController)?.pages.currentPage ?? 0
        let info = RecoveryInfo(displayName: session.displayName, originalPath: session.filePath, originalLength: stamp?.length,
                                originalWriteTime: stamp?.writeTime, saved: Date(), page: page)
        let bytes = session.data
        written.insert(id)
        writer.async {
            let ok = (try? store.write(id, bytes, info)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !ok { self.changed(document) } // written again on the next pass
                    else if self.written.contains(id) { self.onDisk.insert(id) }
                }
            }
        }
    }

    private func remove(_ id: String) {
        onDisk.remove(id)
        guard let store, written.remove(id) != nil else { return }
        writer.async { store.remove(id) }
    }

    func closed(_ document: PdfDocument) {
        scheduled.remove(document.recoveryId)
        remove(document.recoveryId)
    }

    /// A normal quit: every copy and this run's folder go.
    func quit() {
        let store = store
        self.store = nil
        writer.sync { store?.close() }
    }
}
