import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// The offline fixer for one printer (the Windows app's `OfflineFixerViewModel`): the checks as they run, then what to fix,
/// each with a button when Inkvolt Print can do it and the steps for System Settings when it can't.
@MainActor @Observable
final class OfflineFixerModel {
    private(set) var checks: [CheckResult] = CheckKind.allCases.map(CheckResult.waiting)
    private(set) var report: OfflineReport?
    private(set) var running = false
    private(set) var outcomes: [Int: RepairOutcome] = [:]
    private(set) var working: Int?
    /// The new address was taken (or the user said it's the printer's).
    private(set) var adopted: String?

    @ObservationIgnored private let printer: PrinterModel
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(printer: PrinterModel, app: AppModel) {
        self.printer = printer
        self.app = app
    }

    var name: String { printer.name }

    func run() {
        task?.cancel()
        checks = CheckKind.allCases.map(CheckResult.waiting)
        report = nil
        outcomes = [:]
        adopted = nil
        running = true
        let device = OfflineDevice(uuid: printer.id, name: printer.name, model: printer.model, host: printer.isNetwork ? printer.host : nil)
        let probes = app.offlineProbes, queues = app.queues
        task = Task {
            defer { running = false }
            do {
                let r = try await OfflineDiagnosis.run(device, probes: probes, queues: queues) { result in
                    Task { @MainActor in self.show(result) }
                }
                await Task.yield() // the last check's line is queued: show it first
                report = r
                checks = r.checks
                if r.adoption == .adopt, let found = r.found { adopt(found.address) }
            } catch {
                // Cancelled (the sheet closed): nothing to show.
            }
        }
    }

    func stop() { task?.cancel() }

    private func show(_ r: CheckResult) {
        guard report == nil, let i = checks.firstIndex(where: { $0.kind == r.kind }) else { return }
        checks[i] = r
    }

    /// Inkvolt Print reaches the printer at its new address from now on.
    func adopt(_ address: String) {
        adopted = address
        printer.move(to: address)
    }

    func repair(_ index: Int) {
        guard let r = report?.repairs[safe: index], working == nil else { return }
        working = index
        let queues = app.queues, control = app.queueControl
        Task {
            let outcome = await RepairRunner.run(r, queues: queues, control: control)
            outcomes[index] = outcome
            working = nil
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct OfflineFixerSheet: View {
    @State private var model: OfflineFixerModel
    @State private var asking: Int?
    @Environment(\.dismiss) private var dismiss

    init(printer: PrinterModel, app: AppModel) { _model = State(initialValue: OfflineFixerModel(printer: printer, app: app)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fix \(model.name)").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.checks, id: \.kind) { c in CheckRow(check: c) }
            }
            if let r = model.report {
                Divider()
                Text(r.headline).font(.headline)
                Text(r.advice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let adopted = model.adopted {
                    Label("Inkvolt Print now reaches \(model.name) at \(adopted).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let question = r.adoptionQuestion, let found = r.found {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question).fixedSize(horizontal: false, vertical: true)
                        Button("Use \(found.address)") { model.adopt(found.address) }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(r.repairs.enumerated()), id: \.offset) { i, repair in
                            RepairRow(repair: repair, outcome: model.outcomes[i], working: model.working == i) {
                                if repair.question != nil { asking = i } else { model.repair(i) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            HStack {
                Button("Open Printers & Scanners") { NSWorkspace.shared.open(SystemSettings.printers) }
                Spacer()
                if model.running { ProgressView().controlSize(.small) } else { Button("Check Again") { model.run() } }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { model.run() }
        .onDisappear { model.stop() }
        .confirmationDialog(asking.flatMap { model.report?.repairs[safe: $0]?.question } ?? "", isPresented: Binding(get: { asking != nil },
                                                                                                                   set: { if !$0 { asking = nil } })) {
            if let i = asking, let repair = model.report?.repairs[safe: i] {
                Button(repair.confirm, role: .destructive) { model.repair(i) }
            }
        }
    }
}

private struct CheckRow: View {
    let check: CheckResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch check.state {
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.small)
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                if !check.detail.isEmpty { Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RepairRow: View {
    let repair: Repair
    let outcome: RepairOutcome?
    let working: Bool
    let fix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repair.title).font(.body.weight(.medium))
                    Text(repair.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                } else if !repair.manualOnly && outcome?.kind != .fixed {
                    Button(repair.confirm) { fix() }
                }
            }
            if let outcome {
                Label(outcome.message, systemImage: outcome.kind == .fixed ? "checkmark.circle.fill" : outcome.kind == .manual ? "hand.point.right" : "xmark.circle")
                    .foregroundStyle(outcome.kind == .fixed ? .green : outcome.kind == .manual ? .primary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let steps = outcome?.steps.isEmpty == false ? outcome!.steps : repair.manualOnly ? repair.manualSteps : []
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { n, step in
                        Text("\(n + 1). \(step)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
            }
        }
    }
}
