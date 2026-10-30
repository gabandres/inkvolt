using System.Buffers.Binary;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Twain;

/// <summary>TWAIN 2 constants Inkvolt uses (twain.h, TWAIN 2.4).</summary>
public static class Tw
{
    public const uint DgControl = 0x1, DgImage = 0x2, DfApp2 = 0x20000000, DfDsm2 = 0x10000000;

    public const ushort DatCapability = 0x1, DatEvent = 0x2, DatIdentity = 0x3, DatParent = 0x4, DatPendingXfers = 0x5,
        DatStatus = 0x8, DatUserInterface = 0x9, DatImageLayout = 0x102, DatImageNativeXfer = 0x104;

    public const ushort MsgGet = 0x1, MsgGetCurrent = 0x2, MsgGetFirst = 0x4, MsgGetNext = 0x5, MsgSet = 0x6, MsgReset = 0x7,
        MsgXferReady = 0x101, MsgCloseDsReq = 0x102, MsgCloseDsOk = 0x103, MsgOpenDsm = 0x301, MsgCloseDsm = 0x302,
        MsgOpenDs = 0x401, MsgCloseDs = 0x402, MsgDisableDs = 0x501, MsgEnableDs = 0x502, MsgProcessEvent = 0x601, MsgEndXfer = 0x701;

    public const ushort RcSuccess = 0, RcFailure = 1, RcCheckStatus = 2, RcCancel = 3, RcDsEvent = 4, RcNotDsEvent = 5,
        RcXferDone = 6, RcEndOfList = 7;

    public const ushort CapXferCount = 0x0001, IcapPixelType = 0x0101, IcapUnits = 0x0102, CapFeederEnabled = 0x1002,
        CapFeederLoaded = 0x1003, CapAutoFeed = 0x1007, CapDuplex = 0x1012, CapDuplexEnabled = 0x1013,
        IcapPhysicalWidth = 0x1111, IcapPhysicalHeight = 0x1112, IcapXResolution = 0x1118, IcapYResolution = 0x1119,
        IcapBitDepth = 0x112b;

    public const ushort OnArray = 3, OnEnumeration = 4, OnOneValue = 5, OnRange = 6;

    public const ushort TyInt16 = 1, TyUInt16 = 4, TyUInt32 = 5, TyBool = 6, TyFix32 = 7;

    public const ushort PtBw = 0, PtGray = 1, PtRgb = 2, UnInches = 0;

    // Condition codes (DAT_STATUS)
    public const ushort CcLowMemory = 2, CcNoDs = 3, CcMaxConnections = 4, CcOperationError = 5, CcBadCap = 6, CcBadValue = 10,
        CcSeqError = 11, CcCapUnsupported = 13, CcDenied = 16, CcPaperJam = 20, CcPaperDoubleFeed = 21, CcCheckDeviceOnline = 23,
        CcInterlock = 24, CcDamagedCorner = 25, CcNoMedia = 29;

    /// <summary>TW_FIX32 (whole part, then 1/65536ths) as a number.</summary>
    public static double FromFix32(uint raw) => (short)(raw & 0xFFFF) + (raw >> 16) / 65536.0;

    /// <summary>A number as TW_FIX32's 32 bits: Whole in the low half, Frac in the high half (as the struct lies in memory).</summary>
    public static uint ToFix32(double value)
    {
        var whole = (int)Math.Floor(value);
        var frac = (uint)Math.Round((value - whole) * 65536);
        if (frac == 65536) { whole++; frac = 0; }
        return (ushort)(short)whole | frac << 16;
    }
}

/// <summary>What a TWAIN source said about itself when opened (capabilities read with MSG_GET; null or empty: not supported).</summary>
/// <param name="Feeder">CAP_FEEDERENABLED can be set true.</param>
/// <param name="FeederOnly">CAP_FEEDERENABLED can't be set false (a sheet-fed scanner).</param>
/// <param name="Duplex">CAP_DUPLEX is one or two pass.</param>
/// <param name="FeederLoaded">CAP_FEEDERLOADED is supported (the source can tell whether paper is in the feeder).</param>
/// <param name="PixelTypes">ICAP_PIXELTYPE values (TWPT_BW, TWPT_GRAY, TWPT_RGB…).</param>
/// <param name="Resolutions">ICAP_XRESOLUTION as an enumeration or range, in dpi.</param>
/// <param name="Width">ICAP_PHYSICALWIDTH, inches.</param>
public sealed record TwainCaps(bool Feeder, bool FeederOnly, bool Duplex, bool FeederLoaded, IReadOnlyList<int> PixelTypes,
    WiaValues Resolutions, double? Width, double? Height)
{
    /// <summary>
    /// The source in the terms <see cref="WiaScanner"/> works in, so a TWAIN source goes through the same plan, feeder loop and error
    /// words as a WIA one: document handling from the feeder and duplex capabilities, the physical size as both the glass's and the
    /// feeder's, pixel types as WIA data types, pages always handed over as JPEG (from a native DIB transfer).
    /// </summary>
    public WiaScannerInfo ToInfo()
    {
        int? handling = Feeder
            ? WiaIds.CapFeed | (FeederOnly ? 0 : WiaIds.CapFlat) | (Duplex ? WiaIds.CapDuplex : 0) | (FeederLoaded ? WiaIds.CapDetectFeedAvailable : 0)
            : null;
        int? Thousandths(double? inches) => inches is > 0 ? (int)Math.Round(inches.Value * 1000) : null;
        var types = PixelTypes.Select(t => t switch { Tw.PtBw => WiaIds.DataThreshold, Tw.PtGray => WiaIds.DataGrayscale, Tw.PtRgb => WiaIds.DataColor, _ => -1 })
            .Where(t => t >= 0).Distinct().ToList();
        return new WiaScannerInfo(handling, Thousandths(Width), Thousandths(Height), Thousandths(Width), Thousandths(Height),
            Resolutions, types, [WiaIds.FormatBmp]);
    }
}

