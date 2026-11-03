using InkvoltPrint.Core.Discovery;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Windows.Discovery;

namespace InkvoltPrint.App.ViewModels;

/// <summary>What the Add a printer window asks of the printer list (<see cref="AddPrinterViewModel"/>).</summary>
public partial class MainViewModel
{
    /// <summary>Why printers can't be added here (null: they can).</summary>
    public string? AddPrinterOff => _pc.AddByAddressOff;

    /// <summary>Printers mDNS or WSD finds now that were removed from the list: they can be put back.</summary>
    public IReadOnlyList<DiscoveredPrinter> RemovedNearby() =>
        _discovery?.Snapshot().Where(d => d.Host is not null && PrinterId.IsValid(d.Uuid) && _state.IsForgotten(d.Uuid)).ToList() ?? [];

    /// <summary>Puts a printer removed earlier back on the list (discovery lists it again at once).</summary>
    public PrinterViewModel? AddBack(DiscoveredPrinter d)
    {
        _state.Unforget([d.Uuid]);
        _state.Save();
        if (_discovery is not null) Merge(_discovery.Snapshot());
        var vm = Printers.FirstOrDefault(p => p.IsKnownAs(d.Uuid));
        if (vm is not null) ShowPrinter(vm);
        return vm;
    }

    /// <summary>Searches the networks this PC is on; <paramref name="found"/> for each address that may be a printer (any thread).</summary>
    public Task SearchNetworkAsync(Action<string> found, IProgress<SearchProgress>? progress, CancellationToken ct)
    {
        SearchAgain(); // mDNS and WSD look again too: a printer that just woke up shows by itself
        return _pc.SearchNetworkAsync(found, progress, ct);
    }

    /// <summary>
    /// Asks the device at <paramref name="host"/> what it is (LEDM, CDM, IPP at <paramref name="ipp"/> or the default, eSCL, SNMP
    /// with <paramref name="snmpLogin"/>, public when null).
    /// </summary>
    public async Task<ProbeResult> IdentifyAsync(string host, Uri? ipp, CancellationToken ct, SnmpLogin? snmpLogin = null)
    {
        using var http = new Core.Net.DeviceHttp(host, _pc.DeviceTransport());
        return await PrinterConnection.ProbeAsync(http, ct: ct, ippHint: ipp, snmp: _pc.Snmp, snmpLogin: snmpLogin);
    }

    /// <summary>The listed printer this is (same UUID, or the same address for one without), or null.</summary>
    public PrinterViewModel? Listed(ProbeResult probe, string host)
    {
        var id = PrinterId.Normalize(probe.Uuid, host);
        return Printers.FirstOrDefault(p => p.IsKnownAs(id) || string.Equals(p.Host, host, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Lists, remembers and selects the printer that answered at <paramref name="host"/> (see <see cref="IdentifyAsync"/>).</summary>
    /// <remarks>
    /// A printer read over SNMP keeps the login it answered to (<see cref="SnmpIdentity.Login"/>) in Credential Manager, never
    /// in state.json; one that answered HTTP has no use for it.
    /// </remarks>
    public PrinterViewModel Add(ProbeResult probe, string host)
    {
        var uuid = PrinterId.Normalize(probe.Uuid, host);
        if (probe.Snmp is { } answered) KeepSnmpLogin(uuid, answered.LoginOrPublic);
        _state.Unforget([uuid]);
        var vm = Printers.FirstOrDefault(p => string.Equals(p.Uuid, uuid, StringComparison.OrdinalIgnoreCase));
        // Answering only SNMP now makes it an SNMP-only printer (it's asked over HTTP again later, in case it was asleep).
        var snmpOnly = probe.Snmp is { } snmp ? SnmpDevice.From(snmp) : null;
        if (vm is null)
        {
            vm = new PrinterViewModel(uuid, probe.Model ?? host, probe.Model, host, probe.EsclRoot, _state, Presets, Remember, _pc)
                { IppUri = probe.IppEndpoint, SnmpDevice = snmpOnly };
            Printers.Add(vm);
            vm.Start();
            NotifyEmpty();
        }
        else vm.SnmpDevice ??= snmpOnly;
        Remember(vm);
        ShowPrinter(vm);
        Reconcile(queues: true);
        return vm;
    }

    /// <summary>Keeps a printer's SNMP login (public: nothing kept). Credential Manager may refuse: said in the log, without the login.</summary>
    public bool KeepSnmpLogin(string uuid, SnmpLogin login)
    {
        try
        {
            _pc.SnmpLogins.Save(uuid, login);
            return true;
        }
        catch (Exception ex)
        {
            Log.Write($"The SNMP community couldn't be kept in Credential Manager: {ex.GetType().Name}");
            return false;
        }
    }
}
