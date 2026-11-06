import AppKit
import PdfCore
import PrintCore

/// Tools › Snapshot (⌥⌘C; the reading tools' third segment): a rectangle dragged on a page goes to the clipboard as a
/// picture, PNG and TIFF, at the resolution `Snapshot` picks (PdfCore), sized in points so an app pastes it at the size
/// it shows on the page. Esc during the drag cancels it (the pages' Esc), and Esc again leaves the tool. As on Windows,
/// copying is all it does; the picture is rendered off the main thread.
extension DocumentWindowController {
    @objc func chooseSnapshot(_ sender: Any?) {
        pickTool(.snapshot)
    }

    /// Renders and encodes the picture off the main thread, then puts it on the clipboard. A newer snapshot cancels this
    /// one: only the latest reaches the clipboard, whichever is rendered first.
    func copySnapshot(_ engine: PdfEngine, page: Int, region: RectD, viewScale: Double, rotation: Int) {
        let shown = Snapshot.shownSize(region, rotation: rotation)
        let points = NSSize(width: shown.width, height: shown.height)
        snapshotCancel?.cancel()
        let cancel = CancelToken()
        snapshotCancel = cancel
        Task { @MainActor [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> Result<SnapshotPicture?, any Error> in
                Result {
                    let image = try Snapshot.render(engine, page: page, region: region, viewScale: viewScale, rotation: rotation, cancel: cancel)
                    return cancel.isCancelled ? nil : SnapshotBoard.encode(image, points: points)
                }
            }.value
            guard let self, !cancel.isCancelled else { return } // a newer snapshot took its place
            snapshotCancel = nil
            switch made {
            case .success(let picture):
                if let picture, SnapshotBoard.write(picture, to: SnapshotBoard.board) {
                    notify(loc("Snapshot copied ({0} × {1} px)", CoreLanguage.number(picture.width), CoreLanguage.number(picture.height)))
                } else {
                    notify(loc("Couldn't copy the snapshot: the clipboard didn't take it."))
                }
            case .failure(let error):
                notify(SnapshotBoard.failure(error))
            }
        }
    }
}

/// A snapshot as it goes on the pasteboard.
struct SnapshotPicture: Sendable {
    let png: Data, tiff: Data
    let width: Int, height: Int
}

/// The snapshot on a pasteboard.
@MainActor
enum SnapshotBoard {
    /// Where snapshots go: the clipboard (the self-test's own pasteboard while it runs, so a person's clipboard stays).
    static var board = NSPasteboard.general

    /// `image` as PNG and TIFF, `points` big (its resolution follows: 2 pixels a point is 144 dpi); up to 40 megapixels, so
    /// made off the main thread. Nil when it couldn't be encoded.
    nonisolated static func encode(_ image: RenderedImage, points: NSSize) -> SnapshotPicture? {
        guard let cg = PageRenderer.cgImage(image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if points.width > 0, points.height > 0 { rep.size = points }
        guard let png = rep.representation(using: .png, properties: [:]), let tiff = rep.tiffRepresentation else { return nil }
        return SnapshotPicture(png: png, tiff: tiff, width: image.width, height: image.height)
    }

    /// Puts `picture` on `board` (declaring its types clears what was there).
    static func write(_ picture: SnapshotPicture, to board: NSPasteboard) -> Bool {
        board.declareTypes([.png, .tiff], owner: nil)
        return board.setData(picture.png, forType: .png) && board.setData(picture.tiff, forType: .tiff)
    }

    /// What the notice says when the picture couldn't be made (Windows' words).
    nonisolated static func failure(_ error: any Error) -> String {
        if error is PdfEngineClosed { return loc("Couldn't copy the snapshot: the document changed meanwhile. Try again.") }
        if error is CancellationError { return loc("Couldn't copy the snapshot: it was cancelled.") }
        return loc("Couldn't copy the snapshot: {0}", error)
    }
}
