import Foundation
import PrintCore
import PrintMac

/// `--copy` (Windows' Copy tab, page copy): in demo mode, a copy of each kind from the demo HP laser's scanner, through the
/// laser's own route for the first and then to a made-up queue whose jobs are listed: a document from the glass, 2-up and
/// 4-up from the feeder, a preview (laid out again at 4-up, then printed), two copies uncollated and collated on both sides,
/// two copies uncollated by hand on the one-sided USB laser (the prompt answered face down), and why each other printer
/// can't copy, if it can't. Outside demo mode, `--copy-from <name>`: one page from the named printer's glass in grey,
/// previewed first and printed only when the glass is blank (nobody's document is copied), labelled "blank glass".
extension Report {
    static func copyCheck(_ model: AppModel) async -> [String] {
        guard model.isDemo else { return await realCopyCheck(model) }
        guard let laser = model.printers.first(where: { $0.id == Demo.uuid }) else { return ["copy: no demo HP laser"] }
        for _ in 0..<50 where !laser.view.isOnline || laser.queueName == nil { try? await Task.sleep(for: .milliseconds(200)) }
        var lines = ["copy:"]
        var copy = CopyModel(printer: laser, app: model)
        await copy.shown()
        lines.append("  \(laser.name): \(copy.unavailableReason ?? "can copy"); sources \(copy.sources.map { "\($0)" }); two-sided \(copy.canTwoSided)")
        func said(_ what: String) {
            lines.append("  \(what): \(copy.message ?? "-") | \(copy.summary)")
            lines.append("    preview: \(copy.sheets.map { "\($0.pages.count) pages\($0.pages.contains(where: \.rotated) ? " turned" : "")" })")
            lines.append("    job: \(copy.lastJob ?? "none")")
        }
        copy.source = .platen
        await copy.copyAndWait()
        said("document (its own route)")

        // From here the demo inkjet's feeder (three pages) scans, and a made-up queue of the laser's name takes the jobs, so they
        // can be listed.
        guard let queueName = laser.queueName, let queue = DemoBatchQueue.named(queueName) else { return lines + ["  no demo laser queue"] }
        if let inkjet = model.printers.first(where: { $0.id == Demo.inkjetUuid }) {
            for _ in 0..<50 where !inkjet.view.isOnline { try? await Task.sleep(for: .milliseconds(200)) }
            let fed = CopyModel(printer: inkjet, app: model)
            await fed.shown()
            if fed.sources.contains(.adf) {
                copy = fed
                lines.append("  \(inkjet.name)'s scanner from here: sources \(copy.sources.map { "\($0)" })")
            }
        }
        copy.queueOverride = queue
        await copy.readTwoSided()
        func jobs(from: Int) -> String { queue.sent.dropFirst(from).map { "\($0.pages) ×\($0.copies)\($0.twoSided ? " two-sided" : "")" }.joined(separator: "; ") }
        for (label, perSheet) in [("2-up", 2), ("4-up", 4)] {
            let before = queue.sent.count
            copy.source = copy.sources.contains(.adf) ? .adf : .platen
            copy.pagesPerSheet = perSheet
            await copy.copyAndWait()
            said("\(label) from \(copy.source)")
            lines.append("    sent: \(jobs(from: before))")
        }
        copy.previewFirst = true
        copy.pagesPerSheet = 2
        await copy.copyAndWait()
        said("preview at 2-up, waiting \(copy.awaitingPrint)")
        copy.pagesPerSheet = 4
        lines.append("    at 4-up: \(copy.sheets.count) sheets of \(copy.sheets.map(\.pages.count))")
        var before = queue.sent.count
        await copy.printPreviewedAndWait()
        said("preview printed")
        lines.append("    sent: \(jobs(from: before))")
        copy.previewFirst = false
        copy.pagesPerSheet = 1
        copy.copies = 2
        copy.twoSided = true
        for collate in [false, true] {
            before = queue.sent.count
            copy.collate = collate
            await copy.copyAndWait()
            said("two copies, two-sided, \(collate ? "collated" : "uncollated")")
            lines.append("    sent: \(jobs(from: before))")
        }

        // Two-sided by hand: the USB laser's made-up queue prints one side.
        if let usb = DemoBatchQueue.named("Demo_USB_laser") {
            copy.queueOverride = usb
            await copy.readTwoSided()
            copy.twoSided = true
            copy.collate = false
            HandDuplexPrinting.answer = .down
            defer { HandDuplexPrinting.answer = nil }
            await copy.copyAndWait()
            said("two copies by hand (offered \(copy.offersByHand)), uncollated")
            lines.append("    sent: \(usb.sent.map { "\($0.pages)" }.joined(separator: "; ")); prompt: \(HandDuplexPrinting.lastPrompt ?? "none")")
        }
        for p in model.printers where p.id != laser.id {
            lines.append("  \(p.name): \(CopyModel(printer: p, app: model).unavailableReason ?? "can copy")")
        }
        return lines
    }

