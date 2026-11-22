using System.Net;
using System.Net.Sockets;
using InkvoltPrint.Core.Sharing;

namespace InkvoltPrint.Windows.Sharing;

/// <summary>
/// Answers the DNS-SD subtypes Windows' own responder can't register (AirPrint's <c>_universal._sub._ipp._tcp</c>, roadmap 4.10), beside
/// it: one UDP socket on port 5353 shared with Windows (SO_REUSEADDR), joined to the mDNS group on each private interface a shared printer
/// is announced on, only while one is. What to answer is <see cref="MdnsSubtype"/>'s: a query for the subtype, from a device on that
/// interface's subnet, gets a PTR to the instance Windows announces, with its SRV, TXT and address; every other packet is dropped. At most
/// one answer a second per interface (RFC 6762 §6), ten a second in all. Each printer is announced twice when added and said goodbye to
/// (TTL 0) when removed. Nothing is sent on a public network.
/// </summary>
public sealed class MdnsSubtypeResponder : IDisposable
{
    private readonly Action<string> _log;
    private readonly Lock _gate = new();
    private readonly List<(MdnsInstance Instance, LocalNetwork Network)> _registered = [];
    private readonly Dictionary<int, DateTime> _lastAnswer = [];
    private readonly Queue<DateTime> _recent = new();
    private Socket? _socket;
    private CancellationTokenSource? _loop;
    private readonly HashSet<int> _joined = [];

    public MdnsSubtypeResponder(Action<string>? log = null) => _log = log ?? (_ => { });

    /// <summary>Answers for <paramref name="advert"/>'s subtypes on <paramref name="on"/> (their IPv4 addresses) until the result is disposed.</summary>
    public IDisposable Add(ShareAdvert advert, IReadOnlyList<LocalNetwork> on)
    {
        var added = new List<(MdnsInstance, LocalNetwork)>();
        foreach (var network in on.Where(n => n.Address.AddressFamily == AddressFamily.InterNetwork).GroupBy(n => n.InterfaceIndex).Select(g => g.First()))
            foreach (var subtype in advert.Subtypes)
                added.Add((new MdnsInstance(subtype, advert, network.Address), network));
        if (added.Count == 0) return new Removal(this, []);
        lock (_gate)
        {
            _registered.AddRange(added);
            try
            {
                Start();
            }
            catch (SocketException ex)
            {
                _log($"Printer sharing: AirPrint's subtype not answered (port 5353: {ex.SocketErrorCode}).");
            }
            // Every interface registered so far, each on its own: one that refuses (its address just went) doesn't keep the others
            // out, and is tried again with the next printer added or network change.
            foreach (var index in _registered.Select(r => r.Network.InterfaceIndex).Distinct()) Join(index);
        }
        _ = AnnounceAsync(added);
        return new Removal(this, added);
    }

