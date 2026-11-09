using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>This PC's processor, as a maker's download is built for it.</summary>
public enum PcArch { X64, Arm64 }

/// <summary>This PC's Windows, as a maker's download page lists it.</summary>
public enum PcWindows { Windows10, Windows11 }

/// <summary>What to look for: a model of a maker's, for this PC.</summary>
public sealed record DriverQuery(string Maker, string Model, NeedsDriverKind Kind, PcArch Arch, PcWindows Windows)
{
    public static DriverQuery For(NeedsDriverPrinter device, PcArch arch, PcWindows windows) =>
        new(device.Maker ?? "", device.Name, device.Kind, arch, windows);
}

/// <summary>A download a maker's page offers for the model: what the confirmation shows, and where it comes from.</summary>
/// <param name="SizeText">The size as the page says it ("29.5 MB"): shown only; the file's own length is what's checked.</param>
public sealed record DriverOffer(string Title, string? Version, string? SizeText, Uri Download, string FileName, Uri Page);

/// <summary>Why no download was offered.</summary>
public enum NoOffer
{
    /// <summary>Inkvolt Print doesn't look up this maker's downloads (the maker's page and Windows Update instead).</summary>
    MakerNotLookedUp,

    /// <summary>The maker's site has no page for the model, or its page no driver for this Windows.</summary>
    NotFound,

    /// <summary>The model's page has drivers, none of them for ARM64 (this PC's processor).</summary>
    NoArm64,

    /// <summary>The maker's site didn't answer, or answered something that can't be read.</summary>
    Unreachable,
}

/// <summary>What a look found: a download, or why there's none (and the maker's page for the model when one was found).</summary>
public sealed record DriverLookup(DriverOffer? Offer, NoOffer? Why = null, Uri? Page = null, FetchProblem? Problem = null)
{
    public static DriverLookup Found(DriverOffer offer) => new(offer);

    public static DriverLookup None(NoOffer why, Uri? page = null, FetchProblem? problem = null) => new(null, why, page, problem);
}

/// <summary>Finds a model's driver on its maker's site (the seam: <see cref="EpsonDrivers"/>, demo mode's and the tests' fakes).</summary>
public interface IDriverCatalog
{
    bool LooksUp(string? maker);

    Task<DriverLookup> FindAsync(DriverQuery query, CancellationToken ct);
}

/// <summary>
/// The makers whose downloads Inkvolt Print may fetch: the hosts its pages and files come from (https, exactly these names) and the
/// organizations that sign its installers. Nothing else is downloaded or run.
/// </summary>
public sealed record MakerSource(string Maker, IReadOnlyList<string> PageHosts, IReadOnlyList<string> DownloadHosts, IReadOnlyList<string> Signers)
{
    public static readonly MakerSource Epson = new("Epson",
        ["epson.com", "www.epson.com"],
        ["ftp.epson.com", "download.epson.com", "download.ebz.epson.net", "download2.ebz.epson.net", "download3.ebz.epson.net"],
        ["Epson America, Inc.", "Seiko Epson Corporation", "Epson Europe B.V."]);

    public static IReadOnlyList<MakerSource> All { get; } = [Epson];

    public static MakerSource? For(string? maker) => All.FirstOrDefault(m => string.Equals(m.Maker, maker, StringComparison.OrdinalIgnoreCase));

    /// <summary>The signer is one of this maker's (the organization in the signing certificate, case and spacing aside).</summary>
    public bool IsSigner(string? organization) =>
        organization is { Length: > 0 } o && Signers.Any(s => string.Equals(Normalize(s), Normalize(o), StringComparison.OrdinalIgnoreCase));

    private static string Normalize(string s) => string.Join(' ', s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}

/// <summary>The catalogs Inkvolt Print has, one per maker; a maker without one is <see cref="NoOffer.MakerNotLookedUp"/>.</summary>
public sealed class MakerCatalogs(params IDriverCatalog[] catalogs) : IDriverCatalog
{
    public bool LooksUp(string? maker) => catalogs.Any(c => c.LooksUp(maker));

    public Task<DriverLookup> FindAsync(DriverQuery query, CancellationToken ct) =>
        catalogs.FirstOrDefault(c => c.LooksUp(query.Maker)) is { } c ? c.FindAsync(query, ct) : Task.FromResult(DriverLookup.None(NoOffer.MakerNotLookedUp));
}