    /// One real copy, outside demo mode: the named printer's glass scanned in grey at one page per sheet, previewed first; the
    /// scan's dark share decides: a blank glass is printed (labelled so), anything else isn't printed or kept.
    private static func realCopyCheck(_ model: AppModel) async -> [String] {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--copy-from"), i + 1 < args.count else { return ["copy: --copy-from <name> is needed outside demo mode"] }
        let name = args[i + 1]
        for _ in 0..<75 where !model.printers.contains(where: { $0.name.localizedCaseInsensitiveContains(name) && $0.view.isOnline }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        var lines: [String] = []
        var added: PrinterModel?
        if !model.printers.contains(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            // Not in the list: found as Add a Printer finds it, added for the copy and removed after it.
            let search = AddPrinterModel(app: model)
            search.start()
            for _ in 0..<300 where search.isSearching && !search.found.contains(where: { $0.name.localizedCaseInsensitiveContains(name) && $0.state == .canAdd }) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            search.stop()
            if let f = search.found.first(where: { $0.name.localizedCaseInsensitiveContains(name) && $0.state == .canAdd }) {
                search.add(f)
                added = model.printers.first { $0.id == search.found.first(where: { $0.id == f.id })?.printerId }
                lines.append("copy: \(f.name) found on the network and added for the copy")
                for _ in 0..<150 where added?.view.isOnline != true { try? await Task.sleep(for: .milliseconds(200)) }
            }
        }
        defer { if let added { model.remove(added) } }
        guard let printer = added ?? model.printers.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else { return lines + ["copy: no printer named \(name)"] }
        // The route is decided once the printer's queue lookup and IPP read are in.
        for _ in 0..<50 where printer.route == .none && printer.queueName == nil { try? await Task.sleep(for: .milliseconds(200)) }
        let copy = CopyModel(printer: printer, app: model)
        await copy.shown()
        lines.append("copy on \(printer.name): \(copy.unavailableReason ?? "can copy"), route \(printer.route), queue \(printer.queueName != nil)")
        copy.source = .platen
        copy.previewFirst = true
        await copy.copyAndWait()
        lines.append("  scanned: \(copy.message ?? "-"), waiting \(copy.awaitingPrint)")
        guard copy.awaitingPrint, let dark = copy.previewedDarkShare() else { return lines + ["  not printed"] }
        let blank = dark < 0.005 // a page of text is a few percent; a scanner's dark edge a tenth of one
        lines.append("  the glass: " + String(format: "%.4f", dark) + " dark, \(blank ? "blank glass" : "something on it (not printed)")")
        guard blank else {
            copy.startOver()
            return lines
        }
        copy.jobName = "Copy (blank glass)"
        await copy.printPreviewedAndWait()
        lines.append("  printed (blank glass): \(copy.message ?? "-")")
        lines.append("  job: \(copy.lastJob ?? "none")")
        return lines
    }
}
