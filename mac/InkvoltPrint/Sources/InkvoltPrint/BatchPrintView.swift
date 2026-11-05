import AppKit
import PrintCore
import SwiftUI
import UniformTypeIdentifiers

/// File › Batch Print…: the window, one per app model, brought forward when it is open already.
@MainActor
enum BatchPrintWindow {
    private static var window: NSWindow?
    private(set) static var model: BatchPrintModel?

    @discardableResult
    static func show(_ app: AppModel) -> BatchPrintModel {
        if let model, model.app === app, let window {
            model.reloadChoices()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return model
        }
        let model = BatchPrintModel(app: app)
        self.model = model
        let host = NSHostingView(rootView: BatchPrintView(model: model))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.contentView = host
        w.title = app.isDemo ? "Batch Print — Demo" : "Batch Print"
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.contentMinSize = NSSize(width: 720, height: 480)
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        return model
    }

    /// The open window's content size, for `--report`.
    static var size: NSSize? { window.flatMap { $0.isVisible ? $0.contentLayoutRect.size : nil } }
}

struct BatchPrintView: View {
    @Bindable var model: BatchPrintModel
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BatchPrinterBar(model: model)
            BatchListButtons(model: model)
            BatchTable(model: model)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: dropping ? 2 : 0))
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await model.add(urls) }
                    return !urls.isEmpty
                } isTargeted: { dropping = $0 }
            if let row = model.selected { BatchRowEditor(model: model, row: row) }
            if model.watchedFolder != nil { BatchWatchLines(model: model) }
            BatchFooter(model: model)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// The printer and the settings new files take.
private struct BatchPrinterBar: View {
    @Bindable var model: BatchPrintModel

    var body: some View {
        HStack(spacing: 14) {
            Picker("Printer", selection: $model.queueId) {
                if model.choices.isEmpty { Text("No macOS print queue").tag(String?.none) }
                ForEach(model.choices) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 320)
            .disabled(!model.isFree)
            Text("For files added:").foregroundStyle(.secondary)
            Stepper("Copies: \(model.allCopies)", value: $model.allCopies, in: 1...BatchPrintLimits.maxCopies)
            Toggle("Two-sided", isOn: $model.allTwoSided).disabled(!model.canTwoSided)
            BatchPaperPicker(papers: model.papers, paper: $model.allPaper)
        }
    }
}

private struct BatchPaperPicker: View {
    let papers: [BatchPaper]
    @Binding var paper: String?

    var body: some View {
        Picker("Paper", selection: $paper) {
            Text("Printer's default").tag(String?.none)
            ForEach(papers, id: \.key) { Text($0.label).tag(Optional($0.key)) }
        }
        .frame(maxWidth: 220)
    }
}

private struct BatchListButtons: View {
    let model: BatchPrintModel

    var body: some View {
        HStack {
            Button("Add Files…") { pick(folders: false) }
            Button("Add Folder…") { pick(folders: true) }
            Divider().frame(height: 16)
            Button("Move Up") { model.move(-1) }.disabled(model.selected == nil || model.isSending)
            Button("Move Down") { model.move(1) }.disabled(model.selected == nil || model.isSending)
            Button("Remove") { model.remove() }.disabled(model.selected == nil || model.isSending)
            Button("Clear") { model.clear() }.disabled(model.rows.isEmpty || model.isSending)
            Spacer()
            Button("Open List…") { model.openList() }.disabled(!model.isFree)
            Button("Save List…") { model.saveList() }.disabled(model.rows.isEmpty)
        }
        .disabled(model.watchedFolder != nil)
    }

    private func pick(folders: Bool) {
        let panel = NSOpenPanel()
        panel.title = folders ? "Add a folder of PDFs and pictures" : "Add PDFs and pictures"
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        if !folders { panel.allowedContentTypes = [.pdf, .image] }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.add(urls) }
    }
}

private struct BatchTable: View {
    @Bindable var model: BatchPrintModel

    var body: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("#") { row in Text(position(row)).foregroundStyle(.secondary) }.width(28)
            TableColumn("File") { row in Text(BatchPrintText.clean(row.name)).help(BatchPrintText.clean(row.folder)) }.width(min: 160, ideal: 240)
            TableColumn("Pages") { row in Text(row.pagesText) }.width(70)
            TableColumn("Copies") { row in Text("\(row.copies)") }.width(50)
            TableColumn("Sheets") { row in Text(row.sheetsText) }.width(70)
            TableColumn("Status") { row in
                Text(row.stateText).foregroundStyle(row.isProblem ? Color.red : Color.primary).lineLimit(2)
            }
            .width(min: 200, ideal: 320)
        }
        .accessibilityLabel("Files to print")
    }

    private func position(_ row: BatchRow) -> String {
        (model.rows.firstIndex { $0.id == row.id }).map { String($0 + 1) } ?? ""
    }
}

/// The selected file's own settings.
private struct BatchRowEditor: View {
    let model: BatchPrintModel
    @Bindable var row: BatchRow

    var body: some View {
        HStack(spacing: 14) {
            Text(BatchPrintText.clean(row.name)).fontWeight(.semibold).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            Stepper("Copies: \(row.copies)", value: $row.copies, in: 1...BatchPrintLimits.maxCopies)
            TextField("Pages", text: $row.range, prompt: Text("All"))
                .frame(width: 110)
                .help("Use page numbers like 1-3, 5")
            Toggle("Two-sided", isOn: $row.twoSided).disabled(!model.canTwoSided && !row.twoSided)
            BatchPaperPicker(papers: model.papers, paper: $row.paper)
            if row.needsPassword { Button("Enter Password…") { Task { await model.enterPassword() } } }
        }
        .disabled(!row.stillToSend || model.isSending)
        .onChange(of: row.settings) { model.changed(row) }
    }
}

private struct BatchWatchLines: View {
    let model: BatchPrintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Watching \(BatchPrintText.clean(model.watchedFolder ?? ""))").fontWeight(.semibold)
                Spacer()
                Button("Stop Watching") { model.stopWatching() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.watchLines.enumerated()), id: \.offset) { Text($0.element).font(.callout).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
        }
    }
}

private struct BatchFooter: View {
    let model: BatchPrintModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = model.message {
                Text(message).foregroundStyle(model.messageIsError ? Color.red : Color.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(model.progress ?? model.summary).foregroundStyle(.secondary)
                Spacer()
                Button("Watch Folder…") { model.chooseWatchFolder() }.disabled(model.watchedFolder != nil || model.isSending)
                Button("Export Results…") { model.exportResults() }.disabled(!model.hasResults)
                Button("Check Again") { Task { await model.checkAgain() } }.disabled(!model.isFree || model.rows.isEmpty)
                if model.isSending {
                    Button("Stop") { model.stop() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Print") { Task { await model.printAll() } }.keyboardShortcut(.defaultAction).disabled(!model.canPrint)
                }
            }
        }
    }
}
