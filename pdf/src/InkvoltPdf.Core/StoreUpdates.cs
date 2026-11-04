namespace InkvoltPdf.Core;

/// <summary>What the Microsoft Store has for this app: how many package updates, and whether any is mandatory.</summary>
public sealed record StoreUpdateInfo(int Count, bool Mandatory);

public enum StoreInstallOutcome { Completed, Canceled, Failed }

/// <summary>
/// The Store's update calls (Windows.Services.Store in the app; a fake in tests). Talks only to Windows' own Store service.
/// </summary>
public interface IStoreUpdates
{
    /// <summary>The updates the Store has for this package now. Throws when the Store can't be asked (offline, sideloaded).</summary>
    Task<StoreUpdateInfo> FindAsync(CancellationToken cancel = default);

    /// <summary>Downloads and installs the updates last found; Windows closes the app while it installs them.</summary>
    Task<StoreInstallOutcome> InstallAsync(CancellationToken cancel = default);
}

/// <summary>Why the check runs: by itself after startup, or Help › Check for Updates.</summary>
public enum UpdateCheckTrigger { Startup, User }

public enum UpdateCheckResult
{
    /// <summary>Not checked: a startup check with the setting off, or an unpackaged copy at startup.</summary>
    Skipped,
    /// <summary>The user asked, but this copy isn't a Store install.</summary>
    NotFromStore,
    UpToDate,
    Ready,
    Mandatory,
    /// <summary>The Store didn't answer (offline, sideloaded or dev package).</summary>
    Failed,
}

/// <summary>
/// When to ask the Store about updates and what to tell the user. Startup checks are silent unless an update is ready;
/// a check the user asked for always answers.
/// </summary>
public static class UpdateCheck
{
    public static readonly TimeSpan StartupDelay = TimeSpan.FromSeconds(30);

    public static string NotFromStoreText => PdfStrings.Store_NotFromStore;
    public static string UpToDateText => PdfStrings.Store_UpToDate;
    public static string FailedText => PdfStrings.Store_Failed;

    public static async Task<UpdateCheckResult> RunAsync(IStoreUpdates store, UpdateCheckTrigger trigger, bool packaged, bool checkAtStartup,
        Action<string>? log = null, CancellationToken cancel = default)
    {
        if (!packaged) return trigger == UpdateCheckTrigger.User ? UpdateCheckResult.NotFromStore : UpdateCheckResult.Skipped;
        if (trigger == UpdateCheckTrigger.Startup && !checkAtStartup) return UpdateCheckResult.Skipped;
        StoreUpdateInfo info;
        try
        {
            info = await store.FindAsync(cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            return UpdateCheckResult.Skipped;
        }
        catch (Exception ex)
        {
            log?.Invoke($"Store update check failed ({trigger}): {ex.GetType().Name}: {ex.Message}");
            return UpdateCheckResult.Failed;
        }
        log?.Invoke($"Store update check ({trigger}): {info.Count} update(s){(info.Mandatory ? ", mandatory" : "")}");
        return info.Count <= 0 ? UpdateCheckResult.UpToDate : info.Mandatory ? UpdateCheckResult.Mandatory : UpdateCheckResult.Ready;
    }

    /// <summary>Whether the main window shows the update notice for this result.</summary>
    public static bool ShowsNotice(UpdateCheckResult result) => result is UpdateCheckResult.Ready or UpdateCheckResult.Mandatory;

    /// <summary>Whether to tell the user about this result: startup checks only speak up when an update is ready.</summary>
    public static string? Message(UpdateCheckResult result, UpdateCheckTrigger trigger) => result switch
    {
        UpdateCheckResult.Ready or UpdateCheckResult.Mandatory => NoticeText(result == UpdateCheckResult.Mandatory),
        _ when trigger == UpdateCheckTrigger.Startup => null,
        UpdateCheckResult.NotFromStore => NotFromStoreText,
        UpdateCheckResult.UpToDate => UpToDateText,
        UpdateCheckResult.Failed => FailedText,
        _ => null,
    };

    /// <summary>The notice's text; a mandatory update says so more firmly (reading still goes on).</summary>
    public static string NoticeText(bool mandatory) => mandatory
        ? PdfStrings.Store_RequiredReady
        : PdfStrings.Store_UpdateReady;

    /// <summary>What to say after the install request comes back (when Windows hasn't already closed the app).</summary>
    public static string? InstallMessage(StoreInstallOutcome outcome) => outcome switch
    {
        StoreInstallOutcome.Completed => null,
        StoreInstallOutcome.Canceled => PdfStrings.Store_Canceled,
        _ => PdfStrings.Store_InstallFailed,
    };
}
