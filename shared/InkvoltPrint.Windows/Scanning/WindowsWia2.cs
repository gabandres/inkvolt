using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using InkvoltPrint.Core.Wia;
using ComStream = System.Runtime.InteropServices.ComTypes.IStream;
using ComStatStg = System.Runtime.InteropServices.ComTypes.STATSTG;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace InkvoltPrint.Windows.Scanning;

/// <summary>
/// A scanner reached through WIA 2.0's own interface (<c>IWiaDevMgr2</c>, <c>IWiaItem2</c>, <c>IWiaTransfer</c> with a callback,
/// wia_lh.h), which the scripting library WIA 1.0 drivers are scanned through can't reach: the glass and feeder items as the driver
/// defines them (each with its own sizes, resolutions and formats: <see cref="Wia2Items"/>), each page's progress, and a page under
/// way stopped in the driver when the job is cancelled. Used for drivers written for WIA 2.0 (the device says "2.0") that have a
/// glass or a feeder item; any other device, or one this fails to open, goes through <see cref="WindowsWia"/>'s WIA 1.0 path as
/// before, and so does one whose item takes no format this app reads (<see cref="Wia2UnusableException"/>). Its items are
/// touched on its scanner's STA thread only, as <see cref="WindowsWia"/>'s devices are; the transfer callback, an agile COM
/// object, may be called on another thread (<see cref="Wia2TransferCallback"/>). 64-bit processes only (the
/// property structures below are laid out for 64-bit). Failures are <see cref="WiaException"/>s with the driver's HRESULT.
/// </summary>
internal sealed class Wia2Device : IWiaDevice, IDisposable
{
    private static readonly Guid DevMgr2 = new("B6C292BC-7C88-41ee-8B54-8EC92617E599");

    /// <summary>The largest page accepted from a driver's stream: a 1200 dpi Legal page in color as BMP is about 290 MB.</summary>
    internal const long MaxPageBytes = 1L << 30;

    private readonly IWiaItem2 _root;
    private readonly List<(IWiaItem2 Item, Wia2Item Read)> _items;
    private readonly Queue<byte[]> _pending = new();
    private IWiaItem2? _job;

    /// <summary>A failure that ended a transfer after some pages: raised once those pages are handed over.</summary>
    private int? _failure;

    private Wia2Device(IWiaItem2 root, List<(IWiaItem2, Wia2Item)> items, WiaScannerInfo info)
    {
        _root = root;
        _items = items;
        Info = info;
    }

    public WiaScannerInfo Info { get; }

    /// <summary>
    /// The device through WIA 2.0 when its driver is a WIA 2.0 one with a glass or feeder item; null otherwise (WIA 1.0's path is
    /// used). Failures reaching a device that is a WIA 2.0 one are thrown (off, unplugged, busy), as WIA 1.0's connect throws them.
    /// </summary>
    public static Wia2Device? TryConnect(string deviceId)
    {
        if (!Environment.Is64BitProcess || Type.GetTypeFromCLSID(DevMgr2) is not { } type) return null;
        object? manager = null;
        IWiaItem2? root = null;
        var items = new List<(IWiaItem2, Wia2Item)>();
        try
        {
            try
            {
                manager = Activator.CreateInstance(type);
            }
            catch (COMException)
            {
                return null; // no WIA 2.0 manager on this Windows
            }
            if (manager is not IWiaDevMgr2 mgr) return null;
            Check(mgr.CreateDevice(0, deviceId, out root));
            var props = (IWiaPropertyStorage)root;
            if (Props.ReadString(props, Wia2Ids.WiaVersion) is not { } version || !version.StartsWith("2.", StringComparison.Ordinal)) return null;
            var children = Children(root);
            try
            {
                foreach (var child in children)
                    if (Read(child) is { } read) items.Add((child, read));
            }
            finally
            {
                // Every child not kept goes now: those of another kind, and all after one whose reading failed.
                foreach (var child in children)
                    if (!items.Any(i => ReferenceEquals(i.Item1, child))) Release(child);
            }
            if (Wia2Items.Info([.. items.Select(i => i.Item2)], WiaIds.ScanButtonsIn(Events(root))) is not { } info) return null;
            var device = new Wia2Device(root, items, info);
            root = null; // the device owns them now
            items = [];
            return device;
        }
        catch (Exception ex) when (ex is not WiaException { Code: var code } || !WiaErrors.IsWia(code) && code is not (WiaErrors.AccessDenied or WiaErrors.RpcServerUnavailable))
        {
            // Not the device's state (off, busy, a jam: WIA's own errors, thrown as WIA 1.0's connect throws them) but this path
            // failing (an interface the driver lacks, a property it reads differently): WIA 1.0's path, which every driver has.
            return null;
        }
        finally
        {
            foreach (var (item, _) in items) Release(item);
            Release(root, manager);
        }
    }

