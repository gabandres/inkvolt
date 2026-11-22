using System.ComponentModel;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Setup;

namespace InkvoltPrint.Windows.Setup;

/// <summary>
/// This PC's Wi-Fi for the printer setup guide (roadmap 4.17), through Windows' Native Wifi API (wlanapi.dll, no administrator rights):
/// the first Wi-Fi adapter's connection (<c>WlanQueryInterface</c>), the networks in range (<c>WlanScan</c>, then
/// <c>WlanGetAvailableNetworkList</c>; Windows 11 answers access denied while location access is off for desktop apps), joining an open
/// network with a temporary profile and a known one by its saved profile (<c>WlanConnect</c>), leaving (<c>WlanDisconnect</c>), and the
/// gateway its adapter was given. It never reads a profile's key or writes a profile: a secured network is joined in Windows' own list.
/// </summary>
public sealed class WlanWifi : IWifi
{
    private const int AccessDenied = 5;

    public Task<WifiNow> NowAsync(CancellationToken ct) => Task.Run(() =>
    {
        using var client = Client.Open();
        if (client.FirstInterface() is not { } id) return WifiNow.NoAdapter;
        if (WlanQueryInterface(client.Handle, ref id, 7 /* wlan_intf_opcode_current_connection */, IntPtr.Zero, out _, out var data, out _) != 0)
            return new WifiNow(true, null, null); // not connected
        try
        {
            var attributes = Marshal.PtrToStructure<ConnectionAttributes>(data);
            if (attributes.State != 1 /* wlan_interface_state_connected */) return new WifiNow(true, null, null);
            var ssid = attributes.Association.Ssid;
            return new WifiNow(true, ssid.Bytes(), string.IsNullOrEmpty(attributes.ProfileName) ? null : attributes.ProfileName);
        }
        finally
        {
            WlanFreeMemory(data);
        }
    }, ct);

    public async Task<IReadOnlyList<WifiNetwork>> NearbyAsync(CancellationToken ct)
    {
        await Task.Run(() =>
        {
            using var client = Client.Open();
            if (client.FirstInterface() is { } id) WlanScan(client.Handle, ref id, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero); // a fresh look; the list may be from before it
        }, ct).ConfigureAwait(false);
        await Task.Delay(TimeSpan.FromSeconds(4), ct).ConfigureAwait(false);
        return await Task.Run(() =>
        {
            using var client = Client.Open();
            if (client.FirstInterface() is not { } id) return (IReadOnlyList<WifiNetwork>)[];
            var error = WlanGetAvailableNetworkList(client.Handle, ref id, 0, IntPtr.Zero, out var list);
            if (error == AccessDenied) throw new WifiLocationException();
            if (error != 0) throw new Win32Exception((int)error);
            try
            {
                var count = Math.Min(Marshal.ReadInt32(list), 1024);
                var size = Marshal.SizeOf<AvailableNetwork>();
                var networks = new List<WifiNetwork>(count);
                for (var i = 0; i < count; i++)
                {
                    var n = Marshal.PtrToStructure<AvailableNetwork>(list + 8 + i * size);
                    if (n.BssType != 1 /* infrastructure */) continue;
                    networks.Add(new WifiNetwork(n.Ssid.Bytes(), (int)Math.Min(n.SignalQuality, 100), n.SecurityEnabled != 0));
                }
                return networks;
            }
            finally
            {
                WlanFreeMemory(list);
            }
        }, ct).ConfigureAwait(false);
    }

    public Task ConnectOpenAsync(WifiNetwork network, string profileXml, CancellationToken ct) => Task.Run(() =>
    {
        using var client = Client.Open();
        var id = client.FirstInterface() ?? throw new InvalidOperationException("No Wi-Fi adapter.");
        var parameters = new ConnectionParameters { Mode = 1 /* wlan_connection_mode_temporary_profile */, Profile = profileXml, BssType = 1 };
        var error = WlanConnect(client.Handle, ref id, ref parameters, IntPtr.Zero);
        if (error != 0) throw new Win32Exception((int)error);
    }, ct);

    public Task ConnectProfileAsync(string profile, CancellationToken ct) => Task.Run(() =>
    {
        using var client = Client.Open();
        var id = client.FirstInterface() ?? throw new InvalidOperationException("No Wi-Fi adapter.");
        var parameters = new ConnectionParameters { Mode = 0 /* wlan_connection_mode_profile */, Profile = profile, BssType = 1 };
        var error = WlanConnect(client.Handle, ref id, ref parameters, IntPtr.Zero);
        if (error != 0) throw new Win32Exception((int)error);
    }, ct);

