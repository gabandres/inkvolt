using System.Globalization;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Windows.Scanning;

/// <summary>
/// The PC's scanners through Windows Image Acquisition: the scripting library every Windows has (wiaaut.dll,
/// <c>WIA.DeviceManager</c>), late bound, so no package or interop assembly. WIA objects live in a single-threaded apartment,
/// so calls run on background STA threads (<see cref="WorkThread"/>): one for listing and one per scanner, so a driver that
/// hangs holds up only its own scanner, and a call its caller gave up on stops further calls to that scanner until it returns
/// (<see cref="WiaErrors.NotAnswering"/>) instead of piling them up. The UI only awaits. Reads what the scanner offers and
/// scans with it; it never changes the driver's defaults beyond the scan's own settings, and needs no administrator rights.
/// COM objects that hold images are released as soon as a page is read (a 600 dpi page is ~100 MB of native memory).
/// </summary>
public sealed class WindowsWia : IWiaSystem
{
    public static WindowsWia Instance { get; } = new();

    /// <summary>Listing reads Windows' records of the scanners, not the devices, but goes through the WIA service: 20 s at most.</summary>
    private static readonly TimeSpan ListTimeout = TimeSpan.FromSeconds(20);

    private readonly Lazy<WorkThread> _listThread = new(() => new WorkThread("Inkvolt WIA list", true));
    private readonly Dictionary<string, Slot> _slots = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock _gate = new();

    private WindowsWia() { }

    private static Type? ManagerType => Type.GetTypeFromProgID("WIA.DeviceManager");

    /// <summary>
    /// The scanners Windows has drivers for. A <see cref="WiaException"/> (<see cref="WiaErrors.NotAnswering"/>), not a
    /// cancellation, when the WIA service doesn't answer in time, so a caller's loop goes on.
    /// </summary>
    public async Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(ListTimeout);
        try
        {
            return await _listThread.Value.RunAsync(() => Wrap(List), limit.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new WiaException(WiaErrors.NotAnswering, "Windows' list of scanners didn't answer in time.");
        }
        catch (WorkThreadStuckException)
        {
            throw new WiaException(WiaErrors.NotAnswering, "Windows' list of scanners still hasn't answered an earlier request.");
        }
    }

    public IWiaDeviceHost Device(string deviceId)
    {
        lock (_gate)
        {
            if (!_slots.TryGetValue(deviceId, out var slot)) _slots[deviceId] = slot = new Slot(deviceId, _slots.Count + 1);
            return slot;
        }
    }

    private static IReadOnlyList<WiaDeviceInfo> List()
    {
        if (ManagerType is not { } type) return []; // WIA isn't there (some Windows N / Server installs without it)
        object? manager = null, infos = null;
        try
        {
            manager = Activator.CreateInstance(type)!;
            infos = ((dynamic)manager).DeviceInfos;
            var list = new List<WiaDeviceInfo>();
            int count = ((dynamic)infos).Count;
            for (var i = 1; i <= count; i++)
            {
                object? info = null, props = null;
                try
                {
                    object index = i;
                    info = ((dynamic)infos).Item(ref index);
                    dynamic d = info!;
                    if ((int)d.Type != WiaIds.ScannerType) continue;
                    props = d.Properties;
                    string id = d.DeviceID;
                    var name = Text(props!, WiaIds.Name) ?? Text(props!, WiaIds.Description) ?? "Scanner";
                    list.Add(new WiaDeviceInfo(id, name.Trim(), Text(props!, WiaIds.Manufacturer), Text(props!, WiaIds.Description), Text(props!, WiaIds.Port)));
                }
                finally
                {
                    Release(props, info);
                }
            }
            return list;
        }
        finally
        {
            Release(infos, manager);
        }
    }

    /// <summary>One scanner: its own STA thread and, once connected, its COM device (touched on that thread only).</summary>
    private sealed class Slot(string id, int number) : IWiaDeviceHost
    {
        private readonly WorkThread _thread = new($"Inkvolt WIA {number}", true);
        private ComDevice? _device;

        public async Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct)
        {
            try
            {
                return await _thread.RunAsync(() => Run(work), ct).ConfigureAwait(false);
            }
            catch (WorkThreadStuckException)
            {
                throw new WiaException(WiaErrors.NotAnswering, "An earlier call to the scanner's driver hasn't returned.");
            }
        }

