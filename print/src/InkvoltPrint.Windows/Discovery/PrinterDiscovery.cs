using System.Net;
using System.Net.Sockets;
using InkvoltPrint.Core.Discovery;
using Windows.Devices.Enumeration;

namespace InkvoltPrint.Windows.Discovery;

/// <summary>A printer seen on the network, merged from DNS-SD services and Windows association endpoints by UUID.</summary>
public sealed record DiscoveredPrinter(
    string Uuid,
    string Name,
    string? Model,
    string? Host,
    string? HostName,
    Uri? EsclRoot,
    bool HasScanner,
    /// <summary>Association endpoint Windows can pair (install a queue) with: IPP, else WSD. Null if not seen yet.</summary>
    string? PrintEndpointId,
    string? ScanEndpointId,
    bool QueueInstalled,
    bool ScannerInstalled,
    IReadOnlyDictionary<string, string> Txt)
{
    /// <summary>IPP printer URL from the <c>_ipp</c>/<c>_ipps</c> service (port and <c>rp</c> TXT); null if not advertised.</summary>
    public Uri? IppUri { get; init; }

    /// <summary>Every IPv4 address a service with this UUID announced (<see cref="Host"/> is the first). More than one: two devices claim the UUID.</summary>
    public IReadOnlyList<string> Addresses { get; init; } = [];
}

/// <summary>
/// Streams printers from the OS's own mDNS/WSD discovery (no custom multicast sockets, no port 5353 clash).
/// Two watchers: DNS-SD services give IPv4 + TXT; association endpoints give "is a queue installed" and
/// the handle used to install one. They join on the printer UUID (TXT <c>UUID</c> == AEP ContainerId); a service without
/// a UUID joins its host's other services (<see cref="DnssdJoin"/>).
/// Nothing here is HP-specific: any IPP Everywhere / AirPrint / Mopria printer or eSCL scanner is found.
/// </summary>
public sealed class PrinterDiscovery : IDisposable
{
    public const string IppProtocol = "{9f73fafd-2343-4bf9-a532-ad20e2674bea}";
    public const string EsclProtocol = "{9c81228c-d354-40b0-bac3-d8af2fd8ce5a}";
    public const string WsdProtocol = "{782232aa-a2f9-4993-971b-aedc551346b0}";
    private const string DnssdProtocol = "{4526e8c1-8aac-4153-9b16-55e86ada0e54}";

    private static readonly string[] ServiceProps =
    [
        "System.Devices.Dnssd.HostName", "System.Devices.Dnssd.ServiceName", "System.Devices.Dnssd.InstanceName",
        "System.Devices.IpAddress", "System.Devices.Dnssd.PortNumber", "System.Devices.Dnssd.TextAttributes",
    ];

    private static readonly string[] AepProps =
    [
        "System.Devices.Aep.ProtocolId", "System.Devices.Aep.IsPaired", "System.Devices.Aep.ContainerId",
        "System.Devices.Aep.IsPresent", "System.Devices.Aep.ModelName", "System.Devices.Aep.Category",
    ];

    private readonly Lock _gate = new();
    private readonly Dictionary<string, Svc> _services = new();      // DeviceInformation.Id -> service
    private readonly Dictionary<string, Aep> _endpoints = new();     // DeviceInformation.Id -> endpoint
    private readonly List<DeviceWatcher> _watchers = [];

    /// <summary>Bumped on every Start; events from older watchers (still stopping) are ignored.</summary>
    private int _generation;
    private bool _started;

    /// <summary>
    /// Raised with the full current list whenever anything changes. Invoked while an internal lock is held so
    /// lists always arrive in order; handlers must only hand the list off (e.g. Dispatcher.InvokeAsync).
    /// </summary>
    public event Action<IReadOnlyList<DiscoveredPrinter>>? Changed;

    /// <summary>Raised once both watchers finished (or gave up on) their initial sweep.</summary>
    public event Action? InitialSweepCompleted;

    public void Start()
    {
        int gen;
        lock (_gate)
        {
            if (_started) return; // claimed atomically: two concurrent Start calls can't both create watchers
            _started = true;
            gen = ++_generation;
        }
        try
        {
            StartWatchers(gen);
        }
        catch
        {
            Dispose(); // stop a watcher that did start, and reset so a later Start/Restart can try again
            throw;
        }
    }

