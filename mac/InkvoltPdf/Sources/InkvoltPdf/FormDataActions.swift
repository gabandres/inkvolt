import AppKit
import PdfCore
import UniformTypeIdentifiers

/// File › Form Data › Export Form Data…, Import Form Data… and Fill Forms from CSV… (roadmap 1.4; the Windows app's
/// `FormDataActions`): `FormDataFiles` as XFDF, FDF, CSV or JSON, and `FormMerge` (a filled copy of the form per CSV row,
/// with a report of the rows that failed). Import is an edit (one undo step); values the form refuses are listed.
extension DocumentWindowController {
    static let formDataFormats: [(format: FormDataFormat, title: String)] = [
        (.xfdf, "XFDF, for Acrobat and other PDF apps"),
        (.fdf, "FDF"),
        (.csv, "CSV, a header and a row of values"),
        (.json, "JSON"),
    ]

    private static let formDataFormatKey = "FormDataFileFormat"

    static func formDataTypes(_ format: FormDataFormat?) -> [UTType] {
        let names = format.map { [FormDataFiles.fileExtension($0)] } ?? ["xfdf", "fdf", "csv", "json", "xml", "txt"]
        return names.compactMap { UTType(filenameExtension: $0) }
    }

    @objc func exportFormData(_ sender: Any?) {
        guard let window, let session = pdf.session else { return }
        if session.openPassword != nil
            && !confirmUnprotected("The form data is saved without the document's password protection: anyone can read it.", "Export Anyway") {
            return
        }
        let saved = UserDefaults.standard.integer(forKey: Self.formDataFormatKey)
        let start = Self.formDataFormats.indices.contains(saved) ? saved : 0
        let panel = NSSavePanel()
        panel.title = "Export Form Data"
        panel.message = "Save the form's values to a file another form, app or spreadsheet can read."
        panel.nameFieldStringValue = (session.displayName as NSString).deletingPathExtension + " data"
        panel.allowedContentTypes = Self.formDataTypes(Self.formDataFormats[start].format)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.formDataFormats.map(\.title))
        popUp.selectItem(at: start)
        popUp.setAccessibilityLabel("File format")
        let chooser = FormatChooser(panel) { Self.formDataTypes(Self.formDataFormats[$0].format) }
        popUp.target = chooser
        popUp.action = #selector(FormatChooser.changed(_:))
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popUp])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(chooser) {}
                guard response == .OK, let url = panel.url else { return }
                let index = max(popUp.indexOfSelectedItem, 0)
                UserDefaults.standard.set(index, forKey: Self.formDataFormatKey)
                _ = self.form.exportData(to: url, FormDataFiles.format(ofPath: url.path) ?? Self.formDataFormats[index].format)
            }
        }
    }

    @objc func importFormData(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Form Data"
        panel.message = "Choose an XFDF, FDF, CSV or JSON file of form values. Values the form doesn't take are listed."
        panel.allowedContentTypes = Self.formDataTypes(nil)
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self.startLongTask { _ = await self.importFormData(from: url) }
            }
        }
    }

    /// Imports the form data at `url`; nil when the file was refused or nothing was imported.
    @discardableResult
    func importFormData(from url: URL) async -> FormDataImport? {
        let checked: Result<[UInt8], Error> = await Task.detached {
            Result {
                let file = [UInt8](try Data(contentsOf: url))
                if FormDataFiles.sniff(file) != .csv { _ = try FormDataFiles.readValues(file) } // refused before the edit
                return file
            }
        }.value
        switch checked {
        case .failure(let error):
            infoSheet("Can't import \(url.lastPathComponent)", (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        case .success(let file):
            return await form.importData(file)
        }
    }

    // MARK: Fill Forms from CSV

    @objc func fillFormsFromCsv(_ sender: Any?) {
        guard let window, let session = pdf.session else { return }
        if ((try? FormEditor.dataFields(session.data, session.password)) ?? []).isEmpty {
            infoSheet("No form fields", "This document has no form fields to fill. Tools › Forms › Prepare Form adds them.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Fill Forms from CSV"
        panel.message = "Choose a CSV whose first row names the form's fields: each row after it fills a copy of the form."
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType(filenameExtension: "txt")].compactMap { $0 }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self.startLongTask { await self.askFillForms(csv: url, window) }
            }
        }
    }

    private func askFillForms(csv url: URL, _ window: NSWindow) async {
        guard let session = pdf.session else { return }
        let csv: [UInt8], columns: [String]
        do {
            csv = [UInt8](try Data(contentsOf: url))
            columns = try FormMerge.columns(csv)
        } catch {
            infoSheet("Can't read \(url.lastPathComponent)", (error as? PdfEditError)?.message ?? error.localizedDescription)
            return
        }
        let formPath = session.filePath ?? (url.deletingLastPathComponent().path as NSString).appendingPathComponent(session.displayName)
        let stem = ((formPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = NSTextField(string: url.deletingLastPathComponent().appendingPathComponent(stem + " forms").path)
        folder.lineBreakMode = .byTruncatingHead
        let pattern = NSTextField(string: FormMergeOptions.defaultTemplate)
        for (f, label) in [(folder, "Save the forms in"), (pattern, "File names")] {
            f.setAccessibleName(label)
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        let browse = FolderButton(title: "Choose…", target: nil, action: nil)
        browse.field = folder
        browse.message = "Save the filled forms in"
        browse.target = browse
        browse.action = #selector(FolderButton.browse)
        let flatten = NSButton(checkboxWithTitle: "Flatten the forms (the values become part of the pages)", target: nil, action: nil)
        let named = columns.filter { !$0.isEmpty && !FormMerge.isBatchToken($0) }
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 360
        let form = SheetForm("FillForms", width: 460)
        form.row("Save in", folder, browse)
        form.row("File names", pattern)
        form.note("<<name>> the form's name, <<n>> the row (<<n:3>> as 001), <<date>>"
                  + (named.isEmpty ? "" : ", or a column: " + named.prefix(12).map { "<<\($0)>>" }.joined(separator: ", ") + (named.count > 12 ? ", …" : "")))
        form.row(nil, flatten, advanced: true)
        let problemRow = form.wide(problem)
        problemRow.isHidden = true
        while true {
            let alert = NSAlert()
            alert.messageText = "Fill Forms from CSV"
            alert.informativeText = "Each row of \(url.lastPathComponent) fills a copy of this form. A row with a value the form refuses isn't saved and is listed in the report."
            alert.addButton(withTitle: "Fill")
            alert.addButton(withTitle: "Cancel")
            form.install(in: alert)
            if !Report.skipsDialogs {
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            }
            let out = (folder.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            let wrong = !out.hasPrefix("/") ? "Choose a folder for the forms." : FormMerge.validateTemplate(pattern.stringValue, columns)
            if let wrong {
                if Report.skipsDialogs { return notify(wrong) }
                problem.stringValue = wrong
                problemRow.isHidden = false
                continue
            }
            var options = FormMergeOptions(outputFolder: out, nameTemplate: pattern.stringValue)
            options.flatten = flatten.state == .on
            await fillForms(csv: csv, csvName: url.lastPathComponent, formPath: formPath, options)
            return
        }
    }

    /// Runs the merge with a progress sheet, saves the report CSV beside the forms when a row failed or a column was left
    /// out, and says what happened; nil when it couldn't run.
    @discardableResult
    func fillForms(csv: [UInt8], csvName: String, formPath: String, _ options: FormMergeOptions) async -> FormMergeReport? {
        guard let session = pdf.session else { return nil }
        let sheet = ProgressSheet(title: "Filling the forms…", text: "From \(csvName)")
        sheet.begin(on: window)
        let data = session.data, password = session.password, token = sheet.token
        let result: Result<FormMergeReport, Error> = await Task.detached {
            Result {
                try FormMerge.run(data, password, csv, formPath: formPath, options, progress: { done, total in
                    let text = "Row \(done.formatted()) of \(total.formatted())…"
                    DispatchQueue.main.async { MainActor.assumeIsolated { sheet.update(text, Double(done) / Double(max(total, 1))) } }
                }, cancel: token)
            }
        }.value
        sheet.end()
        let report: FormMergeReport
        switch result {
        case .failure(let error):
            infoSheet("The forms couldn't be filled", (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        case .success(let r):
            report = r
        }
        var reportName: String?
        if !report.failed.isEmpty || !report.unknownColumns.isEmpty {
            let stem = ((formPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let path = (options.outputFolder as NSString).appendingPathComponent(stem + " merge report.csv")
            do {
                try FileManager.default.createDirectory(atPath: options.outputFolder, withIntermediateDirectories: true)
                try Data(report.csv()).write(to: URL(fileURLWithPath: path), options: .atomic)
                reportName = (path as NSString).lastPathComponent
            } catch {
                Report.note("merge report not saved: \(error.localizedDescription)")
            }
        }
        var text = report.text + (reportName.map { " The report is saved as \($0) beside the forms." } ?? "")
        if !report.unknownColumns.isEmpty {
            text += "\n\nColumns that aren't fields of the form were left out: "
                + report.unknownColumns.prefix(20).joined(separator: ", ") + (report.unknownColumns.count > 20 ? ", …" : "") + "."
        }
        if report.failed.isEmpty && report.unknownColumns.isEmpty {
            notify(text)
        } else {
            var lines = report.failed.prefix(1000).map { "Row \($0.row): \($0.problems.joined(separator: "; "))" }.joined(separator: "\n")
            if report.failed.count > 1000 { lines += "\n… and \((report.failed.count - 1000).formatted()) more (see the report)" }
            infoSheet("Forms Filled", text, list: report.failed.isEmpty ? nil : lines, listName: "Rows not saved")
        }
        if !report.made.isEmpty && !Report.isRunning { NSWorkspace.shared.open(URL(fileURLWithPath: options.outputFolder)) }
        return report
    }
}

/// A save panel's Format pop-up: the panel's file type follows it.
@MainActor
final class FormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    private let types: (Int) -> [UTType]

    init(_ panel: NSSavePanel, _ types: @escaping (Int) -> [UTType]) {
        self.panel = panel
        self.types = types
    }

    @objc func changed(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem >= 0 { panel?.allowedContentTypes = types(sender.indexOfSelectedItem) }
    }
}
