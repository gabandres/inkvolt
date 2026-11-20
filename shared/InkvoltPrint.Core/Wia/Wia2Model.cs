namespace InkvoltPrint.Core.Wia;

/// <summary>
/// What WIA 2.0's own interface adds to the WIA 1.0 ids in <see cref="WiaIds"/> (WiaDef.h, wia_lh.h): item categories, the
/// properties a scan item has there, transfer messages, the feeder item's handling select values.
/// </summary>
public static class Wia2Ids
{
    /// <summary><c>WIA_CATEGORY_*</c>: what a child item of the device's root item scans from.</summary>
    public static readonly Guid Flatbed = new("FB607B1F-43F3-488B-855B-FB703EC342A6"), Feeder = new("FE131934-F84C-42AD-8DA4-6129CDDD7288"),
        FeederFront = new("4823175C-3B28-487B-A7E6-EEBC17614FD1"), FeederBack = new("61CA74D4-39DB-42AA-89B1-8C19C9CD4C23"),
        Film = new("FCF65BE7-3CE3-4473-AF85-F5D37D21B68A"), Root = new("F193526F-59B8-4A26-9888-E16E4F97CE10"),
        Auto = new("DEFE5FD8-6C97-4DDE-B11E-CB509B270E11");

    // Item properties (WIA_IPA_*, WIA_IPS_*) a WIA 2.0 scan item has beside the WIA 1.0 ones.
    public const int Format = 4106, Tymed = 4108, ItemCategory = 4125, MaxHorizontalSize = 6165, MaxVerticalSize = 6166;

    /// <summary><c>WIA_DIP_WIA_VERSION</c>: "2.0" for a driver written for WIA 2.0.</summary>
    public const int WiaVersion = 14;

    /// <summary><c>TYMED_FILE</c>: the one transfer medium WIA 2.0 items use (a stream per page).</summary>
    public const int TymedFile = 2;

    // WIA_TRANSFER_MSG_*: what IWiaTransferCallback::TransferCallback is told.
    public const int MsgStatus = 1, MsgEndOfStream = 2, MsgEndOfTransfer = 3, MsgDeviceStatus = 5, MsgNewPage = 6;

    /// <summary>The feeder item's document handling select: <c>FRONT_ONLY</c> (one side; <see cref="WiaIds.SelectDuplex"/> and
    /// <see cref="WiaIds.SelectFrontFirst"/> as in WIA 1.0).</summary>
    public const int SelectFrontOnly = 0x020;

    /// <summary><c>WIA_STATUS_END_OF_MEDIA</c>: success, the feeder ran out partway (the pages before it came).</summary>
    public const int EndOfMedia = 0x00210001;
}

/// <summary>Where a WIA 2.0 scan item scans from (its <see cref="Wia2Ids"/> category).</summary>
public enum Wia2Source { Other, Flatbed, Feeder }

/// <summary>
/// One child item of a WIA 2.0 device's root, read once when connecting: the glass or the feeder as the driver defines it, with
/// its own sizes, resolutions, data types and formats.
/// </summary>
/// <param name="Handling">The feeder item's document handling capabilities (<see cref="WiaIds.CapDuplex"/>, <see cref="WiaIds.CapDetectFeedAvailable"/>…); null when it has none.</param>
/// <param name="MaxWidth">The largest area it scans, thousandths of an inch; null when not said.</param>
public sealed record Wia2Item(Wia2Source Source, int? Handling, int? MaxWidth, int? MaxHeight, WiaValues Resolutions,
    IReadOnlyList<int> DataTypes, IReadOnlyList<string> Formats)
{
    public static Wia2Source SourceOf(Guid category) =>
        category == Wia2Ids.Flatbed ? Wia2Source.Flatbed
        : category == Wia2Ids.Feeder || category == Wia2Ids.FeederFront ? Wia2Source.Feeder
        : Wia2Source.Other;
}

/// <summary>
/// The pure part of WIA 2.0 scanning (roadmap 2.3's backlog: the feeder and glass items as the driver defines them): a device's
/// items as the <see cref="WiaScannerInfo"/> <see cref="WiaScanner"/> works in, and which item a job's settings scan with.
/// </summary>
public static class Wia2Items
{
    /// <summary>At most this many child items are read (a driver can't make connecting take forever).</summary>
    public const int MaxItems = 16;

