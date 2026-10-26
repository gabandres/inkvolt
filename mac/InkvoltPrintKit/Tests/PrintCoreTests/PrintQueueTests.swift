import Foundation
import Testing
@testable import PrintCore

/// The print queue card's words for a printer's CUPS jobs. Ported from PrintQueueTests.cs (Windows' job status bits become
/// IPP's job states, which CUPS reports).
struct PrintQueueTests {
    @Test(arguments: [
        (JobState.pending, false, "Waiting"),
        (.held, false, "On hold"),
        (.processing, false, "Printing"),
        (.processing, true, "Printer offline"),
        (.pending, true, "Printer offline"),
        (.stopped, false, "Stopped"),
        (.canceled, false, "Cancelled"),
        (.aborted, false, "Error"),
        (.completed, false, "Printed"),
    ])
    func statusWordsPickTheMostImportantState(_ state: JobState, _ offline: Bool, _ expected: String) {
        #expect(QueueJobText.status(state, printerOffline: offline) == expected)
    }

    @Test func jobStatesAreIpps() {
        #expect(JobState.pending.rawValue == 3)
        #expect(JobState.processing.rawValue == 5)
        #expect(JobState.completed.rawValue == 9)
    }

    @Test(arguments: [
        (Int?.none, 0, JobState.pending, ""),
        (0, 0, .pending, ""),
        (1, 0, .pending, "1 page"),
        (12, 0, .pending, "12 pages"),
        (12, 3, .processing, "Page 4 of 12"),
        (12, 12, .processing, "12 pages"),
    ])
    func pagesText(_ pages: Int?, _ printed: Int, _ state: JobState, _ expected: String) {
        #expect(QueueJobText.pages(pages, printed, state) == expected)
    }

    @Test func submittedShowsTheDateOnlyForOlderJobs() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let now = at(24, 15, 0)
        let today = QueueJobText.submitted(at(24, 9, 5), now: now, calendar: calendar, locale: locale)
        #expect(today.hasSuffix("9:05") && !today.contains("October")) // "09:05" or "9:05", by the platform's ICU
        #expect(QueueJobText.submitted(at(23, 22, 40), now: now, calendar: calendar, locale: locale) == "23 October, 22:40")
    }

    @Test(arguments: [
        ("gabri", "gabri", true),
        ("GABRI", "gabri", true),
        (#"OFFICE\gabri"#, "gabri", true),
        ("alex", "gabri", false),
        ("", "gabri", false),
    ])
    func ownerMatch(_ owner: String, _ user: String, _ mine: Bool) {
        #expect(QueueJobText.isOwner(owner, user) == mine)
    }

    @Test func summaryAndOrder() {
        let t = Date(timeIntervalSince1970: 1_792_843_200)
        let jobs = QueueJobText.order([
            QueueJob(id: 7, name: "b", pages: 1, state: .pending, submitted: t.addingTimeInterval(60), owner: "me"),
            QueueJob(id: 5, name: "a", pages: 3, pagesPrinted: 1, state: .processing, submitted: t, owner: "me"),
            QueueJob(id: 9, name: "c", pages: 2, state: .pending, submitted: t.addingTimeInterval(60), owner: "alex"),
        ])
        #expect(jobs.map(\.id) == [5, 7, 9])
        #expect(QueueJobText.summary(jobs) == "3 jobs, 1 printing")
        #expect(QueueJobText.summary([jobs[0]]) == "1 job")
        #expect(QueueJobText.summary([]) == "Nothing waiting to print")
        #expect(QueueJobText.isProblem(.stopped))
        #expect(QueueJobText.isProblem(.processing, printerOffline: true))
        #expect(!QueueJobText.isProblem(.processing))
    }

    @Test func theMadeUpQueuesCancelYourJobsButNotOthers() async throws {
        let queues = Demo.queues()
        let jobs = try #require(await queues.jobs("Office_color_MFP"))
        #expect(jobs.map(\.owner) == ["you", "alex"])
        #expect(await queues.destinations()?.first { $0.name == "Office_color_MFP" }?.jobs == 2)

        await #expect(throws: PrintJobCancelError("Only an administrator can cancel someone else's job.")) {
            try await queues.cancel("Office_color_MFP", job: 42)
        }
        try await queues.cancel("office_color_mfp", job: 41)
        #expect(await queues.jobs("Office_color_MFP")?.map(\.id) == [42])
        await #expect(throws: PrintJobCancelError.self) { try await queues.cancel("Office_color_MFP", job: 41) } // gone already
    }
}

struct RefreshGateTests {
    @Test func onlyTheLatestReadApplies() {
        var gate = RefreshGate()
        let poll = gate.begin()
        let afterCancel = gate.begin()
        let latest = gate.succeeded(afterCancel), stale = gate.succeeded(poll)
        #expect(latest)
        #expect(!stale) // older read finishing last: stale, dropped
    }

    @Test func repeatedFailuresAreReportedAndASuccessResetsTheCount() {
        var gate = RefreshGate(failuresBeforeReport: 3)
        var said: [Bool] = []
        for _ in 0..<4 { said.append(gate.failed(gate.begin())) }
        said.append(gate.succeeded(gate.begin()))
        said.append(gate.failed(gate.begin()))
        #expect(said == [false, false, true, true, true, false])
    }

    @Test func aStaleFailureDoesNotCount() {
        var gate = RefreshGate(failuresBeforeReport: 1)
        let old = gate.begin()
        let latest = gate.begin()
        let counted = gate.failed(old), applied = gate.succeeded(latest)
        #expect(!counted)
        #expect(applied)
    }
}
