import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// The printer's CUPS queue on its pane (the Windows app's `PrintJobsViewModel`): its jobs, read every few seconds only while
/// the card is on screen, with Cancel for the user's own jobs and Cancel My Jobs. While a network printer's jobs go straight to
/// it (roadmap 2.1, the last route decided), the printer's own job list instead (`PrinterJobs`), cancelled with Cancel-Job.
@MainActor @Observable
final class PrintJobsModel {
    static let interval: Duration = .seconds(3)

    private(set) var jobs: [QueueJob] = []
    private(set) var isLoaded = false
    /// The queue couldn't be read several times in a row; still retrying.
    private(set) var loadError: String?
    var message: String?
    private(set) var cancelling: Set<Int> = []

    let queue: String?
    /// The network printer whose own list is read while its jobs go straight; nil for a queue printer.
    @ObservationIgnored private let printer: PrinterModel?
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var gate = RefreshGate()

    init(queue: String?, printer: PrinterModel?, app: AppModel) {
        self.queue = queue
        self.printer = printer
        self.app = app
    }

    /// The printer's IPP client while its jobs go straight (the last route decided, as job alerts follow it).
    private func direct() async -> IppClient? {
        guard let printer, let choice = try? await printer.routing?.router.forWatching(), choice.route == .direct else { return nil }
        return choice.ipp
    }

    /// The list now: the printer's own while its jobs go straight, else the macOS queue's; nil when it couldn't be read.
    private func list() async -> [QueueJob]? {
        if let ipp = await direct() {
            guard let answer = try? await ipp.getJobs(PrinterJobs.getJobsRequest(ipp.printerUri, user: DirectPrinting.user)) else { return nil }
            return try? PrinterJobs.parse(answer, now: Date())
        }
        guard let queue else { return nil }
        return await app.queues.jobs(queue)
    }

    /// Cancels one job where it is: Cancel-Job on the printer, or the macOS queue.
    private func cancelJob(_ id: Int) async throws {
        if let ipp = await direct() {
            if !(await DirectJob.cancel(ipp, user: DirectPrinting.user, jobId: id)) {
                throw PrintJobCancelError(String(localized: "The printer didn't take the cancel. Cancel it on the printer's control panel."))
            }
            return
        }
        guard let queue else { return }
        try await app.queues.cancel(queue, job: id)
    }

    var user: String { app.queues.user }
    func isMine(_ j: QueueJob) -> Bool { QueueJobText.isOwner(j.owner, user) }
    var offline: Bool { queue.map(app.queueOffline) ?? false }
    var mine: [QueueJob] { jobs.filter { isMine($0) && !cancelling.contains($0.id) && !QueueJobText.isDone($0.state) } }

    /// Reads until the card goes (its task is cancelled).
    func poll() async {
        repeat { await refresh() } while (try? await Task.sleep(for: Self.interval)) != nil
    }

    func refresh() async {
        let ticket = gate.begin()
        guard let read = await list() else {
            if gate.failed(ticket) {
                loadError = printer?.route == .direct ? String(localized: "The printer isn't answering about its jobs. Trying again every few seconds.")
                    : String(localized: "macOS's printing system isn't answering about this queue. Trying again every few seconds.")
                isLoaded = true
                jobs = []
            }
            return
        }
        guard gate.succeeded(ticket) else { return } // a newer read started meanwhile; its list wins
        loadError = nil
        isLoaded = true
        jobs = QueueJobText.order(read)
        cancelling.formIntersection(jobs.map(\.id))
    }

    func cancel(_ j: QueueJob) async {
        message = nil
        cancelling.insert(j.id)
        do {
            try await cancelJob(j.id)
        } catch let e as PrintJobCancelError {
            message = "\"\(j.name)\": \(e.message)"
            cancelling.remove(j.id)
        } catch {
            message = String(localized: "\"\(j.name)\" couldn't be cancelled.")
            cancelling.remove(j.id)
        }
        await refresh()
    }

    func cancelMine() async {
        let list = mine
        var failed = 0
        message = nil
        for j in list {
            cancelling.insert(j.id)
            do {
                try await cancelJob(j.id)
            } catch {
                failed += 1
                cancelling.remove(j.id)
            }
        }
        if failed > 0 { message = String(localized: "\(failed) of \(list.count) jobs couldn't be cancelled. They may have just finished.") }
        await refresh()
    }
}

struct PrintQueueCard: View {
    @State private var model: PrintJobsModel
    @State private var confirmMine = false

    init(queue: String?, printer: PrinterModel? = nil, app: AppModel) {
        _model = State(initialValue: PrintJobsModel(queue: queue, printer: printer, app: app))
        note = printer?.routeNote.text
    }

    /// Where its pages go when that isn't the macOS queue (the Print tab's route note).
    private let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Print Queue").font(.headline)
                if model.isLoaded && model.loadError == nil {
                    Text(QueueJobText.summary(model.jobs)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.mine.isEmpty {
                    Button(model.mine.count == 1 ? String(localized: "Cancel My Job…") : String(localized: "Cancel My Jobs…")) { confirmMine = true }
                }
                Button("Open Printers & Scanners") { NSWorkspace.shared.open(SystemSettings.printers) }
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.jobs) { j in JobRow(job: j, model: model) }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .task { await model.poll() }
        .confirmationDialog(confirmText, isPresented: $confirmMine) {
            Button(model.mine.count == 1 ? String(localized: "Cancel Job") : String(localized: "Cancel Jobs"), role: .destructive) { Task { await model.cancelMine() } }
            Button("Keep", role: .cancel) {}
        }
    }

    private var confirmText: String {
        let mine = model.mine
        guard !mine.isEmpty else { return "" }
        var text = mine.count == 1 ? String(localized: "Cancel \"\(mine[0].name)\"?") : String(localized: "Cancel your \(mine.count) print jobs?")
        let others = model.jobs.count - mine.count
        if others > 0 {
            text += " " + (others == 1 ? String(localized: "1 job from other people stays in the queue.")
                : String(localized: "\(others) jobs from other people stay in the queue."))
        }
        return text
    }
}

private struct JobRow: View {
    let job: QueueJob
    let model: PrintJobsModel

    var body: some View {
        let offline = model.offline
        let problem = QueueJobText.isProblem(job.state, printerOffline: offline)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: problem ? "exclamationmark.triangle.fill" : job.state == .processing ? "printer.fill" : "doc")
                .foregroundStyle(problem ? .orange : .secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                Text(details(offline)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.cancelling.contains(job.id) {
                Text("Cancelling…").font(.caption).foregroundStyle(.secondary)
            } else if model.isMine(job) {
                if !QueueJobText.isDone(job.state) {
                    Button("Cancel") { Task { await model.cancel(job) } }.accessibilityLabel("Cancel \(job.name)")
                }
            } else {
                Text("Only an administrator can cancel it").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func details(_ offline: Bool) -> String {
        var parts = [QueueJobText.status(job.state, printerOffline: offline)]
        let pages = QueueJobText.pages(job.pages, job.pagesPrinted, job.state)
        if !pages.isEmpty { parts.append(pages) }
        parts.append(QueueJobText.submitted(job.submitted, now: Date()))
        if !model.isMine(job) && !job.owner.isEmpty { parts.append(job.owner) }
        return parts.joined(separator: " · ")
    }
}
