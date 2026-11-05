import AppKit
import PdfCore

/// Tools › Snapshot (⌥⌘C; the reading tools' third segment): a rectangle dragged on a page goes to the clipboard as a
/// picture, PNG and TIFF, at the resolution `Snapshot` picks (PdfCore), sized in points so an app pastes it at the size
/// it shows on the page. Esc during the drag cancels it (the pages' Esc), and Esc again leaves the tool. As on Windows,
/// copying is all it does; the picture is rendered off the main thread.
extension DocumentWindowController {
    @objc func chooseSnapshot(_ sender: Any?) {
        pickTool(.snapshot)
    }

    func copySnapshot(_ engine: PdfEngine, page: Int, region: RectD, viewScale: Double, rotation: Int) {
        let shown = Snapshot.shownSize(region, rotation: rotation)
        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> Result<RenderedImage, any Error> in
                Result { try Snapshot.render(engine, page: page, region: region, viewScale: viewScale, rotation: rotation) }
            }.value
            guard let self else { return }
            switch rendered {
            case .success(let image):
                if SnapshotBoard.write(image, points: NSSize(width: shown.width, height: shown.height), to: SnapshotBoard.board) {
                    self.notify("Snapshot copied (\(image.width) × \(image.height) px)")
                } else {
                    self.notify("Couldn't copy the snapshot: the clipboard didn't take it.")
                }
            case .failure(let error):
                self.notify(SnapshotBoard.failure(error))
            }
        }
    }
}

/// The snapshot on a pasteboard.
@MainActor
enum SnapshotBoard {
    /// Where snapshots go: the clipboard (the self-test's own pasteboard while it runs, so a person's clipboard stays).
    static var board = NSPasteboard.general
    /// Puts `image` on `board` as PNG and TIFF, `points` big (its resolution follows: 2 pixels a point is 144 dpi).
    static func write(_ image: RenderedImage, points: NSSize, to board: NSPasteboard) -> Bool {
        guard let cg = PageRenderer.cgImage(image) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        if points.width > 0, points.height > 0 { rep.size = points }
        guard let png = rep.representation(using: .png, properties: [:]), let tiff = rep.tiffRepresentation else { return false }
        board.clearContents()
        board.declareTypes([.png, .tiff], owner: nil)
        return board.setData(png, forType: .png) && board.setData(tiff, forType: .tiff)
    }

    /// What the notice says when the picture couldn't be made (Windows' words).
    nonisolated static func failure(_ error: any Error) -> String {
        if error is PdfEngineClosed { return "Couldn't copy the snapshot: the document changed meanwhile. Try again." }
        if error is CancellationError { return "Couldn't copy the snapshot: it was cancelled." }
        return "Couldn't copy the snapshot: \(error)"
    }
}
