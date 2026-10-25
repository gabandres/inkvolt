using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Wia;
using Microsoft.CSharp.RuntimeBinder;

namespace InkvoltPrint.Windows.Scanning;

/// <summary>
/// The PC's scanners through Windows Image Acquisition: the scripting library every Windows has (wiaaut.dll,
/// <c>WIA.DeviceManager</c>), late bound, so no package or interop assembly. WIA objects live in a single-threaded apartment,
/// so every call runs on one background STA thread of its own; the UI only awaits. Reads what the scanner offers and scans
/// with it; it never changes the driver's defaults beyond the scan's own settings, and needs no administrator rights.
/// </summary>
public sealed class WindowsWia : IWiaSystem
{
    public static WindowsWia Instance { get; } = new();

    private readonly Lazy<StaThread> _sta = new(() => new StaThread("Inkvolt WIA"));

    // Only touched on the STA thread.
    private readonly Dictionary<string, ComDevice> _connected = new(StringComparer.OrdinalIgnoreCase);

    private WindowsWia() { }

    private static Type? ManagerType => Type.GetTypeFromProgID("WIA.DeviceManager");

    public Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct) =>
        _sta.Value.RunAsync(() => Wrap(List)).WaitAsync(ct);

    public IWiaDeviceHost Device(string deviceId) => new Host(this, deviceId);

    private static IReadOnlyList<WiaDeviceInfo> List()
    {
        if (ManagerType is not { } type) return []; // WIA isn't there (some Windows N / Server installs without it)
        dynamic manager = Activator.CreateInstance(type)!;
        var list = new List<WiaDeviceInfo>();
        dynamic infos = manager.DeviceInfos;
        int count = infos.Count;
        for (var i = 1; i <= count; i++)
        {
            object index = i;
            dynamic info = infos.Item(ref index);
            if ((int)info.Type != WiaIds.ScannerType) continue;
            object props = info.Properties;
            string id = info.DeviceID;
            var name = Text(props, WiaIds.Name) ?? Text(props, WiaIds.Description) ?? "Scanner";
            list.Add(new WiaDeviceInfo(id, name.Trim(), Text(props, WiaIds.Manufacturer), Text(props, WiaIds.Description), Text(props, WiaIds.Port)));
        }
        return list;
    }

    private sealed class Host(WindowsWia wia, string id) : IWiaDeviceHost
    {
        public Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct) =>
            wia._sta.Value.RunAsync(() =>
            {
                try
                {
                    if (!wia._connected.TryGetValue(id, out var device)) wia._connected[id] = device = Wrap(() => Connect(id));
                    return Wrap(() => work(device));
                }
                catch (WiaException ex) when (WiaErrors.IsUnreachable(ex.Code) || ex.Code == WiaErrors.GeneralError)
                {
                    wia._connected.Remove(id); // connect again next time (the scanner was off, unplugged or its driver restarted)
                    throw;
                }
            }).WaitAsync(ct);
    }

    private static ComDevice Connect(string id)
    {
        if (ManagerType is not { } type) throw new WiaException(WiaErrors.NoDeviceAvailable, "Windows Image Acquisition isn't available.");
        dynamic manager = Activator.CreateInstance(type)!;
        dynamic infos = manager.DeviceInfos;
        int count = infos.Count;
        for (var i = 1; i <= count; i++)
        {
            object index = i;
            dynamic info = infos.Item(ref index);
            if (!string.Equals((string)info.DeviceID, id, StringComparison.OrdinalIgnoreCase)) continue;
            dynamic device = info.Connect();
            dynamic items = device.Items;
            if ((int)items.Count == 0) throw new WiaException(WiaErrors.InvalidDriverResponse, "The scanner's driver offers nothing to scan.");
            object first = 1;
            return new ComDevice(device, items.Item(ref first));
        }
        throw new WiaException(WiaErrors.NoDeviceAvailable, "Windows no longer has this scanner.");
    }

    /// <summary>COM and late-binding failures as <see cref="WiaException"/>s, with the driver's HRESULT when there is one.</summary>
    private static T Wrap<T>(Func<T> call)
    {
        try
        {
            return call();
        }
        catch (COMException ex)
        {
            throw new WiaException(ex.HResult, ex.Message);
        }
        catch (Exception ex) when (ex is RuntimeBinderException or InvalidCastException or ArgumentException or NotSupportedException)
        {
            throw new WiaException(WiaErrors.GeneralError, ex.Message);
        }
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
            return false; // the driver refused this one; it scans with its own value
        }
    }

    /// <summary>A connected scanner (WIA device and its scan item); used on the STA thread only.</summary>
    private sealed class ComDevice : IWiaDevice
    {
        private readonly dynamic _device, _item;

        public ComDevice(dynamic device, dynamic item)
        {
            _device = device;
            _item = item;
            object dp = device.Properties, ip = item.Properties;
            var formats = new List<string>();
            dynamic f = item.Formats;
            int count = f.Count;
            for (var i = 1; i <= count; i++)
            {
                object index = i;
                if (f.Item(ref index) is string s) formats.Add(s);
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

        public byte[]? TransferPage(WiaScanSettings s, bool first)
        {
            if (first) Apply(s);
            // JPEG straight from the driver when it offers it; otherwise BMP (every driver has it), turned into JPEG here.
            var format = Info.Formats.Contains(WiaIds.FormatJpeg, StringComparer.OrdinalIgnoreCase) ? WiaIds.FormatJpeg : WiaIds.FormatBmp;
            dynamic? image = _item.Transfer(format);
            if (image is null) return null;
            if (!string.Equals((string)image.FormatID, WiaIds.FormatJpeg, StringComparison.OrdinalIgnoreCase)) image = ToJpeg(image);
            byte[]? bytes = image.FileData.BinaryData as byte[];
            return bytes is { Length: > 0 } ? bytes : null;
        }

        private void Apply(WiaScanSettings s)
        {
            object dp = _device.Properties, ip = _item.Properties;
            if (s.Handling is { } handling) Set(dp, WiaIds.DocumentHandlingSelect, handling);
            if (s.Feeder) Set(dp, WiaIds.Pages, 1); // one page per transfer; the job asks again until the feeder is empty
            Set(ip, WiaIds.DataType, s.DataType);
            Set(ip, WiaIds.Depth, s.Depth);
            Set(ip, WiaIds.XResolution, s.Resolution);
            Set(ip, WiaIds.YResolution, s.Resolution);
            Set(ip, WiaIds.XPosition, 0);
            Set(ip, WiaIds.YPosition, 0);
            // The extents' limits follow the resolution just set: read them now.
            Set(ip, WiaIds.XExtent, Limit(ip, WiaIds.XExtent, s.Width));
            Set(ip, WiaIds.YExtent, Limit(ip, WiaIds.YExtent, s.Height));
        }

        private static int Limit(object props, int id, int wanted) =>
            Property(props, id) is { } p && Values(p) is { Max: { } max } ? Math.Min(wanted, max) : wanted;

        private static dynamic ToJpeg(dynamic image)
        {
            dynamic process = Activator.CreateInstance(Type.GetTypeFromProgID("WIA.ImageProcess")!)!;
            dynamic infos = process.FilterInfos;
            object convert = "Convert";
            string filterId = infos.Item(ref convert).FilterID;
            process.Filters.Add(filterId, 0);
            object one = 1;
            dynamic filter = process.Filters.Item(ref one);
            dynamic props = filter.Properties;
            object formatKey = "FormatID", qualityKey = "Quality";
            props.Item(ref formatKey).Value = WiaIds.FormatJpeg;
            props.Item(ref qualityKey).Value = 90;
            return process.Apply(image);
        }
    }

    /// <summary>One background thread in a single-threaded apartment running queued work in order.</summary>
    private sealed class StaThread
    {
        private readonly BlockingCollection<Action> _work = [];

        public StaThread(string name)
        {
            var thread = new Thread(() =>
            {
                foreach (var action in _work.GetConsumingEnumerable()) action();
            }) { IsBackground = true, Name = name };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        public Task<T> RunAsync<T>(Func<T> work)
        {
            var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
            _work.Add(() =>
            {
                try { tcs.SetResult(work()); }
                catch (Exception ex) { tcs.SetException(ex); }
            });
            return tcs.Task;
        }
    }
}
