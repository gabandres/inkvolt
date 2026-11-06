import AppKit
import PdfCore
import PrintCore

/// File › Document Properties… (⇧⌘I; Windows' `FileActions.ShowProperties`, Ctrl+D): the file, where it is, its size,
/// pages, the current page's size, the PDF version, how it is protected, the app that made it and its dates, read only;
/// then Title, Author, Subject and Keywords to change (one undo step, "Edit document properties", the XMP metadata kept in
/// step by `PageEditor.writeMetadata`). What's in This PDF… opens the inventory from there, as on Windows.
extension DocumentWindowController {
    @objc func showDocumentProperties(_ sender: Any?) {
        Task { await askDocumentProperties() }
    }

    /// The read-only rows Windows shows, in its order and words; a row without a value is left out.
    func documentPropertyRows() -> [(label: String, value: String)] {
        guard let session = pdf.session else { return [] }
        let page = max(0, min(activePages.currentPage, engine.pageCount - 1))
        let meta = try? PageEditor.readMetadata(session.data, session.password)
        var rows: [(String, String?)] = [
            (loc("File"), session.displayName),
            (loc("Location"), session.filePath.map { ($0 as NSString).deletingLastPathComponent } ?? loc("Not saved yet")),
            (loc("File size"), Self.formatSize(session.data.count)),
            (loc("Pages"), String(engine.pageCount)),
        ]
        if engine.pageCount > 0 {
            let g = engine.page(page)
            let mm = String(format: "%.0f × %.0f mm", g.width * 25.4 / 72, g.height * 25.4 / 72)
            rows.append((loc("Page size"), loc("{0} × {1} in  ({2})  — page {3}", Self.inches(g.width), Self.inches(g.height), mm, CoreLanguage.number(page + 1))))
        }
        let security = currentSecurity?.summary ?? (session.hasEncryption ? loc("Encrypted") : nil)
        rows += [(loc("PDF version"), meta?.version), (loc("Security"), security), (loc("Created by"), meta?.creator), (loc("Producer"), meta?.producer)]
        rows += [(loc("Created"), meta?.created.map(Self.date)), (loc("Modified"), meta?.modified.map(Self.date))]
        return rows.compactMap { label, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (label, PropertyText.shown(value)) // a hostile file's 2 MB Producer made the sheet taller than the screen
        }
    }

    func askDocumentProperties() async {
        guard let window, let session = pdf.session else { return }
        let rows = documentPropertyRows()
        guard let meta = try? PageEditor.readMetadata(session.data, session.password) else {
            return problemNote(loc("Couldn't read the document's properties"), loc("Its information dictionary is damaged or missing."))
        }
        var answer: (title: String, author: String, subject: String, keywords: String)
        if Report.skipsDialogs {
            DocumentPropertiesState.lastRows = rows
            guard let test = DocumentPropertiesState.testAnswer else { return }
            answer = test
        } else {
            let fields = [meta.title, meta.author, meta.subject, meta.keywords].map { NSTextField(string: $0) }
            let names = [loc("Title"), loc("Author"), loc("Subject"), loc("Keywords")]
            for (f, name) in zip(fields, names) {
                f.setAccessibilityLabel(name)
                f.widthAnchor.constraint(equalToConstant: 340).isActive = true
            }
            var grid: [[NSView]] = rows.map { r in
                let value = NSTextField(wrappingLabelWithString: r.value)
                value.isSelectable = true
                if r.label == loc("Location") {
                    // One line, the folder's end in sight; the whole path in the tooltip.
                    value.maximumNumberOfLines = 1
                    value.lineBreakMode = .byTruncatingHead
                    value.toolTip = r.value
                    value.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
                }
                value.setAccessibilityLabel(r.label)
                value.preferredMaxLayoutWidth = 340
                return [Self.caption(r.label), value]
            }
            grid += zip(names, fields).map { [Self.caption($0), $1] }
            // A third alert button stacks all three in a column; What's in This PDF… sits with the details instead.
            let contents = NSButton(title: loc("What's in This PDF…"), target: nil, action: nil)
            contents.bezelStyle = .push
            grid.append([NSGridCell.emptyContentView, contents])
            let view = NSGridView(views: grid)
            view.column(at: 0).xPlacement = .trailing
            view.rowSpacing = 6
            view.layoutSubtreeIfNeeded()
            view.frame.size = view.fittingSize
            let alert = NSAlert()
            alert.messageText = loc("Document Properties")
            alert.informativeText = loc("The title, author, subject and keywords can be changed; the rest comes from the file.")
            alert.addButton(withTitle: loc("Save Changes"))
            alert.addButton(withTitle: loc("Cancel"))
            _ = ControlAction(contents) { [weak alert] in
                guard let sheet = alert?.window else { return }
                window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
            }
            alert.accessoryView = view
            alert.window.initialFirstResponder = fields[0]
            switch await alert.beginSheetModal(for: window) {
            case .alertFirstButtonReturn: break
            case .alertThirdButtonReturn:
                whatsInThisPdf(nil)
                return
            default: return
            }
            answer = (fields[0].stringValue, fields[1].stringValue, fields[2].stringValue, fields[3].stringValue)
        }
        if answer.title == meta.title && answer.author == meta.author && answer.subject == meta.subject && answer.keywords == meta.keywords {
            return
        }
        let (t, a, s, k) = answer
        if await editor.run(loc("Edit document properties"), { d, pw in try PageEditor.writeMetadata(d, pw, t, a, s, k) }) {
            notify(loc("Document properties changed. Save to keep them."), canUndo: true)
        }
    }

    private func problemNote(_ message: String, _ detail: String) {
        if Report.skipsDialogs { return notify("\(message). \(detail)") }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Windows' `FileActions.FormatSize`: bytes, KB with one decimal, MB with two.
    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return loc("{0} bytes", CoreLanguage.number(bytes)) }
        if bytes < 1024 * 1024 { return "\(trimmed(Double(bytes) / 1024, 1)) KB" }
        return "\(trimmed(Double(bytes) / 1024 / 1024, 2)) MB"
    }

    /// Points as inches with up to two decimals (Windows' `Organize.Inches`, "0.##").
    static func inches(_ points: Double) -> String { trimmed(points / 72, 2) }

    private static func trimmed(_ value: Double, _ places: Int) -> String {
        var s = String(format: "%.\(places)f", value)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }

    private static func date(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .short, timeStyle: .short) }
}

/// What the self-test answers in Document Properties (the sheet isn't shown while it runs), and the rows it was shown.
@MainActor
enum DocumentPropertiesState {
    static var testAnswer: (title: String, author: String, subject: String, keywords: String)?
    static var lastRows: [(label: String, value: String)] = []
}
