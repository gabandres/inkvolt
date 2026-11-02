using System.Security.Cryptography;
using System.Text.Json;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Tests;

/// <summary>
/// Tests that touch the Pro check's globals (<see cref="Pro.Store"/>, <see cref="Pro.Enforced"/>) run one class at a time:
/// the command line asks the same check.
/// </summary>
[CollectionDefinition("Pro")]
public sealed class ProCollection;

/// <summary>
/// The Inkvolt Pro licence: the key format (pdf/tools/pro-key/README.md; <c>ProKeys</c> in InkvoltPrint.Core/Suite, shared
/// with Inkvolt Print), its checks, install and remove, the gate, as Inkvolt PDF's <see cref="Pro"/> presents them.
/// </summary>
[Collection("Pro")]
public sealed class ProTests : IDisposable
{
    private static readonly ProLicence Ada = new("Ada Lovelace", "ada@example.com", new DateOnly(2026, 10, 30), ["pdf", "print"]);

    private readonly ECDsa _signer = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    private readonly byte[] _public;

    public ProTests()
    {
        var q = _signer.ExportParameters(false).Q;
        _public = [4, .. q.X!, .. q.Y!];
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
    }

    public void Dispose()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
        _signer.Dispose();
    }

    private string Issue(ProLicence licence) => ProKeys.Issue(licence, _signer);

    private static string Refusal(string key, byte[] publicKey) => Assert.Throws<ProKeyException>(() => ProKeys.Parse(key, publicKey)).Message;

    [Fact]
    public void A_key_reads_back_what_was_issued()
    {
        var key = Issue(Ada);
        Assert.StartsWith("INKVOLT-PRO-", key);
        Assert.Matches("^INKVOLT-PRO-([A-Z2-7]{5}-)*[A-Z2-7]{1,5}$", key);
        var read = ProKeys.Parse(key, _public);
        Assert.Equal(("Ada Lovelace", "ada@example.com", new DateOnly(2026, 10, 30)), (read.Name, read.Email, read.Issued));
        Assert.Equal(["pdf", "print"], read.Products);
        Assert.True(read.Covers("pdf"));
        Assert.False(new ProLicence("P", "p@x", read.Issued, ["print"]).Covers("pdf"));
    }

    [Fact]
    public void Spacing_case_and_line_breaks_from_an_email_dont_matter()
    {
        var key = Issue(Ada);
        var mangled = "  " + key.ToLowerInvariant().Replace("-", " ").Insert(40, "\r\n") + "\n";
        Assert.Equal("Ada Lovelace", ProKeys.Parse(mangled, _public).Name);
        Assert.Equal(key, ProKeys.Format(mangled));
    }

    [Fact]
    public void Names_in_any_script_round_trip()
    {
        var licence = Ada with { Name = "José Núñez 李", Email = "josé@example.com" };
        Assert.Equal(("José Núñez 李", "josé@example.com"), ProKeys.Parse(Issue(licence), _public) is var r ? (r.Name, r.Email) : default);
    }

    [Fact]
    public void A_changed_character_is_refused_as_altered()
    {
        var key = Issue(Ada);
        var i = key.IndexOf("-", 20, StringComparison.Ordinal) + 1; // inside the payload (the name)
        var tampered = key[..i] + (key[i] == 'A' ? 'B' : 'A') + key[(i + 1)..];
        Assert.Contains("altered", Refusal(tampered, _public));
        var cut = key[..^12]; // the end of the signature missing
        Assert.Contains("altered", Refusal(cut, _public));
    }

    [Fact]
    public void A_key_signed_with_another_key_is_refused()
    {
        using var other = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Assert.Contains("altered", Refusal(ProKeys.Issue(Ada, other), _public));
    }

    [Fact]
    public void A_newer_format_version_is_refused_saying_to_update()
    {
        var payload = ProKeys.Payload(Ada);
        payload[0] = 2;
        Assert.Contains("newer version", Refusal(ProKeys.Encode(payload, _signer), _public));
    }

    [Fact]
    public void Wrong_prefix_bad_characters_and_too_little_are_refused_in_plain_words()
    {
        Assert.Contains("Paste the key", Refusal("", _public));
        Assert.Contains("starts with INKVOLT-PRO-", Refusal("ABCDE-FGHIJ", _public));
        Assert.Contains("starts with INKVOLT-PRO-", Refusal("INKVOLT-PRINT-ABCDE", _public));
        Assert.Contains("character that doesn't belong", Refusal("INKVOLT-PRO-ABCD1-0EFGH", _public));
        Assert.Contains("incomplete", Refusal("INKVOLT-PRO-ABCDE-FGHIJ", _public));
    }

    [Fact]
    public void A_payload_that_isnt_four_lines_is_refused_even_when_signed()
    {
        var bad = ProKeys.Encode([ProKeys.Version, .. "Ada\nada@example.com\n2026-10-30"u8], _signer);
        Assert.Contains("can't be read", Refusal(bad, _public));
        var badDate = ProKeys.Encode([ProKeys.Version, .. "Ada\nada@example.com\nOctober\npdf"u8], _signer);
        Assert.Contains("can't be read", Refusal(badDate, _public));
    }

    [Fact]
    public void Issuing_refuses_an_empty_name_or_unknown_product()
    {
        Assert.Throws<ArgumentException>(() => Issue(Ada with { Name = " " }));
        Assert.Throws<ArgumentException>(() => Issue(Ada with { Email = "a\nb" }));
        Assert.Throws<ArgumentException>(() => Issue(Ada with { Products = ["word"] }));
        Assert.Throws<ArgumentException>(() => Issue(Ada with { Products = [] }));
    }

    [Fact]
    public void Base32_round_trips_every_length()
    {
        for (var n = 0; n < 12; n++)
        {
            var bytes = Enumerable.Range(0, n).Select(i => (byte)(i * 37 + 11)).ToArray();
            var text = ProKeys.ToBase32(bytes);
            Assert.Equal((n * 8 + 4) / 5, text.Length);
            Assert.Equal(bytes, ProKeys.FromBase32(text));
        }
    }

    // ───────────── the committed test vector, against the public key built in ─────────────

    private static JsonElement Vector()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return JsonDocument.Parse(File.ReadAllText(Path.Combine(dir.FullName, "pdf", "tools", "pro-key", "test-vector.json"))).RootElement;
    }

    [Fact]
    public void The_test_vector_matches_the_public_key_in_core()
    {
        var v = Vector();
        Assert.Equal(ProKeys.PublicKeyBase64, v.GetProperty("publicKey").GetString());
        Assert.Equal(65, ProKeys.PublicKey.Length);
        Assert.Equal(4, ProKeys.PublicKey[0]);

        var valid = v.GetProperty("valid");
        var licence = ProKeys.Parse(valid.GetProperty("key").GetString()!);
        Assert.Equal(valid.GetProperty("name").GetString(), licence.Name);
        Assert.Equal(valid.GetProperty("email").GetString(), licence.Email);
        Assert.Equal(DateOnly.Parse(valid.GetProperty("issued").GetString()!), licence.Issued);
        Assert.Equal(valid.GetProperty("products").EnumerateArray().Select(p => p.GetString()!), licence.Products);

        Assert.Contains("altered", Assert.Throws<ProKeyException>(() => ProKeys.Parse(v.GetProperty("tampered").GetProperty("key").GetString()!)).Message);

        var printOnly = ProKeys.Parse(v.GetProperty("printOnly").GetProperty("key").GetString()!);
        Assert.Equal(["print"], printOnly.Products);
    }

    // ───────────── install, remove, the gate ─────────────

    private static string VectorKey(string which) => Vector().GetProperty(which).GetProperty("key").GetString()!;

    [Fact]
    public void Install_keeps_the_key_in_the_store_and_remove_forgets_it()
    {
        var store = new MemoryProStore();
        Pro.Store = store;
        Assert.Null(Pro.Licence);

        var key = VectorKey("valid");
        var licence = Pro.Install("  " + key.ToLowerInvariant() + "\n");
        Assert.Equal("Ada Lovelace", licence.Name);
        Assert.Equal(key, store.Read()); // stored as it is shown: prefix and groups of five
        Assert.Equal("Ada Lovelace", Pro.Licence?.Name);
        Assert.Null(Pro.Problem);

        Pro.Store = store; // another run, same settings
        Assert.Equal("Ada Lovelace", Pro.Licence?.Name);

        Pro.Remove();
        Assert.Null(store.Read());
        Assert.Null(Pro.Licence);
    }

    [Fact]
    public void A_key_for_print_only_or_a_bad_key_isnt_installed()
    {
        Assert.Contains("Inkvolt Print, not Inkvolt PDF", Assert.Throws<ProKeyException>(() => Pro.Install(VectorKey("printOnly"))).Message);
        Assert.Contains("altered", Assert.Throws<ProKeyException>(() => Pro.Install(VectorKey("tampered"))).Message);
        Assert.Null(Pro.Licence);
        Assert.Null(Pro.Store.Read());
    }

    [Fact]
    public void A_stored_key_that_no_longer_checks_out_counts_as_none_and_says_why()
    {
        Pro.Store = new MemoryProStore(VectorKey("tampered"));
        Assert.Null(Pro.Licence);
        Assert.Contains("no longer checks out", Pro.Problem);
        Pro.Store = new MemoryProStore(VectorKey("printOnly"));
        Assert.Null(Pro.Licence);
        Assert.Contains("Inkvolt Print", Pro.Problem);
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
        Assert.False(Pro.Allows(ProFeature.CommandLine));
    }

    [Fact]
    public async Task The_command_line_without_a_licence_says_so_and_exits_2_only_when_enforced()
    {
        var error = new StringWriter();
        Pro.Enforced = true;
        var code = await BatchCommandLine.RunAsync(["--batch", "none.json", "a.pdf"], new StringWriter(), error, new BatchHost(), CancellationToken.None);
        Assert.Equal(BatchCommandLine.Wrong, code);
        Assert.Contains("part of Inkvolt Pro", error.ToString());
        Assert.Contains(Pro.BuyUrl, error.ToString());

        Pro.Enforced = false;
        error = new StringWriter();
        code = await BatchCommandLine.RunAsync(["--batch", "none.json", "a.pdf"], new StringWriter(), error, new BatchHost(), CancellationToken.None);
        Assert.Equal(BatchCommandLine.Wrong, code); // the preset is missing, not the licence
        Assert.DoesNotContain("Inkvolt Pro", error.ToString());
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
    }

    [Fact]
    public void Accessibility_remediation_is_pro_and_checking_stays_free()
    {
        Assert.Equal("Make Accessible is part of Inkvolt Pro.", Pro.Locked(ProFeature.AutoTagging));
        Assert.Equal("Fixing the reading order is part of Inkvolt Pro.", Pro.Locked(ProFeature.ReadingOrder));
        Assert.Equal("Saving accessible PDF/A-2a files is part of Inkvolt Pro.", Pro.Locked(ProFeature.AccessibleOutput));
        Assert.Equal("Make Accessible", Pro.Title(ProFeature.AutoTagging));
        Assert.Equal("Searching folders is part of Inkvolt Pro.", Pro.Locked(ProFeature.FolderSearch));
        Assert.Equal("Comparing Office files, scans and formatting is part of Inkvolt Pro.", Pro.Locked(ProFeature.CompareOfficeAndScans));
        Assert.Equal("Folder search", Pro.Title(ProFeature.FolderSearch));
        Assert.Contains("on this PC", Pro.Describe(ProFeature.FolderSearch));
        Assert.Contains("on this PC", Pro.Describe(ProFeature.AutoTagging));

        Assert.Equal(ProFeature.AutoTagging, new MakeAccessibleStep().Feature);
        Assert.Equal(ProFeature.AccessibleOutput, new SaveAsPdfAStep { Conformance = PdfAConformance.A }.Feature);
        Assert.Null(new SaveAsPdfAStep().Feature); // PDF/A-2b stays free
        Assert.Null(new CheckAccessibilityStep().Feature); // the checker and its report stay free
    }

    [Fact]
    public void Batch_with_make_accessible_or_pdfa_2a_needs_pro_only_when_enforced()
    {
        var folder = Path.GetTempPath();
        BatchPlan Plan(params BatchStep[] steps) => new() { Steps = steps, OutputFolder = folder };

        Pro.Enforced = false;
        Assert.Null(Plan(new MakeAccessibleStep(), new SaveAsPdfAStep { Conformance = PdfAConformance.A }).Validate(false));

        Pro.Enforced = true;
        Assert.Equal(Pro.Locked(ProFeature.AutoTagging), Plan(new MakeAccessibleStep()).Validate(false));
        Assert.Equal(Pro.Locked(ProFeature.AccessibleOutput), Plan(new SaveAsPdfAStep { Conformance = PdfAConformance.A }).Validate(false));
        Assert.Null(Plan(new CheckAccessibilityStep(), new SaveAsPdfAStep()).Validate(false));
        Pro.Install(VectorKey("valid"));
        Assert.Null(Plan(new MakeAccessibleStep(), new SaveAsPdfAStep { Conformance = PdfAConformance.A }).Validate(false));
    }
}
