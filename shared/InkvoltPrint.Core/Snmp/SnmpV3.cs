using System.Security.Cryptography;
using System.Text;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// An SNMPv3 user (RFC 3414's User-based Security Model) as Inkvolt Print signs in with it: authPriv only, authentication
/// HMAC-SHA-256 truncated to 192 bits (usmHMAC192SHA256AuthProtocol, RFC 7860), privacy AES-128 in CFB mode (usmAesCfb128Protocol,
/// RFC 3826). The passphrases are secrets: kept with the <see cref="SnmpLogin"/> in Credential Manager; <see cref="ToString"/> shows neither.
/// </summary>
public sealed record SnmpV3User(string Name, string AuthPassphrase, string PrivPassphrase)
{
    /// <summary>RFC 3414 §11.2: shorter passphrases make weak keys; net-snmp refuses them too.</summary>
    public const int MinPassphrase = 8;

    /// <summary>The longest user name (RFC 3414 usmUserName: SnmpAdminString (SIZE(1..32))).</summary>
    public const int MaxName = 32;

    public override string ToString() => $"SNMPv3 user {Name} (SHA-256, AES-128; keys kept)";
}

/// <summary>
/// The User-based Security Model's cryptography (RFC 3414 §2.6 and A.2, RFC 7860, RFC 3826), with .NET's own SHA-256, HMAC and AES
/// only. Keys are localized to one agent's engine ID, so a key read off one printer is no use on another.
/// </summary>
public static class Usm
{
    /// <summary>usmHMAC192SHA256AuthProtocol's msgAuthenticationParameters: the first 24 bytes of HMAC-SHA-256 (RFC 7860 §4.2.1).</summary>
    public const int AuthLength = 24;

    /// <summary>usmAesCfb128Protocol's msgPrivacyParameters: the 64-bit salt (RFC 3826 §3.1.2.1).</summary>
    public const int SaltLength = 8;

    /// <summary>RFC 3414 A.2.1 (A.2.2 for SHA-1; RFC 7860 §4.2.2 the same with SHA-2): the passphrase repeated to 1 MiB, hashed.</summary>
    public static byte[] PasswordToKey(string passphrase, HashAlgorithmName hash)
    {
        var password = Encoding.UTF8.GetBytes(passphrase);
        if (password.Length == 0) throw new ArgumentException("An empty passphrase makes no key.", nameof(passphrase));
        using var h = IncrementalHash.CreateHash(hash);
        var chunk = new byte[64];
        var index = 0;
        for (var count = 0; count < 1_048_576; count += chunk.Length)
        {
            for (var i = 0; i < chunk.Length; i++) chunk[i] = password[index++ % password.Length];
            h.AppendData(chunk);
        }
        return h.GetHashAndReset();
    }

    /// <summary>RFC 3414 §2.6: Kul = H(Ku | engineID | Ku).</summary>
    public static byte[] Localize(byte[] ku, ReadOnlySpan<byte> engineId, HashAlgorithmName hash)
    {
        using var h = IncrementalHash.CreateHash(hash);
        h.AppendData(ku);
        h.AppendData(engineId);
        h.AppendData(ku);
        return h.GetHashAndReset();
    }

    /// <summary>usmHMAC192SHA256AuthProtocol over a whole message whose msgAuthenticationParameters are 24 zero bytes.</summary>
    public static byte[] Authenticate(byte[] key, ReadOnlySpan<byte> message) => HMACSHA256.HashData(key, message)[..AuthLength];

    /// <summary>RFC 3826 §3.1.2.1: the IV is engine boots (4 bytes), engine time (4 bytes) and the salt, each big-endian.</summary>
    public static byte[] AesIv(int boots, int time, ReadOnlySpan<byte> salt)
    {
        if (salt.Length != SaltLength) throw new ArgumentException("The salt is 8 bytes.", nameof(salt));
        var iv = new byte[16];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(iv, boots);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(iv.AsSpan(4), time);
        salt.CopyTo(iv.AsSpan(8));
        return iv;
    }