    /// <summary>The root's child items, at most <see cref="Wia2Items.MaxItems"/>.</summary>
    private static List<IWiaItem2> Children(IWiaItem2 root)
    {
        var list = new List<IWiaItem2>();
        if (root.EnumChildItems(IntPtr.Zero, out var children) < 0 || children is null) return list;
        try
        {
            while (list.Count < Wia2Items.MaxItems && children.Next(1, out var child, out var fetched) == 0 && fetched == 1 && child is not null)
                list.Add(child);
        }
        finally
        {
            Release(children);
        }
        return list;
    }

    /// <summary>A child item as a glass or feeder item, or null for any other kind (film, an imprinter, a folder).</summary>
    private static Wia2Item? Read(IWiaItem2 item)
    {
        if (item.GetItemCategory(out var category) < 0) return null;
        var source = Wia2Item.SourceOf(category);
        if (source == Wia2Source.Other) return null;
        var props = (IWiaPropertyStorage)item;
        return new Wia2Item(source,
            source == Wia2Source.Feeder ? Props.ReadInt(props, WiaIds.DocumentHandlingCapabilities) : null,
            Props.ReadInt(props, Wia2Ids.MaxHorizontalSize), Props.ReadInt(props, Wia2Ids.MaxVerticalSize),
            Props.Values(props, WiaIds.XResolution) ?? WiaValues.Only(0),
            Props.Values(props, WiaIds.DataType)?.List ?? [],
            Formats(item));
    }

    /// <summary>The formats the item transfers in (<c>IWiaTransfer::EnumWIA_FORMAT_INFO</c>), as "{GUID}" strings.</summary>
    private static List<string> Formats(IWiaItem2 item)
    {
        var list = new List<string>();
        if (item is not IWiaTransfer transfer || transfer.EnumWIA_FORMAT_INFO(out var formats) < 0 || formats is null) return list;
        try
        {
            var one = new WiaFormatInfo[1];
            for (var i = 0; i < 32 && formats.Next(1, one, out var fetched) == 0 && fetched == 1; i++)
            {
                var text = one[0].Format.ToString("B").ToUpperInvariant();
                if (!list.Contains(text)) list.Add(text);
            }
        }
        finally
        {
            Release(formats);
        }
        return list;
    }

    /// <summary>The event ids the device lists (<c>EnumDeviceCapabilities(WIA_DEVICE_EVENTS)</c>): its scan buttons.</summary>
    private static List<string> Events(IWiaItem2 root)
    {
        var ids = new List<string>();
        if (root.EnumDeviceCapabilities(2, out var caps) < 0 || caps is null) return ids;
        try
        {
            var one = new WiaDevCap[1];
            for (var i = 0; i < 64 && caps.Next(1, one, out var fetched) == 0 && fetched == 1; i++)
            {
                ids.Add(one[0].Guid.ToString("B"));
                foreach (var bstr in new[] { one[0].Name, one[0].Description, one[0].Icon, one[0].Commandline })
                    if (bstr != IntPtr.Zero) Marshal.FreeBSTR(bstr);
            }
        }
        finally
        {
            Release(caps);
        }
        return ids;
    }

    /// <summary>Document handling status from the root item (WIA 2.0 keeps it there); pages already transferred count as paper still to come.</summary>
    public int? ReadHandlingStatus()
    {
        var status = Props.ReadInt((IWiaPropertyStorage)_root, WiaIds.DocumentHandlingStatus);
        return _pending.Count > 0 || _failure is not null ? (status ?? 0) | WiaIds.FeedReady : status; // a failure still to raise too
    }

