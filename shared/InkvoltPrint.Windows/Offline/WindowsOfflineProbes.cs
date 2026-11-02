using System.Net.NetworkInformation;
using System.Net.Sockets;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Windows.Discovery;
using InkvoltPrint.Windows.Printing;
using Microsoft.Win32;

namespace InkvoltPrint.Windows.Offline;

/// <summary>
/// The offline fixer's look at this PC and the network. Read-only: the spooler's service state, a fresh mDNS look-up
/// (its own short-lived <see cref="PrinterDiscovery"/>), ping and TCP connects, and the spooler's queues, ports and jobs.
/// Standard TCP/IP port settings come from the port monitor's registry key, which any user can read.
/// </summary>
public sealed class WindowsOfflineProbes : IOfflineProbes
{
    private static readonly TimeSpan LookupTimeout = TimeSpan.FromSeconds(12);
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan OtherAnswersWait = TimeSpan.FromSeconds(2);
    private const string TcpPorts = @"SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports";

    public Task<SpoolerState> SpoolerAsync(CancellationToken ct) => Task.Run(SpoolerService.Query, ct);

    /// <summary>
    /// A fresh mDNS look-up by UUID. Once the printer shows up, listens a moment longer: the UUID is public, so a second
    /// device announcing it must be seen (the fixer then asks before using either address). Only IP addresses and plain
    /// <c>.local</c> names are accepted (<see cref="Rediscovery.Accept"/>).
    /// </summary>
    public async Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct)
    {
        var id = uuid.Trim('{', '}');
        var seen = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var discovery = new PrinterDiscovery();
        DiscoveredPrinter? Find(IReadOnlyList<DiscoveredPrinter> list) =>
            list.FirstOrDefault(p => string.Equals(p.Uuid, id, StringComparison.OrdinalIgnoreCase) && p.Host is not null);
        discovery.Changed += list =>
        {
            if (Find(list) is not null) seen.TrySetResult(true);
        };
        discovery.InitialSweepCompleted += () => seen.TrySetResult(false);
        discovery.Start();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(LookupTimeout);
        bool found;
        await using (timeout.Token.Register(() => seen.TrySetResult(false)))
            found = await seen.Task.ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (!found) return null;
        await Task.Delay(OtherAnswersWait, ct).ConfigureAwait(false);
        return Find(discovery.Snapshot()) is { } p ? Rediscovery.Accept(p.Addresses.Prepend(p.Host), p.HostName) : null;
    }

    public async Task<Reachability> ReachAsync(string host, CancellationToken ct)
    {
        var ping = PingAsync(host);
        var ports = Reachability.Ports.Select(async p => await ConnectAsync(host, p, ct).ConfigureAwait(false) ? p : 0).ToList();
        var open = (await Task.WhenAll(ports).ConfigureAwait(false)).Where(p => p != 0).ToList();
        ct.ThrowIfCancellationRequested();
        return new Reachability(host, await ping.ConfigureAwait(false), open);
    }

    private static async Task<bool> PingAsync(string host)
    {
        try
        {
            using var ping = new Ping();
            return (await ping.SendPingAsync(host, 1500).ConfigureAwait(false)).Status == IPStatus.Success;
        }
        catch (Exception ex) when (ex is PingException or SocketException or InvalidOperationException)
        {
            return false;
        }
    }

    private static async Task<bool> ConnectAsync(string host, int port, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(ConnectTimeout);
        try
        {
            using var client = new TcpClient();
            await client.ConnectAsync(host, port, cts.Token).ConfigureAwait(false);
            return true; // connect only: nothing is sent
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException && !ct.IsCancellationRequested)
        {
            return false;
        }
    }

    public async Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct)
    {
        var containers = await QueueFinder.ListAsync().ConfigureAwait(false);
        return await Task.Run(() =>
        {
            var ports = Winspool.Ports().ToDictionary(p => p.Name, StringComparer.OrdinalIgnoreCase);
            var list = new List<QueueFacts>();
            foreach (var p in Winspool.LocalPrinters())
            {
                ct.ThrowIfCancellationRequested();
                IReadOnlyList<Core.Printing.QueueJob> jobs = [];
                if (p.Jobs > 0)
                {
                    try { jobs = Winspool.Jobs(p.Name); }
                    catch (Exception ex) when (ex is System.ComponentModel.Win32Exception) { } // queue went away while reading
                }
                list.Add(new QueueFacts(p.Name, Port(p.PortName, ports.GetValueOrDefault(p.PortName)))
                {
                    ContainerId = containers.FirstOrDefault(c => string.Equals(c.Name, p.Name, StringComparison.OrdinalIgnoreCase))?.ContainerId,
                    Paused = (p.Status & Winspool.StatusPaused) != 0,
                    ReportsError = (p.Status & Winspool.StatusError) != 0,
                    ReportsOffline = (p.Status & Winspool.StatusOffline) != 0,
                    WorkOffline = (p.Attributes & Winspool.AttributeWorkOffline) != 0,
                    Jobs = jobs,
                });
            }
            return (IReadOnlyList<QueueFacts>)list;
        }, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// One queue by name, a connection to another PC's shared printer included (<see cref="QueuesAsync"/> lists only this PC's):
    /// on the pool, since winspool waits for RPC to time out on a PC that's off. Null when Windows no longer has it; throws when
    /// it can't tell (the caller's limit ends the wait).
    /// </summary>
    public Task<QueueFacts?> QueueAsync(string name, CancellationToken ct) => Task.Run(() =>
    {
        var (q, error) = Winspool.Queue(name);
        if (q is null)
        {
            if (Core.Queues.SpoolerStatus.IsRemoved(error)) return null;
            throw new System.ComponentModel.Win32Exception(error);
        }
        IReadOnlyList<Core.Printing.QueueJob> jobs = [];
        if (q.Jobs > 0)
        {
            try { jobs = Winspool.Jobs(q.Name); }
            catch (System.ComponentModel.Win32Exception) { } // went away while reading
        }
        var ports = Winspool.Ports().ToDictionary(p => p.Name, StringComparer.OrdinalIgnoreCase);
        return (QueueFacts?)new QueueFacts(q.Name, Port(q.PortName, ports.GetValueOrDefault(q.PortName)))
        {
            Paused = (q.Status & Winspool.StatusPaused) != 0,
            ReportsError = (q.Status & Winspool.StatusError) != 0,
            ReportsOffline = (q.Status & Winspool.StatusOffline) != 0,
            WorkOffline = (q.Attributes & Winspool.AttributeWorkOffline) != 0,
            Jobs = jobs,
        };
    }, CancellationToken.None);

    /// <summary>
    /// What kind of port a queue prints to: a Standard TCP/IP port (its host from the port monitor's registry key), an IPP
    /// URL, or a WSD port (Windows' discovered WSD and IPP queues both use the WSD port monitor and follow the device by ID).
    /// </summary>
    internal static QueuePort Port(string name, Winspool.PortInfo? info)
    {
        var kind = PortKinds.Of(name, info?.Monitor, info?.Description);
        if (kind == PortKind.IppUrl)
        {
            var url = new Uri(name);
            return new QueuePort(name, PortKind.IppUrl) { Url = url, Host = url.Host };
        }
        if (kind == PortKind.DeviceId) return new QueuePort(name, PortKind.DeviceId);
        if (kind == PortKind.TcpIp)
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"{TcpPorts}\{name}");
            var host = key?.GetValue("HostName") as string is { Length: > 0 } hn ? hn
                : key?.GetValue("IPAddress") as string is { Length: > 0 } ip ? ip
                : name.StartsWith("IP_", StringComparison.OrdinalIgnoreCase) ? name[3..] : name;
            return new QueuePort(name, PortKind.TcpIp)
            {
                Host = host.Trim(),
                PortNumber = key?.GetValue("PortNumber") is int n and > 0 and < 65536 ? n : 9100,
                Lpr = key?.GetValue("Protocol") is 2,
                Snmp = key?.GetValue("SNMP Enabled") is int s && s != 0,
            };
        }
        return new QueuePort(name, PortKind.Other);
    }
}
