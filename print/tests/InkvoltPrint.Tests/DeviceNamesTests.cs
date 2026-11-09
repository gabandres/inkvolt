using InkvoltPrint.Core;

namespace InkvoltPrint.Tests;

/// <summary>The one rule both apps use for names Windows maps to a device (<see cref="DeviceNames"/>).</summary>
public class DeviceNamesTests
{
    public static TheoryData<string> Devices()
    {
        var data = new TheoryData<string> { "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" };
        for (var d = 0; d <= 9; d++)
        {
            data.Add("COM" + d);
            data.Add("LPT" + d);
        }
        foreach (var s in "¹²³")
        {
            data.Add("COM" + s);
            data.Add("LPT" + s);
        }
        return data;
    }

    [Theory]
    [MemberData(nameof(Devices))]
    public void EveryDeviceNameIsReservedInAnyCaseAndWithAnyExtension(string name)
    {
        Assert.True(DeviceNames.IsReserved(name));
        Assert.True(DeviceNames.IsReserved(name.ToLowerInvariant()));
        Assert.True(DeviceNames.IsReserved(name + ".txt"));
        Assert.True(DeviceNames.IsReserved(name + ".backup.pdf"));
        Assert.True(DeviceNames.IsReserved(name + " "));
        Assert.True(DeviceNames.IsReserved(name + "."));
        Assert.True(DeviceNames.IsReserved(name + " .pdf"));
    }

    [Theory]
    [InlineData("nul.txt")]
    [InlineData("COM1.backup.pdf")]
    [InlineData("Con")]
    [InlineData("cOnOuT$.log")]
    [InlineData("CON ")]
    [InlineData("nul.")]
    [InlineData("nul. . ")]
    [InlineData("PRN  .txt")]
    [InlineData("lpt³.txt")]
    [InlineData("COM1:")]
    [InlineData("aux:stream")]
    public void WhatWindowsTrimsStillNamesTheDevice(string name) => Assert.True(DeviceNames.IsReserved(name));

    [Theory]
    [InlineData("CONSOLE")]
    [InlineData("COM10")]
    [InlineData("LPT10")]
    [InlineData("NULL.pdf")]
    [InlineData("aux-notes.txt")]
    [InlineData("CON1")]
    [InlineData("COM")]
    [InlineData("LPT")]
    [InlineData("COM⁴")] // only ¹ ² ³ (Latin-1) are mapped
    [InlineData("COM₁")]
    [InlineData("COMA")]
    [InlineData(" CON")] // Windows keeps a leading space
    [InlineData("_CON")]
    [InlineData("CON_")]
    [InlineData("nul_.backup")]
    [InlineData("CONIN")]
    [InlineData("CONOUT")]
    [InlineData("CONIN$$")]
    [InlineData(".nul")]
    [InlineData("report.con")]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("...")]
    public void NearMissesStayAllowed(string name) => Assert.False(DeviceNames.IsReserved(name));

    [Fact]
    public void NullIsNotADevice() => Assert.False(DeviceNames.IsReserved(null));
}
