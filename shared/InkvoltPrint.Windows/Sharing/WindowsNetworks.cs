using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Sharing;

namespace InkvoltPrint.Windows.Sharing;

/// <summary>
/// This PC's networks for a shared scanner (roadmap 3.1): each up interface's addresses and subnets (.NET's NetworkInterface), with
/// the category Windows gives its network (Settings › Network: Public or Private), read from Windows' Network List Manager (COM,
/// netlistmgr.h; no administrator rights). An interface the Network List Manager doesn't list, or one it can't be asked about, counts
/// as public. <see cref="Changed"/> comes when an address changes, and when a category changes (checked every 15 s, since no address
/// changes then). Both are watched only while someone listens (a scanner is chosen to be shared): with sharing off, no timer runs and
/// nothing is subscribed.
/// </summary>
public sealed class WindowsNetworks : IShareNetworks, IDisposable
{
    private readonly Lock _gate = new();
    private Action? _changed;
    private Timer? _poll;
    private string? _last;
    private bool _disposed;

    public event Action? Changed
    {
        add
        {
            lock (_gate)
            {
                if (_disposed || value is null) return;
                var first = _changed is null;
                _changed += value;
                if (!first) return;
                NetworkChange.NetworkAddressChanged += OnAddressChanged;
                _poll = new Timer(_ => Poll(), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));
            }
        }
        remove
        {
            lock (_gate)
            {
                _changed -= value;
                if (_changed is null) Unwatch();
            }
        }
    }

    /// <summary>Whether the 15 s category check runs now (for a check by hand: none while sharing is off).</summary>
    public bool IsWatching
    {
        get { lock (_gate) return _poll is not null; }
    }

    /// <summary>Inside <see cref="_gate"/>.</summary>
    private void Unwatch()
    {
        NetworkChange.NetworkAddressChanged -= OnAddressChanged;
        _poll?.Dispose();
        _poll = null;
        _last = null;
    }

    private void Raise()
    {
        Action? changed;
        lock (_gate) changed = _changed;
        changed?.Invoke();
    }

    private void OnAddressChanged(object? sender, EventArgs e) => Raise();

    public IReadOnlyList<LocalNetwork> Read()
    {
        var list = Snapshot();
        lock (_gate) _last = Key(list);
        return list;
    }

    private void Poll()
    {
        try
        {
            var key = Key(Snapshot());
            bool changed;
            lock (_gate)
            {
                changed = _last is not null && key != _last;
                _last = key;
            }
            if (changed) Raise();
        }
        catch (Exception)
        {
            // Not read this time: the next tick tries again.
        }
    }

    private static string Key(IReadOnlyList<LocalNetwork> list) =>
        string.Join(';', list.Select(n => $"{n.InterfaceIndex}/{n.Address}/{n.PrefixLength}/{n.Kind}").Order());

    private static List<LocalNetwork> Snapshot()
    {
        var kinds = Categories();
        var list = new List<LocalNetwork>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            var kind = Guid.TryParse(nic.Id, out var id) && kinds.TryGetValue(id, out var k) ? k : NetworkKind.Public;
            var props = nic.GetIPProperties();
            int? v4 = null, v6 = null;
            try { v4 = props.GetIPv4Properties()?.Index; } catch (NetworkInformationException) { }
            try { v6 = props.GetIPv6Properties()?.Index; } catch (NetworkInformationException) { }
            foreach (var unicast in props.UnicastAddresses)
            {
                var index = unicast.Address.AddressFamily == AddressFamily.InterNetwork ? v4 : v6;
                if (index is null) continue;
                list.Add(new LocalNetwork(index.Value, unicast.Address, unicast.PrefixLength, kind));
            }
        }
        return list;
    }

    /// <summary>Adapter id → its network's category, from the Network List Manager; empty when it can't be asked.</summary>
    private static Dictionary<Guid, NetworkKind> Categories()
    {
        var kinds = new Dictionary<Guid, NetworkKind>();
        object? manager = null;
        try
        {
            manager = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B"), throwOnError: true)!);
            var connections = ((INetworkListManager)manager!).GetNetworkConnections();
            try
            {
                for (var n = 0; n < 256 && connections.Next(1, out var connection, out var fetched) == 0 && fetched == 1; n++)
                {
                    try
                    {
                        var adapter = connection.GetAdapterId();
                        var network = connection.GetNetwork();
                        try
                        {
                            var kind = network.GetCategory() switch { 1 => NetworkKind.Private, 2 => NetworkKind.Domain, _ => NetworkKind.Public };
                            // An adapter on two networks (rare) counts as the least trusted of them.
                            kinds[adapter] = kinds.TryGetValue(adapter, out var had) && had != kind ? NetworkKind.Public : kind;
                        }
                        finally
                        {
                            Marshal.ReleaseComObject(network);
                        }
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(connection);
                    }
                }
            }
            finally
            {
                Marshal.ReleaseComObject(connections);
            }
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException or TypeLoadException or UnauthorizedAccessException)
        {
            kinds.Clear(); // can't tell: every network counts as public
        }
        finally
        {
            if (manager is not null) Marshal.ReleaseComObject(manager);
        }
        return kinds;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            _changed = null;
            Unwatch();
        }
    }

    // The Network List Manager's interfaces (netlistmgr.idl), dual: their methods follow IDispatch's. Only the methods called are typed;
    // the others hold their places in the vtable.

    [ComImport, Guid("DCB00000-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkListManager
    {
        void GetNetworks();
        void GetNetwork();

        [return: MarshalAs(UnmanagedType.Interface)]
        IEnumNetworkConnections GetNetworkConnections();
    }

    [ComImport, Guid("DCB00006-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface IEnumNetworkConnections
    {
        void NewEnum();

        [PreserveSig]
        int Next(uint count, [MarshalAs(UnmanagedType.Interface)] out INetworkConnection connection, out uint fetched);
    }

    [ComImport, Guid("DCB00005-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkConnection
    {
        [return: MarshalAs(UnmanagedType.Interface)]
        INetwork GetNetwork();

        void IsConnectedToInternet();
        void IsConnected();
        void GetConnectivity();
        void GetConnectionId();
        Guid GetAdapterId();
    }

    [ComImport, Guid("DCB00002-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetwork
    {
        void GetName();
        void SetName();
        void GetDescription();
        void SetDescription();
        void GetNetworkId();
        void GetDomainType();
        void GetNetworkConnections();
        void GetTimeCreatedAndConnected();
        void IsConnectedToInternet();
        void IsConnected();
        void GetConnectivity();

        /// <summary>NLM_NETWORK_CATEGORY: 0 public, 1 private, 2 domain authenticated.</summary>
        int GetCategory();
    }
}
