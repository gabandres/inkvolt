import AppKit
import PdfCore
import PrintCore

/// Pages › Remove Blank Pages… and Split at Blank Pages… (Windows' `Organize.BlankPagesCommand`, roadmap 4.4): finds the
/// blank pages (`BlankPages`, File › Scan's test) with a progress sheet that can be stopped, shows them with their
/// pictures to untick, then deletes the ticked ones as one undo step, or saves the runs of pages between them as separate
/// PDFs (the blank ones left out).
extension DocumentWindowController {
    @objc func removeBlankPages(_ sender: Any?) { blankPagesCommand(split: false) }
    @objc func splitAtBlankPages(_ sender: Any?) { blankPagesCommand(split: true) }

    private func blankPagesCommand(split: Bool) {
        guard let window, pdf.session != nil, engine.pageCount > 0 else { return NSSound.beep() }
        Task { await askBlankPages(split: split, window) }
    }

    /// The blank pages and a small picture of each, found with a progress sheet; nil when stopped or the pages couldn't be
    /// read (said).
    func findBlankPages() async -> (pages: [Int], pictures: [NSImage?])? {
        let sheet = ProgressSheet(title: loc("Looking for blank pages"), text: loc("Starting…"))
        sheet.begin(on: window)
        defer { sheet.end() }
        let engine = engine, token = sheet.token
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain {
                sheet.update(loc("{0}: page {1} of {2}…", loc("Looking for blank pages"), CoreLanguage.number(done + 1), CoreLanguage.number(total)),
                             Double(done) / Double(max(total, 1)))
            }
        }
        let found: Result<([Int], [CGImage?]), Error> = await Task.detached {
            Result {
                let blanks = try BlankPages.find(engine, progress: progress, cancel: token)
                return (blanks, blanks.map { Self.thumbnail(engine, $0) })
            }
        }.value
        switch found {
        case .success(let (pages, images)):
            return (pages, images.map { $0.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } })
        case .failure(let error) where error is CancellationError:
            return nil
        case .failure(let error):
            // The document closed under the search, or something in it stopped MuPDF: said, nothing changed.
            Report.progress("blank page search failed: \(type(of: error))")
            pdf.showError(loc("The pages couldn't be read"), PdfEditError(loc("Something in this document stopped Inkvolt PDF from reading its pages. Nothing was changed.")))
            return nil
        }
    }

    /// A small picture of a page for a list to tick (nil when it can't be drawn).
    private nonisolated static func thumbnail(_ engine: PdfEngine, _ page: Int) -> CGImage? {
        let g = engine.page(page)
        guard let image = try? engine.render(page, scale: 96 / max(1, max(g.width, g.height))) else { return nil }
        return PageRenderer.cgImage(image)
    }

    /// The accessibility audit's blank pages (`UxShots`): the list of pictures to tick shown for these pages, without the
    /// search (the synthetic document has none).
    static var testBlankPages: [Int]?

    private func askBlankPages(split: Bool, _ window: NSWindow) async {
        let count = engine.pageCount
        var result: (pages: [Int], pictures: [NSImage?])?
        if let pages = Self.testBlankPages {
            Self.testBlankPages = nil
            let pictures: [NSImage?] = pages.map { (page: Int) -> NSImage? in
                guard let cg = Self.thumbnail(engine, page) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            result = (pages, pictures)
        } else {
            result = await findBlankPages()
        }
        guard let (blanks, pictures) = result, engine.pageCount == count else { return }
        if blanks.isEmpty {
            let alert = NSAlert()
            alert.messageText = loc("No blank pages")
            alert.informativeText = loc("No page of this document looks blank. A page with as little as a short word on it is kept.")
            _ = await alert.beginSheetModal(for: window)
            return
        }
        let note = NSTextField(wrappingLabelWithString: blanks.count == 1 ? loc("1 page looks blank. Untick it to keep it.")
                               : loc("{0} pages look blank. Untick any you want to keep.", CoreLanguage.number(blanks.count)))
        note.preferredMaxLayoutWidth = 440
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: [loc("Delete them"), loc("Split the document at them into separate PDFs (they're left out)")])
        mode.selectItem(at: split ? 1 : 0)
        mode.setAccessibilityLabel(loc("What to do with them"))
        let boxes = blanks.map { NSButton(checkboxWithTitle: loc("Page {0}", CoreLanguage.number($0 + 1)), target: nil, action: nil) }
        for b in boxes { b.state = .on }
        let cards: [NSView] = zip(boxes, pictures).map { box, picture in
            let image = NSImageView()
            image.image = picture
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 72).isActive = true
            image.heightAnchor.constraint(equalToConstant: 96).isActive = true
            // The checkbox names the page. AppKit reports the cell, so it is left out too (the accessibility audit).
            image.setAccessibilityElement(false)
            image.cell?.setAccessibilityElement(false)
            let card = NSStackView(views: [image, box])
            card.orientation = .vertical
            card.spacing = 4
            return card
        }
        let rows = stride(from: 0, to: cards.count, by: 5).map { start -> NSView in
            let row = NSStackView(views: Array(cards[start..<min(start + 5, cards.count)]))
            row.spacing = 12
            row.alignment = .top
            return row
        }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: min(330, CGFloat(rows.count) * 130 + 8)))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(list)
        scroll.documentView = clip
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: clip.topAnchor), list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.bottomAnchor.constraint(equalTo: clip.bottomAnchor), clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: scroll.frame.height).isActive = true
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 440
        problem.isHidden = true
        let modeRow = NSStackView(views: [NSTextField(labelWithString: loc("What to do with them:")), mode])
        let stack = NSStackView(views: [note, modeRow, scroll, problem])
        stack.orientation = .vertical
        stack.alignment = .leading

        var chosen: [Int] = []
        while true {
            let alert = NSAlert()
            alert.messageText = split ? loc("Split at Blank Pages") : loc("Remove Blank Pages")
            alert.addButton(withTitle: loc("Continue"))
            alert.addButton(withTitle: loc("Cancel"))
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            chosen = zip(blanks, boxes).filter { $0.1.state == .on }.map(\.0)
            let wrong: String? = chosen.isEmpty ? loc("Tick at least one page.")
                : mode.indexOfSelectedItem == 0 ? (chosen.count >= count ? loc("Every page is ticked, and a document keeps at least one page. Untick one to keep it.") : nil)
                : BlankPages.splitAt(count, chosen).isEmpty ? loc("Nothing is left between the blank pages to save.") : nil
            if let wrong {
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            break
        }
        guard engine.pageCount == count else { return } // the document changed meanwhile
        if mode.indexOfSelectedItem == 0 {
            await removeBlank(chosen)
            return
        }
        if pdf.session?.openPassword != nil && !confirmUnprotected(loc("The split files are saved without its password protection."), loc("Split Anyway")) {
            return
        }
        guard let folder = await chooseFolder(loc("Choose where to save the parts"), window) else { return }
        if let written = await splitAtBlanks(chosen, to: folder), !written.isEmpty, !Report.isRunning {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        }
    }

    // MARK: The edits (the sheet and the self-test call these)

    @discardableResult
    func removeBlank(_ chosen: [Int]) async -> Bool {
        let label = chosen.count == 1 ? loc("Remove 1 blank page") : loc("Remove {0} blank pages", CoreLanguage.number(chosen.count))
        let count = engine.pageCount
        let ok = await editor.run(label) { d, pw in try BlankPages.remove(d, pw, chosen) }
        if ok, let first = chosen.min() { reselect([min(first, count - chosen.count - 1)]) }
        return ok
    }

    /// The runs of pages between `chosen` (blank pages) as PDFs in `folder` ("name - part 1.pdf"); the paths written, or nil
    /// (said).
    @discardableResult
    func splitAtBlanks(_ chosen: [Int], to folder: String) async -> [String]? {
        guard let session = pdf.session else { return nil }
        let parts = BlankPages.splitAt(engine.pageCount, chosen)
        if parts.isEmpty { return [] }
        let stem = (session.displayName as NSString).deletingPathExtension
        var reserved = Set<String>()
        let data = session.data, password = session.password
        let files: [(path: String, bytes: @Sendable () throws -> [UInt8])] = parts.enumerated().map { i, part in
            (path: SplitFiles.uniquePath(folder, loc("{0} - part {1}", stem, i + 1) + ".pdf", &reserved),
             bytes: { try PageEditor.extract(data, password, part) })
        }
        guard await writeFiles(files, busy: loc("Saving {0} parts…", CoreLanguage.number(parts.count)), failed: loc("Split at Blank Pages didn't work")) else { return nil }
        notify(loc("Saved {0} parts to “{1}”.", CoreLanguage.number(parts.count), (folder as NSString).lastPathComponent))
        return files.map(\.path)
    }
}
