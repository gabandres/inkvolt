using System.Security.Cryptography;
using System.Text;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// The USM authentication protocols spoken: HMAC-SHA-256 cut to 192 bits (usmHMAC192SHA256AuthProtocol, RFC 7860, the default),
/// and RFC 3414's HMAC-SHA-1-96 and HMAC-MD5-96 (usmHMACSHAAuthProtocol, usmHMACMD5AuthProtocol) for agents that offer no better.
/// </summary>
public enum SnmpAuth { Sha256, Sha1, Md5 }

/// <summary>
/// The USM privacy protocols spoken: AES-128 in CFB mode (usmAesCfb128Protocol, RFC 3826, the default), AES-192 and AES-256 in
/// CFB mode (draft-blumenthal-aes-usm-04: the same IV, the key lengthened as <see cref="Usm.Extend"/> says), and RFC 3414 §8's
/// CBC-DES (usmDESPrivProtocol) for agents that offer no better.
/// </summary>
public enum SnmpPriv { Aes128, Aes192, Aes256, Des }

/// <summary>
/// An SNMPv3 user (RFC 3414's User-based Security Model) as Inkvolt Print signs in with it: authPriv only, with the
/// authentication and privacy protocols the printer's agent was set up with (<see cref="Auth"/>, <see cref="Priv"/>; SHA-256 and
/// AES-128 unless chosen). The passphrases are secrets: kept with the <see cref="SnmpLogin"/> in Credential Manager;
/// <see cref="ToString"/> shows neither.
/// </summary>
public sealed record SnmpV3User(string Name, string AuthPassphrase, string PrivPassphrase)
{
    public SnmpAuth Auth { get; init; } = SnmpAuth.Sha256;
    public SnmpPriv Priv { get; init; } = SnmpPriv.Aes128;

    /// <summary>RFC 3414 §11.2: shorter passphrases make weak keys; net-snmp refuses them too.</summary>
    public const int MinPassphrase = 8;

    /// <summary>The longest passphrase taken, so a login always fits Credential Manager (4,000 characters did on the PC this was tried on, 20,000 didn't).</summary>
    public const int MaxPassphrase = 256;

    /// <summary>The longest user name in bytes of UTF-8 (RFC 3414 usmUserName: SnmpAdminString (SIZE(1..32))).</summary>
    public const int MaxName = 32;

    public override string ToString() => $"SNMPv3 user {Name} ({Usm.Name(Auth)}, {Usm.Name(Priv)}; keys kept)";
}

/// <summary>
/// The User-based Security Model's cryptography (RFC 3414 §2.6, §6 to §8 and A.2, RFC 7860, RFC 3826, draft-blumenthal-aes-usm-04),
/// with .NET's own hashes, HMAC, AES and DES only. Keys are localized to one agent's engine ID, so a key read off one printer is no
/// use on another.
/// </summary>
public static class Usm
{
    /// <summary>usmHMAC192SHA256AuthProtocol's msgAuthenticationParameters: the first 24 bytes of HMAC-SHA-256 (RFC 7860 §4.2.1).</summary>
    public const int AuthLength = 24;

    /// <summary>
    /// A protocol's msgAuthenticationParameters: 24 bytes for HMAC-SHA-256-192, 12 for HMAC-SHA-1-96 and HMAC-MD5-96
    /// (RFC 3414 §6.3.1, §7.3.1).
    /// </summary>
    public static int DigestLength(SnmpAuth auth) => auth == SnmpAuth.Sha256 ? AuthLength : 12;

    /// <summary>usmAesCfb128Protocol's msgPrivacyParameters: the 64-bit salt (RFC 3826 §3.1.2.1); CBC-DES's is 8 bytes too (RFC 3414 §8.1.1.1).</summary>
    public const int SaltLength = 8;

    /// <summary>The hash a protocol keys and signs with.</summary>
    public static HashAlgorithmName Hash(SnmpAuth auth) => auth switch
    {
        SnmpAuth.Md5 => HashAlgorithmName.MD5,
        SnmpAuth.Sha1 => HashAlgorithmName.SHA1,
        _ => HashAlgorithmName.SHA256,
    };

