using System.IO;
using System.Windows;
using System.Windows.Interop;
using InkvoltPdf.Core;
using Microsoft.Web.WebView2.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Web pages to PDF with the Microsoft Edge WebView2 runtime that Windows provides (Evergreen; part of Windows 11): the
/// page loads in a hidden, private (InPrivate) WebView2 that keeps no cookies or history, then prints itself to PDF
/// (CoreWebView2.PrintToPdfAsync) with the chosen paper, margins and backgrounds. Pop-ups, downloads, permission requests,
/// script dialogs, autofill and password saving are off. Runs on the UI thread (WebView2 needs it); the browser itself
/// runs in its own processes.
/// </summary>
internal static class WebCapture
{
    /// <summary>How long a page may take to load before giving up.</summary>
    private static readonly TimeSpan LoadTimeout = TimeSpan.FromSeconds(60);

    private static string? _version;
    private static bool _checked;

    /// <summary>The installed WebView2 runtime's version, or null when there is none.</summary>
    public static string? RuntimeVersion
    {
        get
        {
            if (_checked) return _version;
            _checked = true;
            try
            {
                _version = CoreWebView2Environment.GetAvailableBrowserVersionString();
            }
            catch (Exception ex) when (ex is WebView2RuntimeNotFoundException or FileNotFoundException or DllNotFoundException or BadImageFormatException)
            {
                Log.Write($"WebView2 runtime not found: {ex.Message}");
                _version = null;
            }
            return _version;
        }
    }

    public const string Unavailable =
        "This needs the Microsoft Edge WebView2 Runtime, which comes with Windows 11 and recent Windows 10 updates. Install it from Microsoft (search for \"WebView2 Runtime\") and try again.";

