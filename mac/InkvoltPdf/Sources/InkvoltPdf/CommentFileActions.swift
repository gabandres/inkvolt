import AppKit
import PdfCore
import UniformTypeIdentifiers

/// Tools › Annotate › Import Comments… and Export Comments… (roadmap 1.4; the Windows app's `CommentFileActions`):
/// `CommentFiles` as XFDF, FDF or CSV. Import is an edit (one undo step) that only adds: what is already in the document
/// is skipped and listed, never replaced.
extension DocumentWindowController {
    static let commentFormats: [(format: CommentFileFormat, title: String)] = [
        (.xfdf, "XFDF, for Acrobat and other PDF apps"),
        (.fdf, "FDF, keeps every appearance"),
        (.csv, "CSV, a row per comment, for spreadsheets"),
    ]

    private static let commentFormatKey = "CommentFileFormat"

    static func commentTypes(_ format: CommentFileFormat?) -> [UTType] {
        let names = format.map { [CommentFiles.fileExtension($0)] } ?? ["xfdf", "fdf", "csv", "xml", "txt"]
        return names.compactMap { UTType(filenameExtension: $0) }
    }

    @objc func exportComments(_ sender: Any?) {
        guard let window, let session = pdf.session else { return }
        if session.openPassword != nil
            && !confirmUnprotected("The comments are saved without the document's password protection: anyone can read them.", "Export Anyway") {
            return
        }
        let saved = UserDefaults.standard.integer(forKey: Self.commentFormatKey)
        let start = Self.commentFormats.indices.contains(saved) ? saved : 0
        let panel = NSSavePanel()
        panel.title = "Export Comments"
        panel.message = "Save this document's comments and their replies to a file another app or a spreadsheet can read."
        panel.nameFieldStringValue = (session.displayName as NSString).deletingPathExtension
        panel.allowedContentTypes = Self.commentTypes(Self.commentFormats[start].format)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.commentFormats.map(\.title))
        popUp.selectItem(at: start)
        popUp.setAccessibilityLabel("File format")
        let chooser = CommentFormatChooser(panel)
        popUp.target = chooser
        popUp.action = #selector(CommentFormatChooser.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popUp])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(chooser) {}
                guard response == .OK, let url = panel.url else { return }
                let index = max(popUp.indexOfSelectedItem, 0)
                UserDefaults.standard.set(index, forKey: Self.commentFormatKey)
                let format = CommentFiles.format(ofPath: url.path) ?? Self.commentFormats[index].format
                self.startLongTask { _ = await self.exportComments(to: url, format) }
            }
        }
    }

    /// Writes the comments to `url`; nil when nothing was written (no comments, or it failed: said to the user).
    @discardableResult
    func exportComments(to url: URL, _ format: CommentFileFormat) async -> CommentExport? {
        guard let session = pdf.session else { return nil }
        let data = session.data, password = session.password, name = session.displayName
        let result: Result<CommentExport, Error> = await Task.detached {
            Result { try CommentFiles.export(data, password, format, pdfFileName: name) }
        }.value
        switch result {
        case .failure(let error):
            pdf.showError("The comments couldn't be exported.", error)
            return nil
        case .success(let export):
            if export.count == 0 {
                commentAlert("No comments", (["This document has no comments to export, so no file was saved."] + export.left).joined(separator: "\n\n"))
                return nil
            }
            do {
                try Data(export.data).write(to: url, options: .atomic)
            } catch {
                pdf.showError("The comments couldn't be saved.", error)
                return nil
            }
            notify("Exported \(Self.commentCount(export.count, "comment", "comments")) to \(url.lastPathComponent).")
            if !export.left.isEmpty { commentAlert("Some annotations weren't exported", export.left.joined(separator: "\n")) }
            return export
        }
    }

    @objc func importComments(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Comments"
        panel.message = "Choose an XFDF, FDF or CSV file of comments. They are added to this document; the ones it already has are skipped."
        panel.allowedContentTypes = Self.commentTypes(nil)
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self.startLongTask { _ = await self.importComments(from: url) }
            }
        }
    }

    /// Imports the comments of the file at `url` as one undo step and says what was added and skipped; nil when the file
    /// was refused or the edit didn't happen.
    @discardableResult
    func importComments(from url: URL) async -> CommentImport? {
        let name = url.lastPathComponent
        let checked: Result<[UInt8], Error> = await Task.detached {
            Result {
                let file = [UInt8](try Data(contentsOf: url))
                _ = try CommentFiles.count(file) // a file that isn't comments is refused before the edit
                return file
            }
        }.value
        let file: [UInt8]
        switch checked {
        case .failure(let error):
            commentAlert("Can't import \(name)", (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        case .success(let bytes):
            file = bytes
        }
        let box = EditBox<CommentImport>()
        _ = await editor.run("Import comments", contentOnly: true) { data, pw in
            let r = try CommentFiles.importComments(data, pw, file)
            box.value = r
            return r.data
        }
        guard let result = box.value else { return nil }
        let summary = result.added == 0 ? "No comments were added."
            : "\(Self.commentCount(result.added, "comment was", "comments were")) added. You can undo this until you save."
        if result.skipped.isEmpty && result.notes.isEmpty {
            notify(summary, canUndo: result.added > 0)
        } else {
            var text = summary
            if !result.skipped.isEmpty { text += " \(Self.commentCount(result.skipped.count, "was", "were")) skipped:" }
            let list = result.skipped.prefix(2000).joined(separator: "\n")
                + (result.skipped.count > 2000 ? "\n… and \((result.skipped.count - 2000).formatted()) more" : "")
            commentAlert("Comments Imported", ([text] + result.notes).joined(separator: "\n\n"), list: result.skipped.isEmpty ? nil : list)
        }
        return result
    }

    /// An informational alert (a sheet), with an optional scrolling list of lines; in the self-test a notice instead.
    func commentAlert(_ message: String, _ detail: String, list: String? = nil) {
        if Report.skipsDialogs { return notify("\(message). \(detail)") }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let list {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.string = list
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.autoresizingMask = [.width]
            text.setAccessibilityLabel("Skipped comments")
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func commentCount(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(many)" }
}

/// Export Comments' Format pop-up: the save panel's file type follows it.
@MainActor
final class CommentFormatChooser: NSObject {
    private weak var panel: NSSavePanel?

    init(_ panel: NSSavePanel) { self.panel = panel }

    @objc func changed(_ sender: NSPopUpButton) {
        let formats = DocumentWindowController.commentFormats
        guard formats.indices.contains(sender.indexOfSelectedItem) else { return }
        panel?.allowedContentTypes = DocumentWindowController.commentTypes(formats[sender.indexOfSelectedItem].format)
    }
}
