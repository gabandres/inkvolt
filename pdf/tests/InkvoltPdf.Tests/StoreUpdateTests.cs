using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>When the Store update check asks, and what it tells the user (the Store itself is faked).</summary>
public class StoreUpdateTests
{
    private sealed class FakeStore(Func<StoreUpdateInfo> find) : IStoreUpdates
    {
        public int Finds { get; private set; }

        public Task<StoreUpdateInfo> FindAsync(CancellationToken cancel = default)
        {
            Finds++;
            return Task.FromResult(find());
        }

        public Task<StoreInstallOutcome> InstallAsync(CancellationToken cancel = default) => Task.FromResult(StoreInstallOutcome.Completed);
    }

    private static FakeStore Has(int count, bool mandatory = false) => new(() => new StoreUpdateInfo(count, mandatory));

    [Fact]
    public async Task An_update_found_at_startup_shows_the_notice()
    {
        var store = Has(1);
        var result = await UpdateCheck.RunAsync(store, UpdateCheckTrigger.Startup, packaged: true, checkAtStartup: true);
        Assert.Equal(UpdateCheckResult.Ready, result);
        Assert.True(UpdateCheck.ShowsNotice(result));
        Assert.Equal("An update to Inkvolt PDF is ready", UpdateCheck.Message(result, UpdateCheckTrigger.Startup));
        Assert.Equal(1, store.Finds);
    }

    [Fact]
    public async Task A_mandatory_update_says_so_more_firmly()
    {
        var result = await UpdateCheck.RunAsync(Has(2, mandatory: true), UpdateCheckTrigger.Startup, packaged: true, checkAtStartup: true);
        Assert.Equal(UpdateCheckResult.Mandatory, result);
        Assert.True(UpdateCheck.ShowsNotice(result));
        Assert.Contains("required", UpdateCheck.Message(result, UpdateCheckTrigger.Startup));
    }

    [Fact]
    public async Task Nothing_new_at_startup_stays_silent_but_answers_when_asked()
    {
        var startup = await UpdateCheck.RunAsync(Has(0), UpdateCheckTrigger.Startup, packaged: true, checkAtStartup: true);
        Assert.Equal(UpdateCheckResult.UpToDate, startup);
        Assert.False(UpdateCheck.ShowsNotice(startup));
        Assert.Null(UpdateCheck.Message(startup, UpdateCheckTrigger.Startup));

        var asked = await UpdateCheck.RunAsync(Has(0), UpdateCheckTrigger.User, packaged: true, checkAtStartup: true);
        Assert.Equal(UpdateCheck.UpToDateText, UpdateCheck.Message(asked, UpdateCheckTrigger.User));
    }

    [Fact]
    public async Task The_setting_off_skips_the_startup_check_but_not_the_menu()
    {
        var store = Has(1);
        Assert.Equal(UpdateCheckResult.Skipped, await UpdateCheck.RunAsync(store, UpdateCheckTrigger.Startup, packaged: true, checkAtStartup: false));
        Assert.Equal(0, store.Finds);
        Assert.Equal(UpdateCheckResult.Ready, await UpdateCheck.RunAsync(store, UpdateCheckTrigger.User, packaged: true, checkAtStartup: false));
        Assert.Equal(1, store.Finds);
    }

    [Fact]
    public async Task An_unpackaged_copy_never_asks_the_Store()
    {
        var store = Has(1);
        var startup = await UpdateCheck.RunAsync(store, UpdateCheckTrigger.Startup, packaged: false, checkAtStartup: true);
        Assert.Equal(UpdateCheckResult.Skipped, startup);
        Assert.Null(UpdateCheck.Message(startup, UpdateCheckTrigger.Startup));

        var asked = await UpdateCheck.RunAsync(store, UpdateCheckTrigger.User, packaged: false, checkAtStartup: true);
        Assert.Equal(UpdateCheckResult.NotFromStore, asked);
        Assert.Equal(UpdateCheck.NotFromStoreText, UpdateCheck.Message(asked, UpdateCheckTrigger.User));
        Assert.Equal(0, store.Finds);
    }

    [Fact]
    public async Task A_Store_error_is_logged_silent_at_startup_and_explained_when_asked()
    {
        var store = new FakeStore(() => throw new System.Runtime.InteropServices.COMException("No Store license", unchecked((int)0x803F6107)));
        var lines = new List<string>();
        var startup = await UpdateCheck.RunAsync(store, UpdateCheckTrigger.Startup, packaged: true, checkAtStartup: true, lines.Add);
        Assert.Equal(UpdateCheckResult.Failed, startup);
        Assert.False(UpdateCheck.ShowsNotice(startup));
        Assert.Null(UpdateCheck.Message(startup, UpdateCheckTrigger.Startup));
        Assert.Contains(lines, l => l.Contains("failed") && l.Contains("No Store license"));

        var asked = await UpdateCheck.RunAsync(store, UpdateCheckTrigger.User, packaged: true, checkAtStartup: true);
        Assert.Equal(UpdateCheck.FailedText, UpdateCheck.Message(asked, UpdateCheckTrigger.User));
    }

    [Fact]
    public async Task A_cancelled_check_is_quiet()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var store = new FakeStore(() => throw new OperationCanceledException(cts.Token));
        var result = await UpdateCheck.RunAsync(store, UpdateCheckTrigger.User, packaged: true, checkAtStartup: true, cancel: cts.Token);
        Assert.Equal(UpdateCheckResult.Skipped, result);
        Assert.Null(UpdateCheck.Message(result, UpdateCheckTrigger.User));
    }

    [Fact]
    public void Only_a_failed_or_canceled_install_has_something_to_say()
    {
        Assert.Null(UpdateCheck.InstallMessage(StoreInstallOutcome.Completed));
        Assert.Contains("canceled", UpdateCheck.InstallMessage(StoreInstallOutcome.Canceled));
        Assert.Contains("couldn't be installed", UpdateCheck.InstallMessage(StoreInstallOutcome.Failed));
    }
}
