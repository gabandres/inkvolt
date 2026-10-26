import AppKit
import PrintCore
import SwiftUI
import UniformTypeIdentifiers

/// A printer's Scan tab: the settings beside the scanned pages, then Save.
struct ScanView: View {
    let scan: ScanModel
    let leftOver: [LeftOverScan]
    @Environment(AppModel.self) private var app
    @State private var cropping: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScanSettings(scan: scan).frame(width: 270)
            Divider()
            VStack(spacing: 0) {
                ForEach(leftOver, id: \.listPath) { left in
                    RestoreBanner(left: left) {
                        scan.restore(left)
                        app.leftOverScans.removeAll { $0.listPath == left.listPath }
                    } discard: {
                        ScanRecoveryStore.remove(left)
                        app.leftOverScans.removeAll { $0.listPath == left.listPath }
                    }
                }
                if scan.pages.isEmpty {
                    ContentUnavailableView("No pages yet", systemImage: "doc.viewfinder",
                                           description: Text(scan.isScanning ? "The first page is on its way." : "Put a page on the glass or pages in the feeder, then click Scan."))
                } else {
                    PageGrid(scan: scan, cropping: $cropping)
                }
                Divider()
                SaveBar(scan: scan)
            }
        }
        .task { await scan.load() }
        .sheet(item: Binding(get: { cropping.map(CropTarget.init) }, set: { cropping = $0?.id })) { target in
            CropSheet(scan: scan, id: target.id)
        }
    }
}

private struct CropTarget: Identifiable { let id: String }

private struct ScanSettings: View {
    @Bindable var scan: ScanModel

    var body: some View {
        Form {
            PresetStrip(scan: scan)
            if let error = scan.loadError {
                Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await scan.load() } }
            }
            Picker("Source", selection: $scan.source) {
                ForEach(scan.sources, id: \.self) { Text(ScanChoices.sourceLabel($0)).tag($0) }
            }
            Picker("Color", selection: $scan.color) {
                ForEach(scan.colors, id: \.self) { Text($0 == .color ? "Color" : "Grayscale").tag($0) }
            }
            Picker("Resolution", selection: $scan.dpi) {
                ForEach(scan.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
            }
            Picker("Size", selection: $scan.sizeKey) {
                ForEach(scan.sizes, id: \.key) { Text($0.label).tag($0.key) }
            }
            Picker("Save as", selection: $scan.format) {
                ForEach(ScanFormat.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Skip blank pages", isOn: $scan.skipBlank)
            Toggle("Straighten pages", isOn: $scan.straighten)
            HStack {
                if scan.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { scan.stop() }
                } else {
                    Button(scan.pages.isEmpty ? "Scan" : "Scan More") { scan.scan() }
                        .keyboardShortcut("r", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(scan.caps == nil)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(scan.isSaving)
    }
}

private struct RestoreBanner: View {
    let left: LeftOverScan
    let restore: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack {
            Label("\(left.scan.pages.count) scanned \(left.scan.pages.count == 1 ? "page" : "pages") from \(left.scan.savedUtc.formatted(date: .abbreviated, time: .shortened)) weren't saved.",
                  systemImage: "clock.arrow.circlepath")
            Spacer()
            Button("Restore") { restore() }
            Button("Discard") { discard() }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
    }
}

private struct PageGrid: View {
    let scan: ScanModel
    @Binding var cropping: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                ForEach(scan.pages.pages) { page in
                    PageTile(scan: scan, page: page, cropping: $cropping)
                }
            }
            .padding(14)
        }
    }
}

private struct PageTile: View {
    let scan: ScanModel
    let page: ScannedPage
    @Binding var cropping: String?