    /// <summary>
    /// The device as <see cref="WiaScanner"/> sees it: glass and feeder from the items there are (the first of each), the glass's
    /// size, resolutions, data types and formats, the feeder's own beside them, duplex and paper detection from the feeder item's
    /// handling capabilities, and <see cref="WiaScannerInfo.CancelsPage"/>. Null when it has neither a glass nor a feeder item
    /// (then WIA 1.0's view of it is used).
    /// </summary>
    public static WiaScannerInfo? Info(IReadOnlyList<Wia2Item> items, IReadOnlyList<string>? buttons = null)
    {
        var glass = items.Take(MaxItems).FirstOrDefault(i => i.Source == Wia2Source.Flatbed);
        var feeder = items.Take(MaxItems).FirstOrDefault(i => i.Source == Wia2Source.Feeder);
        if (glass is null && feeder is null) return null;
        var main = glass ?? feeder!;
        int? handling = feeder is null ? null
            : WiaIds.CapFeed | (glass is null ? 0 : WiaIds.CapFlat) | ((feeder.Handling ?? 0) & (WiaIds.CapDuplex | WiaIds.CapDetectFeedAvailable));
        return new WiaScannerInfo(handling, glass?.MaxWidth, glass?.MaxHeight, feeder?.MaxWidth, feeder?.MaxHeight,
            main.Resolutions, main.DataTypes.Count > 0 ? main.DataTypes : feeder?.DataTypes ?? [], main.Formats, buttons,
            glass is not null && feeder is not null ? feeder.Resolutions : null,
            glass is not null && feeder is not null ? feeder.Formats : null,
            CancelsPage: true);
    }

    /// <summary>The item a job scans with: the feeder item for a feeder job, else the glass item (the first of each); -1 when there is none.</summary>
    public static int For(WiaScanSettings settings, IReadOnlyList<Wia2Item> items)
    {
        var want = settings.Feeder ? Wia2Source.Feeder : Wia2Source.Flatbed;
        for (var i = 0; i < Math.Min(items.Count, MaxItems); i++)
            if (items[i].Source == want) return i;
        return -1;
    }

    /// <summary>The feeder item's document handling select for a job: both sides front first, or the front only.</summary>
    public static int FeederSelect(WiaScanSettings settings) =>
        settings.Duplex ? WiaIds.SelectDuplex | WiaIds.SelectFrontFirst : Wia2Ids.SelectFrontOnly;

    /// <summary>
    /// What <see cref="IWiaDevice.Apply"/> reads back, in WIA 1.0's terms (<see cref="WiaFeeder.FeederTaken"/>): the feeder when the
    /// job's item is the feeder item, the glass when there is none (a feeder job then scans nothing: said so).
    /// </summary>
    public static int SelectReadBack(WiaScanSettings settings, IReadOnlyList<Wia2Item> items) =>
        For(settings, items) < 0 ? WiaIds.SelectFlatbed : settings.Feeder ? WiaIds.SelectFeeder | (settings.Duplex ? WiaIds.SelectDuplex : 0) : WiaIds.SelectFlatbed;

    /// <summary>
    /// The format to ask a page in, from those the item lists: PDF from a PDF-only item; else JPEG (not for black and white, which
    /// drivers refuse as JPEG), BMP, PNG, TIFF, then JPEG after all; an item that lists nothing is asked for BMP, as every WIA 1.0
    /// driver takes. Null when it lists none of these (WIA 1.0's path is used then).
    /// </summary>
    public static string? FormatFor(WiaScanSettings settings, IReadOnlyList<string> formats)
    {
        if (settings.Pdf) return WiaIds.FormatPdf;
        if (formats.Count == 0) return WiaIds.FormatBmp;
        bool Lists(string format) => formats.Any(f => WiaIds.SameFormat(f, format));
        if (settings.Depth > 1 && Lists(WiaIds.FormatJpeg)) return WiaIds.FormatJpeg;
        return new[] { WiaIds.FormatBmp, WiaIds.FormatPng, WiaIds.FormatTiff, WiaIds.FormatJpeg }.FirstOrDefault(Lists);
    }

    /// <summary>Device statuses that pass (the transfer goes on after them): warming up, busy, waiting for the user, locked.</summary>
    private static bool Passing(int status) =>
        status is WiaErrors.WarmingUp or WiaErrors.Busy or WiaErrors.UserIntervention or WiaErrors.DeviceLocked;

    /// <summary>
    /// The failure a transfer's callback has seen so far, after one more message: a device status or end of transfer that fails and
    /// doesn't pass (a jam, an open cover) is kept; progress, a new page or a stream's end clears what came before (the device went
    /// on after it, as it does after warming up); anything else leaves it as it was.
    /// </summary>
    public static int? TransferError(int? error, int message, int status) => message switch
    {
        Wia2Ids.MsgStatus or Wia2Ids.MsgNewPage or Wia2Ids.MsgEndOfStream => status < 0 && !Passing(status) ? status : null,
        Wia2Ids.MsgDeviceStatus or Wia2Ids.MsgEndOfTransfer when status < 0 && !Passing(status) => status,
        _ => error,
    };

    /// <summary>
    /// The failure to raise for a transfer that ended with <paramref name="hr"/> (Download's result) and <paramref name="callbackError"/>
    /// (<see cref="TransferError"/>'s last): none for success, the end of the media, or an empty feeder (the job's end); else the
    /// failure, raised once the pages that did arrive are handed over (a jam on the third sheet keeps the first two).
    /// </summary>
    public static int? FailureAfter(int hr, int? callbackError)
    {
        var failure = hr < 0 ? hr : callbackError;
        return failure is null or WiaErrors.PaperEmpty || failure >= 0 ? null : failure;
    }
}
