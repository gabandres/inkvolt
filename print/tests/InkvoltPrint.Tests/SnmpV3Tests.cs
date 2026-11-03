using System.Security.Cryptography;
using System.Text;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// SNMPv3 (roadmap 3.2, Pro): the User-based Security Model's key localization against RFC 3414 A.3's vectors (and the same
/// algorithm with SHA-256), HMAC-SHA-256 against RFC 4231, AES-CFB against NIST SP 800-38A, a discovery request and an authPriv
/// GetRequest written by hand byte for byte (RFC 3412 §6, RFC 3414 §2.4, RFC 3826 §3.1), and the made-up agent speaking v3:
/// discovery, reads, and refusing a wrong user or either wrong key.
/// </summary>
public class SnmpV3Tests
{
    private static byte[] Hex(string hex) => Convert.FromHexString(hex.Replace(" ", ""));

    private static readonly byte[] RfcEngine = Hex("000000000000000000000002"); // RFC 3414 A.3's engine ID

    // ------------------------------------------------------------------------------------------------ keys, digest, cipher

    [Fact]
    public void Password_to_key_and_localization_match_RFC_3414_A3_for_MD5_and_SHA1()
    {
        var md5 = Usm.PasswordToKey("maplesyrup", HashAlgorithmName.MD5);
        Assert.Equal(Hex("9f af 32 83 88 4e 92 83 4e bc 98 47 d8 ed d9 63"), md5); // A.3.1
        Assert.Equal(Hex("52 6f 5e ed 9f cc e2 6f 89 64 c2 93 07 87 d8 2b"), Usm.Localize(md5, RfcEngine, HashAlgorithmName.MD5));
        var sha = Usm.PasswordToKey("maplesyrup", HashAlgorithmName.SHA1);
        Assert.Equal(Hex("9f b5 cc 03 81 49 7b 37 93 52 89 39 ff 78 8d 5d 79 14 52 11"), sha); // A.3.2
        Assert.Equal(Hex("66 95 fe bc 92 88 e3 62 82 23 5f c7 15 1f 12 84 97 b3 8f 3f"), Usm.Localize(sha, RfcEngine, HashAlgorithmName.SHA1));
    }

    [Fact]
    public void The_same_algorithm_with_SHA256_gives_the_known_localized_key()
    {
        // RFC 7860 §4.2.2 keeps A.2's algorithm; this is "maplesyrup" at A.3's engine, as other SNMP stacks print it.
        var ku = Usm.PasswordToKey("maplesyrup", HashAlgorithmName.SHA256);
        Assert.Equal(Hex("ab51014d1e077f6017df2b12bee5f5aa72993177e9bb569c4dff5a4ca0b4afac"), ku);
        Assert.Equal(Hex("8982e0e549e866db361a6b625d84cccc11162d453ee8ce3a6445c2d6776f0f8b"), Usm.Localize(ku, RfcEngine, HashAlgorithmName.SHA256));
    }

