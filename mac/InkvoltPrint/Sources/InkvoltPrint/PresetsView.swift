import AppKit
import PrintCore
import SwiftUI

/// One-click scans on the Scan tab: a button per preset (⌘1…⌘9 for the first nine), and Manage Presets.
struct PresetStrip: View {
    let scan: ScanModel
    @Environment(AppModel.self) private var app
    @State private var managing = false

    var body: some View {
        Section("One-click scans") {
            ForEach(Array(app.presets.enumerated()), id: \.element.id) { i, p in
                Button {
                    Task { await scan.scan(with: p) }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(ScanPresetText.summary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command) : nil)
                .accessibilityLabel("Scan with \(p.name)")
                .disabled(scan.isScanning || scan.caps == nil)
            }
            Button("Manage Presets…") { managing = true }
        }
        .sheet(isPresented: $managing) { PresetsManager().environment(app) }
    }
}

/// Manage Presets: create, duplicate, rename, delete and reorder presets, and edit what each does.
struct PresetsManager: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var list: [ScanPreset] = []
    @State private var selected: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(list, id: \.id) { p in Text(p.name).tag(p.id) }
                        .onMove { from, to in list.move(fromOffsets: from, toOffset: to) }
                }
                HStack(spacing: 4) {
                    Button { add(ScanPresets.create(list)) } label: { Image(systemName: "plus") }.help("New preset")
                    Button { if let p = current { add(ScanPresets.duplicate(list, p)) } } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate").disabled(current == nil)
                    Button { list.removeAll { $0.id == selected }; selected = list.first?.id } label: { Image(systemName: "minus") }
                        .help("Delete").disabled(current == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 200)
            Divider()
            if let i = list.firstIndex(where: { $0.id == selected }) {
                PresetEditor(preset: $list[i], others: list)
            } else {
                ContentUnavailableView("No preset selected", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
            }
        }
        .frame(width: 700, height: 520)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.savePresets(ScanPresets.keepCounters(list, app.presets))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(list.contains { ScanPresets.nameProblem(list, $0.id, $0.name) != nil })
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear {
            list = app.presets
            selected = list.first?.id
        }
    }

    private var current: ScanPreset? { list.first { $0.id == selected } }

    private func add(_ p: ScanPreset) {
        list.append(p)
        selected = p.id
    }
}

private struct PresetEditor: View {
    @Binding var preset: ScanPreset
    let others: [ScanPreset]
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                if let problem = ScanPresets.nameProblem(others, preset.id, preset.name) { Text(problem).foregroundStyle(.red).font(.caption) }
            }
            Section("Scan") {
                Picker("Source", selection: $preset.source) {
                    Text("Feeder when it holds pages, else the glass").tag(PresetSource.auto)
                    Text("Glass").tag(PresetSource.glass)
                    Text("Feeder").tag(PresetSource.feeder)
                }
                Toggle("Both sides (feeder)", isOn: $preset.twoSided).disabled(preset.source == .glass)
                Toggle("Color", isOn: $preset.color)
                Picker("Resolution", selection: $preset.resolution) { ForEach([150, 200, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) } }
                Picker("Size", selection: $preset.pageSize) {
                    Text("Letter or A4, by region").tag(String?.none)
                    ForEach(ScanChoices.pageSizes, id: \.key) { Text($0.label).tag(Optional($0.key)) }
                }
                Toggle("Skip blank pages", isOn: $preset.skipBlank)
                Toggle("Straighten pages", isOn: $preset.straighten)
                Toggle("Stop on the pages to review them before saving", isOn: $preset.review)
                if preset.source != .glass {
                    Picker("Split into files at", selection: $preset.splitAt) {
                        ForEach(SplitAt.known, id: \.self) { Text(Separators.label($0)).tag($0) }
                    }
                    if preset.splitAt != .none { Toggle("Keep separator sheets", isOn: $preset.keepSeparators) }
                }
                if preset.source != .feeder { Toggle("Several photos on the glass", isOn: $preset.findPhotos) }
            }
            Section("Save") {
                Picker("As", selection: $preset.fileType) {
                    Text("PDF").tag(PresetFileType.pdf)
                    Text("Searchable PDF").tag(PresetFileType.searchablePdf)
                    Text("JPEG images").tag(PresetFileType.jpeg)
                }
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(app.presetFolder(preset.id)?.path(percentEncoded: false) ?? "Asked the first time").foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { chooseFolder() }
                }
                TextField("Subfolder", text: $preset.subfolder, prompt: Text("none"))
                TextField("File name", text: $preset.fileName)
                if let problem = FileNameTemplate.problem(preset.fileName) {
                    Text(problem).foregroundStyle(.red).font(.caption)
                } else {
                    Text("Next: \(FileNameTemplate.fileName(preset.fileName, NameContext(now: Date(), preset: preset.name, printer: "Printer", number: preset.nextNumber, pages: 3)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("{date}, {date:yyyy-MM}, {time}, {preset}, {printer}, {n} or {n:000}, {pages}").font(.caption).foregroundStyle(.secondary)
                // Open in Inkvolt PDF: offered when Inkvolt PDF is installed (or the preset already has it, from Windows or before
                // Inkvolt PDF was removed).
                Picker("Then", selection: $preset.after) {
                    Text("Nothing more").tag(PresetAfter.none)
                    Text("Print a copy").tag(PresetAfter.print)
                    Text("Attach to a new email").tag(PresetAfter.email)
                    if InkvoltPdfApp.url != nil || preset.after == .openInInkvoltPdf {
                        Text(InkvoltPdfApp.url == nil ? "Open in Inkvolt PDF (not installed)" : "Open in Inkvolt PDF").tag(PresetAfter.openInInkvoltPdf)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.setPresetFolder(preset.id, url)
        preset.folder = .custom
    }
}
