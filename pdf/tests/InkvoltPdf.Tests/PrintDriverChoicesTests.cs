using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Print when Windows can't use the printer's driver: the ways on the prompt offers (PrintDriverCheck shows them).</summary>
public class PrintDriverChoicesTests
{
    [Fact]
    public void Before_the_dialog_a_known_printer_offers_Inkvolt_Print_first_then_another_printer()
    {
        var offered = PrintDriverChoices.Offered(canHandOver: true, printerChosen: false);
        Assert.Equal([PrintDriverChoice.HandOver, PrintDriverChoice.ChooseAnother, PrintDriverChoice.Stop], offered);
        Assert.False(PrintDriverChoices.StopOnlyCloses(offered));
    }

    [Fact]
    public void A_printer_Inkvolt_Print_cant_reach_offers_another_printer_or_stopping()
    {
        Assert.Equal([PrintDriverChoice.ChooseAnother, PrintDriverChoice.Stop], PrintDriverChoices.Offered(canHandOver: false, printerChosen: false));
    }

    [Fact]
    public void A_printer_already_chosen_isnt_offered_again()
    {
        Assert.Equal([PrintDriverChoice.HandOver, PrintDriverChoice.Stop], PrintDriverChoices.Offered(canHandOver: true, printerChosen: true));
    }

    [Fact]
    public void With_no_way_on_the_prompt_only_tells_and_closes()
    {
        var offered = PrintDriverChoices.Offered(canHandOver: false, printerChosen: true);
        Assert.Equal([PrintDriverChoice.Stop], offered);
        Assert.True(PrintDriverChoices.StopOnlyCloses(offered));
    }
}