/// <summary>What a scan sets on a TWAIN source, from the same <see cref="WiaScanSettings"/> a WIA scan uses.</summary>
/// <param name="Feeder">CAP_FEEDERENABLED (and CAP_AUTOFEED).</param>
/// <param name="Right">Image layout frame, inches from the top left.</param>
/// <param name="Count">CAP_XFERCOUNT: -1 (all the feeder holds) or 1 (the glass).</param>
public sealed record TwainSettings(bool Feeder, bool Duplex, ushort PixelType, ushort BitDepth, int Resolution, double Right, double Bottom, short Count)
{
    public static TwainSettings From(WiaScanSettings s) => new(
        s.Feeder, s.Duplex,
        s.DataType switch { WiaIds.DataThreshold => Tw.PtBw, WiaIds.DataGrayscale => Tw.PtGray, _ => Tw.PtRgb },
        (ushort)s.Depth, s.Resolution,
        Math.Round(s.Width / (double)s.Resolution, 3), Math.Round(s.Height / (double)s.Resolution, 3),
        s.Feeder ? (short)-1 : (short)1);
}

/// <summary>TWAIN failures as the WIA errors <see cref="WiaErrors.Message"/> words, so both read the same to the user.</summary>
public static class TwainErrors
{
    public static int ToWia(ushort conditionCode) => conditionCode switch
    {
        Tw.CcPaperJam => WiaErrors.PaperJam,
        Tw.CcPaperDoubleFeed or Tw.CcDamagedCorner => WiaErrors.PaperProblem,
        Tw.CcNoMedia => WiaErrors.PaperEmpty,
        Tw.CcCheckDeviceOnline or Tw.CcNoDs => WiaErrors.Offline,
        Tw.CcInterlock => WiaErrors.CoverOpen,
        Tw.CcMaxConnections or Tw.CcDenied => WiaErrors.Busy,
        Tw.CcLowMemory => WiaErrors.OutOfMemory,
        Tw.CcBadCap or Tw.CcBadValue or Tw.CcCapUnsupported or Tw.CcSeqError => WiaErrors.InvalidCommand,
        _ => WiaErrors.GeneralError,
    };
}

/// <summary>A TWAIN native transfer's image (a packed DIB: BITMAPINFOHEADER, color table, pixels) as a .bmp file.</summary>
public static class Dib
{
    private const int FileHeaderSize = 14;

    /// <summary>Bytes the DIB takes from its header on, from the header alone (its first 40 bytes); 0 when it isn't one.</summary>
    public static int Length(ReadOnlySpan<byte> header)
    {
        if (header.Length < 40) return 0;
        var size = BinaryPrimitives.ReadInt32LittleEndian(header);
        var width = BinaryPrimitives.ReadInt32LittleEndian(header[4..]);
        var height = Math.Abs(BinaryPrimitives.ReadInt32LittleEndian(header[8..]));
        int bits = BinaryPrimitives.ReadUInt16LittleEndian(header[14..]);
        var compression = BinaryPrimitives.ReadInt32LittleEndian(header[16..]);
        var imageSize = BinaryPrimitives.ReadInt32LittleEndian(header[20..]);
        if (size < 40 || width <= 0 || height == 0 || bits is not (1 or 4 or 8 or 16 or 24 or 32)) return 0;
        var stride = (long)((width * bits + 31) / 32) * 4;
        long pixels = compression == 0 ? stride * height : imageSize; // BI_RGB: the driver may leave biSizeImage 0
        if (compression == 3 && size == 40) size += 12; // BI_BITFIELDS: three masks after the header
        var total = size + ColorTableSize(header) + pixels;
        return pixels <= 0 || total > int.MaxValue ? 0 : (int)total;
    }

    private static int ColorTableSize(ReadOnlySpan<byte> header)
    {
        int bits = BinaryPrimitives.ReadUInt16LittleEndian(header[14..]);
        var used = BinaryPrimitives.ReadInt32LittleEndian(header[32..]);
        var entries = used > 0 ? used : bits <= 8 ? 1 << bits : 0;
        return entries * 4;
    }

    /// <summary>The DIB with a BITMAPFILEHEADER in front: a .bmp any decoder reads. <see cref="FormatException"/> when it isn't a DIB.</summary>
    public static byte[] ToBmp(ReadOnlySpan<byte> dib)
    {
        var length = Length(dib);
        if (length == 0 || length > dib.Length) throw new FormatException("The scanner's driver sent an image that can't be read.");
        var headerSize = BinaryPrimitives.ReadInt32LittleEndian(dib);
        if (BinaryPrimitives.ReadInt32LittleEndian(dib[16..]) == 3 && headerSize == 40) headerSize += 12;
        var bmp = new byte[FileHeaderSize + length];
        bmp[0] = (byte)'B';
        bmp[1] = (byte)'M';
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(2), bmp.Length);
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(10), FileHeaderSize + headerSize + ColorTableSize(dib));
        dib[..length].CopyTo(bmp.AsSpan(FileHeaderSize));
        return bmp;
    }
}
