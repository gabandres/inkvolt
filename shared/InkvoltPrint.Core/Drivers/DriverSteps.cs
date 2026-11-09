using System.Globalization;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>The button a step of "What to do" has: the maker's page, as the page's main (accent) button or a plain one.</summary>
public enum StepButton { None, Main, Plain }

/// <summary>One numbered step of a device's "What to do".</summary>
public sealed record DriverStep(int Number, string Text, StepButton Button)
{
    public string NumberText => Number.ToString(CultureInfo.CurrentCulture);
    public bool ShowMainButton => Button == StepButton.Main;
    public bool ShowPlainButton => Button == StepButton.Plain;
}

/// <summary>
/// "What to do" on the page of a device that needs its driver, numbered in order: the maker's driver (its page's button the page's
/// main one only where Get the driver doesn't apply: there, Get the driver and then Download it from the maker are), plugging it in
/// (only while it isn't), and running the installer as this copy has it (a Store copy watches for the device after its link).
/// </summary>
public static class DriverSteps
{
    /// <param name="present">The device is plugged in now (it was in the last read of the PC's devices).</param>
    /// <param name="getDriver">This copy's Get the driver for the device (<see cref="IDriverGetter.Mode"/>); null where it doesn't apply.</param>
    public static IReadOnlyList<DriverStep> For(NeedsDriverPrinter p, bool present, DriverMode? getDriver)
    {
        var steps = new List<(string Text, StepButton Button)> { (NeedsDriverText.StepGetDriver(p), getDriver is null ? StepButton.Main : StepButton.Plain) };
        if (!present) steps.Add((NeedsDriverText.StepPlugIn(p), StepButton.None));
        steps.Add((Install(p, getDriver), StepButton.None));
        return steps.Select((s, i) => new DriverStep(i + 1, s.Text, s.Button)).ToList();
    }

    private static string Install(NeedsDriverPrinter p, DriverMode? getDriver) => getDriver == DriverMode.OpenLink
        ? string.Format(CoreLanguage.Culture, p.IsScanner ? CoreStrings.NeedsDriver_StepInstallLinkScanner : CoreStrings.NeedsDriver_StepInstallLinkPrinter,
            p.Maker ?? "", DriverText.LookAgainButton)
        : NeedsDriverText.StepInstall(p);
}