    var body: some View {
        let number = scan.pages.number(page.id) ?? 0
        VStack(spacing: 6) {
            ZStack {
                if let image = scan.thumbnails[page.id] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .shadow(radius: 1)
                } else {
                    Rectangle().fill(.background.secondary).aspectRatio(0.77, contentMode: .fit).overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(height: 200)
            .opacity(page.skipped ? 0.35 : 1)
            .onTapGesture(count: 2) { cropping = page.id }
            HStack(spacing: 4) {
                Text("\(number)").font(.caption.monospacedDigit().weight(.semibold))
                if !page.note.isEmpty { Text(page.note).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 2) {
                Button { scan.turn(page.id, -1) } label: { Image(systemName: "rotate.left") }.help("Turn left")
                Button { scan.turn(page.id, 1) } label: { Image(systemName: "rotate.right") }.help("Turn right")
                Button { cropping = page.id } label: { Image(systemName: "crop") }.help("Crop")
                if page.skipped {
                    Button("Keep") { scan.keepPage(page.id) }
                } else {
                    Button { scan.delete(page.id) } label: { Image(systemName: "trash") }.help("Delete")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.background.secondary.opacity(0.5), in: .rect(cornerRadius: 8))
        .contextMenu {
            Button("Turn Left") { scan.turn(page.id, -1) }
            Button("Turn Right") { scan.turn(page.id, 1) }
            Button("Crop…") { cropping = page.id }
            if !page.edits.isEmpty { Button("Undo Edits") { scan.reset(page.id) } }
            Divider()
            Button("Move Earlier") { scan.move(page.id, by: -1) }.disabled(number <= 1)
            Button("Move Later") { scan.move(page.id, by: 1) }.disabled(number >= scan.pages.pages.count)
            Divider()
            if page.skipped { Button("Keep") { scan.keepPage(page.id) } } else { Button("Don't Save") { scan.skipPage(page.id) } }
            Button("Delete", role: .destructive) { scan.delete(page.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page.note.isEmpty ? "Page \(number)" : "Page \(number), \(page.note.lowercased())")
        .draggable(page.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != page.id, let to = scan.pages.number(page.id) else { return false }
            scan.move(id, to: to - 1)
            return true
        }
    }
}

private struct SaveBar: View {
    let scan: ScanModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let problem = scan.problem { Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Text(scan.status).foregroundStyle(.secondary)
            }
            Spacer()
            if scan.isSaving { ProgressView().controlSize(.small) }
            Button("Clear") { scan.clear() }.disabled(scan.pages.isEmpty || scan.isScanning || scan.isSaving)
            Button("Print…") { Task { await scan.printPages() } }
                .help("Print the pages: a copy")
                .disabled(scan.pages.toSave.isEmpty || scan.isScanning || scan.isSaving)
            if let p = scan.preset {
                Button("Save (\(p.name))") { Task { await scan.saveWithPreset() } }
                    .disabled(scan.pages.toSave.isEmpty || scan.isScanning || scan.isSaving)
            }
            Button("Save…") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(scan.pages.toSave.isEmpty || scan.isScanning || scan.isSaving)
        }
        .padding(12)
    }

    /// The save panel (a sandboxed app writes only where the user points): a file for a PDF or one image, a folder for several.
    private func save() {
        let count = scan.pages.toSave.count
        if scan.format == .jpeg && count > 1 {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose the folder for the \(count) images."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await scan.save(to: url) }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [scan.format == .jpeg ? .jpeg : .pdf]
        panel.nameFieldStringValue = scan.suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await scan.save(to: url) }
    }
}

/// Crop: the page enlarged; drag a box over the part to keep.
private struct CropSheet: View {
    let scan: ScanModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var box: CropBox = .full
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag over the part of the page to keep.").foregroundStyle(.secondary)
            GeometryReader { geo in
                if let image {
                    let fit = fitted(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height)
                        Rectangle().fill(.black.opacity(0.35)).frame(width: fit.width, height: fit.height)
                            .mask {
                                Rectangle().overlay {
                                    Rectangle().frame(width: box.width * fit.width, height: box.height * fit.height)
                                        .position(x: (box.x + box.width / 2) * fit.width, y: (box.y + box.height / 2) * fit.height)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                            }
                        Rectangle().strokeBorder(.white, lineWidth: 2)
                            .frame(width: box.width * fit.width, height: box.height * fit.height)
                            .offset(x: box.x * fit.width, y: box.y * fit.height)
                    }
                    .frame(width: fit.width, height: fit.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                        let start = dragStart ?? g.startLocation
                        dragStart = start
                        let x0 = min(start.x, g.location.x) / fit.width, y0 = min(start.y, g.location.y) / fit.height
                        let x1 = max(start.x, g.location.x) / fit.width, y1 = max(start.y, g.location.y) / fit.height
                        box = CropBox(x0, y0, x1 - x0, y1 - y0).clamp()
                    }.onEnded { _ in dragStart = nil })
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ProgressView().position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .frame(minWidth: 520, minHeight: 620)
            HStack {
                Button("Whole Page") { box = .full }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Crop") {
                    scan.crop(id, shown: box)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .task {
            box = scan.pages.page(id)?.edits.shownCrop ?? .full
            image = await scan.image(id)
        }
    }

    private func fitted(_ size: NSSize, in space: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return space }
        let scale = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
