using System.IO;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Twain;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Windows.Scanning;

/// <summary>
/// The PC's 64-bit TWAIN sources through the TWAIN 2 data source manager (TWAINDSM.dll, which scanner makers' TWAIN drivers
/// install; Windows doesn't ship it), behind the same <see cref="IWiaSystem"/> / <see cref="IWiaDevice"/> interface as WIA, so
/// <see cref="WiaScanner"/>'s plan, feeder loop and error words apply unchanged (<see cref="TwainCaps.ToInfo"/>,
/// <see cref="TwainSettings"/>, <see cref="TwainErrors"/>). Calls run on background STA threads (<see cref="WorkThread"/>): one for
/// the list, one per source, each with a hidden window as TWAIN's parent, pumping its messages to the source while a scan waits
/// for its first page. The source's own window is never shown (ShowUI off); pages come by native transfer (a DIB, turned into JPEG).
/// </summary>
public sealed class WindowsTwain : IWiaSystem
{
    public static WindowsTwain Instance { get; } = new();

    private const string Dsm = "TWAINDSM.dll";
    private static readonly TimeSpan ListTimeout = TimeSpan.FromSeconds(20);

    /// <summary>The longest a scan waits for the source to have its first page ready (a scanner warming up, paper being fed).</summary>
    private static readonly TimeSpan ReadyTimeout = TimeSpan.FromMinutes(2);

    private readonly Lazy<WorkThread> _listThread = new(() => new WorkThread("Inkvolt TWAIN list", true));
    private readonly Dictionary<string, Slot> _slots = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    private WindowsTwain() { }

    /// <summary>The 64-bit TWAIN manager is installed (in Windows' system folder, where makers' installers put it).</summary>
    public static bool ManagerInstalled => Environment.Is64BitProcess && File.Exists(Path.Combine(Environment.SystemDirectory, Dsm));

