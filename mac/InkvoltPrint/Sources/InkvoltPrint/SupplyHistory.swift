import AppKit
import Charts
import PrintCore
import SwiftUI
import UniformTypeIdentifiers

/// The status tab's supplies card (roadmap 1.1, Windows' supplies card): each supply with its line from the supply history
/// ("About 34 days left · 1,240 pages since this cartridge went in", or why not yet), the level chart over the last year once
/// two days are kept, why it isn't there yet, and Export history… (Inkvolt Pro).
struct SuppliesSection: View {
    let printer: PrinterModel
    @Environment(AppModel.self) private var app
    /// What Export history… did ("Saved …", or why not).
    @State private var exportMessage: String?

    var body: some View {
        let v = printer.view
        let history = v.supplyHistory
        VStack(alignment: .leading, spacing: 10) {
            Text("Supplies").font(.headline)
            if let source = v.suppliesSource { Text(source).font(.caption).foregroundStyle(.secondary) } // a queue printer's (roadmap 3.6)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(Array(v.supplies.enumerated()), id: \.offset) { _, supply in
                    SupplyCard(supply: SupplyText(supply), historyLine: history?.line(for: supply))
                }
            }
            if let history, history.chart.hasEnoughToDraw {
                chart(history.chart)
            } else if let note = history?.chartNote(v.supplies) {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: printer.id) { exportMessage = nil }
    }

    private func chart(_ data: SupplyChartData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Levels over the last year").font(.caption).foregroundStyle(.secondary)
            SupplyChart(data: data).frame(minWidth: 240, maxWidth: 560, minHeight: 120, maxHeight: 120)
            HStack(spacing: 12) {
                Button("Export history…") { exportMessage = SupplyHistoryExport.run(app) }
                    .buttonStyle(.link)
                    .help("Save the supply history of all printers as one CSV file (Inkvolt Pro)")
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// The level chart (Windows' `SupplyChartView`): each supply's stored levels over the last year as a line in its own color,
/// broken where the printer gave no level and at a change of cartridge, which gets a dot where the new one starts. Draws
/// `SupplyChartData` as it is: no smoothing, nothing between the stored points.
struct SupplyChart: View {
    let data: SupplyChartData
    @Environment(\.colorSchemeContrast) private var contrast

    /// One mark: a point on a line, a lone point, or the start of a new cartridge.
    struct Mark: Identifiable {
        enum Kind { case line, lone, change }
        let id: Int
        let series: String
        let date: Date
        let percent: Int
        let color: String?
        let kind: Kind
    }

    var body: some View {
        let marks = Self.marks(data)
        VStack(alignment: .leading, spacing: 2) {
            Chart(marks) { mark in
                if mark.kind == .line {
                    LineMark(x: .value("Day", mark.date), y: .value("Level", mark.percent), series: .value("Line", mark.series))
                        .foregroundStyle(color(mark.color))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                } else {
                    PointMark(x: .value("Day", mark.date), y: .value("Level", mark.percent))
                        .foregroundStyle(color(mark.color))
                        .symbolSize(mark.kind == .change ? 30 : 8)
                }
            }
            .chartXScale(domain: Self.date(data.from)...Self.date(data.to))
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [1, 2]))
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            HStack {
                Text(Self.date(data.from).formatted(.dateTime.month(.abbreviated).year()))
                Spacer()
                Text(Self.date(data.to).formatted(.dateTime.day().month(.abbreviated)))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 34)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(data))
    }

    /// The marks in drawing order: each segment's points (a segment of one point is a dot), then each change of cartridge's
    /// dot at the first point on or after it.
    static func marks(_ data: SupplyChartData) -> [Mark] {
        var marks: [Mark] = []
        for (n, line) in data.lines.enumerated() {
            for (s, segment) in line.segments.enumerated() {
                let kind: Mark.Kind = segment.count == 1 ? .lone : .line
                for p in segment {
                    marks.append(Mark(id: marks.count, series: "\(n)-\(s)", date: date(p.day), percent: p.percent, color: line.color, kind: kind))
                }
            }
            let points = line.segments.flatMap { $0 }
            for change in line.changes {
                guard let start = points.first(where: { $0.day >= change }) else { continue }
                marks.append(Mark(id: marks.count, series: "\(n)-change", date: date(start.day), percent: start.percent, color: line.color, kind: .change))
            }
        }
        return marks
    }

    /// What VoiceOver says: each supply's first and last level shown, and its changes of cartridge (Windows' chart name).
    static func spoken(_ data: SupplyChartData) -> String {
        let long = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        let parts = data.lines.compactMap { line -> String? in
            let points = line.segments.flatMap { $0 }
            guard let first = points.first, let last = points.last else { return nil }
            let levels = "\(line.supply) from \(first.percent)% to \(last.percent)%"
            switch line.changes.count {
            case 0: return levels
            case 1: return levels + ", changed on " + date(line.changes[0]).formatted(long)
            default: return levels + ", changed \(line.changes.count) times"
            }
        }
        return "Levels since \(date(data.from).formatted(long)): " + parts.joined(separator: "; ")
    }

    /// Noon on that day here (a day's mark never slips across midnight with daylight saving).
    static func date(_ day: Day) -> Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? .distantPast
    }

    /// Cyan, magenta and yellow as Windows draws them; black, no color, or Increase Contrast: the text color, which reads on
    /// light and dark.
    private func color(_ code: String?) -> Color {
        if contrast == .increased { return .primary }
        switch code?.uppercased() {
        case "C": return Color(red: 0x00 / 255.0, green: 0xA3 / 255.0, blue: 0xE0 / 255.0)
        case "M": return Color(red: 0xD0 / 255.0, green: 0x1C / 255.0, blue: 0x8B / 255.0)
        case "Y": return Color(red: 0xE0 / 255.0, green: 0xB0 / 255.0, blue: 0x00 / 255.0)
        case let hex? where hex.hasPrefix("#"): return Swatch.color(hex) ?? .primary
        default: return .primary
        }
    }
}

/// Export history… (Windows' `ExportHistory`): one CSV of every printer's supply history behind Inkvolt Pro; without the
/// licence the Pro window says what it does. The chart and days left stay free.
@MainActor
enum SupplyHistoryExport {
    /// The file's text when the Pro check allows it (`SupplyHistoryCsv.export`), across every printer on the list.
    static func csv(_ app: AppModel) -> String? {
        SupplyHistoryCsv.export(app.history, app.printers.map { (id: $0.id, name: $0.name) })
    }

    /// Asks where to save it and saves it; what happened in words, nil when nothing did (the Pro window or Cancel).
    static func run(_ app: AppModel) -> String? {
        guard let csv = csv(app) else {
            ProWindow.show(feature: .supplyHistoryExport)
            return nil
        }
        let panel = NSSavePanel()
        panel.title = "Export the supply history"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Supply history \(Day(Date())).csv"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try write(csv, to: url)
            return "Saved \(url.lastPathComponent)"
        } catch {
            return "Could not save the supply history: \(error.localizedDescription)"
        }
    }

    /// UTF-8 with a byte order mark, so Excel reads the names as UTF-8 (as Windows writes it).
    static func write(_ csv: String, to url: URL) throws {
        try bytes(csv).write(to: url, options: .atomic)
    }

    /// The file's bytes as `write` saves them.
    static func bytes(_ csv: String) -> Data { Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8) }
}
