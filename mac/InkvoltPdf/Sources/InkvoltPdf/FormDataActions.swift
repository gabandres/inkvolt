import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// File › Form Data › Export Form Data…, Import Form Data… and Fill Forms from CSV… (roadmap 1.4; the Windows app's
/// `FormDataActions`): `FormDataFiles` as XFDF, FDF, CSV or JSON, and `FormMerge` (a filled copy of the form per CSV row,
/// with a report of the rows that failed). Import is an edit (one undo step); values the form refuses are listed.
extension DocumentWindowController {
    /// The Format pop-up's choices, in order (the saved choice is the index); titles in the interface's language.
    static var formDataFormats: [(format: FormDataFormat, title: String)] {
        [
            (.xfdf, loc("XFDF, for Acrobat and other PDF apps")),
            (.fdf, "FDF"), // English: a format's name
            (.csv, loc("CSV, a header and a row of values")),
            (.json, "JSON"), // English: a format's name
        ]
    }

    private static let formDataFormatKey = "FormDataFileFormat"

    static func formDataTypes(_ format: FormDataFormat?) -> [UTType] {
        let names = format.map { [FormDataFiles.fileExtension($0)] } ?? ["xfdf", "fdf", "csv", "json", "xml", "txt"]
        return names.compactMap { UTType(filenameExtension: $0) }
    }

    @objc func exportFormData(_ sender: Any?) {
        guard let window, let session = pdf.session else { return }
        if session.openPassword != nil
            && !confirmUnprotected(loc("The form data is saved without the document's password protection: anyone can read it."), loc("Export Anyway")) {
            return
        }
        let saved = UserDefaults.standard.integer(forKey: Self.formDataFormatKey)
        let start = Self.formDataFormats.indices.contains(saved) ? saved : 0
        let panel = NSSavePanel()
        panel.title = loc("Export Form Data")
        panel.message = loc("Save the form's values to a file another form, app or spreadsheet can read.")
        panel.nameFieldStringValue = loc("{0} data", (session.displayName as NSString).deletingPathExtension)
        panel.allowedContentTypes = Self.formDataTypes(Self.formDataFormats[start].format)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.formDataFormats.map(\.title))
        popUp.selectItem(at: start)
        popUp.setAccessibilityLabel(loc("File format"))
        let chooser = FormatChooser(panel) { Self.formDataTypes(Self.formDataFormats[$0].format) }
        popUp.target = chooser
        popUp.action = #selector(FormatChooser.changed(_:))
        let row = NSStackView(views: [NSTextField(labelWithString: loc("Format:")), popUp])
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
        panel.title = loc("Import Form Data")
        panel.message = loc("Choose an XFDF, FDF, CSV or JSON file of form values. Values the form doesn't take are listed.")
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
            infoSheet(loc("Can't import {0}", url.lastPathComponent), (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        case .success(let file):
            return await form.importData(file)
        }
    }

    // MARK: Fill Forms from CSV