    /// <summary>Loads <paramref name="source"/> (a web address or a local file) and prints it to PDF bytes.</summary>
    /// <exception cref="InvalidOperationException">The page couldn't be loaded or printed (the message says why).</exception>
    /// <exception cref="OperationCanceledException">Cancelled.</exception>
    public static async Task<byte[]> PrintAsync(Uri source, WebPdfOptions options, Action<string>? status, CancellationToken cancel)
    {
        if (RuntimeVersion is null) throw new InvalidOperationException(Unavailable);
        // A window that is never shown gives the WebView2 controller its parent.
        var host = new Window { Width = 1280, Height = 900, ShowInTaskbar = false, ShowActivated = false, WindowStyle = WindowStyle.None };
        var hwnd = new WindowInteropHelper(host).EnsureHandle();
        CoreWebView2Controller? controller = null;
        var temp = Path.Combine(Path.GetTempPath(), $"inkvolt-web-{Guid.NewGuid():N}.pdf");
        try
        {
            var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(AppPaths.DataDirectory, "WebView2"));
            var controllerOptions = env.CreateCoreWebView2ControllerOptions();
            controllerOptions.IsInPrivateModeEnabled = true;
            controller = await env.CreateCoreWebView2ControllerAsync(hwnd, controllerOptions);
            cancel.ThrowIfCancellationRequested();
            controller.Bounds = new System.Drawing.Rectangle(0, 0, 1280, 900);
            var web = controller.CoreWebView2;
            var s = web.Settings;
            s.AreDevToolsEnabled = false;
            s.AreDefaultContextMenusEnabled = false;
            s.AreDefaultScriptDialogsEnabled = false;
            s.AreHostObjectsAllowed = false;
            s.IsWebMessageEnabled = false;
            s.IsStatusBarEnabled = false;
            s.IsPasswordAutosaveEnabled = false;
            s.IsGeneralAutofillEnabled = false;
            s.IsZoomControlEnabled = false;
            web.NewWindowRequested += (_, e) => e.Handled = true; // pop-ups don't open
            web.DownloadStarting += (_, e) => e.Cancel = true;
            web.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            web.ScriptDialogOpening += (_, _) => { }; // alert/confirm/prompt answer as dismissed

            var loaded = new TaskCompletionSource<CoreWebView2NavigationCompletedEventArgs>(TaskCreationOptions.RunContinuationsAsynchronously);
            web.NavigationCompleted += (_, e) => loaded.TrySetResult(e);
            status?.Invoke(source.IsFile ? "Opening the file…" : $"Loading {source.Host}…");
            web.Navigate(source.AbsoluteUri);
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel))
            {
                timeout.CancelAfter(LoadTimeout);
                CoreWebView2NavigationCompletedEventArgs done;
                try
                {
                    done = await loaded.Task.WaitAsync(timeout.Token);
                }
                catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
                {
                    throw new InvalidOperationException($"The page didn't finish loading within {LoadTimeout.TotalSeconds:0} seconds.");
                }
                if (!done.IsSuccess) throw new InvalidOperationException(Describe(done.WebErrorStatus, done.HttpStatusCode));
            }

            // Let late content arrive: wait for the document to be complete, then scroll to the end and back so pictures
            // that load as they come into view are fetched.
            status?.Invoke("Waiting for the page to settle…");
            for (var i = 0; i < 30 && await web.ExecuteScriptAsync("document.readyState") != "\"complete\""; i++) await Task.Delay(250, cancel);
            await web.ExecuteScriptAsync("window.scrollTo(0, document.documentElement.scrollHeight)");
            await Task.Delay(700, cancel);
            await web.ExecuteScriptAsync("window.scrollTo(0, 0)");
            await Task.Delay(500, cancel);

            status?.Invoke("Making the PDF…");
            var print = env.CreatePrintSettings();
            var (w, h) = options.PageInches;
            print.PageWidth = w;
            print.PageHeight = h;
            print.Orientation = CoreWebView2PrintOrientation.Portrait; // the page size already turned for landscape
            var m = options.MarginInches;
            (print.MarginTop, print.MarginBottom, print.MarginLeft, print.MarginRight) = (m, m, m, m);
            print.ShouldPrintBackgrounds = options.Backgrounds;
            print.ShouldPrintHeaderAndFooter = options.HeaderAndFooter;
            print.ScaleFactor = 1;
            if (!await web.PrintToPdfAsync(temp, print)) throw new InvalidOperationException("The page couldn't be printed to PDF.");
            cancel.ThrowIfCancellationRequested();
            return await File.ReadAllBytesAsync(temp, CancellationToken.None);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            throw new InvalidOperationException(Unavailable);
        }
        finally
        {
            controller?.Close();
            host.Close();
            try { File.Delete(temp); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }

    private static string Describe(CoreWebView2WebErrorStatus status, int http) => status switch
    {
        CoreWebView2WebErrorStatus.HostNameNotResolved => "The site wasn't found. Check the address and the internet connection.",
        CoreWebView2WebErrorStatus.CannotConnect or CoreWebView2WebErrorStatus.ServerUnreachable or CoreWebView2WebErrorStatus.Disconnected
            => "The site couldn't be reached. Check the internet connection.",
        CoreWebView2WebErrorStatus.Timeout => "The site took too long to answer.",
        CoreWebView2WebErrorStatus.CertificateCommonNameIsIncorrect or CoreWebView2WebErrorStatus.CertificateExpired
            or CoreWebView2WebErrorStatus.ClientCertificateContainsErrors or CoreWebView2WebErrorStatus.CertificateRevoked
            or CoreWebView2WebErrorStatus.CertificateIsInvalid => "The site's security certificate isn't valid, so the page wasn't loaded.",
        CoreWebView2WebErrorStatus.ConnectionAborted or CoreWebView2WebErrorStatus.ConnectionReset => "The connection was interrupted.",
        CoreWebView2WebErrorStatus.OperationCanceled => "The page didn't load (it was stopped or left for a download).",
        _ when http >= 400 => $"The site answered with an error ({http}).",
        _ => $"The page couldn't be loaded ({status}).",
    };
}
