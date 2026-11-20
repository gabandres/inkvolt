using System.Security.Cryptography;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// SNMPv3's other protocols beside SHA-256 and AES-128: HMAC-MD5-96 and HMAC-SHA-1-96 (RFC 3414 §6, §7), CBC-DES (RFC 3414 §8),
/// AES-192 and AES-256 in CFB mode with a short key lengthened as Blumenthal's draft says (net-snmp) or, tried next, as Reeder's
/// (Cisco). The primitives against RFC 2202, NIST SP 800-38A and the textbook DES example; the key extensions and RFC 3414's
/// DES framing against values Python's hashlib and cryptography computed; then the made-up agent read with every pair.
/// </summary>
public class SnmpV3ProtocolTests
{
    private static byte[] Hex(string hex) => Convert.FromHexString(hex.Replace(" ", ""));

    private static readonly byte[] RfcEngine = Hex("000000000000000000000002"); // RFC 3414 A.3's engine ID

    // ------------------------------------------------------------------------------------------------ primitives

    [Fact]
    public void HMAC_MD5_96_and_HMAC_SHA1_96_are_RFC_2202_s_first_case_cut_to_12_bytes()
    {
        Assert.Equal(Hex("9294727a3638bb1c13f48ef8"), Usm.Authenticate(SnmpAuth.Md5, Enumerable.Repeat((byte)0x0b, 16).ToArray(), "Hi There"u8));
        Assert.Equal(Hex("b617318655057264e28bc0b6"), Usm.Authenticate(SnmpAuth.Sha1, Enumerable.Repeat((byte)0x0b, 20).ToArray(), "Hi There"u8));
        Assert.Equal((12, 12, 24), (Usm.DigestLength(SnmpAuth.Md5), Usm.DigestLength(SnmpAuth.Sha1), Usm.DigestLength(SnmpAuth.Sha256)));
    }

    [Theory]
    [InlineData("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b", "cdc80d6fddf18cab34c25909c99a417467ce7f7f81173621961a2b70171d3d7a")] // F.3.15
    [InlineData("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4", "dc7e84bfda79164b7ecd8486985d386039ffed143b28b1c832113c6331e5407b")] // F.3.17
    public void AES_192_and_256_CFB_match_NIST_SP800_38A(string key, string cipher)
    {
        var k = Hex(key);
        var iv = Hex("000102030405060708090a0b0c0d0e0f");
        var plain = Hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
        Assert.Equal(Hex(cipher), Usm.AesCfb(k, iv, plain, encrypt: true, k.Length));
        Assert.Equal(plain[..21], Usm.AesCfb(k, iv, Hex(cipher)[..21], encrypt: false, k.Length));
    }

    [Fact]
    public void DES_matches_the_textbook_example()
    {
        // Key 133457799BBCDFF1, block 0123456789ABCDEF (J. Orlin Grabbe's worked example); a zero IV makes CBC's first block ECB's.
        var key = Hex("133457799BBCDFF1 0000000000000000");
        Assert.Equal(Hex("85e813540f0ab405"), Usm.DesCbc(key, new byte[8], Hex("0123456789ABCDEF"), encrypt: true));
    }

    [Fact]
    public void CBC_DES_takes_its_key_and_pre_IV_from_the_privacy_key_and_pads_to_whole_blocks()
    {
        // RFC 3414 §8.1.1: "maplesyrup" localized with MD5 at A.3's engine; key = its first 8 bytes, IV = its last 8 XOR the salt.
        var kul = Hex("526f5eed9fcce26f8964c2930787d82b");
        var salt = Usm.Salt(SnmpPriv.Des, 3, 1);
        Assert.Equal(Hex("0000000300000001"), salt); // engine boots, then this sender's number
        var plain = Enumerable.Range(0, 20).Select(i => (byte)i).ToArray();
        var cipher = Usm.DesCbc(kul, salt, plain, encrypt: true);
        Assert.Equal(Hex("009824bac70e3bdf7ab2bc947a02bd83c129148f14e64170"), cipher); // 20 bytes padded to 24
        Assert.Equal(plain, Usm.DesCbc(kul, salt, cipher, encrypt: false)[..20]);
        Assert.Throws<FormatException>(() => Usm.DesCbc(kul, salt, cipher[..23], encrypt: false)); // not whole blocks: a decryption error
    }