    [Fact]
    public void The_digest_is_HMAC_SHA256_cut_to_192_bits()
    {
        // RFC 4231 test case 1, its first 24 bytes (RFC 7860 §4.2.1's usmHMAC192SHA256AuthProtocol).
        var digest = Usm.Authenticate(Enumerable.Repeat((byte)0x0b, 20).ToArray(), "Hi There"u8);
        Assert.Equal(Hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da7"), digest);
    }

    [Fact]
    public void AES_CFB_matches_NIST_SP800_38A_and_takes_any_length()
    {
        var key = Hex("2b7e151628aed2a6abf7158809cf4f3c");
        var iv = Hex("000102030405060708090a0b0c0d0e0f");
        var plain = Hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"); // F.3.13 CFB128-AES128.Encrypt, blocks 1-2
        var cipher = Hex("3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b");
        Assert.Equal(cipher, Usm.AesCfb(key, iv, plain, encrypt: true));
        Assert.Equal(plain, Usm.AesCfb(key, iv, cipher, encrypt: false));
        // No padding is sent: 20 bytes in, the same 20 bytes of the cipher stream out.
        Assert.Equal(cipher[..20], Usm.AesCfb(key, iv, plain[..20], encrypt: true));
        Assert.Equal(plain[..20], Usm.AesCfb(key, iv, cipher[..20], encrypt: false));
    }

    [Fact]
    public void The_AES_IV_is_boots_time_and_salt_big_endian()
    {
        Assert.Equal(Hex("00000003 000010e1 0102030405060708"), Usm.AesIv(3, 4321, Hex("0102030405060708"))); // RFC 3826 §3.1.2.1
    }

    // ------------------------------------------------------------------------------------------------ messages written by hand

    [Fact]
    public void A_discovery_request_is_written_as_RFC_3414_section_4_has_it()
    {
        var bytes = new SnmpV3Message
        {
            MessageId = 0x5678, Flags = SnmpV3Message.FlagReportable, ContextEngineId = [],
            Pdu = new SnmpMessage(SnmpVersion.V3, "", SnmpPduType.GetRequest, 0x1234, 0, 0, []),
        }.Encode();
        Assert.Equal(Hex(
            "30 3a" +
            "  02 01 03" +                                               // msgVersion 3
            "  30 0f 02 02 5678 02 03 00ffe3 04 01 04 02 01 03" +       // msgID, msgMaxSize 65507, msgFlags reportable, USM
            "  04 10 30 0e 04 00 02 01 00 02 01 00 04 00 04 00 04 00" + // no engine, boots 0, time 0, no user, no digest, no salt
            "  30 12 04 00 04 00" +                                      // scoped PDU in clear: no contextEngineID, no contextName
            "    a0 0c 02 02 1234 02 01 00 02 01 00 30 00"),            // GetRequest, no variables
            bytes);
    }

    // An authPriv GetRequest of sysDescr.0, written out by hand; the cipher text and digest come from the keys below (Python's
    // hashlib, hmac and an AES-CFB of its own, not this code).
    private static readonly byte[] Engine = Hex("80001f8880e9630000d61ff449");
    private const string AuthPass = "authpass-2026", PrivPass = "privpass-2026", User = "inkvolt";
    private const string AuthKul = "fc253677d1f53f3308d820c695259b271a4e65004cc6c46f2efe050abd363445", PrivKul16 = "677c849915cc5a33c1fb6bebd52d9811";
    private const string Scoped = "302d 040d80001f8880e9630000d61ff449 0400 a01a 02021234 020100 020100 300e 300c 06082b06010201010100 0500";
    private const string Encrypted = "fa556369817b47a255f05ca418f50a2f209c3ec43e1b9a0479fc35b9ea1f3d21b48ddc9c39f93d089e580931b3e57f";
    private const string Digest = "d64adc4fcc6e02902b608b478d48dab23ae4b6006a8f12ce";
    private const string Message =
        "30818c 020103 300f 02025678 020300ffe3 040107 020103" +
        " 0445 3043 040d80001f8880e9630000d61ff449 020103 020210e1 0407696e6b766f6c74 0418" + Digest + " 04080000000000000001" +
        " 042f" + Encrypted;

    [Fact]
    public void An_authPriv_request_is_byte_for_byte_the_one_written_by_hand()
    {
        var keys = Usm.Keys.For(new SnmpV3User(User, AuthPass, PrivPass), Engine);
        Assert.Equal(Hex(AuthKul), keys.Auth);
        Assert.Equal(Hex(PrivKul16), keys.Priv[..16]); // RFC 3826 §1.2: AES-128 takes the first 16 bytes

        var pdu = new SnmpMessage(SnmpVersion.V3, "", SnmpPduType.GetRequest, 0x1234, 0, 0, [new SnmpVarBind(PrinterMib.SysDescr.Append(0), SnmpValue.Null)]);
        var scoped = SnmpV3Message.EncodeScoped(Engine, "", pdu);
        Assert.Equal(Hex(Scoped), scoped);
        var salt = Hex("0000000000000001");
        var encrypted = Usm.AesCfb(keys.Priv, Usm.AesIv(3, 4321, salt), scoped, encrypt: true);
        Assert.Equal(Hex(Encrypted), encrypted);

        var signed = new SnmpV3Message
        {
            MessageId = 0x5678, Flags = SnmpV3Message.FlagAuth | SnmpV3Message.FlagPriv | SnmpV3Message.FlagReportable,
            EngineId = Engine, EngineBoots = 3, EngineTime = 4321, UserName = User, PrivParameters = salt, Encrypted = encrypted,
        }.Sign(keys.Auth);
        Assert.Equal(Hex(Message), signed);
    }

    [Fact]
    public void The_hand_written_message_reads_back_checks_and_decrypts()
    {
        var bytes = Hex(Message);
        var m = SnmpV3Message.Decode(bytes);
        Assert.Equal((0x5678, (byte)7, 3, 4321, User), (m.MessageId, m.Flags, m.EngineBoots, m.EngineTime, m.UserName));
        Assert.Equal(Engine, m.EngineId);
        Assert.True(m.Verify(bytes, Hex(AuthKul)));
        var (contextEngine, contextName, pdu) = SnmpV3Message.DecodeScoped(Usm.AesCfb(Hex(PrivKul16), Usm.AesIv(3, 4321, m.PrivParameters), m.Encrypted!, encrypt: false));
        Assert.Equal(Engine, contextEngine);
        Assert.Equal(("", SnmpPduType.GetRequest, 0x1234), (contextName, pdu.Type, pdu.RequestId));
        Assert.Equal(PrinterMib.SysDescr.Append(0), Assert.Single(pdu.VarBinds).Name);

        // Any byte changed anywhere fails the digest; so does another key.
        for (var i = 0; i < bytes.Length; i++)
        {
            if (i >= m.AuthOffset && i < m.AuthOffset + Usm.AuthLength) continue;
            var changed = (byte[])bytes.Clone();
            changed[i] ^= 0x01;
            SnmpV3Message read;
            try { read = SnmpV3Message.Decode(changed); }
            catch (FormatException) { continue; } // no longer a message at all: nothing to check
            Assert.False(read.Verify(changed, Hex(AuthKul)), $"byte {i}");
        }
        Assert.False(m.Verify(bytes, Usm.Keys.For(new SnmpV3User(User, "another-pass", PrivPass), Engine).Auth));
    }

    [Fact]
    public void A_v1_or_v2c_decoder_doesnt_take_a_v3_message()
    {
        Assert.True(SnmpV3Message.IsV3(Hex(Message)));
        Assert.Throws<FormatException>(() => SnmpMessage.Decode(Hex(Message)));
        Assert.False(SnmpV3Message.IsV3(new SnmpMessage(SnmpVersion.V2c, "public", SnmpPduType.GetRequest, 1, 0, 0, []).Encode()));
    }

    // ------------------------------------------------------------------------------------------------ the made-up agent over v3

    private static readonly SnmpV3User Right = new(User, AuthPass, PrivPass);

    private static SnmpAgent Agent() =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt"))), Right, Engine, engineBoots: 3, engineTime: 4321);

    private static SnmpLogin Login(SnmpV3User u) => SnmpLogin.ForUser(u.Name, u.AuthPassphrase, u.PrivPassphrase, out _)!;

    [Fact]
    public async Task The_agent_is_discovered_then_read_signed_and_encrypted()
    {
        var agent = Agent();
        var printer = await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14", Login(Right));
        Assert.NotNull(printer);
        Assert.Equal(SnmpVersion.V3, printer.Identity.Version);
        Assert.Equal("DEMO0005200", printer.Identity.SerialNumber);
        Assert.Equal(3, (await printer.GetSuppliesAsync()).Count);
        // Each client discovers the engine once (the probe's, then the reader's); every other request is answered.
        Assert.Equal(2, agent.V3Log.Count(e => e == "discovery"));
        Assert.Equal("discovery", agent.V3Log[0]);
        Assert.All(agent.V3Log.Where(e => e != "discovery"), e => Assert.Equal("answered", e));
        Assert.NotNull(await printer.ReadIdentityAsync());
    }

    [Fact]
    public async Task A_walk_uses_GetBulk_over_v3()
    {
        var agent = Agent();
        var client = new SnmpClient(agent, "192.0.2.14", SnmpVersion.V3, Login(Right));
        var columns = await client.WalkAsync([PrinterMib.SuppliesDescription]);
        Assert.Equal(3, columns[0].Count);
        Assert.Contains(agent.Received, m => m.Type == SnmpPduType.GetBulkRequest);
    }

    [Theory]
    [InlineData("someone", AuthPass, PrivPass, SnmpRefusal.UnknownUser, "unknownUserNames")]
    [InlineData(User, "wrong-auth-pass", PrivPass, SnmpRefusal.WrongAuthKey, "wrongDigests")]
    [InlineData(User, AuthPass, "wrong-priv-pass", SnmpRefusal.WrongPrivKey, "decryptionErrors")]
    public async Task The_agent_refuses_a_wrong_user_or_key_and_the_client_says_which(string name, string auth, string priv, SnmpRefusal reason, string counter)
    {
        var agent = Agent();
        var client = new SnmpClient(agent, "192.0.2.14", SnmpVersion.V3, Login(new SnmpV3User(name, auth, priv)));
        var ex = await Assert.ThrowsAsync<SnmpAccessException>(() => client.GetAsync([PrinterMib.SysDescr.Append(0)]));
        Assert.Equal(reason, ex.Reason);
        Assert.Equal(counter, agent.V3Log[^1]);
        Assert.DoesNotContain(agent.Received, m => m.Type == SnmpPduType.GetRequest && m.VarBinds.Count > 0); // nothing was read
        Assert.DoesNotContain(auth, ex.Message);
        Assert.DoesNotContain(priv, ex.Message);

        SnmpRefusal? told = null; // the probe finds nothing, and says why
        Assert.Null(await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14", Login(new SnmpV3User(name, auth, priv)), refused: r => told = r));
        Assert.Equal(reason, told);
    }

    [Fact]
    public async Task A_v3_agent_ignores_v1_and_v2c_and_a_community_login_never_speaks_v3()
    {
        var agent = Agent();
        Assert.Null(await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14"));
        Assert.Empty(agent.V3Log);
        var v2 = new SnmpAgent(SnmpAgent.ParseWalk(".1.3.6.1.2.1.1.5.0 = STRING: \"x\""));
        Assert.Null(v2.Respond(Hex(Message))); // a v1/v2c agent doesn't speak v3
        Assert.Throws<ArgumentException>(() => new SnmpClient(agent, "h", SnmpVersion.V3));
        Assert.Throws<ArgumentException>(() => new SnmpClient(agent, "h", SnmpVersion.V2c, Login(Right)));
    }

    [Fact]
    public async Task A_clock_out_of_the_window_is_set_from_the_agents_signed_report()
    {
        var agent = Agent();
        var client = new SnmpClient(agent, "192.0.2.14", SnmpVersion.V3, Login(Right));
        await client.GetAsync([PrinterMib.SysDescr.Append(0)]);
        agent.EngineBoots = 4; // the printer restarted
        agent.EngineTime = 12;
        var got = await client.GetAsync([PrinterMib.SysName.Append(0)]);
        Assert.Equal("demo-laser", got[0].Value.Text);
        Assert.Equal(["discovery", "answered", "notInTimeWindows", "answered"], agent.V3Log);
    }

    [Fact]
    public async Task A_reply_changed_on_the_way_is_no_answer()
    {
        var agent = Agent();
        var tampered = new Tamper(agent);
        var client = new SnmpClient(tampered, "192.0.2.14", SnmpVersion.V3, Login(Right)) { Retries = 0 };
        await client.GetAsync([PrinterMib.SysName.Append(0)]); // discovery and a first answer pass untouched
        tampered.On = true;
        await Assert.ThrowsAsync<TimeoutException>(() => client.GetAsync([PrinterMib.SysName.Append(0)]));
    }

    /// <summary>Flips a byte in the encrypted answer, as someone on the way could.</summary>
    private sealed class Tamper(SnmpAgent agent) : ISnmpTransport
    {
        public bool On { get; set; }

        public async Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct)
        {
            var reply = await agent.SendAsync(host, request, timeout, ct);
            if (On && reply is not null) reply[^1] ^= 0x01;
            return reply;
        }
    }

    // ------------------------------------------------------------------------------------------------ the login

    [Fact]
    public void A_v3_login_round_trips_as_its_kept_secret_and_shows_nothing()
    {
        var login = SnmpLogin.ForUser("ops:reader", "auth pass:1", "priv:pass 2", out var error);
        Assert.Null(error);
        Assert.Equal(login, SnmpLogin.FromSecret(login!.ToSecret()));
        Assert.False(login.IsDefault);
        foreach (var shown in new[] { login.ToString(), login.User!.ToString().Replace("ops:reader", "") })
        {
            Assert.DoesNotContain("auth pass:1", shown);
            Assert.DoesNotContain("priv:pass 2", shown);
        }
        Assert.DoesNotContain("ops:reader", login.ToString());
    }

    [Theory]
    [InlineData("", "authpass1", "privpass1", "user name")]
    [InlineData("u", "short", "privpass1", "authentication passphrase")]
    [InlineData("u", "authpass1", "short", "privacy passphrase")]
    [InlineData("a-user-name-longer-than-32-chars!", "authpass1", "privpass1", "1 to 32")]
    public void A_v3_login_that_cant_be_used_is_refused_with_why(string name, string auth, string priv, string why)
    {
        Assert.Null(SnmpLogin.ForUser(name, auth, priv, out var error));
        Assert.Contains(why, error);
    }
}

/// <summary>SNMPv3 is a Pro feature: the gate (<see cref="Pro.Allows"/>) decides whether a kept v3 user is used; a community always is.</summary>
[Collection("Pro")]
public sealed class SnmpV3ProTests : IDisposable
{
    public SnmpV3ProTests()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
    }

    public void Dispose()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
    }

    [Fact]
    public void A_kept_v3_user_is_used_only_while_Pro_allows_it()
    {
        ISnmpLogins logins = new MemorySnmpLogins();
        logins.Save("v3", SnmpLogin.ForUser("reader", "authpass1", "privpass1", out _)!);
        logins.Save("community", SnmpLogin.ForCommunity("office", out _)!);
        Assert.NotNull(logins.Usable("v3")); // the gate is off while the apps launch

        Pro.Enforced = true; // no licence
        Assert.False(Pro.Allows(ProFeature.SnmpV3));
        Assert.Null(logins.Usable("v3"));
        Assert.Equal("office", logins.Usable("community")!.Community); // free
        Assert.NotNull(logins.Get("v3")); // kept, for when a licence comes
    }
}