    /// <summary>Starts the socket and its loop. Inside <see cref="_gate"/>.</summary>
    private void Start()
    {
        if (_socket is not null) return;
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true); // beside Windows' own responder
            socket.Bind(new IPEndPoint(IPAddress.Any, MdnsSubtype.Port));
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.PacketInformation, true);
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastLoopback, true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
        _socket = socket;
        _joined.Clear();
        _loop = new CancellationTokenSource();
        _ = ReceiveAsync(socket, _loop.Token);
    }

    private void Join(int interfaceIndex)
    {
        if (_socket is null || !_joined.Add(interfaceIndex)) return;
        try
        {
            _socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership, new MulticastOption(MdnsSubtype.Group, interfaceIndex));
        }
        catch (SocketException ex)
        {
            _joined.Remove(interfaceIndex); // tried again next time
            _log($"Printer sharing: an interface didn't join the mDNS group ({ex.SocketErrorCode}).");
        }
    }

    private async Task ReceiveAsync(Socket socket, CancellationToken ct)
    {
        var buffer = new byte[MdnsSubtype.MaxPacket];
        var backoff = TimeSpan.Zero;
        var bad = 0;
        while (!ct.IsCancellationRequested)
        {
            SocketReceiveMessageFromResult received;
            try
            {
                received = await socket.ReceiveMessageFromAsync(buffer, SocketFlags.None, new IPEndPoint(IPAddress.Any, 0), ct).ConfigureAwait(false);
                backoff = TimeSpan.Zero;
                bad = 0;
            }
            catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException)
            {
                return;
            }
            catch (SocketException ex)
            {
                try
                {
                    if (ex.SocketErrorCode is SocketError.MessageSize or SocketError.ConnectionReset && ++bad < 64) continue; // one bad datagram: the next
                    // The network itself (down, gone after sleep), or bad datagrams without end: wait, longer each time, up to a minute.
                    backoff = backoff == TimeSpan.Zero ? TimeSpan.FromSeconds(1) : TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, TimeSpan.FromMinutes(1).Ticks));
                    bad = 0;
                    if (backoff == TimeSpan.FromSeconds(1)) _log($"Printer sharing: mDNS answers paused ({ex.SocketErrorCode}).");
                    await Task.Delay(backoff, ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                continue;
            }
            try
            {
                Answer(socket, buffer.AsSpan(0, received.ReceivedBytes), (IPEndPoint)received.RemoteEndPoint, received.PacketInformation.Interface);
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException or ArgumentException)
            {
                // not answered: the next query asks again
            }
        }
    }

    private void Answer(Socket socket, ReadOnlySpan<byte> packet, IPEndPoint from, int interfaceIndex)
    {
        if (MdnsSubtype.Questions(packet) is not { Count: > 0 } questions) return;
        List<MdnsInstance> instances;
        lock (_gate) instances = [.. MdnsSubtype.For(_registered, from.Address, interfaceIndex)];
        if (MdnsSubtype.Answer(questions, instances) is not { } answer || !MayAnswer(interfaceIndex)) return;
        if (questions.Any(q => q.Unicast) && from.Port == MdnsSubtype.Port) socket.SendTo(answer, from); // QU: to the asker alone
        else Send(socket, answer, interfaceIndex);
    }

    /// <summary>One answer a second per interface, ten a second in all.</summary>
    private bool MayAnswer(int interfaceIndex)
    {
        var now = DateTime.UtcNow;
        lock (_gate)
        {
            if (_lastAnswer.TryGetValue(interfaceIndex, out var last) && now - last < TimeSpan.FromSeconds(1)) return false;
            while (_recent.Count > 0 && now - _recent.Peek() > TimeSpan.FromSeconds(1)) _recent.Dequeue();
            if (_recent.Count >= 10) return false;
            _recent.Enqueue(now);
            _lastAnswer[interfaceIndex] = now;
            return true;
        }
    }

    /// <summary>To the mDNS group, out of one interface.</summary>
    private void Send(Socket socket, byte[] packet, int interfaceIndex)
    {
        lock (_gate)
        {
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, IPAddress.HostToNetworkOrder(interfaceIndex));
            socket.SendTo(packet, new IPEndPoint(MdnsSubtype.Group, MdnsSubtype.Port));
        }
    }

    /// <summary>Two announcements a second apart (RFC 6762 §8.3), per interface.</summary>
    private async Task AnnounceAsync(List<(MdnsInstance Instance, LocalNetwork Network)> added)
    {
        try
        {
            for (var i = 0; i < 2; i++)
            {
                if (i > 0) await Task.Delay(TimeSpan.FromSeconds(1)).ConfigureAwait(false);
                Broadcast(added, goodbye: false);
            }
        }
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
        {
            // not announced: queries are still answered
        }
    }

    private void Broadcast(List<(MdnsInstance Instance, LocalNetwork Network)> records, bool goodbye)
    {
        Socket? socket;
        lock (_gate) socket = _socket;
        if (socket is null) return;
        foreach (var group in records.GroupBy(r => r.Network.InterfaceIndex))
            if (MdnsSubtype.Answer(null, group.Select(r => r.Instance), goodbye) is { } packet) Send(socket, packet, group.Key);
    }

    private void Remove(List<(MdnsInstance Instance, LocalNetwork Network)> records)
    {
        try
        {
            Broadcast(records, goodbye: true);
        }
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
        {
            // gone anyway: caches drop it after its TTL
        }
        lock (_gate)
        {
            foreach (var r in records) _registered.Remove(r);
            if (_registered.Count == 0) Stop();
        }
    }

    /// <summary>Inside <see cref="_gate"/>.</summary>
    private void Stop()
    {
        _loop?.Cancel();
        _loop?.Dispose();
        _loop = null;
        _socket?.Dispose();
        _socket = null;
        _joined.Clear();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _registered.Clear();
            Stop();
        }
    }

    private sealed class Removal(MdnsSubtypeResponder owner, List<(MdnsInstance, LocalNetwork)> records) : IDisposable
    {
        private int _done;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) == 0 && records.Count > 0) owner.Remove(records);
        }
    }
}
