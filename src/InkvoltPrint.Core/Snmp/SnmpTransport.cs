using System.Net;
using System.Net.Sockets;

namespace InkvoltPrint.Core.Snmp;

/// <summary>Carries SNMP datagrams to a printer's agent: UDP port 161 (<see cref="UdpSnmpTransport"/>), or a made-up agent (<see cref="SnmpAgent"/>).</summary>
public interface ISnmpTransport
{
    /// <summary>Sends one request to <paramref name="host"/>'s agent; the first reply, or null when none came within <paramref name="timeout"/>.</summary>
    Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct);
}

/// <summary>
/// SNMP over UDP to port 161 (RFC 3417 §2), one socket per request, so a late reply to an earlier request never lands on a
/// later one. An ICMP "port unreachable" (no agent there) or an address that can't be resolved counts as no reply.
/// </summary>
public sealed class UdpSnmpTransport : ISnmpTransport
{
    public const int Port = 161;

    public static UdpSnmpTransport Instance { get; } = new();

    public async Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout);
        try
        {
            var address = IPAddress.TryParse(host.Trim('[', ']'), out var ip) ? ip
                : (await Dns.GetHostAddressesAsync(host, deadline.Token).ConfigureAwait(false))
                    .OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1).FirstOrDefault();
            if (address is null) return null;
            using var udp = new UdpClient(address.AddressFamily);
            udp.Connect(address, Port); // only datagrams from the agent's address and port are received
            await udp.SendAsync(request, deadline.Token).ConfigureAwait(false);
            return (await udp.ReceiveAsync(deadline.Token).ConfigureAwait(false)).Buffer;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return null; // timed out
        }
        catch (SocketException)
        {
            return null; // no agent (ICMP port unreachable), unreachable network, or a name that doesn't resolve
        }
    }
}

/// <summary>Several made-up agents behind one transport (demo mode): each request goes to its host's; other hosts never answer.</summary>
public sealed class SnmpRouter(IReadOnlyDictionary<string, ISnmpTransport> hosts) : ISnmpTransport
{
    private readonly Dictionary<string, ISnmpTransport> _hosts = new(hosts, StringComparer.OrdinalIgnoreCase);

    public Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct) =>
        _hosts.TryGetValue(host, out var agent) ? agent.SendAsync(host, request, timeout, ct) : Task.FromResult<byte[]?>(null);
}
