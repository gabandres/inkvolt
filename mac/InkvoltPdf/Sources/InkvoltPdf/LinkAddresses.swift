import AppKit
import PdfCore
import PrintCore

/// Links from Addresses (roadmap 4.15; Windows' `DocumentTab.AddressLinks`): finds the web and email addresses printed in
/// the text that aren't links yet (`AddressLinks`), lists them to untick, and makes the ticked ones links as one undo
/// step. Tools › Annotate › Links from Addresses….
extension DocumentWindowController {
    @objc func linkAddresses(_ sender: Any?) {
        guard pdf.session != nil else { return }
        startLongTask { await self.linkAddressesNow() }
    }

    func linkAddressesNow() async {
        guard let session = pdf.session, let window else { return }
        let engine = engine
        let data = session.data
        let sheet = ProgressSheet(title: loc("Looking for web and email addresses"), text: loc("Starting…"))
        progressSheet = sheet
        sheet.begin(on: window)
        let token = sheet.token
        let found: [FoundAddress]
        do {
            found = try await Task.detached {
                try AddressLinks.find(engine, progress: { done, total in
                    Task { @MainActor in
                        sheet.update(loc("Page {0} of {1}", CoreLanguage.number(done + 1), CoreLanguage.number(total)), Double(done) / Double(max(total, 1)))
                    }
                }, cancel: token)
            }.value
        } catch {
            sheet.end()
            progressSheet = nil
            if !(error is CancellationError) { pdf.showError(loc("“{0}” couldn't be done.", loc("Links from Addresses")), error) }
            return
        }
        sheet.end()
        progressSheet = nil
        guard pdf.session?.data == data else { return } // changed meanwhile: what was found may be elsewhere now
        if found.isEmpty {
            let body = loc("No web or email address in the text needs a link: each one found is a link already. A scanned page needs Recognize Text first.")
            if Report.skipsDialogs { return notify(body) }
            let alert = NSAlert()
            alert.messageText = loc("No addresses to link")
            alert.informativeText = body
            await alert.beginSheetModal(for: window)
            return
        }
        guard let chosen = await pickAddresses(found, window), !chosen.isEmpty, pdf.session?.data == data else { return }
        let label = chosen.count == 1 ? loc("Add 1 link") : loc("Add {0} links", CoreLanguage.number(chosen.count))
        await editor.run(label) { d, pw in try AddressLinks.apply(d, pw, chosen) }
        if editor.lastOutcome == .noChange { notify(loc("No link was added: none of the ticked addresses could be made a link.")) }
    }

    /// The list of addresses, each ticked, to untick any; nil when cancelled.
    private func pickAddresses(_ found: [FoundAddress], _ window: NSWindow) async -> [FoundAddress]? {
        if Report.skipsDialogs { return found } // the self-test keeps every address ticked
        let alert = NSAlert()
        alert.messageText = loc("Links from Addresses")
        var intro = found.count == 1 ? loc("1 address in the text isn't a link yet. Untick it to leave it as it is.")
            : loc("{0} addresses in the text aren't links yet. Untick any you want left as they are.", CoreLanguage.number(found.count))
        if found.count >= AddressLinks.maxFound {
            intro += " " + loc("Only the first {0} are listed: run it again for the rest.", CoreLanguage.number(AddressLinks.maxFound))
        }
        alert.informativeText = intro
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        var boxes: [NSButton] = []
        func shortened(_ s: String) -> String { s.count > 80 ? String(s.prefix(77)) + "…" : s }
        for address in found {
            // The address as printed, its page, and where the link will lead when that reads differently.
            let shown = shortened(address.text), leads = shortened(address.uri)
            let line = loc("Page {0}: {1}", CoreLanguage.number(address.page + 1), shown)
            let box = NSButton(checkboxWithTitle: line, target: nil, action: nil)
            box.state = .on
            box.lineBreakMode = .byTruncatingTail
            boxes.append(box)
            if leads.caseInsensitiveCompare(shown) == .orderedSame {
                list.addArrangedSubview(box)
            } else {
                let to = NSTextField(labelWithString: loc("Opens {0}", leads))
                to.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                to.textColor = .secondaryLabelColor
                to.lineBreakMode = .byTruncatingTail
                let item = NSStackView(views: [box, to])
                item.orientation = .vertical
                item.alignment = .leading
                item.spacing = 1
                item.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
                list.addArrangedSubview(item)
            }
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: min(360, CGFloat(found.count) * 38 + 8)))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 0))
        list.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            list.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            list.widthAnchor.constraint(lessThanOrEqualToConstant: 492),
        ])
        content.frame.size.height = list.fittingSize.height + 8
        scroll.documentView = content
        alert.accessoryView = scroll
        alert.addButton(withTitle: loc("Add Links"))
        alert.addButton(withTitle: loc("Cancel"))
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        let chosen = found.indices.filter { boxes[$0].state == .on }.map { found[$0] }
        if chosen.isEmpty { notify(loc("Tick at least one address.")) }
        return chosen
    }
}