    /// <summary>
    /// AES-128 in CFB mode with 128-bit feedback (RFC 3826 §3.1.3), any length: no padding is sent, so a short last block is
    /// filled with zeros for .NET and cut off again (CFB's last bytes depend only on what comes before them).
    /// </summary>
    public static byte[] AesCfb(ReadOnlySpan<byte> key, byte[] iv, ReadOnlySpan<byte> data, bool encrypt)
    {
        using var aes = Aes.Create();
        aes.Key = key[..16].ToArray();
        var whole = new byte[(data.Length + 15) / 16 * 16];
        data.CopyTo(whole);
        var result = encrypt ? aes.EncryptCfb(whole, iv, PaddingMode.None, 128) : aes.DecryptCfb(whole, iv, PaddingMode.None, 128);
        return result[..data.Length];
    }

    /// <summary>A user's two keys localized to one engine (the privacy key from the same hash, RFC 3826 §1.2), worked out once.</summary>
    public sealed class Keys(byte[] auth, byte[] priv)
    {
        public byte[] Auth { get; } = auth;
        public byte[] Priv { get; } = priv;

        public static Keys For(SnmpV3User user, ReadOnlySpan<byte> engineId) => new(
            Localize(PasswordToKey(user.AuthPassphrase, HashAlgorithmName.SHA256), engineId, HashAlgorithmName.SHA256),
            Localize(PasswordToKey(user.PrivPassphrase, HashAlgorithmName.SHA256), engineId, HashAlgorithmName.SHA256));
    }

    // RFC 3414 §5 usmStats counters an agent reports instead of answering: which tells the manager what went wrong.
    public static readonly Oid UnsupportedSecLevels = Oid.Parse("1.3.6.1.6.3.15.1.1.1.0");
    public static readonly Oid NotInTimeWindows = Oid.Parse("1.3.6.1.6.3.15.1.1.2.0");
    public static readonly Oid UnknownUserNames = Oid.Parse("1.3.6.1.6.3.15.1.1.3.0");
    public static readonly Oid UnknownEngineIds = Oid.Parse("1.3.6.1.6.3.15.1.1.4.0");
    public static readonly Oid WrongDigests = Oid.Parse("1.3.6.1.6.3.15.1.1.5.0");
    public static readonly Oid DecryptionErrors = Oid.Parse("1.3.6.1.6.3.15.1.1.6.0");

    /// <summary>RFC 3414 §2.2.3: a message's time may differ from the engine's by this much.</summary>
    public const int TimeWindow = 150;
}

/// <summary>Why an SNMPv3 agent refused a request (an RFC 3414 report): told apart, so the user hears which part is wrong.</summary>
public enum SnmpRefusal { UnknownUser, WrongAuthKey, WrongPrivKey, SecurityLevel }

/// <summary>An SNMPv3 agent refused the user or its keys (<see cref="Reason"/>). The message names neither.</summary>
public sealed class SnmpAccessException(SnmpRefusal reason) : Exception(Words(reason))
{
    public SnmpRefusal Reason { get; } = reason;

    private static string Words(SnmpRefusal reason) => reason switch
    {
        SnmpRefusal.UnknownUser => "The printer doesn't know this SNMPv3 user name.",
        SnmpRefusal.WrongAuthKey => "The printer refused the SNMPv3 authentication passphrase.",
        SnmpRefusal.WrongPrivKey => "The printer couldn't read the request: check the SNMPv3 privacy passphrase.",
        _ => "The printer doesn't take SNMPv3 with authentication and privacy (SHA-256, AES-128) for this user.",
    };
}

/// <summary>
/// An SNMPv3 message (RFC 3412 §6, RFC 3414 §2.4): header, USM security parameters, and the scoped PDU, in clear or encrypted.
/// <see cref="Encode"/> writes it; <see cref="Sign"/> puts the digest in; <see cref="Decode"/> reads one and says where its digest is,
/// so it can be checked over the very bytes that came.
/// </summary>
public sealed record SnmpV3Message
{
    public const byte FlagAuth = 0x01, FlagPriv = 0x02, FlagReportable = 0x04;

    /// <summary>The largest message this manager takes (RFC 3412 msgMaxSize; also what UDP gives a printer's reply).</summary>
    public const int MaxSize = 65507;

    public required int MessageId { get; init; }
    public int MaxMessageSize { get; init; } = MaxSize;
    public required byte Flags { get; init; }
    public byte[] EngineId { get; init; } = [];
    public int EngineBoots { get; init; }
    public int EngineTime { get; init; }
    public string UserName { get; init; } = "";

