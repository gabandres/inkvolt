using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Snmp;

/// <summary>Who answered over SNMP: the version it speaks, its printer's hrDeviceIndex, and what it says about itself.</summary>
public sealed record SnmpIdentity(SnmpVersion Version, uint DeviceIndex, string? DeviceDescription, string? SystemDescription,
    string? SystemName, string? Location, string? SerialNumber, string Community = SnmpClient.DefaultCommunity)
{
    /// <summary>The model: hrDeviceDescr ("Brand Model"), else the first line of sysDescr (often model plus firmware).</summary>
    public string? Model => DeviceDescription ?? (SystemDescription?.Split('\n', ';')[0].Trim() is { Length: > 0 } s ? s : null);
}

/// <summary>
/// A printer's status and supplies over SNMP (read only): Host Resources MIB and Printer MIB objects of the printer's
/// hrDeviceIndex. Status and supplies come from one read, shared for a moment, since the connection asks for both at once.
/// </summary>
public sealed class SnmpPrinterClient
{
    private readonly SnmpClient _client;
    private readonly object _gate = new();
    private Task<SnmpReading>? _read;
    private DateTime _readAt;
    private IReadOnlyDictionary<int, string>? _colorants;

    /// <summary>How long one read serves both the status and the supplies.</summary>
    internal static readonly TimeSpan Shared = TimeSpan.FromSeconds(2);

    public SnmpPrinterClient(ISnmpTransport transport, string host, SnmpIdentity identity, TimeSpan? timeout = null)
    {
        Identity = identity;
        _client = new SnmpClient(transport, host, identity.Version, identity.Community) { Timeout = timeout ?? ProbeTimeout };
    }

    public SnmpIdentity Identity { get; }
    public string Host => _client.Host;

    /// <summary>How long a probe waits for each reply (it asks over v2c and v1 at once, and once more on silence).</summary>
    public static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(1);

    /// <summary>
    /// Asks <paramref name="host"/> over SNMP whether it is a printer: one GetNext of the system description, name and location
    /// and of hrPrinterStatus, over v2c and v1 at once (v2c kept when both answer). Only an agent with a Host Resources printer
    /// entry counts (a router or a PC answering "public" isn't a printer). Then its model and serial number. Null when nothing
    /// answers, or it isn't a printer.
    /// </summary>
    public static async Task<SnmpPrinterClient?> ProbeAsync(ISnmpTransport transport, string host, string community = SnmpClient.DefaultCommunity,
        CancellationToken ct = default)
    {
        using var loser = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var v2 = TryProbe(SnmpVersion.V2c);
        var v1 = TryProbe(SnmpVersion.V1);
        SnmpIdentity? found;
        var first = await Task.WhenAny(v2, v1).ConfigureAwait(false);
        if (first == v2 && v2.Result is { } a) found = a;
        else if (first == v1 && v1.Result is { } b)
        {
            // v1 answered first: a v2c agent's reply is usually right behind it.
            await Task.WhenAny(v2, Task.Delay(300, ct)).ConfigureAwait(false);
            found = v2.IsCompletedSuccessfully && v2.Result is { } c ? c : b;
        }
        else found = await (first == v2 ? v1 : v2).ConfigureAwait(false);
        await loser.CancelAsync().ConfigureAwait(false);
        await Task.WhenAll(v2, v1).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return found is null ? null : new SnmpPrinterClient(transport, host, found);

        async Task<SnmpIdentity?> TryProbe(SnmpVersion version)
        {
            try
            {
                var client = new SnmpClient(transport, host, version, community) { Timeout = ProbeTimeout };
                var next = await client.GetNextAsync([PrinterMib.SysDescr, PrinterMib.SysName, PrinterMib.SysLocation, PrinterMib.HrPrinterStatus], loser.Token)
                    .ConfigureAwait(false);
                if (next[3].Value.IsException || next[3].Name.After(PrinterMib.HrPrinterStatus) is not [var index]) return null;
                string? Text(int i, Oid column) => next[i].Name.After(column) is [0] ? next[i].Value.Text : null;
                var more = await client.GetAsync([PrinterMib.HrDeviceDescr.Append(index), PrinterMib.PrtGeneralSerialNumber.Append(index)], loser.Token)
                    .ConfigureAwait(false);
                return new SnmpIdentity(version, index, more[0].Value.Text, Text(0, PrinterMib.SysDescr), Text(1, PrinterMib.SysName),
                    Text(2, PrinterMib.SysLocation), more[1].Value.Text, community);
            }
            catch (Exception ex) when (ex is TimeoutException or FormatException or SnmpErrorException or OperationCanceledException)
            {
                return null;
            }
        }
    }

