using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>
/// Every word "Get the driver" shows (<see cref="CoreStrings"/>, English and Spanish), and the command line's and the log's in
/// English. Never an address but the maker's site's name, never a serial or an instance id, never an exit code or exception text
/// on screen (the log has the exit code).
/// </summary>
public static class DriverText
{
    private static string F(string format, params object?[] args) => string.Format(CoreLanguage.Culture, format, args);

    private static string Maker(NeedsDriverPrinter d) => d.Maker ?? "";

    public static string Button => CoreStrings.GetDriver_Button;

    public static string Note(NeedsDriverPrinter d) => F(d.IsScanner ? CoreStrings.GetDriver_NoteScanner : CoreStrings.GetDriver_NotePrinter, Maker(d));

    public static string Looking(NeedsDriverPrinter d) => F(CoreStrings.GetDriver_Looking, Maker(d));

    public static string Downloading(long bytes) => F(CoreStrings.GetDriver_Downloading, Megabytes(bytes));

    public static string Megabytes(long bytes) => F(CoreStrings.GetDriver_Megabytes, Math.Round(bytes / 1048576.0, 1));

    public static string FoundTitle(NeedsDriverPrinter d) => F(CoreStrings.GetDriver_FoundTitle, Maker(d));

    public static string Facts(DriverReady r) =>
        string.Join(Environment.NewLine,
            F(CoreStrings.GetDriver_FactDriver, r.Offer.Title),
            F(CoreStrings.GetDriver_FactVersion, r.Offer.Version ?? CoreStrings.GetDriver_NotSaid),
            F(CoreStrings.GetDriver_FactSize, Megabytes(r.Bytes)),
            F(CoreStrings.GetDriver_FactSigner, r.Signer));

    /// <summary>What a Store copy shows of a download it will only link to: title, version, size as the page says, and its host.</summary>
    public static string OfferFacts(DriverOffer o) =>
        string.Join(Environment.NewLine,
            F(CoreStrings.GetDriver_FactDriver, o.Title),
            F(CoreStrings.GetDriver_FactVersion, o.Version ?? CoreStrings.GetDriver_NotSaid),
            F(CoreStrings.GetDriver_FactSize, o.SizeText ?? CoreStrings.GetDriver_NotSaid),
            F(CoreStrings.GetDriver_FactFrom, o.Download.IdnHost));

    public static string FoundTitleLink(NeedsDriverPrinter d) => F(CoreStrings.GetDriver_FoundTitleLink, Maker(d));
    public static string OpenLinkButton(NeedsDriverPrinter d) => F(CoreStrings.GetDriver_OpenLinkButton, Maker(d));
    public static string OpenLinkNote(NeedsDriverPrinter d) => F(d.IsScanner ? CoreStrings.GetDriver_OpenLinkNoteScanner : CoreStrings.GetDriver_OpenLinkNotePrinter, Maker(d));
    public static string LookAgainButton => CoreStrings.GetDriver_LookAgainButton;
    public static string Waiting => CoreStrings.GetDriver_Waiting;
    public static string LookingAgain => CoreStrings.GetDriver_LookingAgain;

    public static string FoundIt(NeedsDriverPrinter d) => d.IsScanner ? F(CoreStrings.GetDriver_FoundItScanner, d.Name) : CoreStrings.GetDriver_FoundItPrinter;

    public static string NotYet(NeedsDriverPrinter d) => F(CoreStrings.GetDriver_NotYet, d.Name);

    public static string InstallButton => CoreStrings.GetDriver_InstallButton;
    public static string CancelButton => CoreStrings.GetDriver_CancelButton;
    public static string InstallNote => CoreStrings.GetDriver_InstallNote;
    public static string Installing => CoreStrings.GetDriver_Installing;

    public static string Done(NeedsDriverPrinter d) => d.IsScanner ? F(CoreStrings.GetDriver_DoneScanner, d.Name) : CoreStrings.GetDriver_DonePrinter;

