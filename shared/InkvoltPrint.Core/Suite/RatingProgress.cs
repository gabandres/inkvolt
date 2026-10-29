namespace InkvoltPrint.Core.Suite;

/// <summary>
/// When an Inkvolt app asks for a Microsoft Store rating: once ever, after the app has done its job for the person
/// <see cref="SuccessesNeeded"/> times (Inkvolt PDF: saved a document; Inkvolt Print: saved a scan or sent a print), the
/// first of them at least <see cref="Wait"/> ago, so never during the first session. The Store's own rating window does the
/// asking; closing it counts as asked. Kept in each app's settings file; nothing leaves the PC.
/// </summary>
/// <param name="Successes">How many times the app has done its job.</param>
/// <param name="FirstSuccess">When it first did.</param>
/// <param name="Asked">When the rating window was shown, if it was.</param>
public sealed record RatingProgress(int Successes = 0, DateTimeOffset? FirstSuccess = null, DateTimeOffset? Asked = null)
{
    public const int SuccessesNeeded = 5;

    public static readonly TimeSpan Wait = TimeSpan.FromDays(2);

    public RatingProgress Record(DateTimeOffset now) => this with { Successes = Successes + 1, FirstSuccess = FirstSuccess ?? now };

    public bool ShouldAsk(DateTimeOffset now) =>
        Asked is null && Successes >= SuccessesNeeded && FirstSuccess is { } first && now - first >= Wait;

    public RatingProgress MarkAsked(DateTimeOffset now) => this with { Asked = Asked ?? now };

    /// <summary>
    /// Two windows' copies of the progress (an app's settings file merged with another process's): the higher count, the
    /// earliest first success, and asked if either asked, so the window never comes twice.
    /// </summary>
    public static RatingProgress? Merge(RatingProgress? a, RatingProgress? b) => (a, b) switch
    {
        (null, _) => b,
        (_, null) => a,
        _ => new(Math.Max(a.Successes, b.Successes), Earliest(a.FirstSuccess, b.FirstSuccess), Earliest(a.Asked, b.Asked)),
    };

    private static DateTimeOffset? Earliest(DateTimeOffset? a, DateTimeOffset? b) =>
        a is null ? b : b is null ? a : a < b ? a : b;
}