    [Fact]
    public void An_AES_salt_is_the_whole_counter_and_a_DES_one_starts_with_the_boots()
    {
        Assert.Equal(Hex("0000000000000102"), Usm.Salt(SnmpPriv.Aes256, 7, 0x102));
        Assert.Equal(Hex("0000000700000102"), Usm.Salt(SnmpPriv.Des, 7, 0x102));
    }

    // ------------------------------------------------------------------------------------------------ keys

    [Theory]
    [InlineData(SnmpAuth.Md5, SnmpPriv.Aes192, Usm.KeyExtension.Blumenthal, "526f5eed9fcce26f8964c2930787d82bfa24a92467426c2f")]
    [InlineData(SnmpAuth.Md5, SnmpPriv.Aes256, Usm.KeyExtension.Blumenthal, "526f5eed9fcce26f8964c2930787d82bfa24a92467426c2f4b09192be10dfaec")]
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Aes192, Usm.KeyExtension.Blumenthal, "6695febc9288e36282235fc7151f128497b38f3f505e07eb")]
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Aes256, Usm.KeyExtension.Blumenthal, "6695febc9288e36282235fc7151f128497b38f3f505e07eb9af25568fa1f5dbe")]
    [InlineData(SnmpAuth.Md5, SnmpPriv.Aes256, Usm.KeyExtension.Reeder, "526f5eed9fcce26f8964c2930787d82b79eff44a90650ee0a3a40abfac5acc12")]
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Aes192, Usm.KeyExtension.Reeder, "6695febc9288e36282235fc7151f128497b38f3f9b8b6d78")]
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Aes256, Usm.KeyExtension.Reeder, "6695febc9288e36282235fc7151f128497b38f3f9b8b6d78936ba6e7d19dfd9c")]
    [InlineData(SnmpAuth.Md5, SnmpPriv.Des, Usm.KeyExtension.Blumenthal, "526f5eed9fcce26f8964c2930787d82b")] // long enough already
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Aes128, Usm.KeyExtension.Reeder, "6695febc9288e36282235fc7151f128497b38f3f")]
    public void A_short_privacy_key_is_lengthened_as_the_drafts_say(SnmpAuth auth, SnmpPriv priv, Usm.KeyExtension how, string key)
    {
        var keys = Usm.Keys.For(new SnmpV3User("u", "maplesyrup", "maplesyrup") { Auth = auth, Priv = priv }, RfcEngine, how);
        Assert.Equal(Hex(key), keys.Priv);
        Assert.Equal(keys.Priv[..16], Usm.Localize(Usm.PasswordToKey("maplesyrup", Usm.Hash(auth)), RfcEngine, Usm.Hash(auth))[..16]); // the localized key first
    }

    [Fact]
    public void Only_AES_192_or_256_after_MD5_or_SHA1_has_another_key_to_try()
    {
        SnmpV3User U(SnmpAuth a, SnmpPriv p) => new("u", "maplesyrup", "maplesyrup") { Auth = a, Priv = p };
        Assert.NotNull(Usm.Keys.Otherwise(U(SnmpAuth.Sha1, SnmpPriv.Aes256), RfcEngine, Usm.KeyExtension.Blumenthal));
        Assert.NotNull(Usm.Keys.Otherwise(U(SnmpAuth.Md5, SnmpPriv.Aes192), RfcEngine, Usm.KeyExtension.Blumenthal));
        Assert.Null(Usm.Keys.Otherwise(U(SnmpAuth.Sha256, SnmpPriv.Aes256), RfcEngine, Usm.KeyExtension.Blumenthal)); // 32 bytes: no extension
        Assert.Null(Usm.Keys.Otherwise(U(SnmpAuth.Sha1, SnmpPriv.Aes128), RfcEngine, Usm.KeyExtension.Blumenthal));
        Assert.Null(Usm.Keys.Otherwise(U(SnmpAuth.Md5, SnmpPriv.Des), RfcEngine, Usm.KeyExtension.Blumenthal));
    }

    // ------------------------------------------------------------------------------------------------ the made-up agent

    private static readonly byte[] Engine = Hex("80001f8880e1b2c3d4e5f60718");

    private static SnmpV3User User(SnmpAuth auth, SnmpPriv priv) => new("reader", "authpass-2026", "privpass-2026") { Auth = auth, Priv = priv };

    private static SnmpAgent Agent(SnmpV3User user, Usm.KeyExtension how = Usm.KeyExtension.Blumenthal) =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt"))),
            user, Engine, engineBoots: 3, engineTime: 4321, extension: how);

    private static SnmpLogin Login(SnmpV3User u) => SnmpLogin.ForUser(u.Name, u.AuthPassphrase, u.PrivPassphrase, out _, u.Auth, u.Priv)!;

    public static TheoryData<SnmpAuth, SnmpPriv> EveryPair()
    {
        var pairs = new TheoryData<SnmpAuth, SnmpPriv>();
        foreach (var a in Enum.GetValues<SnmpAuth>())
            foreach (var p in Enum.GetValues<SnmpPriv>()) pairs.Add(a, p);
        return pairs;
    }

    [Theory]
    [MemberData(nameof(EveryPair))]
    public async Task The_agent_is_read_with_every_pair_of_protocols(SnmpAuth auth, SnmpPriv priv)
    {
        var agent = Agent(User(auth, priv));
        var printer = await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14", Login(User(auth, priv)));
        Assert.NotNull(printer);
        Assert.Equal("DEMO0005200", printer.Identity.SerialNumber);
        Assert.Equal(3, (await printer.GetSuppliesAsync()).Count); // GetBulk, encrypted both ways
        Assert.All(agent.V3Log.Where(e => e != "discovery"), e => Assert.Equal("answered", e));
    }

    [Theory]
    [InlineData(SnmpAuth.Sha256, SnmpPriv.Aes128, SnmpAuth.Sha1, SnmpPriv.Aes128, SnmpRefusal.WrongAuthKey)] // a 12-byte digest where 24 are due
    [InlineData(SnmpAuth.Md5, SnmpPriv.Aes128, SnmpAuth.Sha1, SnmpPriv.Aes128, SnmpRefusal.WrongAuthKey)]
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Des, SnmpAuth.Sha1, SnmpPriv.Aes128, SnmpRefusal.WrongPrivKey)]
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Aes256, SnmpAuth.Sha1, SnmpPriv.Aes192, SnmpRefusal.WrongPrivKey)]
    public async Task Another_protocol_than_the_agent_s_is_refused_as_that_part(SnmpAuth agentAuth, SnmpPriv agentPriv, SnmpAuth auth, SnmpPriv priv, SnmpRefusal reason)
    {
        var agent = Agent(User(agentAuth, agentPriv));
        var client = new SnmpClient(agent, "192.0.2.14", SnmpVersion.V3, Login(User(auth, priv)));
        var ex = await Assert.ThrowsAsync<SnmpAccessException>(() => client.GetAsync([PrinterMib.SysName.Append(0)]));
        Assert.Equal(reason, ex.Reason);
    }

    [Theory]
    [InlineData(SnmpAuth.Sha1, SnmpPriv.Aes256)]
    [InlineData(SnmpAuth.Md5, SnmpPriv.Aes192)]
    public async Task An_agent_that_lengthens_its_key_as_Reeder_does_is_read_after_one_decryption_error(SnmpAuth auth, SnmpPriv priv)
    {
        var agent = Agent(User(auth, priv), Usm.KeyExtension.Reeder);
        var client = new SnmpClient(agent, "192.0.2.14", SnmpVersion.V3, Login(User(auth, priv)));
        Assert.Equal("demo-laser", (await client.GetAsync([PrinterMib.SysName.Append(0)]))[0].Value.Text);
        Assert.Equal(["discovery", "decryptionErrors", "answered"], agent.V3Log);
        await client.GetAsync([PrinterMib.SysName.Append(0)]); // the key that worked is kept
        Assert.Equal("answered", agent.V3Log[^1]);
        Assert.Equal(1, agent.V3Log.Count(e => e == "decryptionErrors"));
    }

    [Fact]
    public async Task A_wrong_privacy_passphrase_is_still_a_wrong_privacy_key_after_both_extensions()
    {
        var agent = Agent(User(SnmpAuth.Sha1, SnmpPriv.Aes256));
        var wrong = new SnmpV3User("reader", "authpass-2026", "another-priv-pass") { Auth = SnmpAuth.Sha1, Priv = SnmpPriv.Aes256 };
        var ex = await Assert.ThrowsAsync<SnmpAccessException>(() => new SnmpClient(agent, "192.0.2.14", SnmpVersion.V3, Login(wrong)).GetAsync([PrinterMib.SysName.Append(0)]));
        Assert.Equal(SnmpRefusal.WrongPrivKey, ex.Reason);
        Assert.Equal(2, agent.V3Log.Count(e => e == "decryptionErrors"));
    }

    [Fact]
    public void A_DES_request_whose_blocks_aren_t_whole_is_a_decryption_error()
    {
        var user = User(SnmpAuth.Md5, SnmpPriv.Des);
        var agent = Agent(user);
        var keys = Usm.Keys.For(user, Engine);
        var salt = keys.Salt(3, 1);
        var scoped = SnmpV3Message.EncodeScoped(Engine, "", new SnmpMessage(SnmpVersion.V3, "", SnmpPduType.GetRequest, 9, 0, 0,
            [new SnmpVarBind(PrinterMib.SysName.Append(0), SnmpValue.Null)]));
        var request = new SnmpV3Message
        {
            MessageId = 9, Flags = SnmpV3Message.FlagAuth | SnmpV3Message.FlagPriv | SnmpV3Message.FlagReportable, EngineId = Engine,
            EngineBoots = 3, EngineTime = 4321, UserName = user.Name, PrivParameters = salt, Encrypted = keys.Encrypt(3, 4321, salt, scoped)[..^1],
        }.Sign(keys);
        Assert.NotNull(agent.Respond(request));
        Assert.Equal("decryptionErrors", agent.V3Log[^1]);
    }

    // ------------------------------------------------------------------------------------------------ the login kept

    [Fact]
    public void The_protocols_are_kept_with_the_login_and_an_older_entry_is_SHA256_and_AES128()
    {
        var login = Login(User(SnmpAuth.Md5, SnmpPriv.Des));
        Assert.EndsWith(":Md5:Des", login.ToSecret());
        Assert.Equal(login, SnmpLogin.FromSecret(login.ToSecret()));

        var plain = Login(User(SnmpAuth.Sha256, SnmpPriv.Aes128));
        Assert.Equal(3, plain.ToSecret()["usm:".Length..].Split(':').Length); // as kept before the other protocols came
        Assert.Equal((SnmpAuth.Sha256, SnmpPriv.Aes128), (SnmpLogin.FromSecret(plain.ToSecret())!.User!.Auth, SnmpLogin.FromSecret(plain.ToSecret())!.User!.Priv));
        Assert.DoesNotContain("authpass", login.ToString());
    }

    [Theory]
    [InlineData(":7:Des")]
    [InlineData(":sha1:Des")]
    [InlineData(": Sha1:Des")]
    [InlineData(":Sha512:Aes128")]
    [InlineData(":Sha1:Aes512")]
    [InlineData(":Sha1")]
    [InlineData(":Sha1:Des:More")]
    public void A_kept_login_with_protocols_this_version_didn_t_write_is_no_login(string tail)
    {
        var secret = Login(User(SnmpAuth.Sha256, SnmpPriv.Aes128)).ToSecret() + tail;
        Assert.Null(SnmpLogin.FromSecret(secret));
    }

    [Fact]
    public void A_protocol_that_isn_t_one_is_refused() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => SnmpLogin.ForUser("u", "authpass-2026", "privpass-2026", out _, (SnmpAuth)9));

    [Fact]
    public void The_digest_placeholder_has_the_protocol_s_length()
    {
        var keys = Usm.Keys.For(User(SnmpAuth.Sha1, SnmpPriv.Aes128), Engine);
        var bytes = new SnmpV3Message
        {
            MessageId = 1, Flags = SnmpV3Message.FlagAuth, EngineId = Engine, UserName = "reader", ContextEngineId = Engine,
            Pdu = new SnmpMessage(SnmpVersion.V3, "", SnmpPduType.GetRequest, 1, 0, 0, []),
        }.Sign(keys);
        var read = SnmpV3Message.Decode(bytes);
        Assert.Equal(12, read.AuthParameters.Length);
        Assert.True(read.Verify(bytes, keys));
        Assert.False(read.Verify(bytes, Usm.Keys.For(User(SnmpAuth.Sha256, SnmpPriv.Aes128), Engine))); // another length: no digest of it
        Assert.True(CryptographicOperations.FixedTimeEquals(read.AuthParameters, keys.Sign(ZeroAt(bytes, read.AuthOffset, 12))));

        static byte[] ZeroAt(byte[] b, int at, int n)
        {
            var copy = (byte[])b.Clone();
            Array.Clear(copy, at, n);
            return copy;
        }
    }
}
