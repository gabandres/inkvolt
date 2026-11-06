import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// Tools › Annotate › Import Comments…, Export Comments… and Summarize Comments… (roadmap 1.4; the Windows app's
/// `CommentFileActions`): `CommentFiles` as XFDF, FDF or CSV, and `CommentSummary`'s PDF. Import is an edit (one undo step) that only adds: what is already in the document
/// is skipped and listed, never replaced.
extension DocumentWindowController {
    /// The Format pop-up's choices, in order (the saved choice is the index); titles in the interface's language.
    static var commentFormats: [(format: CommentFileFormat, title: String)] {
        [
            (.xfdf, loc("XFDF, for Acrobat and other PDF apps")),
            (.fdf, loc("FDF, keeps every appearance")),
            (.csv, loc("CSV, a row per comment, for spreadsheets")),
        ]
    }

    private static let commentFormatKey = "CommentFileFormat"

    static func commentTypes(_ format: CommentFileFormat?) -> [UTType] {
        let names = format.map { [CommentFiles.fileExtension($0)] } ?? ["xfdf", "fdf", "csv", "xml", "txt"]
        return names.compactMap { UTType(filenameExtension: $0) }
    }

    @objc func exportComments(_ sender: Any?) {
        guard let window, let session = pdf.session else { return }
        if session.openPassword != nil
            && !confirmUnprotected(loc("The comments are saved without the document's password protection: anyone can read them."), loc("Export Anyway")) {
            return
        }
        let saved = UserDefaults.standard.integer(forKey: Self.commentFormatKey)
        let start = Self.commentFormats.indices.contains(saved) ? saved : 0
        let panel = NSSavePanel()
        panel.title = loc("Export Comments")
        panel.message = loc("Save this document's comments and their replies to a file another app or a spreadsheet can read.")
        panel.nameFieldStringValue = (session.displayName as NSString).deletingPathExtension
        panel.allowedContentTypes = Self.commentTypes(Self.commentFormats[start].format)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.commentFormats.map(\.title))
        popUp.selectItem(at: start)
        popUp.setAccessibilityLabel(loc("File format"))
        let chooser = CommentFormatChooser(panel)
        popUp.target = chooser
        popUp.action = #selector(CommentFormatChooser.changed(_:))
        let label = NSTextField(labelWithString: loc("Format:"))
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
            pdf.showError(loc("The comments couldn't be exported."), error)
            return nil
        case .success(let export):
            if export.count == 0 {
                infoSheet(loc("No comments"), ([loc("This document has no comments to export, so no file was saved.")] + export.left).joined(separator: "\n\n"))
                return nil
            }
            do {
                try Data(export.data).write(to: url, options: .atomic)
            } catch {
                pdf.showError(loc("The comments couldn't be saved."), error)
                return nil
            }
            notify(export.count == 1
                ? loc("Exported {0} comment to {1}.", 1, url.lastPathComponent)
                : loc("Exported {0} comments to {1}.", CoreLanguage.number(export.count), url.lastPathComponent))
            if !export.left.isEmpty { infoSheet(loc("Some annotations weren't exported"), export.left.joined(separator: "\n")) }
            return export
        }
    }

    @objc func importComments(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = loc("Import Comments")
        panel.message = loc("Choose an XFDF, FDF or CSV file of comments. They are added to this document; the ones it already has are skipped.")
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
            infoSheet(loc("Can't import {0}", name), (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        case .success(let bytes):
            file = bytes
        }
        let box = EditBox<CommentImport>()
        _ = await editor.run(loc("Import comments"), contentOnly: true) { data, pw in
            let r = try CommentFiles.importComments(data, pw, file)
            box.value = r
            return r.data
        }
        guard let result = box.value else { return nil }
        let summary = result.added == 0 ? loc("No comments were added.")
            : result.added == 1 ? loc("{0} comment was added. You can undo this until you save.", 1)
            : loc("{0} comments were added. You can undo this until you save.", CoreLanguage.number(result.added))
        if result.skipped.isEmpty && result.notes.isEmpty {
            notify(summary, canUndo: result.added > 0)
        } else {
            var text = summary
            if !result.skipped.isEmpty {
                let skipped = result.skipped.count
                text += " " + (skipped == 1 ? loc("{0} was skipped:", 1) : loc("{0} were skipped:", CoreLanguage.number(skipped)))
            }
            var list = result.skipped.prefix(2000).joined(separator: "\n")
            if result.skipped.count > 2000 { list += "\n" + loc("… and {0} more", CoreLanguage.number(result.skipped.count - 2000)) }
            infoSheet(loc("Comments Imported"), ([text] + result.notes).joined(separator: "\n\n"), list: result.skipped.isEmpty ? nil : list)
        }
        return result
    }

    @objc func summarizeComments(_ sender: Any?) {
        guard let window, let session = pdf.session else { return }
        if session.openPassword != nil
            && !confirmUnprotected(loc("The summary is saved without the document's password protection: anyone can open it."), loc("Summarize Anyway")) {
            return
        }
        let panel = NSSavePanel()
        panel.title = loc("Summarize Comments")
        panel.message = loc("A new PDF with each page that has comments beside its numbered list of comments.")
        panel.nameFieldStringValue = loc("{0} comments.pdf", (session.displayName as NSString).deletingPathExtension)
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self.startLongTask {
                    if await self.summarizeComments(to: url), !Report.isRunning {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    }
                }
            }
        }
    }

    /// Writes the comment summary to `url`; false when there are no comments or it failed (said).
    func summarizeComments(to url: URL) async -> Bool {
        guard let session = pdf.session else { return false }
        let data = session.data, password = session.password, name = session.displayName
        let sheet = ProgressSheet(title: loc("Summarize Comments"), text: loc("Laying out the pages and their comments…"))
        sheet.begin(on: window)
        let result: Result<[UInt8], Error> = await Task.detached { Result { try CommentSummary.make(data, password, title: name) } }.value
        sheet.end()
        do {
            try Data(try result.get()).write(to: url, options: .atomic)
            notify(loc("Comment summary saved as {0}.", url.lastPathComponent))
            return true
        } catch let e as PdfEditError where e.message.contains("no comments") || e.message == loc("This document has no comments to summarize.") {
            infoSheet(loc("No comments"), e.message)
        } catch {
            pdf.showError(loc("The comment summary couldn't be saved."), error)
        }
        return false
    }

    /// An informational alert (a sheet), with an optional scrolling list of lines; in the self-test a notice instead.
    /// `message`, `detail` and `listName` are shown as given: pass them through `loc`.
    func infoSheet(_ message: String, _ detail: String, list: String? = nil, listName: String = loc("Skipped comments")) {
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
            text.setAccessibilityLabel(listName)
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: loc("OK"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
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