    private void StartWatchers(int gen)
    {
        var services = DeviceInformation.CreateWatcher(
            $"System.Devices.AepService.ProtocolId:=\"{DnssdProtocol}\" AND System.Devices.Dnssd.Domain:=\"local\" AND " +
            "(System.Devices.Dnssd.ServiceName:=\"_ipp._tcp\" OR System.Devices.Dnssd.ServiceName:=\"_ipps._tcp\" OR " +
            "System.Devices.Dnssd.ServiceName:=\"_uscan._tcp\" OR System.Devices.Dnssd.ServiceName:=\"_uscans._tcp\")",
            ServiceProps, DeviceInformationKind.AssociationEndpointService);
        var endpoints = DeviceInformation.CreateWatcher(
            $"System.Devices.Aep.ProtocolId:=\"{IppProtocol}\" OR System.Devices.Aep.ProtocolId:=\"{EsclProtocol}\" OR " +
            $"System.Devices.Aep.ProtocolId:=\"{WsdProtocol}\"",
            AepProps, DeviceInformationKind.AssociationEndpoint);

        services.Added += (_, d) => Mutate(gen, () => _services[d.Id] = Svc.From(d.Properties));
        services.Updated += (_, u) => Mutate(gen, () => Patch(_services, u, Svc.From));
        services.Removed += (_, u) => Mutate(gen, () => _services.Remove(u.Id));
        endpoints.Added += (_, d) => Mutate(gen, () => _endpoints[d.Id] = Aep.From(d.Id, d.Name, d.Properties));
        endpoints.Updated += (_, u) => Mutate(gen, () => Patch(_endpoints, u, p => Aep.From(u.Id, null, p)));
        endpoints.Removed += (_, u) => Mutate(gen, () => _endpoints.Remove(u.Id));

        var pending = 2;
        void SweepDone()
        {
            lock (_gate)
            {
                if (gen != _generation || --pending != 0) return;
            }
            InitialSweepCompleted?.Invoke();
        }
        foreach (var w in new[] { services, endpoints })
        {
            var finished = 0;
            void Once() { if (Interlocked.Exchange(ref finished, 1) == 0) SweepDone(); }
            w.EnumerationCompleted += (_, _) => Once();
            w.Stopped += (_, _) => Once(); // aborted before finishing its sweep: don't leave callers waiting forever
            lock (_gate) _watchers.Add(w);
            w.Start();
        }
    }

    /// <summary>Drops everything seen so far and runs a fresh sweep.</summary>
    public void Restart()
    {
        Dispose();
        lock (_gate)
        {
            _services.Clear();
            _endpoints.Clear();
            Changed?.Invoke(Merge());
        }
        Start();
    }

    public IReadOnlyList<DiscoveredPrinter> Snapshot()
    {
        lock (_gate) return Merge();
    }

    private void Mutate(int gen, Action change)
    {
        lock (_gate)
        {
            if (gen != _generation) return; // late event from a watcher being torn down
            change();
            Changed?.Invoke(Merge());
        }
    }

    private static void Patch<T>(Dictionary<string, T> map, DeviceInformationUpdate u, Func<IReadOnlyDictionary<string, object>, T> make)
        where T : IMergeable<T>
    {
        var update = make(u.Properties);
        map[u.Id] = map.TryGetValue(u.Id, out var old) ? old.With(update) : update;
    }

    private List<DiscoveredPrinter> Merge()
    {
        var byUuid = new Dictionary<string, (List<Svc> S, List<Aep> A)>(StringComparer.OrdinalIgnoreCase);
        var all = _services.Values.Select(s => s.Dnssd).ToList();
        foreach (var s in _services.Values)
            if (DnssdJoin.Key(s.Dnssd, all) is { } key) Bucket(key).S.Add(s);
        foreach (var a in _endpoints.Values.Where(a => a.ContainerId is not null && a.IsPresent != false))
            Bucket(a.ContainerId!).A.Add(a);

        return byUuid
            .Where(kv => kv.Value.S.Count > 0 || kv.Value.A.Count > 0)
            .Select(kv =>
            {
                var (svcs, aeps) = kv.Value;
                var ipp = svcs.FirstOrDefault(s => s.Service is "_ipp._tcp" or "_ipps._tcp");
                var scan = svcs.FirstOrDefault(s => s.Service is "_uscan._tcp" or "_uscans._tcp");
                var any = ipp ?? scan;
                var ippAep = aeps.FirstOrDefault(a => a.Protocol == IppProtocol);
                var wsdAep = aeps.FirstOrDefault(a => a.Protocol == WsdProtocol && a.IsPrinter);
                // Prefer IPP (IPP Class Driver queue); WSD covers printers without IPP.
                var printAep = ippAep ?? wsdAep;
                var scanAep = aeps.FirstOrDefault(a => a.Protocol == EsclProtocol);
                var host = svcs.Select(s => s.IPv4).FirstOrDefault(h => h is not null);
                var escl = scan is not null && host is not null ? DnssdJoin.EsclRoot(scan.Dnssd, host) : null;
                // Plain IPP when the printer offers both: it needs no certificate; IPPS-only printers get https.
                var ippSvc = svcs.FirstOrDefault(s => s.Service == "_ipp._tcp") ?? ipp;
                var ippUri = ippSvc is not null && host is not null ? DnssdJoin.IppUri(ippSvc.Dnssd, host) : null;
                var txt = (ipp?.Txt ?? scan?.Txt ?? new Dictionary<string, string>());
                return new DiscoveredPrinter(
                    Uuid: kv.Key.ToLowerInvariant(),
                    Name: any?.Instance ?? printAep?.Name ?? scanAep?.Name ?? kv.Key,
                    Model: txt.GetValueOrDefault("ty") ?? printAep?.Model,
                    Host: host,
                    HostName: any?.HostName,
                    EsclRoot: escl,
                    HasScanner: scan is not null || scanAep is not null || txt.GetValueOrDefault("Scan") == "T",
                    PrintEndpointId: printAep?.Id,
                    ScanEndpointId: scanAep?.Id,
                    // A queue on either protocol counts: Windows often installs over WSD first.
                    QueueInstalled: ippAep?.IsPaired == true || wsdAep?.IsPaired == true,
                    ScannerInstalled: scanAep?.IsPaired == true || wsdAep is { IsPaired: true, IsScanner: true },
                    Txt: txt)
                {
                    IppUri = ippUri,
                    Addresses = svcs.Select(s => s.IPv4).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
                };
            })
            .Where(p => p.Host is not null || p.PrintEndpointId is not null)
            .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        (List<Svc> S, List<Aep> A) Bucket(string uuid)
        {
            var key = uuid.Trim('{', '}');
            if (!byUuid.TryGetValue(key, out var b)) byUuid[key] = b = ([], []);
            return b;
        }
    }

