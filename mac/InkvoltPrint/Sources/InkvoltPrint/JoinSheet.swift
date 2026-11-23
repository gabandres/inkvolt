import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// Join with the Next Page… (roadmap 4.8, the Windows app's join view): the two halves of an original too big for the glass,
/// joined where they overlap (`HalvesJoin`), shown before anything changes. Not sure of the overlap, the second half starts
/// edge to edge: the arrows move it (⇧ further), Turn turns it half a turn, Other Side puts it on the next side. Join is one
/// step of Undo.
struct JoinSheet: View {
    let scan: ScanModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var work: JoinWork?
    @State private var placement = JoinPlacement(.right, false, 0, 0)
    @State private var preview: NSImage?
    @State private var note = String(localized: "Looking for where the halves overlap…")
    @State private var joiningNow = false
    @State private var stop = BatchStop()

    private var title: String {
        let n = scan.pages.number(id) ?? 1
        return String(localized: "Join page \(n) and page \(n + 1)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text("For an original too big for the glass: scan one half, then the other with an inch or so of overlap (turning the original round is fine).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                controls.frame(width: 230)
                shown
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    stop.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Join") { join() }.keyboardShortcut(.defaultAction).disabled(work == nil || joiningNow)
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 620)
        .task { await find() }
        .task(id: placement) { await draw() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note).fixedSize(horizontal: false, vertical: true)
            if work != nil {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        arrow("arrow.up", String(localized: "Move the second half up"), 0, -1, .upArrow)
                    }
                    GridRow {
                        arrow("arrow.left", String(localized: "Move the second half left"), -1, 0, .leftArrow)
                        Color.clear.frame(width: 1, height: 1)
                        arrow("arrow.right", String(localized: "Move the second half right"), 1, 0, .rightArrow)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        arrow("arrow.down", String(localized: "Move the second half down"), 0, 1, .downArrow)
                    }
                }
                Button("Turn the Second Half") { turnSecond() }.help("Turns it half a turn, for an original turned round on the glass")
                Button("Other Side") { otherSide() }.help("Puts the second half below, to the left of, above or to the right of the first")
            }
        }
        .disabled(joiningNow)
    }

    private func arrow(_ symbol: String, _ label: String, _ dx: Int, _ dy: Int, _ key: KeyEquivalent) -> some View {
        Button { nudge(dx, dy) } label: { Image(systemName: symbol) }
            .help(label)
            .accessibilityLabel(label)
            .keyboardShortcut(key, modifiers: [])
    }

    private var shown: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit).shadow(radius: 1)
                    .accessibilityLabel(String(localized: "The joined page"))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func find() async {
        guard let found = await scan.findJoin(id, stop: stop) else {
            note = scan.problem ?? String(localized: "Couldn't join the pages. Try scanning the halves again.")
            return
        }
        work = found
        placement = found.placement
        note = found.found.sure ? String(localized: "Found where the halves overlap. Move the second half if it isn't quite right.")
            : String(localized: "Couldn't find where the halves overlap: move the second half with the arrows (Shift moves it further), turn it, or put it on another side.")
        AccessibilityNotification.Announcement(note).post()
    }

    private func draw() async {
        guard let work else { return }
        let at = placement
        let image: CGImage? = await offPool { ScanModel.joinPreview(work, at) }
        if !Task.isCancelled && at == placement { preview = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
    }

    /// A fiftieth of an inch a click, a fifth with ⇧.
    private func nudge(_ dx: Int, _ dy: Int) {
        guard let work else { return }
        let step = max(1, work.dpi / (NSEvent.modifierFlags.contains(.shift) ? 5 : 50))
        placement = placement.nudged(dx * step, dy * step)
    }

    /// The second half turned half a turn where it lies.
    private func turnSecond() {
        placement = JoinPlacement(placement.side, !placement.turned, placement.x, placement.y)
    }

    /// The next side round (right, below, left, above), edge to edge.
    private func otherSide() {
        guard let work else { return }
        let next = JoinSide(rawValue: (placement.side.rawValue + 1) % 4) ?? .right
        placement = HalvesJoin.edgeToEdge(next, placement.turned, work.a.width, work.a.height, work.b.width, work.b.height)
    }

    private func join() {
        guard let work else { return }
        joiningNow = true
        let at = placement
        Task {
            if await scan.join(work, at: at) {
                dismiss()
            } else {
                note = scan.problem ?? String(localized: "Couldn't join the pages. Try scanning the halves again.")
                joiningNow = false
            }
        }
    }
}
