using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Twain;

/// <summary>
/// Made-up TWAIN sources for tests and demo mode (the <see cref="FakeWiaSystem"/>'s twin): what the source says it can do comes
/// through <see cref="TwainCaps.ToInfo"/> as a real source's does, it is listed with the TWAIN port, and once its feeder has no more
/// pages the next transfer gives no image (a TWAIN source's "no pending transfers"), not WIA's "feeder empty" error.
/// </summary>
public static class FakeTwain
{
    public static FakeWiaScanner Source(string name, TwainCaps caps, Func<WiaScanSettings, int, byte[]> draw, string? maker = null) =>
        new(new WiaDeviceInfo(name, name, maker, null, WiaDeviceInfo.TwainPort), caps.ToInfo(), draw) { EndsWithoutImage = true };
}