    /// <summary>The sources the manager knows (id and name: the source's product name). Empty when the manager isn't installed.</summary>
    public async Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct)
    {
        if (!ManagerInstalled) return [];
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(ListTimeout);
        try
        {
            return await _listThread.Value.RunAsync(() => WindowsWia.Wrap(List), limit.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new WiaException(WiaErrors.NotAnswering, "The TWAIN manager didn't answer in time.");
        }
        catch (WorkThreadStuckException)
        {
            throw new WiaException(WiaErrors.NotAnswering, "The TWAIN manager still hasn't answered an earlier request.");
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
        using var dsm = new Manager();
        return dsm.Sources().Select(s => new WiaDeviceInfo(s.ProductName, s.ProductName, NullIfEmpty(s.Manufacturer), NullIfEmpty(s.ProductFamily), "TWAIN"))
            .ToList();
    }

    private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    /// <summary>One source: its own STA thread and, once opened, its session (touched on that thread only).</summary>
    private sealed class Slot(string id, int number) : IWiaDeviceHost
    {
        private readonly WorkThread _thread = new($"Inkvolt TWAIN {number}", true);
        private Session? _session;

        public async Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct)
        {
            try
            {
                return await _thread.RunAsync(() => Run(work), ct).ConfigureAwait(false);
            }
            catch (WorkThreadStuckException)
            {
                throw new WiaException(WiaErrors.NotAnswering, "An earlier call to the scanner's TWAIN driver hasn't returned.");
            }
        }

        private T Run<T>(Func<IWiaDevice, T> work)
        {
            try
            {
                _session ??= WindowsWia.Wrap(() => Session.Open(id));
                return WindowsWia.Wrap(() => work(_session));
            }
            catch (WiaException ex) when (WiaErrors.NeedsReconnect(ex.Code))
            {
                _session?.Dispose(); // closes the source and the manager: the next call starts from a clean state
                _session = null;
                throw;
            }
        }
    }

    /// <summary>The data source manager opened with a hidden parent window, on the calling (STA) thread.</summary>
    private class Manager : IDisposable
    {
        protected readonly IntPtr App = Marshal.AllocHGlobal(Marshal.SizeOf<TwIdentity>());
        protected readonly IntPtr Window;
        private bool _open;

        public Manager()
        {
            Marshal.StructureToPtr(new TwIdentity
            {
                Version = new TwVersion { MajorNum = 1, Language = 13, Country = 1, Info = "Inkvolt" },
                ProtocolMajor = 2,
                ProtocolMinor = 4,
                SupportedGroups = Tw.DgControl | Tw.DgImage | Tw.DfApp2,
                Manufacturer = "Inkvolt",
                ProductFamily = "Inkvolt",
                ProductName = "Inkvolt",
            }, App, false);
            Window = CreateWindowExW(0, "STATIC", "Inkvolt TWAIN", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            var parent = Window;
            if (Entry(App, IntPtr.Zero, Tw.DgControl, Tw.DatParent, Tw.MsgOpenDsm, ref parent) != Tw.RcSuccess)
            {
                Dispose();
                throw new WiaException(WiaErrors.NoDeviceAvailable, "The TWAIN manager didn't open.");
            }
            _open = true;
        }

        public List<TwIdentity> Sources()
        {
            var list = new List<TwIdentity>();
            var block = Marshal.AllocHGlobal(Marshal.SizeOf<TwIdentity>());
            try
            {
                for (var rc = Entry(App, IntPtr.Zero, Tw.DgControl, Tw.DatIdentity, Tw.MsgGetFirst, block);
                     rc == Tw.RcSuccess;
                     rc = Entry(App, IntPtr.Zero, Tw.DgControl, Tw.DatIdentity, Tw.MsgGetNext, block))
                {
                    var id = Marshal.PtrToStructure<TwIdentity>(block);
                    if (!string.IsNullOrWhiteSpace(id.ProductName)) list.Add(id);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(block);
            }
            return list;
        }

        public virtual void Dispose()
        {
            if (_open)
            {
                var parent = Window;
                Entry(App, IntPtr.Zero, Tw.DgControl, Tw.DatParent, Tw.MsgCloseDsm, ref parent);
                _open = false;
            }
            if (Window != IntPtr.Zero) DestroyWindow(Window);
            Marshal.FreeHGlobal(App);
        }
    }

    /// <summary>
    /// One open source (TWAIN state 4 between jobs). A job: <see cref="Apply"/> sets its capabilities; the first
    /// <see cref="TransferPage"/> enables the source without its window and waits for its first page (state 6), then each call
    /// takes one page by native transfer; when the source has no more (pending transfers 0) it is disabled and the job is over.
    /// </summary>
    private sealed class Session : Manager, IWiaDevice
    {
        private readonly IntPtr _source = Marshal.AllocHGlobal(Marshal.SizeOf<TwIdentity>());
        private bool _duplexCap;
        private bool _sourceOpen, _enabled, _jobOver;
        private int _pending = -1;

        private void Connect(string name)
        {
            var id = Sources().FirstOrDefault(s => s.ProductName == name);
            if (id.ProductName != name) throw new WiaException(WiaErrors.NoDeviceAvailable, "The TWAIN manager no longer has this scanner.");
            Marshal.StructureToPtr(id, _source, false);
            if (Entry(App, IntPtr.Zero, Tw.DgControl, Tw.DatIdentity, Tw.MsgOpenDs, _source) != Tw.RcSuccess)
                throw new WiaException(TwainErrors.ToWia(Status(false)), "The TWAIN source didn't open.");
            _sourceOpen = true;
            SetOne(Tw.IcapUnits, Tw.TyUInt16, Tw.UnInches);
            var hasFeeder = Get(Tw.CapFeederEnabled) is not null;
            var feeder = hasFeeder && SetOne(Tw.CapFeederEnabled, Tw.TyBool, 1) && Get(Tw.CapFeederEnabled)?.Current == 1;
            var glass = !feeder || SetOne(Tw.CapFeederEnabled, Tw.TyBool, 0) && Get(Tw.CapFeederEnabled)?.Current == 0;
            _duplexCap = Get(Tw.CapDuplex)?.Current is 1 or 2;
            var res = Get(Tw.IcapXResolution);
            Info = new TwainCaps(feeder, feeder && !glass, _duplexCap, Get(Tw.CapFeederLoaded) is not null,
                Get(Tw.IcapPixelType) is { } pt ? pt.Values.Select(v => (int)v).ToList() : [],
                res is null ? WiaValues.Only(0) : res.ToValues(),
                Get(Tw.IcapPhysicalWidth)?.CurrentFix32, Get(Tw.IcapPhysicalHeight)?.CurrentFix32).ToInfo();
        }

        public static Session Open(string name)
        {
            if (!ManagerInstalled) throw new WiaException(WiaErrors.NoDeviceAvailable, "The TWAIN manager isn't installed.");
            var session = new Session();
            try
            {
                session.Connect(name);
                return session;
            }
            catch
            {
                session.Dispose(); // the source (if it opened), the manager and the window
                throw;
            }
        }

        public WiaScannerInfo Info { get; private set; } = null!;

        /// <summary>Paper in the feeder (CAP_FEEDERLOADED), or ready while the source still holds pages of this job; null when it can't tell.</summary>
        public int? ReadHandlingStatus()
        {
            if (_enabled && _pending != 0) return WiaIds.FeedReady;
            if (Info.Handling is not { } h || (h & WiaIds.CapDetectFeedAvailable) == 0) return null;
            return Get(Tw.CapFeederLoaded)?.Current == 1 ? WiaIds.FeedReady : 0;
        }

        public int? Apply(WiaScanSettings s)
        {
            EndJob();
            var t = TwainSettings.From(s);
            SetOne(Tw.IcapUnits, Tw.TyUInt16, Tw.UnInches);
            bool? feederTaken = null;
            if (Info.Handling is not null)
            {
                SetOne(Tw.CapFeederEnabled, Tw.TyBool, t.Feeder ? 1u : 0u);
                if (t.Feeder) SetOne(Tw.CapAutoFeed, Tw.TyBool, 1);
                if (_duplexCap) SetOne(Tw.CapDuplexEnabled, Tw.TyBool, t.Duplex ? 1u : 0u);
                feederTaken = Get(Tw.CapFeederEnabled)?.Current == 1;
            }
            SetOne(Tw.IcapPixelType, Tw.TyUInt16, t.PixelType);
            SetOne(Tw.IcapBitDepth, Tw.TyUInt16, t.BitDepth);
            SetOne(Tw.IcapXResolution, Tw.TyFix32, Tw.ToFix32(t.Resolution));
            SetOne(Tw.IcapYResolution, Tw.TyFix32, Tw.ToFix32(t.Resolution));
            var layout = new TwImageLayout
            {
                Right = Tw.ToFix32(t.Right), Bottom = Tw.ToFix32(t.Bottom),
                DocumentNumber = uint.MaxValue, PageNumber = uint.MaxValue, FrameNumber = uint.MaxValue,
            };
            Entry(App, _source, Tw.DgImage, Tw.DatImageLayout, Tw.MsgSet, ref layout); // a source that refuses scans its whole area
            SetOne(Tw.CapXferCount, Tw.TyInt16, (ushort)t.Count);
            _jobOver = false;
            return feederTaken is null ? null
                : feederTaken.Value ? WiaIds.SelectFeeder | (t.Duplex ? WiaIds.SelectDuplex : 0) : WiaIds.SelectFlatbed;
        }

        public byte[]? TransferPage(WiaScanSettings s)
        {
            if (_jobOver) return null;
            if (!_enabled && !EnableAndWait()) return null;
            var handle = IntPtr.Zero;
            var rc = Entry(App, _source, Tw.DgImage, Tw.DatImageNativeXfer, Tw.MsgGet, ref handle);
            byte[]? bmp = null;
            try
            {
                if (rc == Tw.RcXferDone) bmp = ReadDib(handle);
                else if (rc != Tw.RcCancel)
                {
                    var code = Status(true);
                    EndJob();
                    throw new WiaException(TwainErrors.ToWia(code), "The TWAIN source couldn't transfer the page.");
                }
            }
            finally
            {
                if (handle != IntPtr.Zero) GlobalFree(handle);
            }
            var pending = new TwPendingXfers();
            Entry(App, _source, Tw.DgControl, Tw.DatPendingXfers, Tw.MsgEndXfer, ref pending);
            _pending = pending.Count == 0xFFFF ? -1 : pending.Count;
            if (_pending == 0 || bmp is null) EndJob();
            return bmp is null ? null : WindowsWia.JpegFromBmp(bmp);
        }

        /// <summary>Enables the source without its window and pumps messages until it has a page; false when it closed instead.</summary>
        private bool EnableAndWait()
        {
            var ui = new TwUserInterface { ShowUi = 0, ModalUi = 0, Parent = Window };
            var rc = Entry(App, _source, Tw.DgControl, Tw.DatUserInterface, Tw.MsgEnableDs, ref ui);
            if (rc is not (Tw.RcSuccess or Tw.RcCheckStatus))
                throw new WiaException(TwainErrors.ToWia(Status(true)), "The TWAIN source didn't start the scan.");
            _enabled = true;
            _pending = -1;
            var msg = Marshal.AllocHGlobal(Marshal.SizeOf<Msg>());
            try
            {
                var deadline = DateTime.UtcNow + ReadyTimeout;
                while (DateTime.UtcNow < deadline)
                {
                    while (PeekMessageW(msg, IntPtr.Zero, 0, 0, 1))
                    {
                        var ev = new TwEvent { Event = msg };
                        if (Entry(App, _source, Tw.DgControl, Tw.DatEvent, Tw.MsgProcessEvent, ref ev) == Tw.RcDsEvent)
                        {
                            if (ev.Message == Tw.MsgXferReady) return true;
                            if (ev.Message is Tw.MsgCloseDsReq or Tw.MsgCloseDsOk)
                            {
                                EndJob();
                                return false;
                            }
                            continue;
                        }
                        TranslateMessage(msg);
                        DispatchMessageW(msg);
                    }
                    Thread.Sleep(15);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(msg);
            }
            EndJob();
            throw new WiaException(WiaErrors.UserIntervention, "The TWAIN source had no page ready in time.");
        }

        /// <summary>Back to state 4: pending pages dropped, the source disabled.</summary>
        private void EndJob()
        {
            _jobOver = true;
            if (!_enabled) return;
            if (_pending != 0)
            {
                var reset = new TwPendingXfers();
                Entry(App, _source, Tw.DgControl, Tw.DatPendingXfers, Tw.MsgReset, ref reset);
            }
            var ui = new TwUserInterface { Parent = Window };
            Entry(App, _source, Tw.DgControl, Tw.DatUserInterface, Tw.MsgDisableDs, ref ui);
            _enabled = false;
            _pending = -1;
        }

        private static byte[] ReadDib(IntPtr handle)
        {
            var p = GlobalLock(handle);
            if (p == IntPtr.Zero) throw new WiaException(WiaErrors.OutOfMemory, "The page couldn't be read.");
            try
            {
                var size = (long)GlobalSize(handle);
                var header = new byte[(int)Math.Min(size, 40)];
                Marshal.Copy(p, header, 0, header.Length);
                var length = Dib.Length(header);
                if (length == 0 || length > size) throw new WiaException(WiaErrors.InvalidDriverResponse, "The page isn't an image.");
                var dib = new byte[length];
                Marshal.Copy(p, dib, 0, length);
                return Dib.ToBmp(dib);
            }
            finally
            {
                GlobalUnlock(handle);
            }
        }

        /// <summary>The source's condition code after a failure (<paramref name="ofSource"/>: the source's; else the manager's).</summary>
        private ushort Status(bool ofSource)
        {
            var status = new TwStatus();
            Entry(App, ofSource ? _source : IntPtr.Zero, Tw.DgControl, Tw.DatStatus, Tw.MsgGet, ref status);
            return status.ConditionCode;
        }

        private Cap? Get(ushort cap)
        {
            var c = new TwCapability { Cap = cap, ConType = 0xFFFF };
            if (Entry(App, _source, Tw.DgControl, Tw.DatCapability, Tw.MsgGet, ref c) != Tw.RcSuccess || c.Container == IntPtr.Zero) return null;
            try
            {
                var p = GlobalLock(c.Container);
                if (p == IntPtr.Zero) return null;
                try
                {
                    return Cap.Read(c.ConType, p);
                }
                finally
                {
                    GlobalUnlock(c.Container);
                }
            }
            finally
            {
                GlobalFree(c.Container);
            }
        }

        private bool SetOne(ushort cap, ushort type, uint value)
        {
            var h = GlobalAlloc(0x42, 6); // GHND: movable, zeroed
            if (h == IntPtr.Zero) return false;
            try
            {
                var p = GlobalLock(h);
                Marshal.WriteInt16(p, (short)type);
                Marshal.WriteInt32(p, 2, (int)value);
                GlobalUnlock(h);
                var c = new TwCapability { Cap = cap, ConType = Tw.OnOneValue, Container = h };
                return Entry(App, _source, Tw.DgControl, Tw.DatCapability, Tw.MsgSet, ref c) is Tw.RcSuccess or Tw.RcCheckStatus;
            }
            finally
            {
                GlobalFree(h);
            }
        }

        public override void Dispose()
        {
            try
            {
                EndJob();
                if (_sourceOpen) Entry(App, IntPtr.Zero, Tw.DgControl, Tw.DatIdentity, Tw.MsgCloseDs, _source);
                _sourceOpen = false;
            }
            finally
            {
                Marshal.FreeHGlobal(_source);
                base.Dispose();
            }
        }
    }

    /// <summary>A capability's container as read: its values (raw 32 bits each) and, for ranges, the range.</summary>
    private sealed record Cap(ushort ItemType, IReadOnlyList<uint> Values, uint Current, uint? Min = null, uint? Max = null, uint? Step = null)
    {
        public double? CurrentFix32 => ItemType == Tw.TyFix32 ? Tw.FromFix32(Current) : null;

        public WiaValues ToValues()
        {
            int Dpi(uint raw) => ItemType == Tw.TyFix32 ? (int)Math.Round(Tw.FromFix32(raw)) : (int)raw;
            if (Min is { } min && Max is { } max) return WiaValues.Range(Dpi(Current), Dpi(min), Dpi(max), Math.Max(1, Dpi(Step ?? 1)));
            return Values.Count > 1 ? new WiaValues(Dpi(Current), Values.Select(Dpi).ToList()) : WiaValues.Only(Dpi(Current));
        }

        public static Cap? Read(ushort conType, IntPtr p)
        {
            var type = (ushort)Marshal.ReadInt16(p);
            uint U32(int offset) => (uint)Marshal.ReadInt32(p, offset);
            switch (conType)
            {
                case Tw.OnOneValue:
                    var one = Item(p, 2, type);
                    return new Cap(type, [one], one);
                case Tw.OnRange:
                    return new Cap(type, [], U32(18), U32(2), U32(6), U32(10));
                case Tw.OnEnumeration:
                {
                    var count = (int)Math.Min(U32(2), 1024);
                    var current = U32(6);
                    var items = Enumerable.Range(0, count).Select(i => Item(p, 14 + i * Size(type), type)).ToList();
                    return new Cap(type, items, current < items.Count ? items[(int)current] : items.FirstOrDefault());
                }
                case Tw.OnArray:
                {
                    var count = (int)Math.Min(U32(2), 1024);
                    var items = Enumerable.Range(0, count).Select(i => Item(p, 6 + i * Size(type), type)).ToList();
                    return new Cap(type, items, items.FirstOrDefault());
                }
                default:
                    return null;
            }
        }

        private static int Size(ushort type) => type switch { 0 or 3 => 1, 1 or 4 or Tw.TyBool => 2, _ => 4 };

        private static uint Item(IntPtr p, int offset, ushort type) => Size(type) switch
        {
            1 => Marshal.ReadByte(p, offset),
            2 => type == Tw.TyInt16 ? (uint)(short)Marshal.ReadInt16(p, offset) : (ushort)Marshal.ReadInt16(p, offset),
            _ => (uint)Marshal.ReadInt32(p, offset),
        };
    }

    // twain.h structures: packed on 2 bytes on Windows.
    [StructLayout(LayoutKind.Sequential, Pack = 2, CharSet = CharSet.Ansi)]
    private struct TwVersion
    {
        public ushort MajorNum, MinorNum, Language, Country;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string Info;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2, CharSet = CharSet.Ansi)]
    private struct TwIdentity
    {
        public uint Id;
        public TwVersion Version;
        public ushort ProtocolMajor, ProtocolMinor;
        public uint SupportedGroups;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string Manufacturer;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string ProductFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string ProductName;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct TwUserInterface
    {
        public ushort ShowUi, ModalUi;
        public IntPtr Parent;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct TwEvent
    {
        public IntPtr Event;
        public ushort Message;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct TwPendingXfers
    {
        public ushort Count;
        public uint Eoj;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct TwCapability
    {
        public ushort Cap, ConType;
        public IntPtr Container;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct TwStatus
    {
        public ushort ConditionCode, Data;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct TwImageLayout
    {
        public uint Left, Top, Right, Bottom, DocumentNumber, PageNumber, FrameNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Msg
    {
        public IntPtr Hwnd;
        public uint Message;
        public IntPtr WParam, LParam;
        public uint Time;
        public int X, Y;
        public uint Private;
    }

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, IntPtr data);

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, ref IntPtr data);

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, ref TwUserInterface data);

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, ref TwEvent data);

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, ref TwPendingXfers data);

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, ref TwCapability data);

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, ref TwStatus data);

    [DllImport(Dsm, EntryPoint = "DSM_Entry")]
    private static extern ushort Entry(IntPtr origin, IntPtr dest, uint dg, ushort dat, ushort msg, ref TwImageLayout data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowExW(int exStyle, string className, string windowName, int style, int x, int y, int width, int height,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool PeekMessageW(IntPtr msg, IntPtr hwnd, uint min, uint max, uint remove);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(IntPtr msg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessageW(IntPtr msg);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalAlloc(uint flags, nuint bytes);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalLock(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern bool GlobalUnlock(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalFree(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern nuint GlobalSize(IntPtr handle);
}
