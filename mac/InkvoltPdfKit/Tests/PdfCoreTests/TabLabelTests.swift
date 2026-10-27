import Foundation
import Testing
@testable import PdfCore

/// Ported from TabLabelTests.cs: all 5 tests, with Mac paths for the Windows ones.
struct TabLabelTests {
    @Test func differentTitlesStayAsTheyAre() {
        #expect(TabLabels.labels([("report.pdf", "/a/report.pdf"), ("Tax form", "/a/f1040.pdf")]) == ["report.pdf", "Tax form"])
    }

    @Test func documentsTitledAlikeAddTheirFileNames() {
        #expect(TabLabels.labels([("S-73-S", "/a/report.pdf"), ("S-73-S", "/b/f1040.pdf")]) == ["S-73-S · report.pdf", "S-73-S · f1040.pdf"])
    }

    @Test func filesNamedAlikeAddTheirFolders() {
        #expect(TabLabels.labels([("report.pdf", "/taxes/2025/report.pdf"), ("Report.pdf", "/taxes/2026/Report.pdf")])
            == ["report.pdf · 2025", "Report.pdf · 2026"])
    }

    @Test func sameTitleAndFileNameAddBoth() {
        #expect(TabLabels.labels([("Invoice", "/March/bill.pdf"), ("Invoice", "/April/bill.pdf")])
            == ["Invoice · bill.pdf · March", "Invoice · bill.pdf · April"])
    }

    @Test func unsavedDocumentsHaveNothingToAdd() {
        #expect(TabLabels.labels([("Untitled.pdf", nil), ("Untitled.pdf", nil)]) == ["Untitled.pdf", "Untitled.pdf"])
        #expect(TabLabels.labels([("Scan.pdf", "/Docs/Scan.pdf"), ("Scan.pdf", nil)]) == ["Scan.pdf · Docs", "Scan.pdf"])
    }
}
