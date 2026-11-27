namespace InkvoltPdf.Core;

/// <summary>A way on when Windows can't use the printer's driver (the app's PrintDriverCheck asks).</summary>
public enum PrintDriverChoice
{
    /// <summary>Open the document in Inkvolt Print, which sends it straight to the printer.</summary>
    HandOver,

    /// <summary>Go on to the print dialog and pick another printer.</summary>
    ChooseAnother,

    /// <summary>Stop: Cancel, or Close when the prompt only tells.</summary>
    Stop,
}

/// <summary>Which ways on Print offers when Windows can't use a printer's driver, in the prompt's order (the last one stops).</summary>
public static class PrintDriverChoices
{
    /// <param name="canHandOver">
    /// Inkvolt Print is installed and knows the printer (it can print to it straight), and the document is a PDF it can open
    /// (no password).
    /// </param>
    /// <param name="printerChosen">The printer was picked in the dialog already (else it's the default printer, before the dialog).</param>
    public static IReadOnlyList<PrintDriverChoice> Offered(bool canHandOver, bool printerChosen)
    {
        var offered = new List<PrintDriverChoice>(3);
        if (canHandOver) offered.Add(PrintDriverChoice.HandOver);
        if (!printerChosen) offered.Add(PrintDriverChoice.ChooseAnother);
        offered.Add(PrintDriverChoice.Stop);
        return offered;
    }

    /// <summary>Whether the stop button only closes the prompt (nothing else is offered: it tells, it doesn't ask).</summary>
    public static bool StopOnlyCloses(IReadOnlyList<PrintDriverChoice> offered) => offered.Count == 1;
}
