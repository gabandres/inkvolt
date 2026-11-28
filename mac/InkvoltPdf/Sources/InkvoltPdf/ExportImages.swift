import AppKit
import PdfCore
import PrintCore

/// File › Export To › Pages as Images… and Convert › Images… (Windows' `FileActions.ExportImages`): which pages, PNG or
/// JPEG, the resolution and the folder; then each page as an image there (PdfCore's `PageImageExport`), from what is
/// shown (the Layers pane's choice), with a progress sheet and Cancel; the folder opens in Finder when done.
extension DocumentWindowController {
    @objc func exportImages(_ sender: Any?) {
        guard let window, pdf.session != nil, engine.pageCount > 0 else { return }
        Task { await askExportImages(window) }
    }

    private func askExportImages(_ window: NSWindow) async {
        guard let session = pdf.session else { return }
        let choice = pageChoice(allTitle: loc("All pages"))
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: [loc("PNG (lossless)"), loc("JPEG (smaller)")])
        format.setAccessibleName(loc("Format"))
        let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
        resolution.addItems(withTitles: PageImageExport.resolutions.map { loc("{0} dpi", $0) })
        resolution.selectItem(at: PageImageExport.defaultResolution)
        resolution.setAccessibleName(loc("Resolution"))
        let folder = NSTextField(string: session.filePath.map { ($0 as NSString).deletingLastPathComponent }
                                 ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        folder.setAccessibleName(loc("Save to folder"))
        folder.lineBreakMode = .byTruncatingHead
        folder.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let browse = FolderButton(title: loc("Choose…"), target: nil, action: nil)
        browse.message = loc("Export images to")
        browse.field = folder
        browse.target = browse
        browse.action = #selector(FolderButton.browse)
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 340
        let form = SheetForm("ExportImages")
        form.row(loc("Pages"), choice.view)
        form.row(loc("Format"), format)
        form.row(loc("Resolution"), resolution)
        form.row(loc("Save to folder"), folder, browse)
        let problemRow = form.wide(problem)
        problemRow.isHidden = true
        var pages: [Int] = []
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Export Pages as Images")
            alert.addButton(withTitle: loc("Export"))
            alert.addButton(withTitle: loc("Cancel"))
            form.install(in: alert)
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            let read = choice.read()
            var isFolder: ObjCBool = false
            let wrong = read.pages == nil ? read.error ?? loc("That page range isn't valid.")
                : FileManager.default.fileExists(atPath: folder.stringValue, isDirectory: &isFolder) && isFolder.boolValue ? nil
                : loc("Choose an existing folder.")
            if let wrong {
                problem.stringValue = wrong
                problemRow.isHidden = false
                continue
            }
            pages = read.pages ?? []
            break
        }
        if pdf.session?.openPassword != nil
            && !confirmUnprotected(loc("The page images are saved without its password protection: anyone can open them."), loc("Export anyway")) {
            return
        }
        pages = pages.filter { $0 < engine.pageCount } // the document changed meanwhile
        guard !pages.isEmpty else { return }
        let jpeg = format.indexOfSelectedItem == 1
        let dpi = PageImageExport.resolutions[max(0, resolution.indexOfSelectedItem)]
        startLongTask { await self.runExportImages(pages, folder: folder.stringValue, dpi: dpi, jpeg: jpeg) }
    }

    /// Exports `chosen` as images into `dir`, asking first when some pages are too large for `dpi`.
    func runExportImages(_ chosen: [Int], folder dir: String, dpi: Int, jpeg: Bool) async {
        guard let session = pdf.session, let window else { return }
        let name = (session.displayName as NSString).deletingPathExtension
        let data = session.data, password = session.password, layers = shownLayerVisibility
        let engine: PdfEngine
        do {
            engine = try Self.exportEngine(data, password, layers) // what is shown (chosen layers included)
        } catch {
            return pdf.showError(loc("Can't export to that folder"), error)
        }
        defer { engine.close() }
        let plan: PageImageExport.Plan
        do {
            plan = try PageImageExport.plan(engine, pages: chosen, folder: dir, name: name, dpi: dpi, jpeg: jpeg)
        } catch {
            return pdf.showError(loc("Can't export to that folder"), error)
        }
        if let lowest = plan.lowest, !Report.skipsDialogs {
            let count = plan.clamped.count, megapixels = Int(PageImages.maxPixels / 1e6)
            let alert = NSAlert()
            alert.messageText = loc("Some pages are very large")
            alert.informativeText = count == 1
                ? loc("{0} page is too large to export at {1} dpi, so it is exported at a lower resolution (down to {2} dpi) to stay under {3} megapixels per image.",
                      1, dpi, Int(lowest), megapixels)
                : loc("{0} pages are too large to export at {1} dpi, so they are exported at a lower resolution (down to {2} dpi) to stay under {3} megapixels per image.",
                      CoreLanguage.number(count), dpi, Int(lowest), megapixels)
            alert.addButton(withTitle: loc("Export"))
            alert.addButton(withTitle: loc("Cancel"))
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
        }
        let total = plan.targets.count
        let sheet = ProgressSheet(title: loc("Exporting images"),
                                  text: total == 1 ? loc("Exporting {0} page…", 1) : loc("Exporting {0} pages…", CoreLanguage.number(total)))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let token = sheet.token
        let outcome = await Task.detached {
            PageImageExport.run(engine, plan, jpeg: jpeg, cancel: token) { page, done, count in
                let text = loc("Exporting page {0} ({1} of {2})…", page + 1, done + 1, count)
                onMain { sheet.update(text, Double(done) / Double(count)) }
            }
        }.value
        let into = (dir as NSString).lastPathComponent
        if outcome.cancelled {
            notify(loc("Export cancelled. {0} image(s) were saved to {1}", outcome.done, into))
        } else if let failure = outcome.failure {
            pdf.showError(loc("Export stopped after {0} page(s)", outcome.done), NSError(domain: "InkvoltPdf", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]))
        } else {
            notify(outcome.refused.isEmpty ? loc("Exported {0} image(s) to {1}", outcome.done, into)
                   : loc("Exported {0} image(s) to {1}. Left out page(s) {2}: they couldn't be read", outcome.done, into, PageRange.format(outcome.refused)))
            if !Report.isRunning { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
        }
    }
}