    /// <summary>The digest; <see cref="Usm.AuthLength"/> zero bytes before <see cref="Sign"/>, empty without authentication.</summary>
    public byte[] AuthParameters { get; init; } = [];

    /// <summary>The AES salt; empty without privacy.</summary>
    public byte[] PrivParameters { get; init; } = [];

    /// <summary>The scoped PDU in clear: contextEngineID, contextName, PDU (null when <see cref="Encrypted"/>).</summary>
    public byte[]? ContextEngineId { get; init; }
    public string ContextName { get; init; } = "";
    public SnmpMessage? Pdu { get; init; }

    /// <summary>The scoped PDU encrypted (privacy): its BER, AES-CFB encrypted.</summary>
    public byte[]? Encrypted { get; init; }

    /// <summary>Where the digest's 24 bytes are in the bytes <see cref="Decode"/> read (-1: no digest).</summary>
    public int AuthOffset { get; private init; } = -1;

    public bool Authenticated => (Flags & FlagAuth) != 0;
    public bool Private => (Flags & FlagPriv) != 0;

    /// <summary>The scoped PDU's BER (what privacy encrypts).</summary>
    public static byte[] EncodeScoped(byte[] contextEngineId, string contextName, SnmpMessage pdu) =>
        Ber.Constructed(Ber.Sequence, Ber.Octets(contextEngineId), Ber.Octets(Encoding.UTF8.GetBytes(contextName)), pdu.EncodePdu());

    /// <summary>A scoped PDU as <see cref="EncodeScoped"/> writes it. <see cref="FormatException"/> for anything else (a wrong privacy key's output).</summary>
    public static (byte[] ContextEngineId, string ContextName, SnmpMessage Pdu) DecodeScoped(byte[] data)
    {
        var r = new Ber.Reader(data);
        var scoped = r.Enter(Ber.Sequence);
        if (r.HasMore) throw new FormatException("SNMPv3: data after the scoped PDU.");
        return ReadScoped(data, scoped);
    }

    private static (byte[] ContextEngineId, string ContextName, SnmpMessage Pdu) ReadScoped(byte[] data, Ber.Reader scoped)
    {
        var engine = scoped.ReadOctets();
        var name = Encoding.UTF8.GetString(scoped.ReadOctets());
        var pdu = SnmpMessage.DecodePdu(data, scoped, SnmpVersion.V3, "");
        if (scoped.HasMore) throw new FormatException("SNMPv3: data after the PDU.");
        return (engine, name, pdu);
    }

    /// <summary>The message's bytes, the digest as it is in <see cref="AuthParameters"/>; and where that digest is in them.</summary>
    public (byte[] Bytes, int AuthOffset) EncodeWithOffset()
    {
        var header = Ber.Constructed(Ber.Sequence, Ber.Integer32(MessageId), Ber.Integer32(MaxMessageSize), Ber.Octets([Flags]), Ber.Integer32(3));
        var beforeAuth = Ber.Octets(EngineId).Concat(Ber.Integer32(EngineBoots)).Concat(Ber.Integer32(EngineTime))
            .Concat(Ber.Octets(Encoding.UTF8.GetBytes(UserName))).ToArray();
        var auth = Ber.Octets(AuthParameters);
        var usmContent = beforeAuth.Concat(auth).Concat(Ber.Octets(PrivParameters)).ToArray();
        var usm = Ber.Tlv(Ber.Sequence, usmContent);
        var security = Ber.Octets(usm);
        var data = Encrypted is { } e ? Ber.Octets(e)
            : EncodeScoped(ContextEngineId ?? throw new InvalidOperationException("No scoped PDU."), ContextName, Pdu ?? throw new InvalidOperationException("No scoped PDU."));
        var version = Ber.Integer32(3);
        var body = version.Concat(header).Concat(security).Concat(data).ToArray();
        var message = Ber.Tlv(Ber.Sequence, body);
        // The digest's place: the outer header, version, header, the security OCTET STRING's and USM SEQUENCE's headers, then the USM fields before it.
        var offset = message.Length - body.Length + version.Length + header.Length + (security.Length - usm.Length) + (usm.Length - usmContent.Length)
                     + beforeAuth.Length + (auth.Length - AuthParameters.Length);
        return (message, AuthParameters.Length == 0 ? -1 : offset);
    }

