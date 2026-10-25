using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Tabs whose titles clash get what tells them apart: the file name, else the folder.</summary>
public class TabLabelTests
{
    [Fact]
    public void Different_titles_stay_as_they_are()
    {
        Assert.Equal(["report.pdf", "Tax form"],
            TabLabels.For([("report.pdf", @"C:\a\report.pdf"), ("Tax form", @"C:\a\f1040.pdf")]));
    }

    [Fact]
    public void Documents_titled_alike_add_their_file_names()
    {
        Assert.Equal(["S-73-S · report.pdf", "S-73-S · f1040.pdf"],
            TabLabels.For([("S-73-S", @"C:\a\report.pdf"), ("S-73-S", @"C:\b\f1040.pdf")]));
    }

    [Fact]
    public void Files_named_alike_add_their_folders()
    {
        Assert.Equal(["report.pdf · 2025", "Report.pdf · 2026"],
            TabLabels.For([("report.pdf", @"C:\taxes\2025\report.pdf"), ("Report.pdf", @"C:\taxes\2026\Report.pdf")]));
    }

    [Fact]
    public void Same_title_and_file_name_add_both()
    {
        Assert.Equal(["Invoice · bill.pdf · March", "Invoice · bill.pdf · April"],
            TabLabels.For([("Invoice", @"C:\March\bill.pdf"), ("Invoice", @"C:\April\bill.pdf")]));
    }

    [Fact]
    public void Unsaved_documents_have_nothing_to_add()
    {
        Assert.Equal(["Untitled.pdf", "Untitled.pdf"], TabLabels.For([("Untitled.pdf", null), ("Untitled.pdf", null)]));
        Assert.Equal(["Scan.pdf · Docs", "Scan.pdf"], TabLabels.For([("Scan.pdf", @"C:\Docs\Scan.pdf"), ("Scan.pdf", null)]));
    }
}