    @objc func fillFormsFromCsv(_ sender: Any?) {
        guard let window, let session = pdf.session else { return }
        if ((try? FormEditor.dataFields(session.data, session.password)) ?? []).isEmpty {
            infoSheet(loc("No form fields"), loc("This document has no form fields to fill. Tools › Forms › Prepare Form adds them."))
            return
        }
        let panel = NSOpenPanel()
        panel.title = loc("Fill Forms from CSV")
        panel.message = loc("Choose a CSV whose first row names the form's fields: each row after it fills a copy of the form.")
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
            infoSheet(loc("Can't read {0}", url.lastPathComponent), (error as? PdfEditError)?.message ?? error.localizedDescription)
            return
        }
        let formPath = session.filePath ?? (url.deletingLastPathComponent().path as NSString).appendingPathComponent(session.displayName)
        let stem = ((formPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = NSTextField(string: url.deletingLastPathComponent().appendingPathComponent(loc("{0} forms", stem)).path)
        folder.lineBreakMode = .byTruncatingHead
        let pattern = NSTextField(string: FormMergeOptions.defaultTemplate)
        for (f, label) in [(folder, loc("Save the forms in")), (pattern, loc("File names"))] {
            f.setAccessibleName(label)
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        let browse = FolderButton(title: loc("Choose…"), target: nil, action: nil)
        browse.field = folder
        browse.message = loc("Save the filled forms in")
        browse.target = browse
        browse.action = #selector(FolderButton.browse)
        let flatten = NSButton(checkboxWithTitle: loc("Flatten the forms (the values become part of the pages)"), target: nil, action: nil)
        let named = columns.filter { !$0.isEmpty && !FormMerge.isBatchToken($0) }
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 360
        let form = SheetForm("FillForms", width: 460)
        form.row(loc("Save in"), folder, browse)
        form.row(loc("File names"), pattern)
        if named.isEmpty {
            form.note(loc("<<name>> the form's name, <<n>> the row (<<n:3>> as 001), <<date>>"))
        } else {
            let tokens = named.prefix(12).map { "<<\($0)>>" }.joined(separator: ", ") + (named.count > 12 ? ", …" : "")
            form.note(loc("<<name>> the form's name, <<n>> the row (<<n:3>> as 001), <<date>>, or a column: {0}", tokens))
        }
        form.row(nil, flatten, advanced: true)
        let problemRow = form.wide(problem)
        problemRow.isHidden = true
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Fill Forms from CSV")
            alert.informativeText = loc("Each row of {0} fills a copy of this form. A row with a value the form refuses isn't saved and is listed in the report.", url.lastPathComponent)
            alert.addButton(withTitle: loc("Fill"))
            alert.addButton(withTitle: loc("Cancel"))
            form.install(in: alert)
            if !Report.skipsDialogs {
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            }
            let out = (folder.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            let wrong = !out.hasPrefix("/") ? loc("Choose a folder for the forms.") : FormMerge.validateTemplate(pattern.stringValue, columns)
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
        let sheet = ProgressSheet(title: loc("Filling the forms…"), text: loc("From {0}", csvName))
        sheet.begin(on: window)
        let data = session.data, password = session.password, token = sheet.token
        let result: Result<FormMergeReport, Error> = await Task.detached {
            Result {
                try FormMerge.run(data, password, csv, formPath: formPath, options, progress: { done, total in
                    let text = loc("Row {0} of {1}…", CoreLanguage.number(done), CoreLanguage.number(total))
                    DispatchQueue.main.async { MainActor.assumeIsolated { sheet.update(text, Double(done) / Double(max(total, 1))) } }
                }, cancel: token)
            }
        }.value
        sheet.end()
        let report: FormMergeReport
        switch result {
        case .failure(let error):
            infoSheet(loc("The forms couldn't be filled"), (error as? PdfEditError)?.message ?? error.localizedDescription)
            return nil
        case .success(let r):
            report = r
        }
        var reportName: String?
        if !report.failed.isEmpty || !report.unknownColumns.isEmpty {
            let stem = ((formPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let path = (options.outputFolder as NSString).appendingPathComponent(stem + " merge report.csv") // English: the report's file name, as Windows'
            do {
                try FileManager.default.createDirectory(atPath: options.outputFolder, withIntermediateDirectories: true)
                try Data(report.csv()).write(to: URL(fileURLWithPath: path), options: .atomic)
                reportName = (path as NSString).lastPathComponent
            } catch {
                Report.note("merge report not saved: \(error.localizedDescription)")
            }
        }
        var text = report.text
        if let reportName { text += " " + loc("The report is saved as {0} beside the forms.", reportName) }
        if !report.unknownColumns.isEmpty {
            let columns = report.unknownColumns.prefix(20).joined(separator: ", ") + (report.unknownColumns.count > 20 ? ", …" : "")
            text += "\n\n" + loc("Columns that aren't fields of the form were left out: {0}.", columns)
        }
        if report.failed.isEmpty && report.unknownColumns.isEmpty {
            notify(text)
        } else {
            var lines = report.failed.prefix(1000).map { loc("Row {0}: {1}", CoreLanguage.number($0.row), $0.problems.joined(separator: "; ")) }.joined(separator: "\n")
            if report.failed.count > 1000 { lines += "\n" + loc("… and {0} more (see the report)", CoreLanguage.number(report.failed.count - 1000)) }
            infoSheet(loc("Forms Filled"), text, list: report.failed.isEmpty ? nil : lines, listName: loc("Rows not saved"))
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