    public void Dispose()
    {
        DeviceWatcher[] old;
        lock (_gate)
        {
            old = [.. _watchers];
            _watchers.Clear();
            _started = false;
            _generation++; // ignore anything the stopping watchers still deliver
        }
        foreach (var w in old)
            if (w.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted) w.Stop();
    }

    private interface IMergeable<T> { T With(T update); }

    private sealed record Svc(string? Service, string? Instance, string? HostName, string? IPv4, int? Port, IReadOnlyDictionary<string, string> Txt)
        : IMergeable<Svc>
    {
        public string? Uuid => Txt.GetValueOrDefault("UUID");

        public DnssdService Dnssd => new(Service, Uuid, HostName, IPv4, Port, Txt);

        public Svc With(Svc u) => new(u.Service ?? Service, u.Instance ?? Instance, u.HostName ?? HostName, u.IPv4 ?? IPv4,
            u.Port ?? Port, u.Txt.Count > 0 ? u.Txt : Txt);

        public static Svc From(IReadOnlyDictionary<string, object> p)
        {
            var txt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (p.GetValueOrDefault("System.Devices.Dnssd.TextAttributes") is string[] attrs)
                foreach (var a in attrs)
                {
                    var eq = a.IndexOf('=');
                    if (eq > 0) txt[a[..eq]] = a[(eq + 1)..];
                }
            var ipv4 = (p.GetValueOrDefault("System.Devices.IpAddress") as string[] ?? [])
                .FirstOrDefault(a => IPAddress.TryParse(a, out var ip) && ip.AddressFamily == AddressFamily.InterNetwork);
            return new Svc(
                p.GetValueOrDefault("System.Devices.Dnssd.ServiceName") as string,
                p.GetValueOrDefault("System.Devices.Dnssd.InstanceName") as string,
                (p.GetValueOrDefault("System.Devices.Dnssd.HostName") as string)?.TrimEnd('.'),
                ipv4,
                p.GetValueOrDefault("System.Devices.Dnssd.PortNumber") is ushort port ? port : null,
                txt);
        }
    }

    private sealed record Aep(string Id, string? Name, string? Protocol, string? ContainerId, bool? IsPaired, bool? IsPresent, string? Model,
        string[]? Categories) : IMergeable<Aep>
    {
        public bool IsPrinter => Categories?.Any(c => c.StartsWith("PrintFax", StringComparison.Ordinal)) == true;
        public bool IsScanner => Categories?.Contains("Imaging.Scanner") == true;

        public Aep With(Aep u) => new(Id, u.Name ?? Name, u.Protocol ?? Protocol, u.ContainerId ?? ContainerId,
            u.IsPaired ?? IsPaired, u.IsPresent ?? IsPresent, u.Model ?? Model, u.Categories ?? Categories);

        public static Aep From(string id, string? name, IReadOnlyDictionary<string, object> p) => new(
            id, name,
            p.GetValueOrDefault("System.Devices.Aep.ProtocolId") is Guid g ? g.ToString("B") : null,
            p.GetValueOrDefault("System.Devices.Aep.ContainerId") is Guid c ? c.ToString("D") : null,
            p.GetValueOrDefault("System.Devices.Aep.IsPaired") as bool?,
            p.GetValueOrDefault("System.Devices.Aep.IsPresent") as bool?,
            p.GetValueOrDefault("System.Devices.Aep.ModelName") as string is { Length: > 0 } m ? m : null,
            p.GetValueOrDefault("System.Devices.Aep.Category") as string[]);
    }
}
