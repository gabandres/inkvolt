using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace InkvoltPrint.Core.Sharing;

/// <summary>One instance our own responder answers for: its subtype (<c>_universal</c>), service (<c>_ipp._tcp</c>), and the SRV, TXT and address that go with it.</summary>
public sealed record MdnsInstance(string Subtype, ShareAdvert Advert, IPAddress Address)
{
    public string SubtypeName => $"{Subtype}._sub.{Advert.Kind}.local";
    public string InstanceName => $"{Advert.Instance}.{Advert.Kind}.local";
}

/// <summary>
/// The few multicast DNS messages Inkvolt Print writes itself (roadmap 4.10): Windows' DNS-SD API registers no subtype, and iPhones look
/// for AirPrint printers under <c>_universal._sub._ipp._tcp</c>. Windows' responder keeps announcing the printer (its PTR, SRV, TXT and
/// address); this answers only a question for the subtype, with a PTR to the same instance and its SRV, TXT and address as additional
/// records (RFC 6762, RFC 6763 §7.1). Every packet read is hostile: at most <see cref="MaxPacket"/> bytes, <see cref="MaxQuestions"/>
/// questions, names of at most 255 bytes followed through at most 16 compression pointers, and anything that isn't a plain query
/// (a response, another opcode, a truncated packet) is ignored. Nothing here sends; the Windows side does, rate-limited.
/// </summary>
public static class MdnsSubtype
{
    /// <remarks>
    /// <see cref="MaxQuestions"/> is generous: an iPhone's printer browse asks after every printer it has met in the same packet (18
    /// questions with five, seen 2026-11-22), and a query past the limit is dropped unanswered. Each question takes at least 5 bytes, so
    /// <see cref="MaxPacket"/> bounds the work anyway; the limit only refuses a header that claims more than any query asks.
    /// </remarks>
    public const int MaxPacket = 9000, MaxQuestions = 256, Port = 5353;
    public static readonly IPAddress Group = IPAddress.Parse("224.0.0.251");

    private const ushort Ptr = 12, Txt = 16, Srv = 33, A = 1, Any = 255, In = 1;

    /// <summary>A question: the name asked (lower case, no trailing dot), its type, and whether it asks for a unicast answer (the QU bit).</summary>
    public readonly record struct Question(string Name, ushort Type, bool Unicast);

    /// <summary>The questions of a plain query; null for a packet that isn't one (or is malformed).</summary>
    public static IReadOnlyList<Question>? Questions(ReadOnlySpan<byte> packet)
    {
        if (packet.Length < 12 || packet.Length > MaxPacket) return null;
        var flags = BinaryPrimitives.ReadUInt16BigEndian(packet[2..]);
        if ((flags & 0x8000) != 0 || ((flags >> 11) & 0xF) != 0) return null; // a response, or not a standard query
        int count = BinaryPrimitives.ReadUInt16BigEndian(packet[4..]);
        if (count is 0 or > MaxQuestions) return null;
        var questions = new List<Question>(count);
        var at = 12;
        for (var i = 0; i < count; i++)
        {
            if (ReadName(packet, ref at) is not { } name || at + 4 > packet.Length) return null;
            var type = BinaryPrimitives.ReadUInt16BigEndian(packet[at..]);
            var cls = BinaryPrimitives.ReadUInt16BigEndian(packet[(at + 2)..]);
            at += 4;
            if ((cls & 0x7FFF) == In) questions.Add(new Question(name, type, (cls & 0x8000) != 0));
        }
        return questions;
    }

    /// <summary>A name at <paramref name="at"/> (moved past it), following compression pointers backwards only, at most 16; null if malformed.</summary>
    internal static string? ReadName(ReadOnlySpan<byte> packet, ref int at)
    {
        var labels = new StringBuilder();
        var position = at;
        var jumped = false;
        var jumps = 0;
        var length = 0;
        while (true)
        {
            if (position >= packet.Length) return null;
            var n = packet[position];
            if (n == 0)
            {
                if (!jumped) at = position + 1;
                return labels.ToString().ToLowerInvariant();
            }
            if ((n & 0xC0) == 0xC0)
            {
                if (position + 1 >= packet.Length || ++jumps > 16) return null;
                var target = ((n & 0x3F) << 8) | packet[position + 1];
                if (target >= position) return null; // only backwards: no loops
                if (!jumped) at = position + 2;
                jumped = true;
                position = target;
                continue;
            }
            if ((n & 0xC0) != 0 || position + 1 + n > packet.Length) return null;
            length += n + 1;
            if (length > 255) return null;
            if (labels.Length > 0) labels.Append('.');
            labels.Append(Encoding.UTF8.GetString(packet.Slice(position + 1, n)));
            position += 1 + n;
        }
    }

