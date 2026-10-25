using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Tests;

/// <summary>The printer list's one line: the state, and the reason for a warning or error the state's own words don't give.</summary>
public class StatusLineTests
{
    private static PrinterAlert A(Severity severity, string text) => new(text, severity, text);

    [Fact]
    public void A_printer_without_problems_shows_its_state()
    {
        Assert.Equal("Ready", PrinterStatus.ListLine("Ready", Severity.Info, []));
        Assert.Equal("Sleeping", PrinterStatus.ListLine("Sleeping", Severity.Info, [A(Severity.Info, "Genuine HP supply")]));
    }

    [Fact]
    public void A_warning_names_its_reason_after_the_state()
    {
        Assert.Equal("Ready · Yellow ink is low", PrinterStatus.ListLine("Ready", Severity.Warning, [A(Severity.Warning, "Yellow ink is low.")]));
    }

    [Fact]
    public void The_worst_alert_is_named_and_the_others_counted()
    {
        var alerts = new[] { A(Severity.Warning, "Yellow ink is low."), A(Severity.Error, "Paper jam in tray 2."), A(Severity.Warning, "Tray 1 is low on paper.") };
        Assert.Equal("Error · Paper jam in tray 2 · +2", PrinterStatus.ListLine("Error", Severity.Error, alerts));
    }

    [Fact]
    public void An_alert_that_repeats_or_extends_the_state_replaces_it()
    {
        Assert.Equal("Paper jam", PrinterStatus.ListLine("Paper jam", Severity.Error, [A(Severity.Error, "Paper jam.")]));
        Assert.Equal("Paper jam in tray 2", PrinterStatus.ListLine("Paper jam", Severity.Error, [A(Severity.Error, "Paper jam in tray 2")]));
    }

    [Fact]
    public void A_warning_without_alerts_keeps_the_state()
    {
        Assert.Equal("Toner low", PrinterStatus.ListLine("Toner low", Severity.Warning, []));
    }
}