    /// <summary>The job's settings on its item (the feeder item for a feeder job, else the glass item); reads back which was taken.</summary>
    public int? Apply(WiaScanSettings s)
    {
        _pending.Clear();
        _failure = null;
        var reads = _items.Select(i => i.Read).ToList();
        var index = Wia2Items.For(s, reads);
        _job = index < 0 ? null : _items[index].Item;
        if (_job is not { } item) return Wia2Items.SelectReadBack(s, reads);
        var props = (IWiaPropertyStorage)item;
        if (s.Feeder)
        {
            var select = Wia2Items.FeederSelect(s);
            if (!Props.WriteInt(props, WiaIds.DocumentHandlingSelect, select) && s.Duplex)
                Props.WriteInt(props, WiaIds.DocumentHandlingSelect, WiaIds.SelectDuplex); // a driver that doesn't know "front first"
            // One side: one page a transfer. Both sides: a sheet a transfer (its two pages), so the feeder is read before each sheet.
            Props.WriteInt(props, WiaIds.Pages, s.Duplex ? 2 : 1);
        }
        Props.WriteInt(props, Wia2Ids.Tymed, Wia2Ids.TymedFile);
        // A format this app reads, from the item's list, and taken by the driver; else WIA 1.0's path scans this device.
        if (Wia2Items.FormatFor(s, reads[index].Formats) is not { } format || !Props.WriteGuid(props, Wia2Ids.Format, new Guid(format)))
            throw new Wia2UnusableException("The driver's WIA 2.0 item takes no format this app reads.");
        Props.WriteInt(props, WiaIds.DataType, s.DataType);
        Props.WriteInt(props, WiaIds.Depth, s.Depth);
        Props.WriteInt(props, WiaIds.XResolution, s.Resolution);
        Props.WriteInt(props, WiaIds.YResolution, s.Resolution);
        Props.WriteInt(props, WiaIds.XPosition, s.X);
        Props.WriteInt(props, WiaIds.YPosition, s.Y);
        // The extents' limits follow the resolution just set: read them now.
        Props.WriteInt(props, WiaIds.XExtent, Math.Min(s.Width, Props.Values(props, WiaIds.XExtent)?.Max ?? s.Width));
        Props.WriteInt(props, WiaIds.YExtent, Math.Min(s.Height, Props.Values(props, WiaIds.YExtent)?.Max ?? s.Height));
        if (s.Duplex && (Props.ReadInt(props, WiaIds.DocumentHandlingSelect) ?? 0) is var taken && (taken & WiaIds.SelectDuplex) == 0)
            return WiaIds.SelectFeeder; // the driver kept one side
        return Wia2Items.SelectReadBack(s, reads);
    }

    public byte[]? TransferPage(WiaScanSettings settings) => TransferPage(settings, null, CancellationToken.None);

    /// <summary>
    /// The next page: one already transferred with the sheet before (both sides), else a download of the job's item through
    /// <c>IWiaTransfer::Download</c>, its pages into memory streams, the progress reported, a cancel answered with S_FALSE so the
    /// driver stops the page. Pages come as JPEG (BMP turned into JPEG here) or, from a PDF-only item, as the driver's PDF.
    /// </summary>
    public byte[]? TransferPage(WiaScanSettings settings, Action<int>? progress, CancellationToken cancel)
    {
        if (_pending.TryDequeue(out var waiting)) return waiting;
        if (_failure is { } later)
        {
            // The pages before the failure were handed over first; now the failure itself (a jam on a later sheet).
            _failure = null;
            throw new WiaException(later, "The driver's transfer failed after some pages.");
        }
        if (_job is not { } item || item is not IWiaTransfer transfer) throw new WiaException(WiaErrors.InvalidCommand, "No item to scan with.");
        var callback = new Wia2TransferCallback(progress, cancel);
        var hr = transfer.Download(0, callback);
        callback.Close();
        if (cancel.IsCancellationRequested) throw new OperationCanceledException(cancel);
        var failure = Wia2Items.FailureAfter(hr, callback.Error);
        var pages = callback.Pages.Select(p => ToPage(p, settings)).OfType<byte[]>().ToList();
        if (pages.Count == 0)
        {
            if (failure is { } now) throw new WiaException(now, "The driver's transfer failed.");
            if (hr < 0) throw new WiaException(hr, "The driver's transfer failed."); // an empty feeder: the job's end
            return null;
        }
        _failure = failure;
        foreach (var next in pages.Skip(1)) _pending.Enqueue(next);
        return pages[0];
    }