        private T Run<T>(Func<IWiaDevice, T> work)
        {
            try
            {
                _device ??= Wrap(() => Connect(id));
                return Wrap(() => work(_device));
            }
            catch (WiaException ex) when (WiaErrors.NeedsReconnect(ex.Code))
            {
                // Connect again next time: the scanner was off or unplugged, its driver or the WIA service restarted (RPC errors).
                _device?.Dispose();
                _device = null;
                throw;
            }
        }
    }

    private static ComDevice Connect(string id)
    {
        if (ManagerType is not { } type) throw new WiaException(WiaErrors.NoDeviceAvailable, "Windows Image Acquisition isn't available.");
        object? manager = null, infos = null;
        try
        {
            manager = Activator.CreateInstance(type)!;
            infos = ((dynamic)manager).DeviceInfos;
            int count = ((dynamic)infos).Count;
            for (var i = 1; i <= count; i++)
            {
                object? info = null, items = null;
                try
                {
                    object index = i;
                    info = ((dynamic)infos).Item(ref index);
                    dynamic d = info!;
                    if (!string.Equals((string)d.DeviceID, id, StringComparison.OrdinalIgnoreCase)) continue;
                    object device = d.Connect();
                    items = ((dynamic)device).Items;
                    if ((int)((dynamic)items!).Count == 0)
                    {
                        Release(device);
                        throw new WiaException(WiaErrors.InvalidDriverResponse, "The scanner's driver offers nothing to scan.");
                    }
                    object first = 1;
                    object item = ((dynamic)items!).Item(ref first);
                    try
                    {
                        return new ComDevice(device, item);
                    }
                    catch
                    {
                        Release(item, device);
                        throw;
                    }
                }
                finally
                {
                    Release(items, info);
                }
            }
            throw new WiaException(WiaErrors.NoDeviceAvailable, "Windows no longer has this scanner.");
        }
        finally
        {
            Release(infos, manager);
        }
    }

    /// <summary>
    /// Any failure as a <see cref="WiaException"/> with its HRESULT (<see cref="WiaErrors.From"/>): COM errors, and those .NET
    /// maps to other exception types (access denied, out of memory, not implemented), so none escapes a caller that catches
    /// <see cref="WiaException"/>.
    /// </summary>
    private static T Wrap<T>(Func<T> call)
    {
        try
        {
            return call();
        }
        catch (Exception ex) when (ex is not (WiaException or OperationCanceledException))
        {
            throw WiaErrors.From(ex);
        }
    }

    /// <summary>Lets go of COM objects now rather than when the finalizer gets to them (their native memory is invisible to the GC).</summary>
    private static void Release(params object?[] objects)
    {
        foreach (var o in objects)
            if (o is not null && Marshal.IsComObject(o)) Marshal.FinalReleaseComObject(o);
    }

    /// <summary>The property with this ID, or null when the driver doesn't have it.</summary>
    private static object? Property(object props, int id)
    {
        object key = id.ToString(CultureInfo.InvariantCulture);
        dynamic d = props;
        try
        {
            return (bool)d.Exists(ref key) ? (object)d.Item(ref key) : null;
        }
        catch (COMException)
        {
            return null;
        }
    }

    private static string? Text(object props, int id) => Value(props, id) is string { Length: > 0 } s ? s : null;

    private static int? Number(object props, int id) => Value(props, id) is int i ? i : null;

    private static object? Value(object props, int id) => Property(props, id) is { } p ? (object?)((dynamic)p).Value : null;

    /// <summary>A property's valid values: a range, a list (or flags), or only its current value.</summary>
    private static WiaValues Values(object property)
    {
        dynamic prop = property;
        int current = prop.Value is int v ? v : 0;
        int subType = prop.SubType;
        if (subType == 1) return WiaValues.Range(current, (int)prop.SubTypeMin, (int)prop.SubTypeMax, (int)prop.SubTypeStep);
        if (subType is 2 or 3)
        {
            var list = new List<int>();
            dynamic values = prop.SubTypeValues;
            int count = values.Count;
            for (var i = 1; i <= count; i++)
            {
                object index = i;
                if (values.Item(ref index) is int x) list.Add(x);
            }
            return new WiaValues(current, list);
        }
        return WiaValues.Only(current);
    }

    private static bool Set(object props, int id, int value)
    {
        if (Property(props, id) is not { } property) return false;
        try
        {
            ((dynamic)property).Value = value;
            return true;
        }
        catch (COMException)
        {
            return false; // the driver refused this one; it scans with its own value (the document handling select is read back)
        }
    }

    /// <summary>A connected scanner (WIA device and its scan item); used on its STA thread only.</summary>
    private sealed class ComDevice : IWiaDevice, IDisposable
    {
        private readonly dynamic _device, _item;

        public ComDevice(object device, object item)
        {
            _device = device;
            _item = item;
            object dp = _device.Properties, ip = _item.Properties;
            var formats = new List<string>();
            object f = _item.Formats;
            try
            {
                int count = ((dynamic)f).Count;
                for (var i = 1; i <= count; i++)
                {
                    object index = i;
                    if (((dynamic)f).Item(ref index) is string s) formats.Add(s);
                }
            }
            finally
            {
                Release(f);
            }
            Info = new WiaScannerInfo(
                Number(dp, WiaIds.DocumentHandlingCapabilities),
                Number(dp, WiaIds.HorizontalBedSize), Number(dp, WiaIds.VerticalBedSize),
                Number(dp, WiaIds.HorizontalSheetFeedSize), Number(dp, WiaIds.VerticalSheetFeedSize),
                Property(ip, WiaIds.XResolution) is { } res ? Values(res) : WiaValues.Only(0),
                Property(ip, WiaIds.DataType) is { } dt ? Values(dt).List : [],
                formats);
        }

        public WiaScannerInfo Info { get; }

        public int? ReadHandlingStatus() => Number((object)_device.Properties, WiaIds.DocumentHandlingStatus);

        public int? Apply(WiaScanSettings s)
        {
            object dp = _device.Properties, ip = _item.Properties;
            if (s.Handling is { } handling && !Set(dp, WiaIds.DocumentHandlingSelect, handling) && (handling & WiaIds.SelectFrontFirst) != 0)
                Set(dp, WiaIds.DocumentHandlingSelect, handling & ~WiaIds.SelectFrontFirst); // a driver that doesn't know "front first"
            // One side: one page per transfer, the job asks again until the feeder is empty. Both sides: all pages (a sheet is two).
            if (s.Pages is { } pages && !Set(dp, WiaIds.Pages, pages) && pages == 0) Set(dp, WiaIds.Pages, 2);
            Set(ip, WiaIds.DataType, s.DataType);
            Set(ip, WiaIds.Depth, s.Depth);
            Set(ip, WiaIds.XResolution, s.Resolution);
            Set(ip, WiaIds.YResolution, s.Resolution);
            Set(ip, WiaIds.XPosition, 0);
            Set(ip, WiaIds.YPosition, 0);
            // The extents' limits follow the resolution just set: read them now.
            Set(ip, WiaIds.XExtent, Limit(ip, WiaIds.XExtent, s.Width));
            Set(ip, WiaIds.YExtent, Limit(ip, WiaIds.YExtent, s.Height));
            // What the driver took (a refusal of the feeder comes without an error).
            return s.Handling is null ? null : Number((object)_device.Properties, WiaIds.DocumentHandlingSelect);
        }

        public byte[]? TransferPage(WiaScanSettings s)
        {
            // JPEG straight from the driver when it offers it; otherwise BMP (every driver has it), turned into JPEG here.
            var format = Info.Formats.Contains(WiaIds.FormatJpeg, StringComparer.OrdinalIgnoreCase) ? WiaIds.FormatJpeg : WiaIds.FormatBmp;
            object? image = null, jpeg = null, data = null;
            try
            {
                image = _item.Transfer(format);
                if (image is null) return null;
                var file = image;
                if (!string.Equals((string)((dynamic)image).FormatID, WiaIds.FormatJpeg, StringComparison.OrdinalIgnoreCase)) file = jpeg = ToJpeg(image);
                data = ((dynamic)file).FileData;
                byte[]? bytes = ((dynamic)data!).BinaryData as byte[];
                return bytes is { Length: > 0 } ? bytes : null;
            }
            finally
            {
                Release(data, jpeg, image);
            }
        }

        private static int Limit(object props, int id, int wanted) =>
            Property(props, id) is { } p && Values(p) is { Max: { } max } ? Math.Min(wanted, max) : wanted;

        private static object ToJpeg(object image)
        {
            object? process = null, infos = null, info = null, filters = null, filter = null, props = null, format = null, quality = null;
            try
            {
                process = Activator.CreateInstance(Type.GetTypeFromProgID("WIA.ImageProcess")!)!;
                infos = ((dynamic)process).FilterInfos;
                object convert = "Convert";
                info = ((dynamic)infos!).Item(ref convert);
                string filterId = ((dynamic)info!).FilterID;
                filters = ((dynamic)process).Filters;
                ((dynamic)filters!).Add(filterId, 0);
                object one = 1;
                filter = ((dynamic)filters!).Item(ref one);
                props = ((dynamic)filter!).Properties;
                object formatKey = "FormatID", qualityKey = "Quality";
                format = ((dynamic)props!).Item(ref formatKey);
                ((dynamic)format!).Value = WiaIds.FormatJpeg;
                quality = ((dynamic)props!).Item(ref qualityKey);
                ((dynamic)quality!).Value = 90;
                return ((dynamic)process).Apply(image);
            }
            finally
            {
                Release(quality, format, props, filter, filters, info, infos, process);
            }
        }

        public void Dispose() => Release((object)_item, (object)_device);
    }
}
