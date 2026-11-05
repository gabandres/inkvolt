using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Organize's page grid: how big a card's page picture is and how many cards a row holds.</summary>
public sealed class OrganizeGridTests
{
    [Fact]
    public void ThePicturesFollowWindowsTextSizeAsTheirNumbersAndButtonsDo()
    {
        // The slider's size is as at 100 %: at Text size 150 % the picture is half as big again, so the card's scaled
        // number and buttons keep their place on it (UX-REVIEW round 3).
        Assert.Equal(170, OrganizeGrid.Box(170, 1));
        Assert.Equal(255, OrganizeGrid.Box(170, 1.5));
        Assert.Equal(180, OrganizeGrid.Box(90, 2));
        Assert.Equal(OrganizeGrid.Box(360, 1), OrganizeGrid.Box(400, 1)); // the slider's range, whatever the settings file says
        Assert.Equal(OrganizeGrid.Box(170, 1), OrganizeGrid.Box(170, double.NaN));
    }

    [Fact]
    public void ARowHoldsTheCardsThatFitAndAlwaysOne()
    {
        // A card is its picture and 28 DIPs around it; the grid keeps 48 for its margins and scroll bar.
        Assert.Equal(5, OrganizeGrid.Columns(48 + 5 * 198, 170));
        Assert.Equal(4, OrganizeGrid.Columns(48 + 5 * 198 - 1, 170));
        Assert.Equal(3, OrganizeGrid.Columns(48 + 5 * 198, OrganizeGrid.Box(170, 1.5)));
        Assert.Equal(1, OrganizeGrid.Columns(0, 170));
        Assert.Equal(1, OrganizeGrid.Columns(double.NaN, 170));
    }
}