    /// <summary>
    /// A stream's bytes as the page WiaScanner takes: a JPEG or a PDF as they are, a BMP, PNG or TIFF turned into JPEG (WIC); null
    /// for an empty stream.
    /// </summary>
    private static byte[]? ToPage(byte[] data, WiaScanSettings settings)
    {
        if (data.Length == 0) return null;
        if (data is [0xFF, 0xD8, ..] || Core.Escl.ScannerPdf.IsPdf(data)) return data;
        if (data is [(byte)'B', (byte)'M', ..] or [0x89, (byte)'P', (byte)'N', (byte)'G', ..] or [(byte)'I', (byte)'I', 42, 0, ..] or [(byte)'M', (byte)'M', 0, 42, ..])
            return PictureToJpeg(data);
        throw new WiaException(WiaErrors.InvalidDriverResponse, settings.Pdf ? "The driver didn't send a PDF." : "The driver sent a picture this app doesn't read.");
    }

    /// <summary>
    /// A BMP, PNG or TIFF page (a TIFF's first frame) as a JPEG at quality 90 through WIC (Windows.Graphics.Imaging), grey kept grey;
    /// on the thread pool, so waiting here never blocks a call WIC makes back to this STA thread.
    /// </summary>
    internal const uint MaxPageSide = 65_000;
    internal const long MaxPagePixels = 400_000_000;