    /// <summary>Whether a question is one of ours: the subtype's PTR (or ANY) for an instance we answer for.</summary>
    public static bool Asks(Question q, MdnsInstance instance) =>
        q.Type is Ptr or Any && string.Equals(q.Name, instance.SubtypeName.ToLowerInvariant(), StringComparison.Ordinal);

    /// <summary>
    /// The answer to <paramref name="questions"/> for <paramref name="instances"/> (those on the interface the query came in on): a
    /// response with a PTR from the subtype to each instance asked about, and its SRV, TXT and A as additional records; null when nothing
    /// asked is ours. <paramref name="goodbye"/> writes the same with a TTL of 0 (the printer stops being shared).
    /// </summary>
    public static byte[]? Answer(IEnumerable<Question>? questions, IEnumerable<MdnsInstance> instances, bool goodbye = false)
    {
        var asked = questions is null ? instances.ToList() : instances.Where(i => questions.Any(q => Asks(q, i))).ToList();
        if (asked.Count == 0) return null;
        using var ms = new MemoryStream();
        Span<byte> header = stackalloc byte[12];
        BinaryPrimitives.WriteUInt16BigEndian(header[2..], 0x8400); // a response, authoritative
        BinaryPrimitives.WriteUInt16BigEndian(header[6..], (ushort)asked.Count);
        BinaryPrimitives.WriteUInt16BigEndian(header[10..], (ushort)(asked.Count * 3));
        ms.Write(header);
        uint longTtl = goodbye ? 0u : 4500, shortTtl = goodbye ? 0u : 120;
        foreach (var i in asked) Record(ms, i.SubtypeName, Ptr, false, longTtl, Name(i.InstanceName));
        foreach (var i in asked)
        {
            var srv = new byte[6];
            BinaryPrimitives.WriteUInt16BigEndian(srv.AsSpan(4), (ushort)i.Advert.Port);
            Record(ms, i.InstanceName, Srv, true, shortTtl, [.. srv, .. Name(i.Advert.Host)]);
            Record(ms, i.InstanceName, Txt, true, longTtl, TxtData(i.Advert.Txt));
            Record(ms, i.Advert.Host, A, false, shortTtl, i.Address.GetAddressBytes()); // no cache-flush: the host has other addresses Windows announces
        }
        return ms.Length <= MaxPacket ? ms.ToArray() : null;
    }

    /// <summary>A name in DNS form: each label (at most 63 bytes, cut between characters) after its length, then 0.</summary>
    internal static byte[] Name(string name)
    {
        var bytes = new List<byte>();
        foreach (var label in name.TrimEnd('.').Split('.'))
        {
            var b = Encoding.UTF8.GetBytes(label);
            if (b.Length > 63) b = b[..63];
            bytes.Add((byte)b.Length);
            bytes.AddRange(b);
        }
        bytes.Add(0);
        return [.. bytes];
    }

    private static byte[] TxtData(IReadOnlyList<KeyValuePair<string, string>> txt)
    {
        var data = new List<byte>();
        foreach (var (key, value) in txt)
        {
            var b = Encoding.UTF8.GetBytes($"{key}={value}");
            if (b.Length > 255) b = b[..255];
            data.Add((byte)b.Length);
            data.AddRange(b);
        }
        if (data.Count == 0) data.Add(0);
        return [.. data];
    }

    private static void Record(Stream s, string name, ushort type, bool unique, uint ttl, byte[] data)
    {
        s.Write(Name(name));
        Span<byte> fixedPart = stackalloc byte[10];
        BinaryPrimitives.WriteUInt16BigEndian(fixedPart, type);
        BinaryPrimitives.WriteUInt16BigEndian(fixedPart[2..], (ushort)(In | (unique ? 0x8000 : 0))); // cache-flush on the records only we own
        BinaryPrimitives.WriteUInt32BigEndian(fixedPart[4..], ttl);
        BinaryPrimitives.WriteUInt16BigEndian(fixedPart[8..], (ushort)data.Length);
        s.Write(fixedPart);
        s.Write(data);
    }

    /// <summary>The instances to answer with for a query from <paramref name="peer"/> that came in on interface <paramref name="interfaceIndex"/>: only on a served network, to a device on its subnet.</summary>
    public static IReadOnlyList<MdnsInstance> For(IEnumerable<(MdnsInstance Instance, LocalNetwork Network)> registered, IPAddress peer, int interfaceIndex) =>
        [.. registered.Where(r => r.Network.InterfaceIndex == interfaceIndex && r.Network.Address.AddressFamily == AddressFamily.InterNetwork
                                  && SharePeers.Allows(peer, r.Network.Address, [r.Network]))
            .Select(r => r.Instance)];
}