    public static string Outcome(NeedsDriverPrinter d, InstallResult r) => r.Outcome switch
    {
        InstallOutcome.Done => Done(d),
        InstallOutcome.NotSeen => F(CoreStrings.GetDriver_NotSeen, d.Name),
        InstallOutcome.Declined => CoreStrings.GetDriver_Declined,
        InstallOutcome.TimedOut => CoreStrings.GetDriver_TimedOut,
        InstallOutcome.CouldntStart => F(CoreStrings.GetDriver_CouldntStart, Maker(d)),
        _ => F(CoreStrings.GetDriver_Failed, Maker(d)),
    };

    /// <summary>Why nothing is offered; null when the button isn't shown for this maker at all.</summary>
    public static string? Unavailable(NeedsDriverPrinter d, DriverLookup l) => l.Why switch
    {
        NoOffer.NotFound => F(CoreStrings.GetDriver_NotFound, Maker(d), d.Name),
        NoOffer.NoArm64 => F(CoreStrings.GetDriver_NoArm64, Maker(d), d.Name),
        NoOffer.Unreachable => F(CoreStrings.GetDriver_Unreachable, Maker(d)),
        _ => null,
    };

    /// <summary>Why a download wasn't kept (it was deleted, nothing ran).</summary>
    public static string Refused(NeedsDriverPrinter d, DriverDownload r) => r.Why switch
    {
        Refusal.NotAnInstaller => CoreStrings.GetDriver_RefusedNotProgram,
        Refusal.NotSigned => CoreStrings.GetDriver_RefusedNotSigned,
        Refusal.BadSignature => CoreStrings.GetDriver_RefusedBadSignature,
        Refusal.Untrusted => CoreStrings.GetDriver_RefusedUntrusted,
        Refusal.WrongSigner => F(CoreStrings.GetDriver_RefusedWrongSigner, r.Signer ?? "?", Maker(d)),
        Refusal.Fetch => r.Problem switch
        {
            FetchProblem.NotMakersSite or FetchProblem.TooManyRedirects => F(CoreStrings.GetDriver_RefusedOtherSite, Maker(d)),
            FetchProblem.TooBig => CoreStrings.GetDriver_RefusedTooBig,
            FetchProblem.CutShort => CoreStrings.GetDriver_RefusedCutShort,
            FetchProblem.TimedOut => CoreStrings.GetDriver_RefusedTimedOut,
            _ => F(CoreStrings.GetDriver_Unreachable, Maker(d)),
        },
        _ => F(CoreStrings.GetDriver_Failed, Maker(d)),
    };

    public static string Demo => CoreStrings.GetDriver_Demo;

    // ---------------------------------------------------------------- the command line and the log (English)

    public static string EnglishNoOffer(NeedsDriverPrinter d, DriverLookup l) => l.Why switch
    {
        NoOffer.MakerNotLookedUp => $"Inkvolt Print doesn't look up {d.Maker ?? "this maker"}'s drivers",
        NoOffer.NotFound => $"{d.Maker}'s site has no driver for the {d.Name} for this Windows",
        NoOffer.NoArm64 => $"{d.Maker} has no ARM64 driver for the {d.Name}",
        _ => $"{d.Maker}'s site didn't answer ({l.Problem})",
    };

    public static string EnglishRefused(DriverDownload r) =>
        $"refused: {r.Why}{(r.Problem is { } p ? $" ({p})" : "")}{(r.Signer is { } s ? $", signed by \"{s}\"" : "")}; deleted, nothing ran";

    public static string EnglishFacts(DriverReady r) =>
        $"{r.Offer.Title} | version {r.Offer.Version ?? "?"} | {Math.Round(r.Bytes / 1048576.0, 1)} MB | signed by {r.Signer} (valid, trusted) | from {r.Offer.Download.Host}";

    public static string LogLine(NeedsDriverPrinter d, InstallResult r) =>
        $"[{d.Name}] driver install: {r.Outcome}{(r.ExitCode is { } c ? $", installer exit {c}" : "")}{(r.Rescanned ? ", rescanned" : "")}{(r.Elevated ? " (elevated)" : "")}";
}