    /// <summary>The printer's status objects now (or from a read a moment ago).</summary>
    public Task<SnmpReading> ReadAsync(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_read is not null && DateTime.UtcNow - _readAt < Shared && !_read.IsFaulted && !_read.IsCanceled) return _read;
            _readAt = DateTime.UtcNow;
            return _read = ReadNowAsync(ct);
        }
    }

    public async Task<PrinterStatus> GetStatusAsync(CancellationToken ct = default) => SnmpPrinterStatus.ToStatus(await ReadAsync(ct).ConfigureAwait(false));

    public async Task<IReadOnlyList<Consumable>> GetSuppliesAsync(CancellationToken ct = default) =>
        SnmpPrinterStatus.ToConsumables(await ReadAsync(ct).ConfigureAwait(false));

    /// <summary>A read now, not shared (callers that keep their own pace: a queue printer's status).</summary>
    internal async Task<SnmpReading> ReadNowAsync(CancellationToken ct)
    {
        var i = Identity.DeviceIndex;
        var state = await _client.GetAsync([PrinterMib.HrDeviceStatus.Append(i), PrinterMib.HrPrinterStatus.Append(i), PrinterMib.HrPrinterDetectedErrorState.Append(i)], ct)
            .ConfigureAwait(false);
        var alertColumns = new[] { PrinterMib.AlertSeverity, PrinterMib.AlertGroup, PrinterMib.AlertGroupIndex, PrinterMib.AlertCode, PrinterMib.AlertDescription };
        var alerts = Rows(await _client.WalkAsync(alertColumns.Select(c => c.Append(i)).ToList(), ct).ConfigureAwait(false));
        var supplyColumns = new[] { PrinterMib.SuppliesClass, PrinterMib.SuppliesType, PrinterMib.SuppliesDescription, PrinterMib.SuppliesMaxCapacity,
            PrinterMib.SuppliesLevel, PrinterMib.SuppliesColorantIndex };
        var supplies = Rows(await _client.WalkAsync(supplyColumns.Select(c => c.Append(i)).ToList(), ct).ConfigureAwait(false));
        // Colorants belong to the marker, not the cartridge in it: read once.
        _colorants ??= Rows(await _client.WalkAsync([PrinterMib.ColorantValue.Append(i)], ct).ConfigureAwait(false))
            .Where(r => r.Value[0]?.Text is not null).ToDictionary(r => r.Key, r => r.Value[0]!.Text!);

        return new SnmpReading(
            state[0].Value.Int,
            state[1].Value.Int,
            state[2].Value.Bytes ?? [],
            alerts.Select(r => new SnmpAlert(r.Key, Int(r.Value[0]), Int(r.Value[1]), Int(r.Value[2], -1), Int(r.Value[3]), r.Value[4]?.Text)).ToList(),
            supplies.Select(r => new SnmpSupply(r.Key, Int(r.Value[0]), Int(r.Value[1]), r.Value[2]?.Text, Int(r.Value[3], -2), Int(r.Value[4], -2), Int(r.Value[5])))
                .ToList(),
            _colorants);

        static int Int(SnmpValue? v, int missing = 0) => v?.Int ?? missing;
    }

    /// <summary>Columns walked side by side → rows by their (single-arc) index, each with its value per column (null where missing).</summary>
    private static SortedDictionary<int, SnmpValue?[]> Rows(IReadOnlyList<IReadOnlyList<(uint[] Index, SnmpValue Value)>> columns)
    {
        var rows = new SortedDictionary<int, SnmpValue?[]>();
        for (var c = 0; c < columns.Count; c++)
            foreach (var (index, value) in columns[c])
            {
                if (index is not [var row] || row > int.MaxValue) continue;
                if (!rows.TryGetValue((int)row, out var cells)) rows[(int)row] = cells = new SnmpValue?[columns.Count];
                cells[c] = value;
            }
        return rows;
    }
}