    public byte[] Encode() => EncodeWithOffset().Bytes;

    /// <summary>The message signed with <paramref name="authKey"/>: its digest over the bytes with 24 zero bytes in its place.</summary>
    public byte[] Sign(byte[] authKey)
    {
        var (bytes, offset) = (this with { AuthParameters = new byte[Usm.AuthLength] }).EncodeWithOffset();
        Usm.Authenticate(authKey, bytes).CopyTo(bytes, offset);
        return bytes;
    }

    /// <summary>True when <paramref name="bytes"/> (as <see cref="Decode"/> read them) carry the right digest for <paramref name="authKey"/>.</summary>
    public bool Verify(byte[] bytes, byte[] authKey)
    {
        if (!Authenticated || AuthOffset < 0 || AuthParameters.Length != Usm.AuthLength) return false;
        var zeroed = (byte[])bytes.Clone();
        Array.Clear(zeroed, AuthOffset, Usm.AuthLength);
        return CryptographicOperations.FixedTimeEquals(Usm.Authenticate(authKey, zeroed), AuthParameters);
    }

    /// <summary>True when <paramref name="data"/> is an SNMPv3 message (its version says 3), without reading the rest.</summary>
    public static bool IsV3(byte[] data)
    {
        try { return new Ber.Reader(data).Enter(Ber.Sequence).ReadInteger() == 3; }
        catch (FormatException) { return false; }
    }

    /// <summary>A v3 message from the network; <see cref="FormatException"/> for anything else (only the USM, security model 3, is spoken).</summary>
    public static SnmpV3Message Decode(byte[] data)
    {
        var outer = new Ber.Reader(data);
        var message = outer.Enter(Ber.Sequence);
        if (message.ReadInteger() != 3) throw new FormatException("SNMP: not a v3 message.");
        var header = message.Enter(Ber.Sequence);
        var id = Int(header.ReadInteger());
        var max = Int(header.ReadInteger());
        var flags = header.ReadOctets();
        if (flags.Length != 1) throw new FormatException("SNMPv3: msgFlags is one byte.");
        if (header.ReadInteger() != 3) throw new FormatException("SNMPv3: only the User-based Security Model is spoken.");
        var (st, ss, sl) = message.Next();
        if (st != Ber.OctetString) throw new FormatException("SNMPv3: security parameters expected.");
        var usm = new Ber.Reader(data, ss, ss + sl).Enter(Ber.Sequence);
        var engine = usm.ReadOctets();
        var boots = Int(usm.ReadInteger());
        var time = Int(usm.ReadInteger());
        var user = Encoding.UTF8.GetString(usm.ReadOctets());
        var (at, aStart, aLength) = usm.Next();
        if (at != Ber.OctetString) throw new FormatException("SNMPv3: authentication parameters expected.");
        var priv = usm.ReadOctets();
        var result = new SnmpV3Message
        {
            MessageId = id, MaxMessageSize = max, Flags = flags[0], EngineId = engine, EngineBoots = boots, EngineTime = time, UserName = user,
            AuthParameters = data.AsSpan(aStart, aLength).ToArray(), PrivParameters = priv, AuthOffset = aLength == 0 ? -1 : aStart,
        };
        var (dt, ds, dl) = message.Next();
        if (message.HasMore || outer.HasMore) throw new FormatException("SNMPv3: extra data after the message.");
        if (dt == Ber.OctetString) return result with { Encrypted = data.AsSpan(ds, dl).ToArray() };
        if (dt != Ber.Sequence) throw new FormatException("SNMPv3: scoped PDU expected.");
        var (cid, cname, pdu) = ReadScoped(data, new Ber.Reader(data, ds, ds + dl));
        return result with { ContextEngineId = cid, ContextName = cname, Pdu = pdu };

        static int Int(long v) => v is >= 0 and <= int.MaxValue ? (int)v : throw new FormatException("SNMPv3: value out of range.");
    }

    /// <summary>For logs: the message's shape, never its keys or digest.</summary>
    public override string ToString() => $"SNMPv3 message {MessageId} flags {Flags:X2} user {UserName}";
}
