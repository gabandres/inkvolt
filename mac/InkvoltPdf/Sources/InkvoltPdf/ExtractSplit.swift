import AppKit
import PdfCore

/// Pages › Extract Pages… and Split Document… (Windows' `Organize.Extract` and `Organize.Split`). Extract asks which
/// pages and where to: a new document (opened in a window), one PDF file, or a PDF file per page in a folder; then,
/// if ticked, deletes them from this document (one undo step). Split makes a file per part, by a number of pages, by
/// page ranges (separated by ;) or at the top-level bookmarks, in a folder, named by a pattern ({name}, {n}); every name
/// is picked before anything is written, and no file is replaced.
extension DocumentWindowController {
    // MARK: Extract

    private static func count(_ n: Int) -> String { n == 1 ? "1 page" : "\(n) pages" }

    /// Where Extract Pages puts the pages (Windows' "Extract to" choices).
    enum ExtractTarget: Int { case newDocument, oneFile, filePerPage }

    @objc func extractPages(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        Task { await askExtract(chosen, window) }
    }

    private func askExtract(_ chosen: [Int], _ window: NSWindow) async {
        let range = NSTextField(string: PageRange.format(chosen))
        range.setAccessibilityLabel("Pages")
        range.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let target = NSPopUpButton(frame: .zero, pullsDown: false)
        target.addItems(withTitles: ["A new document (opens in a window)", "One PDF file…", "A separate PDF file per page…"])
        target.setAccessibilityLabel("Extract to")
        let delete = NSButton(checkboxWithTitle: "Delete the pages from this document after extracting", target: nil, action: nil)
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.isHidden = true
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Pages:"), range], [NSTextField(labelWithString: "Extract to:"), target]])
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [grid, delete, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        var pages: [Int] = []
        while true {
            let alert = NSAlert()
            alert.messageText = "Extract Pages"
            alert.addButton(withTitle: "Extract")
            alert.addButton(withTitle: "Cancel")
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            alert.window.initialFirstResponder = range
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            let r = PageRange.tryParse(range.stringValue, engine.pageCount)
            let wrong = !r.ok ? r.error : delete.state == .on && r.pages.count >= engine.pageCount ? "You can't delete every page of a document." : nil
            if let wrong {
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            pages = r.pages
            break
        }
        let how = ExtractTarget(rawValue: target.indexOfSelectedItem) ?? .newDocument
        if engine.pageCount == 0 || pages.contains(where: { $0 >= engine.pageCount }) { return } // the document changed meanwhile
        if pdf.session?.openPassword != nil && !confirmUnprotected("The extracted pages are saved without its password protection.", "Extract Anyway") {
            return
        }
        let done: Bool
        switch how {
        case .newDocument: done = extractToNewDocument(pages) != nil
        case .oneFile: done = await extractToFile(pages, window)
        case .filePerPage:
            guard let folder = await chooseFolder("Save the extracted pages to", window) else { return }
            done = await extractPerPage(pages, to: folder) != nil
            if done && !Report.isRunning { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
        }
        if done && delete.state == .on { await removePages(pages) }
    }

    /// The pages as a new, unsaved document in its own window.
    @discardableResult
    func extractToNewDocument(_ chosen: [Int]) -> PdfDocument? {
        guard let session = pdf.session else { return nil }
        do {
            let bytes = try PageEditor.extract(session.data, session.password, chosen)
            let name = (session.displayName as NSString).deletingPathExtension
            return NewDocuments.open(bytes, name: "\(name) (pages \(PageRange.format(chosen))).pdf")
        } catch {
            pdf.showError("The pages couldn't be extracted.", error)
            return nil
        }
    }

    private func extractToFile(_ chosen: [Int], _ window: NSWindow) async -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (pdf.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base) (pages \(PageRange.format(chosen))).pdf"
        panel.message = "Save \(Self.count(chosen.count)) (\(PageRange.format(chosen))) as a new PDF."
        if let folder = pdf.session?.filePath.map({ ($0 as NSString).deletingLastPathComponent }) { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
        return extract(chosen, to: url)
    }

    /// Each page of `chosen` as its own PDF in `folder` ("name (page 3).pdf"); the paths written, or nil (said).
    @discardableResult
    func extractPerPage(_ chosen: [Int], to folder: String) async -> [String]? {
        guard let session = pdf.session else { return nil }
        let name = (session.displayName as NSString).deletingPathExtension
        var reserved = Set<String>()
        let paths = chosen.map { SplitFiles.uniquePath(folder, "\(name) (page \($0 + 1)).pdf", &reserved) }
        let data = session.data, password = session.password
        let files: [(path: String, bytes: @Sendable () throws -> [UInt8])] = zip(paths, chosen).map { path, page in
            (path: path, bytes: { try PageEditor.extract(data, password, [page]) })
        }
        guard await writeFiles(files, busy: "Extracting pages…", failed: "Extract didn't work") else { return nil }
        notify("Saved \(Self.count(chosen.count)) to “\((folder as NSString).lastPathComponent)”.")
        return paths
    }

    // MARK: Split

    @objc func splitDocument(_ sender: Any?) {
        guard let window, pdf.session != nil, engine.pageCount > 0 else { return }
        Task { await askSplit(window) }
    }

    private func askSplit(_ window: NSWindow) async {
        let count = engine.pageCount
        let outline = (try? engine.outline()) ?? []
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: ["Number of pages", "Page ranges", "Top-level bookmarks"])
        let every = NSTextField(string: "1")
        let half = max(1, count / 2)
        let ranges = NSTextField(string: count > 1 ? "1-\(half); \(half + 1)-\(count)" : "1")
        let note = NSTextField(wrappingLabelWithString: outline.isEmpty ? "This document has no bookmarks, so splitting by bookmarks isn't available."
                                                                       : "\(outline.count) top-level bookmarks.")
        note.textColor = .secondaryLabelColor
        let name = ((pdf.session?.displayName ?? pdf.name) as NSString).deletingPathExtension
        let folder = NSTextField(string: pdf.session?.filePath.map { ($0 as NSString).deletingLastPathComponent }
                                 ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        let pattern = NSTextField(string: "{name} (part {n})")
        for (f, label) in [(every, "Pages per file"), (ranges, "Page ranges"), (folder, "Save to folder"), (pattern, "File name")] {
            f.setAccessibilityLabel(label)
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let browse = FolderButton(title: "Choose…", target: nil, action: nil)
        browse.field = folder
        browse.target = browse
        browse.action = #selector(FolderButton.browse)
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.isHidden = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Split by:"), mode],
            [NSTextField(labelWithString: "Pages per file:"), every],
            [NSTextField(labelWithString: "Page ranges:"), ranges],
            [NSGridCell.emptyContentView, NSTextField(labelWithString: "One file per range, separated by ;")],
            [NSGridCell.emptyContentView, note],
            [NSTextField(labelWithString: "Save to folder:"), folder],
            [NSGridCell.emptyContentView, browse],
            [NSTextField(labelWithString: "File name:"), pattern],
            [NSGridCell.emptyContentView, NSTextField(labelWithString: "{name} = document name, {n} = part number")],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        let stack = NSStackView(views: [grid, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        while true {
            let alert = NSAlert()
            alert.messageText = "Split Document"
            alert.addButton(withTitle: "Split")
            alert.addButton(withTitle: "Cancel")
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            let how = SplitBy(rawValue: mode.indexOfSelectedItem) ?? .pageCount
            let planned = SplitFiles.parts(how, pageCount: count, pagesPerFile: every.stringValue, ranges: ranges.stringValue, outline: outline)
            let named: (paths: [String], error: String?) = planned.error == nil
                ? SplitFiles.targets(planned.parts, mode: how, folder: folder.stringValue, pattern: pattern.stringValue, name: name)
                : ([], planned.error)
            if let wrong = named.error {
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            guard engine.pageCount == count else { return } // the document changed meanwhile
            if pdf.session?.openPassword != nil && !confirmUnprotected("The split files are saved without its password protection.", "Split Anyway") {
                return
            }
            if await split(planned.parts, to: named.paths), !Report.isRunning {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder.stringValue))
            }
            return
        }
    }

    /// Writes each part to its path (both from `SplitFiles`); false (and said) when it failed.
    @discardableResult
    func split(_ parts: [SplitPart], to paths: [String]) async -> Bool {
        guard let session = pdf.session, parts.count == paths.count, !parts.isEmpty else { return false }
        let data = session.data, password = session.password
        let files: [(path: String, bytes: @Sendable () throws -> [UInt8])] = zip(paths, parts).map { path, part in
            (path: path, bytes: { try PageEditor.extract(data, password, part.pages) })
        }
        guard await writeFiles(files, busy: "Splitting into \(parts.count) files…", failed: "Split didn't work") else { return false }
        let folder = ((paths[0] as NSString).deletingLastPathComponent as NSString).lastPathComponent
        notify("Split into \(parts.count) files in “\(folder)”.")
        return true
    }

    // MARK: Shared

    /// Writes the files off the main thread with a progress sheet; false (and the error shown) when it stopped.
    private func writeFiles(_ files: [(path: String, bytes: @Sendable () throws -> [UInt8])], busy: String, failed: String) async -> Bool {
        let sheet = ProgressSheet(title: busy, text: "\(files.count) files")
        sheet.begin(on: window)
        defer { sheet.end() }
        let batch = files, token = sheet.token
        let result: Error? = await Task.detached {
            do {
                try SplitFiles.writeBatch(batch.map { f in (path: f.path, bytes: f.bytes) }, cancel: token)
                return nil
            } catch {
                return error
            }
        }.value
        guard let result else { return true }
        if result is CancellationError {
            notify("Stopped: the files written before are kept.")
            return false
        }
        let detail = (result as? BatchWriteError)?.message ?? (result as? PdfEditError)?.message ?? result.localizedDescription
        if Report.isRunning {
            notify("\(failed). \(detail)")
        } else {
            let alert = NSAlert()
            alert.messageText = failed
            alert.informativeText = detail
            alert.runModal()
        }
        return false
    }

    private func chooseFolder(_ message: String, _ window: NSWindow) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        if let folder = pdf.session?.filePath.map({ ($0 as NSString).deletingLastPathComponent }) { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.url?.path
    }

    /// Asks once (Windows asks once per tab) before writing pages of a password-protected PDF without the password.
    private func confirmUnprotected(_ text: String, _ confirm: String) -> Bool {
        if Report.isRunning || unprotectedConfirmed { return true }
        let alert = NSAlert()
        alert.messageText = "This PDF is password-protected"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        unprotectedConfirmed = true
        return true
    }
}

/// Split Document's Choose…: a folder's path in the folder box.
@MainActor
private final class FolderButton: NSButton {
    weak var field: NSTextField?

    @objc func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Save the split files to"
        if let path = field?.stringValue, !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { field?.stringValue = url.path }
    }
}