    /// <summary>A privacy protocol's key: AES-128 16 bytes, AES-192 24, AES-256 32; CBC-DES 16 (its key, then its pre-IV).</summary>
    public static int PrivKeyLength(SnmpPriv priv) => priv switch
    {
        SnmpPriv.Aes192 => 24,
        SnmpPriv.Aes256 => 32,
        _ => 16,
    };

    /// <summary>The protocols' names as agents' settings show them.</summary>
    public static string Name(SnmpAuth auth) => auth switch { SnmpAuth.Md5 => "MD5", SnmpAuth.Sha1 => "SHA-1", _ => "SHA-256" };

    public static string Name(SnmpPriv priv) => priv switch { SnmpPriv.Aes192 => "AES-192", SnmpPriv.Aes256 => "AES-256", SnmpPriv.Des => "DES", _ => "AES-128" };

    /// <summary>RFC 3414 A.2.1 (A.2.2 for SHA-1; RFC 7860 §4.2.2 the same with SHA-2): the passphrase repeated to 1 MiB, hashed.</summary>
    public static byte[] PasswordToKey(string passphrase, HashAlgorithmName hash) => PasswordToKey(Encoding.UTF8.GetBytes(passphrase), hash);

    /// <summary>The same over bytes (Reeder's key extension runs it over a localized key).</summary>
    public static byte[] PasswordToKey(byte[] password, HashAlgorithmName hash)
    {
        if (password.Length == 0) throw new ArgumentException("An empty passphrase makes no key.", nameof(password));
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

    /// <summary>
    /// A protocol's digest over a whole message whose msgAuthenticationParameters are zeros: the HMAC cut to
    /// <see cref="DigestLength"/> (RFC 3414 §6.3.1 HMAC-MD5-96, §7.3.1 HMAC-SHA-96, RFC 7860 §4.2.1).
    /// </summary>
    public static byte[] Authenticate(SnmpAuth auth, byte[] key, ReadOnlySpan<byte> message) => auth switch
    {
        SnmpAuth.Md5 => HMACMD5.HashData(key, message)[..12],
        SnmpAuth.Sha1 => HMACSHA1.HashData(key, message)[..12],
        _ => Authenticate(key, message),
    };

    /// <summary>
    /// How a localized key too short for its cipher (SHA-1's 20 bytes or MD5's 16 for AES-192 or AES-256) is lengthened.
    /// Blumenthal's (draft-blumenthal-aes-usm-04 §3.1.2.1, net-snmp's default): the hash of all of it so far appended,
    /// until long enough. Reeder's (draft-reeder-snmpv3-usm-3desede-00 §2.1, Cisco's and pysnmp's usmAesCfb192/256): the key
    /// so far run through password-to-key and localized again, appended. SHA-256's 32 bytes need neither.
    /// </summary>
    public enum KeyExtension { Blumenthal, Reeder }

    /// <summary>A localized key lengthened to <paramref name="length"/> bytes (<see cref="KeyExtension"/>), or cut to it.</summary>
    public static byte[] Extend(byte[] kul, int length, HashAlgorithmName hash, ReadOnlySpan<byte> engineId, KeyExtension how)
    {
        var key = kul;
        while (key.Length < length)
        {
            var more = how == KeyExtension.Reeder ? Localize(PasswordToKey(key, hash), engineId, hash) : HashData(hash, key);
            key = [.. key, .. more];
        }
        return key[..length];

        static byte[] HashData(HashAlgorithmName hash, byte[] data)
        {
            using var h = IncrementalHash.CreateHash(hash);
            h.AppendData(data);
            return h.GetHashAndReset();
        }
    }

    /// <summary>
    /// RFC 3414 §8.1.1.1: CBC-DES's salt is the engine's boots (4 bytes) then a number this sender changes every message
    /// (4 bytes); AES's is a 64-bit number that changes every message (RFC 3826 §3.1.2.1).
    /// </summary>
    public static byte[] Salt(SnmpPriv priv, int boots, long counter)
    {
        var salt = new byte[SaltLength];
        System.Buffers.Binary.BinaryPrimitives.WriteInt64BigEndian(salt, counter);
        if (priv == SnmpPriv.Des) System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(salt, boots);
        return salt;
    }

    /// <summary>
    /// RFC 3414 §8.1.1: CBC-DES with the privacy key's first 8 bytes and, as IV, its last 8 (the pre-IV) XORed with the salt.
    /// Sent padded to whole 8-byte blocks (the scoped PDU's BER says where it ends); what comes in must be whole blocks
    /// (§8.3.2: else a decryption error, as here a <see cref="FormatException"/>).
    /// </summary>
    public static byte[] DesCbc(ReadOnlySpan<byte> privKey, ReadOnlySpan<byte> salt, ReadOnlySpan<byte> data, bool encrypt)
    {
        if (salt.Length != SaltLength) throw new ArgumentException("The salt is 8 bytes.", nameof(salt));
        var iv = new byte[8];
        for (var i = 0; i < 8; i++) iv[i] = (byte)(privKey[8 + i] ^ salt[i]);
        using var des = DES.Create();
        try
        {
            des.Key = privKey[..8].ToArray();
            if (encrypt)
            {
                var whole = new byte[(data.Length + 7) / 8 * 8];
                data.CopyTo(whole);
                return des.EncryptCbc(whole, iv, PaddingMode.None);
            }
            if (data.Length % 8 != 0) throw new FormatException("CBC-DES: not whole blocks.");
            return des.DecryptCbc(data, iv, PaddingMode.None);
        }
        catch (CryptographicException ex)
        {
            throw new FormatException("CBC-DES: the key can't be used.", ex); // one of DES's weak keys: no message can be read
        }
    }

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
    /// AES in CFB mode with 128-bit feedback (RFC 3826 §3.1.3), any length: no padding is sent, so a short last block is
    /// filled with zeros for .NET and cut off again (CFB's last bytes depend only on what comes before them). The key is the
    /// privacy key's first <paramref name="keyLength"/> bytes: 16 (AES-128), 24 or 32.
    /// </summary>
    public static byte[] AesCfb(ReadOnlySpan<byte> key, byte[] iv, ReadOnlySpan<byte> data, bool encrypt, int keyLength = 16)
    {
        using var aes = Aes.Create();
        aes.Key = key[..keyLength].ToArray();
        var whole = new byte[(data.Length + 15) / 16 * 16];
        data.CopyTo(whole);
        var result = encrypt ? aes.EncryptCfb(whole, iv, PaddingMode.None, 128) : aes.DecryptCfb(whole, iv, PaddingMode.None, 128);
        return result[..data.Length];
    }

    /// <summary>
    /// A user's two keys localized to one engine, with the protocols they're for, worked out once. The privacy key comes from the
    /// privacy passphrase with the authentication protocol's hash (RFC 3414 §2.6, RFC 3826 §1.2), lengthened for AES-192 or
    /// AES-256 when that hash is too short (<see cref="KeyExtension"/>).
    /// </summary>
    public sealed class Keys(byte[] auth, byte[] priv, SnmpAuth authProtocol = SnmpAuth.Sha256, SnmpPriv privProtocol = SnmpPriv.Aes128)
    {
        public byte[] Auth { get; } = auth;
        public byte[] Priv { get; } = priv;
        public SnmpAuth AuthProtocol { get; } = authProtocol;
        public SnmpPriv PrivProtocol { get; } = privProtocol;

        /// <summary>The digest's length in a message signed with these keys.</summary>
        public int DigestLength => Usm.DigestLength(AuthProtocol);

        public byte[] Sign(ReadOnlySpan<byte> message) => Authenticate(AuthProtocol, Auth, message);

        public static Keys For(SnmpV3User user, ReadOnlySpan<byte> engineId, KeyExtension extension = KeyExtension.Blumenthal)
        {
            var hash = Hash(user.Auth);
            var priv = Localize(PasswordToKey(user.PrivPassphrase, hash), engineId, hash);
            return new Keys(Localize(PasswordToKey(user.AuthPassphrase, hash), engineId, hash),
                Extend(priv, Math.Max(priv.Length, PrivKeyLength(user.Priv)), hash, engineId, extension), user.Auth, user.Priv);
        }

        /// <summary>
        /// The keys with the other way of lengthening the privacy key (<see cref="KeyExtension"/>), when it gives another key
        /// (AES-192 or AES-256 after MD5 or SHA-1); null when it makes no difference.
        /// </summary>
        public static Keys? Otherwise(SnmpV3User user, ReadOnlySpan<byte> engineId, KeyExtension extension) =>
            user.Priv is SnmpPriv.Aes192 or SnmpPriv.Aes256 && Usm.Hash(user.Auth) != HashAlgorithmName.SHA256
                ? For(user, engineId, extension == KeyExtension.Blumenthal ? KeyExtension.Reeder : KeyExtension.Blumenthal) : null;

        /// <summary>A scoped PDU encrypted as the privacy protocol says, with the message's boots, time and salt.</summary>
        public byte[] Encrypt(int boots, int time, byte[] salt, ReadOnlySpan<byte> scoped) => PrivProtocol == SnmpPriv.Des
            ? DesCbc(Priv, salt, scoped, encrypt: true)
            : AesCfb(Priv, AesIv(boots, time, salt), scoped, encrypt: true, PrivKeyLength(PrivProtocol));

        /// <summary>The other way; <see cref="FormatException"/> when it can't be (CBC-DES's blocks not whole).</summary>
        public byte[] Decrypt(int boots, int time, byte[] salt, ReadOnlySpan<byte> encrypted) => PrivProtocol == SnmpPriv.Des
            ? DesCbc(Priv, salt, encrypted, encrypt: false)
            : AesCfb(Priv, AesIv(boots, time, salt), encrypted, encrypt: false, PrivKeyLength(PrivProtocol));

        /// <summary>A fresh salt for a message (<see cref="Salt"/>).</summary>
        public byte[] Salt(int boots, long counter) => Usm.Salt(PrivProtocol, boots, counter);
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

    /// <summary>
    /// The engine ID of the agent that refused, in hex, as discovered (unsigned: any device can claim one); null when not from
    /// an agent. A refusal is this printer's only when that engine is the one its signed answers came from (<see cref="SnmpDevice.IsItsEngine"/>).
    /// </summary>
    public string? EngineId { get; init; }

    private static string Words(SnmpRefusal reason) => reason switch
    {
        SnmpRefusal.UnknownUser => CoreStrings.Snmp_UnknownUser,
        SnmpRefusal.WrongAuthKey => CoreStrings.Snmp_WrongAuthKey,
        SnmpRefusal.WrongPrivKey => CoreStrings.Snmp_WrongPrivKey,
        _ => CoreStrings.Snmp_SecurityLevel,
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

    /// <summary>
    /// A scoped PDU as <see cref="EncodeScoped"/> writes it. <see cref="FormatException"/> for anything else (a wrong privacy key's
    /// output). <paramref name="padded"/>: decrypted CBC-DES, whose last block may carry up to 7 bytes of padding after it.
    /// </summary>
    public static (byte[] ContextEngineId, string ContextName, SnmpMessage Pdu) DecodeScoped(byte[] data, bool padded = false)
    {
        var r = new Ber.Reader(data);
        var scoped = r.Enter(Ber.Sequence);
        if (r.HasMore && (!padded || data.Length - r.Position > 7)) throw new FormatException("SNMPv3: data after the scoped PDU.");
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
    public byte[] Sign(byte[] authKey) => Sign(new Usm.Keys(authKey, []));

    /// <summary>The message signed with the keys' protocol: its digest over the bytes with zeros of the digest's length in its place.</summary>
    public byte[] Sign(Usm.Keys keys)
    {
        var (bytes, offset) = (this with { AuthParameters = new byte[keys.DigestLength] }).EncodeWithOffset();
        keys.Sign(bytes).CopyTo(bytes, offset);
        return bytes;
    }

    /// <summary>True when <paramref name="bytes"/> (as <see cref="Decode"/> read them) carry the right digest for <paramref name="authKey"/>.</summary>
    public bool Verify(byte[] bytes, byte[] authKey) => Verify(bytes, new Usm.Keys(authKey, []));

    /// <summary>The same with the keys' protocol: a digest of another length is no digest of it.</summary>
    public bool Verify(byte[] bytes, Usm.Keys keys)
    {
        if (!Authenticated || AuthOffset < 0 || AuthParameters.Length != keys.DigestLength) return false;
        var zeroed = (byte[])bytes.Clone();
        Array.Clear(zeroed, AuthOffset, keys.DigestLength);
        return CryptographicOperations.FixedTimeEquals(keys.Sign(zeroed), AuthParameters);
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