    public Task DisconnectAsync(CancellationToken ct) => Task.Run(() =>
    {
        using var client = Client.Open();
        if (client.FirstInterface() is not { } id) return;
        var error = WlanDisconnect(client.Handle, ref id, IntPtr.Zero);
        if (error != 0) throw new Win32Exception((int)error);
    }, ct);

    public Task<IPAddress?> GatewayAsync(CancellationToken ct) => Task.Run(() =>
    {
        using var client = Client.Open();
        if (client.FirstInterface() is not { } id) return null;
        var nic = NetworkInterface.GetAllNetworkInterfaces()
            .FirstOrDefault(n => Guid.TryParse(n.Id, out var g) && g == id && n.OperationalStatus == OperationalStatus.Up);
        if (nic is null) return null;
        var props = nic.GetIPProperties();
        return props.GatewayAddresses.Select(g => g.Address).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork)
               ?? props.DhcpServerAddresses.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
    }, ct);

    /// <summary>A WLAN client handle, closed when disposed.</summary>
    private sealed class Client : IDisposable
    {
        public IntPtr Handle { get; private init; }

        public static Client Open()
        {
            var error = WlanOpenHandle(2, IntPtr.Zero, out _, out var handle);
            // No WLAN service (no Wi-Fi hardware, or the service off): as no adapter.
            return error == 0 ? new Client { Handle = handle } : new Client { Handle = IntPtr.Zero };
        }

        /// <summary>The first Wi-Fi adapter's id, or null.</summary>
        public Guid? FirstInterface()
        {
            if (Handle == IntPtr.Zero || WlanEnumInterfaces(Handle, IntPtr.Zero, out var list) != 0) return null;
            try
            {
                // WLAN_INTERFACE_INFO_LIST: dwNumberOfItems, dwIndex, then WLAN_INTERFACE_INFO (a GUID first).
                return Marshal.ReadInt32(list) > 0 ? Marshal.PtrToStructure<Guid>(list + 8) : null;
            }
            finally
            {
                WlanFreeMemory(list);
            }
        }

        public void Dispose()
        {
            if (Handle != IntPtr.Zero) WlanCloseHandle(Handle, IntPtr.Zero);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Dot11Ssid
    {
        public uint Length;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] Ssid;

        public readonly byte[] Bytes() => Ssid is null ? [] : Ssid[..(int)Math.Min(Length, 32)];
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct AvailableNetwork
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string ProfileName;

        public Dot11Ssid Ssid;
        public uint BssType;
        public uint NumberOfBssids;
        public int NetworkConnectable;
        public uint NotConnectableReason;
        public uint NumberOfPhyTypes;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
        public uint[] PhyTypes;

        public int MorePhyTypes;
        public uint SignalQuality;
        public int SecurityEnabled;
        public uint AuthAlgorithm;
        public uint CipherAlgorithm;
        public uint Flags;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ConnectionAttributes
    {
        public uint State;
        public uint Mode;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string ProfileName;

        public AssociationAttributes Association;
        public SecurityAttributes Security;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AssociationAttributes
    {
        public Dot11Ssid Ssid;
        public uint BssType;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
        public byte[] Bssid;

        public uint PhyType;
        public uint PhyIndex;
        public uint SignalQuality;
        public uint RxRate;
        public uint TxRate;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int SecurityEnabled;
        public int OneXEnabled;
        public uint AuthAlgorithm;
        public uint CipherAlgorithm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ConnectionParameters
    {
        public uint Mode;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string Profile;

        public IntPtr Ssid;
        public IntPtr DesiredBssids;
        public uint BssType;
        public uint Flags;
    }

    [DllImport("wlanapi.dll")]
    private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiatedVersion, out IntPtr handle);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanQueryInterface(IntPtr handle, ref Guid id, uint opCode, IntPtr reserved, out uint size, out IntPtr data, out uint type);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanScan(IntPtr handle, ref Guid id, IntPtr ssid, IntPtr ie, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanGetAvailableNetworkList(IntPtr handle, ref Guid id, uint flags, IntPtr reserved, out IntPtr list);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanConnect(IntPtr handle, ref Guid id, ref ConnectionParameters parameters, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern uint WlanDisconnect(IntPtr handle, ref Guid id, IntPtr reserved);

    [DllImport("wlanapi.dll")]
    private static extern void WlanFreeMemory(IntPtr memory);
}