    internal static byte[] PictureToJpeg(byte[] picture)
    {
        try
        {
            return Task.Run(async () =>
            {
                using var input = new InMemoryRandomAccessStream();
                await input.WriteAsync(picture.AsBuffer());
                input.Seek(0);
                var decoder = await BitmapDecoder.CreateAsync(input);
                // The size is the driver's word: checked before WIC allocates the page (a few bytes can claim 60,000 a side).
                if (decoder.PixelWidth is 0 or > MaxPageSide || decoder.PixelHeight is 0 or > MaxPageSide
                    || (long)decoder.PixelWidth * decoder.PixelHeight > MaxPagePixels)
                    throw new WiaException(WiaErrors.InvalidDriverResponse, $"The driver sent a page of {decoder.PixelWidth} x {decoder.PixelHeight} pixels.");
                var format = decoder.BitmapPixelFormat == BitmapPixelFormat.Gray8 ? BitmapPixelFormat.Gray8 : BitmapPixelFormat.Bgra8;
                using var bitmap = await decoder.GetSoftwareBitmapAsync(format, BitmapAlphaMode.Ignore);
                using var output = new InMemoryRandomAccessStream();
                var options = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(0.9, global::Windows.Foundation.PropertyType.Single) };
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output, options);
                encoder.SetSoftwareBitmap(bitmap);
                await encoder.FlushAsync();
                var bytes = new byte[output.Size];
                output.Seek(0);
                await output.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
                return bytes;
            }).GetAwaiter().GetResult();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not WiaException)
        {
            throw new WiaException(WiaErrors.InvalidDriverResponse, "The page couldn't be read: " + ex.Message);
        }
    }

    public void Dispose()
    {
        _pending.Clear();
        foreach (var (item, _) in _items) Release(item);
        _items.Clear();
        Release(_root);
    }

    private static void Check(int hr)
    {
        if (hr < 0) throw new WiaException(hr, "The WIA 2.0 call failed.");
    }

    private static void Release(params object?[] objects) => WindowsWia.Release(objects);

    // ---- Properties (IWiaPropertyStorage, PROPSPEC and PROPVARIANT as laid out for 64-bit) ----------------------------------------

    private static class Props
    {
        private const ushort VtI4 = 3, VtBstr = 8, VtUi4 = 19, VtClsid = 72, VtVector = 0x1000;
        private const int PrspecPropid = 1, PropRange = 0x10, PropList = 0x20;

        /// <summary>WriteMultiple's first id for named properties (none are written): WIA_IPA_FIRST, as WIA's samples pass.</summary>
        private const int NamesFirst = 4098;

        private static PropSpec[] Spec(int id) => [new PropSpec { Kind = PrspecPropid, Id = id }];

        public static int? ReadInt(IWiaPropertyStorage props, int id)
        {
            var value = new PropVariant[1];
            try
            {
                if (props.ReadMultiple(1, Spec(id), value) != 0) return null; // S_FALSE: the item has no such property
                return value[0].Vt is VtI4 or VtUi4 ? value[0].Int : null;
            }
            finally
            {
                PropVariantClear(ref value[0]);
            }
        }

        public static string? ReadString(IWiaPropertyStorage props, int id)
        {
            var value = new PropVariant[1];
            try
            {
                if (props.ReadMultiple(1, Spec(id), value) != 0 || value[0].Vt != VtBstr || value[0].Ptr == IntPtr.Zero) return null;
                return Marshal.PtrToStringBSTR(value[0].Ptr);
            }
            finally
            {
                PropVariantClear(ref value[0]);
            }
        }

        /// <summary>A property's valid values (a range or a list of numbers) and its current value; null when it has neither.</summary>
        public static WiaValues? Values(IWiaPropertyStorage props, int id)
        {
            if (ReadInt(props, id) is not { } current) return null;
            var flags = new int[1];
            var valid = new PropVariant[1];
            try
            {
                if (props.GetPropertyAttributes(1, Spec(id), flags, valid) != 0) return WiaValues.Only(current);
                var v = valid[0];
                if ((v.Vt & ~VtVector) is not (VtI4 or VtUi4) || (v.Vt & VtVector) == 0 || v.Elems == IntPtr.Zero) return WiaValues.Only(current);
                var count = (int)Math.Min(v.Count, 512u);
                var elems = new int[count];
                Marshal.Copy(v.Elems, elems, 0, count);
                if ((flags[0] & PropRange) != 0 && count >= 4) return WiaValues.Range(current, elems[0], elems[2], elems[3]); // min, nominal, max, step
                if ((flags[0] & PropList) != 0 && count >= 2) return new WiaValues(current, [.. elems.Skip(2)]); // count, nominal, values
                return WiaValues.Only(current);
            }
            finally
            {
                PropVariantClear(ref valid[0]);
            }
        }

        /// <summary>Sets a number; false when the driver refused it (it scans with its own value then).</summary>
        public static bool WriteInt(IWiaPropertyStorage props, int id, int value) =>
            props.WriteMultiple(1, Spec(id), [new PropVariant { Vt = VtI4, Int = value }], NamesFirst) >= 0;

        public static bool WriteGuid(IWiaPropertyStorage props, int id, Guid value)
        {
            var memory = Marshal.AllocCoTaskMem(16);
            try
            {
                Marshal.StructureToPtr(value, memory, false);
                return props.WriteMultiple(1, Spec(id), [new PropVariant { Vt = VtClsid, Ptr = memory }], NamesFirst) >= 0;
            }
            finally
            {
                Marshal.FreeCoTaskMem(memory);
            }
        }

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant pvar);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropSpec
    {
        public int Kind;
        public nint Id;
    }

    /// <summary>PROPVARIANT on 64-bit: the type, then (at 8) a value, a pointer, or a vector's count and (at 16) its elements.</summary>
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort Vt;
        [FieldOffset(8)] public int Int;
        [FieldOffset(8)] public IntPtr Ptr;
        [FieldOffset(8)] public uint Count;
        [FieldOffset(16)] public IntPtr Elems;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WiaFormatInfo
    {
        public Guid Format;
        public int Tymed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WiaDevCap
    {
        public Guid Guid;
        public int Flags;
        public IntPtr Name, Description, Icon, Commandline;
    }

    // ---- The interfaces (wia_lh.h; methods in vtable order, up to the last one used) ------------------------------------------------

    [ComImport, Guid("79C07CF1-CBDD-41ee-8EC3-F00080CADA7A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWiaDevMgr2
    {
        [PreserveSig] int EnumDeviceInfo(int flags, out IntPtr enumInfo);
        [PreserveSig] int CreateDevice(int flags, [MarshalAs(UnmanagedType.BStr)] string deviceId, out IWiaItem2 root);
    }

    [ComImport, Guid("6CBA0075-1287-407d-9B77-CF0E030435CC"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWiaItem2
    {
        [PreserveSig] int CreateChildItem(int itemFlags, int creationFlags, IntPtr name, out IntPtr item);
        [PreserveSig] int DeleteItem(int flags);
        [PreserveSig] int EnumChildItems(IntPtr category, out IEnumWiaItem2? items);
        [PreserveSig] int FindItemByName(int flags, IntPtr fullItemName, out IntPtr item);
        [PreserveSig] int GetItemCategory(out Guid category);
        [PreserveSig] int GetItemType(out int type);
        [PreserveSig] int DeviceDlg(int flags, IntPtr parent, IntPtr folder, IntPtr fileName, IntPtr numFiles, IntPtr filePaths, IntPtr item);
        [PreserveSig] int DeviceCommand(int flags, IntPtr command, IntPtr item);
        [PreserveSig] int EnumDeviceCapabilities(int flags, out IEnumWiaDevCaps? caps);
    }

    [ComImport, Guid("59970AF4-CD0D-44d9-AB24-52295630E582"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumWiaItem2
    {
        [PreserveSig] int Next(int count, out IWiaItem2? item, out int fetched);
    }

    [ComImport, Guid("1fcc4287-aca6-11d2-a093-00c04f72dc3c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumWiaDevCaps
    {
        [PreserveSig] int Next(int count, [Out] WiaDevCap[] caps, out int fetched);
    }

    [ComImport, Guid("81BEFC5B-656D-44f1-B24C-D41D51B4DC81"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumWiaFormatInfo
    {
        [PreserveSig] int Next(int count, [Out] WiaFormatInfo[] formats, out int fetched);
    }

    [ComImport, Guid("98B5E8A0-29CC-491a-AAC0-E6DB4FDCCEB6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWiaPropertyStorage
    {
        [PreserveSig] int ReadMultiple(int count, [In] PropSpec[] specs, [Out] PropVariant[] values);
        [PreserveSig] int WriteMultiple(int count, [In] PropSpec[] specs, [In] PropVariant[] values, int firstName);
        [PreserveSig] int DeleteMultiple(int count, IntPtr specs);
        [PreserveSig] int ReadPropertyNames(int count, IntPtr ids, IntPtr names);
        [PreserveSig] int WritePropertyNames(int count, IntPtr ids, IntPtr names);
        [PreserveSig] int DeletePropertyNames(int count, IntPtr ids);
        [PreserveSig] int Commit(int flags);
        [PreserveSig] int Revert();
        [PreserveSig] int Enum(out IntPtr enumerator);
        [PreserveSig] int SetTimes(IntPtr created, IntPtr accessed, IntPtr modified);
        [PreserveSig] int SetClass(IntPtr clsid);
        [PreserveSig] int Stat(IntPtr stat);
        [PreserveSig] int GetPropertyAttributes(int count, [In] PropSpec[] specs, [Out] int[] flags, [Out] PropVariant[] values);
    }

    [ComImport, Guid("c39d6942-2f4e-4d04-92fe-4ef4d3a1de5a"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWiaTransfer
    {
        [PreserveSig] int Download(int flags, IWiaTransferCallback callback);
        [PreserveSig] int Upload(int flags, IntPtr source, IntPtr callback);
        [PreserveSig] int Cancel();
        [PreserveSig] int EnumWIA_FORMAT_INFO(out IEnumWiaFormatInfo? formats);
    }
}

[ComImport, Guid("27d4eaaf-28a6-4ca5-9aab-e678168b9527"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IWiaTransferCallback
{
    [PreserveSig] int Transfer(int flags, ref WiaTransferParams parameters);
    [PreserveSig] int GetNextStream(int flags, [MarshalAs(UnmanagedType.BStr)] string? itemName, [MarshalAs(UnmanagedType.BStr)] string? fullItemName, out ComStream? stream);
}

[StructLayout(LayoutKind.Sequential)]
public struct WiaTransferParams
{
    public int Message;
    public int PercentComplete;
    public ulong TransferredBytes;
    public int ErrorStatus;
}

/// <summary>
/// <c>IWiaTransferCallback</c>: a memory stream for each page the driver asks one for, its progress passed on, and S_FALSE once
/// the job is cancelled (the driver stops the page). Its COM wrapper is agile (a .NET object's is), so WIA may call it on any thread
/// while Download runs, not only the scanner's: its state is kept under a lock, and <c>progress</c> must marshal to a UI itself.
/// </summary>
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class Wia2TransferCallback(Action<int>? progress, CancellationToken cancel) : IWiaTransferCallback
{
    private readonly Lock _gate = new();
    private readonly List<byte[]> _pages = [];
    private MemoryStream? _current;
    private int? _error;

    /// <summary>The pages the driver wrote, in order (read once Download has returned and <see cref="Close"/> was called).</summary>
    public List<byte[]> Pages
    {
        get { lock (_gate) return [.. _pages]; }
    }

    /// <summary>A failure the driver reported through the callback that ended the transfer (<see cref="Wia2Items.TransferError"/>).</summary>
    public int? Error
    {
        get { lock (_gate) return _error; }
    }

    public int Transfer(int flags, ref WiaTransferParams p)
    {
        if (cancel.IsCancellationRequested) return 1; // S_FALSE: cancel the transfer
        lock (_gate)
        {
            _error = Wia2Items.TransferError(_error, p.Message, p.ErrorStatus);
            if (p.Message == Wia2Ids.MsgEndOfStream) Finish();
        }
        if (p.Message == Wia2Ids.MsgStatus) progress?.Invoke(p.PercentComplete);
        return 0;
    }

    public int GetNextStream(int flags, string? itemName, string? fullItemName, out System.Runtime.InteropServices.ComTypes.IStream? stream)
    {
        lock (_gate)
        {
            Finish();
            if (cancel.IsCancellationRequested)
            {
                stream = null;
                return 1;
            }
            _current = new MemoryStream();
            stream = new Wia2PageStream(_current);
            return 0;
        }
    }

    private void Finish()
    {
        if (_current is not { } done) return;
        _current = null;
        if (done.Length > 0) _pages.Add(done.ToArray());
    }

    /// <summary>The page streams' bytes, the last one included (Download has returned).</summary>
    public void Close()
    {
        lock (_gate) Finish();
    }
}

/// <summary>A COM stream over a page's memory, as WIA writes a page into it; capped at <see cref="Wia2Device.MaxPageBytes"/>.</summary>
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class Wia2PageStream(MemoryStream inner) : ComStream
{
    public void Read(byte[] pv, int cb, IntPtr pcbRead)
    {
        var n = inner.Read(pv, 0, Math.Min(cb, pv.Length));
        if (pcbRead != IntPtr.Zero) Marshal.WriteInt32(pcbRead, n);
    }

    public void Write(byte[] pv, int cb, IntPtr pcbWritten)
    {
        var n = Math.Min(cb, pv.Length);
        if (inner.Position + n > Wia2Device.MaxPageBytes) throw new COMException("The page is larger than any scan.", WiaErrors.OutOfMemory);
        inner.Write(pv, 0, n);
        if (pcbWritten != IntPtr.Zero) Marshal.WriteInt32(pcbWritten, n);
    }

    public void Seek(long dlibMove, int dwOrigin, IntPtr plibNewPosition)
    {
        var target = dwOrigin switch { 0 => dlibMove, 1 => inner.Position + dlibMove, 2 => inner.Length + dlibMove, _ => -1 };
        if (target < 0 || target > Wia2Device.MaxPageBytes) throw new COMException("Seek outside the page.", unchecked((int)0x80030019)); // STG_E_SEEKERROR
        inner.Position = target;
        if (plibNewPosition != IntPtr.Zero) Marshal.WriteInt64(plibNewPosition, inner.Position);
    }

    public void SetSize(long libNewSize)
    {
        if (libNewSize < 0 || libNewSize > Wia2Device.MaxPageBytes) throw new COMException("The page is larger than any scan.", WiaErrors.OutOfMemory);
        inner.SetLength(libNewSize);
    }

    public void CopyTo(ComStream pstm, long cb, IntPtr pcbRead, IntPtr pcbWritten) => throw new NotSupportedException();

    public void Commit(int grfCommitFlags) { }

    public void Revert() { }

    public void LockRegion(long libOffset, long cb, int dwLockType) { }

    public void UnlockRegion(long libOffset, long cb, int dwLockType) { }

    public void Stat(out ComStatStg pstatstg, int grfStatFlag) => pstatstg = new ComStatStg { type = 2, cbSize = inner.Length }; // STGTY_STREAM

    public void Clone(out ComStream ppstm) => throw new NotSupportedException();
}

/// <summary>A WIA 2.0 device this path can't scan with (its item takes no format this app reads): WIA 1.0's path is used instead.</summary>
internal sealed class Wia2UnusableException(string message) : Exception(message);
