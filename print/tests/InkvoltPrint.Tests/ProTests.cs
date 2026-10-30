using System.Security.Cryptography;
using System.Text.Json;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Tests that touch the Pro check's globals (<see cref="Pro.Store"/>, <see cref="ProCheck.Enforced"/>) run one class at a time.
/// </summary>
[CollectionDefinition("Pro")]
public sealed class ProCollection;

/// <summary>
/// The Inkvolt Pro licence as Inkvolt Print sees it: the shared key (Suite/ProKeys, the test vector in
/// pdf/tools/pro-key/test-vector.json read in place), the products a key lists, the gate, and the file both apps read
/// (Suite/ProKeyFile), with any folder standing in for %LOCALAPPDATA%.
/// </summary>
[Collection("Pro")]
public sealed class ProTests : IDisposable
{
    private readonly string _localAppData = Path.Combine(Path.GetTempPath(), "InkvoltProTests", Guid.NewGuid().ToString("N"));

    public ProTests()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
        Directory.CreateDirectory(_localAppData);
    }

    public void Dispose()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
        try { Directory.Delete(_localAppData, recursive: true); }
        catch (IOException) { }
    }

    // ───────────── the committed test vector, against the public key built in ─────────────

    private static JsonElement Vector()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return JsonDocument.Parse(File.ReadAllText(Path.Combine(dir.FullName, "pdf", "tools", "pro-key", "test-vector.json"))).RootElement;
    }

    private static string VectorKey(string which) => Vector().GetProperty(which).GetProperty("key").GetString()!;

    [Fact]
    public void The_test_vector_reads_with_the_public_key_in_the_shared_library()
    {
        var v = Vector();
        Assert.Equal(ProKeys.PublicKeyBase64, v.GetProperty("publicKey").GetString());
        var valid = v.GetProperty("valid");
        var licence = ProKeys.Parse(valid.GetProperty("key").GetString()!);
        Assert.Equal(valid.GetProperty("name").GetString(), licence.Name);
        Assert.Equal(valid.GetProperty("products").EnumerateArray().Select(p => p.GetString()!), licence.Products);
        Assert.True(licence.Covers(ProKeys.ProductPrint));
        Assert.Contains("altered", Assert.Throws<ProKeyException>(() => ProKeys.Parse(VectorKey("tampered"))).Message);
    }

    [Fact]
    public void Every_changed_character_of_a_key_is_refused()
    {
        var key = VectorKey("valid");
        var start = ProKeys.Prefix.Length;
        for (var i = start; i < key.Length; i++)
        {
            if (key[i] == '-') continue;
            var other = key[i] == 'A' ? 'B' : 'A';
            var changed = key[..i] + other + key[(i + 1)..];
            var refusal = Assert.Throws<ProKeyException>(() => ProKeys.Parse(changed)).Message;
            Assert.True(refusal.Contains("altered") || refusal.Contains("newer version") || refusal.Contains("can't be read"), $"position {i}: {refusal}");
        }
    }

    [Fact]
    public void A_key_signed_by_a_test_pair_passes_and_one_signed_by_another_fails()
    {
        using var signer = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var q = signer.ExportParameters(false).Q;
        byte[] pub = [4, .. q.X!, .. q.Y!];
        var licence = new ProLicence("Grace Hopper", "grace@example.com", new DateOnly(2026, 11, 1), ["print"]);
        var key = ProKeys.Issue(licence, signer);
        Assert.Equal(licence, ProKeys.Parse(key, pub) with { Products = licence.Products });
        Assert.Equal(["print"], ProKeys.Parse(key, pub).Products);
        Assert.Contains("altered", Assert.Throws<ProKeyException>(() => ProKeys.Parse(key)).Message); // not Inkvolt's key
    }

    // ───────────── products: a key for Inkvolt Print, for Inkvolt PDF, for both ─────────────

    [Fact]
    public void A_print_only_key_installs_here_and_is_refused_by_the_pdf_check()
    {
        var licence = Pro.Install(VectorKey("printOnly"));
        Assert.Equal(["print"], licence.Products);
        Assert.NotNull(Pro.Licence);
        Assert.Null(Pro.Problem);

        var pdf = new ProCheck(ProKeys.ProductPdf) { Store = new MemoryProStore(VectorKey("printOnly")) };
        Assert.Null(pdf.Licence);
        Assert.Equal("The saved key is for Inkvolt Print, not Inkvolt PDF.", pdf.Problem);
        Assert.Equal("This key is for Inkvolt Print, not Inkvolt PDF. A key for Inkvolt PDF lists it.",
            Assert.Throws<ProKeyException>(() => pdf.Install(VectorKey("printOnly"))).Message);
    }

    [Fact]
    public void A_pdf_only_key_is_refused_here_in_plain_words()
    {
        using var signer = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var q = signer.ExportParameters(false).Q;
        byte[] pub = [4, .. q.X!, .. q.Y!];
        var key = ProKeys.Issue(new ProLicence("Ada", "ada@example.com", new DateOnly(2026, 10, 30), ["pdf"]), signer);
        // Install checks against Inkvolt's key first (this one isn't signed by it), so test the product check on a parsed licence.
        Assert.False(ProKeys.Parse(key, pub).Covers(Pro.Product));
        Assert.Contains("altered", Assert.Throws<ProKeyException>(() => Pro.Install(key)).Message);
        Assert.Null(Pro.Licence);
    }

    [Fact]
    public void With_enforcement_off_everything_is_allowed_with_it_on_a_licence_is_needed()
    {
        Pro.Enforced = false;
        Assert.All(Enum.GetValues<ProFeature>(), f => Assert.True(Pro.Allows(f)));
        Pro.Enforced = true;
        Assert.All(Enum.GetValues<ProFeature>(), f => Assert.False(Pro.Allows(f)));
        Pro.Install(VectorKey("valid"));
        Assert.All(Enum.GetValues<ProFeature>(), f => Assert.True(Pro.Allows(f)));
        Pro.Remove();
        Assert.False(Pro.Allows(ProFeature.FleetExport));
        Assert.Null(Pro.Store.Read());
    }

    [Fact]
    public void Each_feature_has_a_title_a_description_and_a_locked_message()
    {
        foreach (var f in Enum.GetValues<ProFeature>())
        {
            Assert.NotEmpty(Pro.Title(f));
            Assert.Contains(" ", Pro.Describe(f));
            Assert.Contains("Inkvolt Pro", Pro.Locked(f));
        }
        Assert.Contains("$19", Pro.HowToGet);
        Assert.Contains("Inkvolt PDF", Pro.HowToGet);
    }

    // ───────────── the file both apps read ─────────────

    [Fact]
    public void A_key_installed_in_one_app_is_found_by_the_other()
    {
        var pdfSettings = new MemoryProStore();
        var printSettings = new MemoryProStore();
        var pdf = new ProCheck(ProKeys.ProductPdf) { Store = new SharedProStore(pdfSettings, _localAppData) };
        var print = new ProCheck(ProKeys.ProductPrint) { Store = new SharedProStore(printSettings, _localAppData) };
        Assert.Null(print.Licence);

        var key = VectorKey("valid");
        pdf.Install("  " + key.ToLowerInvariant() + "\n");
        Assert.Equal(key, File.ReadAllText(ProKeyFile.PathUnder(_localAppData)).Trim()); // stored as shown: prefix and groups of five
        Assert.Null(pdfSettings.Read()); // the file is the key's home; neither app's settings hold a copy...
        Assert.Null(printSettings.Read());
        print.Store = print.Store; // ...and the other app reads the file afresh
        Assert.Equal("Ada Lovelace", print.Licence?.Name);

        print.Remove();
        Assert.False(File.Exists(ProKeyFile.PathUnder(_localAppData)));
        pdf.Store = pdf.Store;
        Assert.Null(pdf.Licence); // removed in one app: gone for both
    }

    [Fact]
    public void A_key_from_the_apps_own_settings_moves_into_the_shared_file()
    {
        var key = VectorKey("valid");
        var settings = new MemoryProStore(key); // Inkvolt PDF 1.2.1 kept the key in its settings
        var print = new ProCheck(ProKeys.ProductPrint) { Store = new SharedProStore(settings, _localAppData) };
        Assert.Equal("Ada Lovelace", print.Licence?.Name);
        Assert.Equal(key, ProKeyFile.Read(_localAppData));
        Assert.Null(settings.Read());
    }

    [Fact]
    public void When_the_shared_file_cant_be_written_the_apps_own_settings_keep_the_key()
    {
        var blocked = Path.Combine(_localAppData, "blocked");
        File.WriteAllText(blocked, ""); // a file where the Inkvolt folder should go: the key file can't be made
        var settings = new MemoryProStore();
        var print = new ProCheck(ProKeys.ProductPrint) { Store = new SharedProStore(settings, blocked) };
        print.Install(VectorKey("valid"));
        Assert.Equal(VectorKey("valid"), settings.Read());
        print.Store = print.Store;
        Assert.Equal("Ada Lovelace", print.Licence?.Name);
    }

    [Fact]
    public void A_packaged_apps_redirected_copy_is_found_and_the_newest_copy_wins()
    {
        var plain = ProKeyFile.PathUnder(_localAppData);
        var redirected = Path.Combine(_localAppData, "Packages", "BermudezSystems.InkvoltPDF_abc123", "LocalCache", "Local", "Inkvolt", ProKeyFile.FileName);
        var other = Path.Combine(_localAppData, "Packages", "Contoso.Other_abc123", "LocalCache", "Local", "Inkvolt", ProKeyFile.FileName);
        foreach (var f in new[] { plain, redirected, other }) Directory.CreateDirectory(Path.GetDirectoryName(f)!);
        File.WriteAllText(other, "ignored\n");
        File.WriteAllText(plain, "older\n");
        File.WriteAllText(redirected, "newer\n");
        File.SetLastWriteTimeUtc(plain, new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc));
        File.SetLastWriteTimeUtc(redirected, new DateTime(2026, 2, 1, 0, 0, 0, DateTimeKind.Utc));
        Assert.Equal([plain, redirected], ProKeyFile.Candidates(_localAppData));
        Assert.Equal("newer", ProKeyFile.Read(_localAppData));

        Assert.True(ProKeyFile.Write(_localAppData, null));
        Assert.Empty(ProKeyFile.Candidates(_localAppData));
        Assert.True(File.Exists(other)); // not ours
        Assert.Null(ProKeyFile.Read(_localAppData));
    }

    [Fact]
    public void A_stored_key_that_no_longer_checks_out_counts_as_none_and_says_why()
    {
        Pro.Store = new MemoryProStore(VectorKey("tampered"));
        Assert.Null(Pro.Licence);
        Assert.Contains("no longer checks out", Pro.Problem);
    }
}
