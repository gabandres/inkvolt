import AppKit
import PdfCore
import PrintCore

/// Pages › Bookmarks from Headings… and the Bookmarks list's menu (Windows' `DocumentTab.BookmarksFromHeadings`, roadmap
/// 4.5): finds the headings (`HeadingBookmarks`) with a progress sheet that can be stopped, shows the bookmarks they make,
/// nested by level, with a choice of levels, then writes them in place of the bookmarks or after them as one undo step.
extension DocumentWindowController {
    @objc func bookmarksFromHeadings(_ sender: Any?) {
        guard let window, pdf.session != nil, engine.pageCount > 0 else { return NSSound.beep() }
        Task { await askBookmarksFromHeadings(window) }
    }

    /// The document's headings and how many bookmarks it has, read with a progress sheet; nil when stopped or the pages
    /// couldn't be read (said).
    func findHeadings() async -> (headings: [FoundHeading], existing: Int)? {
        guard let session = pdf.session else { return nil }
        let sheet = ProgressSheet(title: loc("Finding headings"), text: loc("Starting…"))
        sheet.begin(on: window)
        defer { sheet.end() }
        let engine = engine, token = sheet.token, data = session.data, password = session.password
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain {
                sheet.update(loc("{0}: page {1} of {2}…", loc("Finding headings"), CoreLanguage.number(done + 1), CoreLanguage.number(total)),
                             Double(done) / Double(max(total, 1)))
            }
        }
        let found: Result<([FoundHeading], Int), Error> = await Task.detached {
            Result {
                func count(_ tree: [Bookmark]) -> Int { tree.reduce(0) { $0 + 1 + count($1.children) } }
                return (try HeadingBookmarks.find(engine, progress: progress, cancel: token), count(try Bookmarks.read(data, password)))
            }
        }.value
        switch found {
        case .success(let (headings, existing)):
            return (headings, existing)
        case .failure(let error) where error is CancellationError:
            return nil
        case .failure(let error):
            Report.progress("heading search failed: \(type(of: error))")
            pdf.showError(loc("The pages couldn't be read"), PdfEditError(loc("Something in this document stopped Inkvolt PDF from reading its pages. Nothing was changed.")))
            return nil
        }
    }

    private func askBookmarksFromHeadings(_ window: NSWindow) async {
        guard let data = pdf.session?.data, let (headings, existing) = await findHeadings(), pdf.session?.data == data else { return }
        if headings.isEmpty {
            let alert = NSAlert()
            alert.messageText = loc("No headings found")
            alert.informativeText = loc("Headings are found from text set larger than the body text. This document has none, or its pages are scans without text: recognize the text first.")
            _ = await alert.beginSheetModal(for: window)
            return
        }
        let note = NSTextField(wrappingLabelWithString: headings.count == 1 ? loc("1 heading found. The bookmarks will be:")
                               : loc("{0} headings found. The bookmarks will be:", CoreLanguage.number(headings.count)))
        note.preferredMaxLayoutWidth = 440
        let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        preview.isEditable = false
        preview.isVerticallyResizable = true
        preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.setAccessibilityLabel(loc("Bookmarks to make"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = preview
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        let levels = NSPopUpButton(frame: .zero, pullsDown: false)
        levels.addItems(withTitles: [loc("All levels"), loc("Level 1 only"), loc("Levels 1 and 2"), loc("Levels 1 to 3")])
        levels.setAccessibilityLabel(loc("Heading levels"))
        levels.isEnabled = (headings.map(\.level).max() ?? 1) > 1
        let replace = NSPopUpButton(frame: .zero, pullsDown: false)
        replace.addItems(withTitles: [loc("Replace them"), loc("Keep them and add these after")])
        let existingText = existing == 1 ? loc("The document has 1 bookmark") : loc("The document has {0} bookmarks", CoreLanguage.number(existing))
        replace.setAccessibilityLabel(existingText)
        var rows: [[NSView]] = [[NSTextField(labelWithString: loc("Headings:")), levels]]
        if existing > 0 { rows.append([NSTextField(labelWithString: existingText + ":"), replace]) }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [note, scroll, grid])
        stack.orientation = .vertical
        stack.alignment = .leading

        func deepest() -> Int { levels.indexOfSelectedItem > 0 ? levels.indexOfSelectedItem : 6 }
        let labels = pdf.session.flatMap { try? DocumentFeatures.pageLabels($0.data, $0.password) }
        let show = PopUpAction {
            let level = levels.indexOfSelectedItem > 0 ? levels.indexOfSelectedItem : 6
            preview.string = Self.preview(HeadingBookmarks.tree(headings, deepest: level), labels)
        }
        levels.target = show
        levels.action = #selector(PopUpAction.changed(_:))
        show.changed(nil)
        defer { withExtendedLifetime(show) {} }

        while true {
            let alert = NSAlert()
            alert.messageText = loc("Bookmarks from Headings")
            alert.addButton(withTitle: loc("Make Bookmarks"))
            alert.addButton(withTitle: loc("Cancel"))
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            if headings.contains(where: { $0.level <= deepest() }) { break }
            NSSound.beep() // no heading at these levels: the preview says so
        }
        guard pdf.session?.data == data else { return } // the document changed meanwhile
        await makeHeadingBookmarks(headings, replace: existing == 0 || replace.indexOfSelectedItem == 0, deepest: deepest())
    }

    /// The bookmarks to make, a line each ("Title  (page iv)"), indented by level.
    private nonisolated static func preview(_ tree: [Bookmark], _ labels: [String]?) -> String {
        var lines: [String] = []
        func walk(_ nodes: [Bookmark], _ depth: Int) {
            for b in nodes {
                let page = labels.flatMap { $0.indices.contains(b.pageIndex) ? $0[b.pageIndex] : nil } ?? CoreLanguage.number(b.pageIndex + 1)
                lines.append(String(repeating: " ", count: depth * 4) + loc("{0}  (page {1})", b.title, page))
                walk(b.children, depth + 1)
            }
        }
        walk(tree, 0)
        return lines.isEmpty ? loc("No heading at these levels.") : lines.joined(separator: "\n")
    }

    // MARK: The edit (the sheet and the self-test call it)

    @discardableResult
    func makeHeadingBookmarks(_ headings: [FoundHeading], replace: Bool, deepest: Int) async -> Bool {
        let made = headings.filter { $0.level <= deepest }.count
        let label = made == 1 ? loc("Bookmark 1 heading") : loc("Bookmark {0} headings", CoreLanguage.number(made))
        let ok = await editor.run(label, contentOnly: true) { d, pw in try HeadingBookmarks.write(d, pw, headings, replace: replace, deepest: deepest) }
        if ok { showBookmarks(nil) }
        return ok
    }
}
