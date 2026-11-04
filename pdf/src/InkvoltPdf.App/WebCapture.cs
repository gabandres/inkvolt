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

    /// <summary>How long a script call into the page, and printing it, may take.</summary>
    private static readonly TimeSpan ScriptTimeout = TimeSpan.FromSeconds(10), PrintTimeout = TimeSpan.FromSeconds(120);

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

    public static string Unavailable => Strings.Web_Unavailable;

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
            status?.Invoke(source.IsFile ? Strings.Web_OpeningFile : Loc.Format(Strings.Web_Loading, source.Host));
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
                    throw new InvalidOperationException(Loc.Format(Strings.Web_LoadTimeout, LoadTimeout.TotalSeconds));
                }
                if (!done.IsSuccess) throw new InvalidOperationException(Describe(done.WebErrorStatus, done.HttpStatusCode));
            }

            // Let late content arrive: wait for the document to be complete, then scroll to the end and back so pictures
            // that load as they come into view are fetched.
            status?.Invoke(Strings.Web_Settling);
            // A page whose own scripts never let go (a busy loop) would never answer: every call has a time limit and
            // Cancel, and the WebView is torn down when this ends (finally).
            Task<string> Script(string js) => web.ExecuteScriptAsync(js).WaitAsync(ScriptTimeout, cancel);
            try
            {
                for (var i = 0; i < 30 && await Script("document.readyState") != "\"complete\""; i++) await Task.Delay(250, cancel);
                await Script("window.scrollTo(0, document.documentElement.scrollHeight)");
                await Task.Delay(700, cancel);
                await Script("window.scrollTo(0, 0)");
                await Task.Delay(500, cancel);
            }
            catch (TimeoutException)
            {
                throw new InvalidOperationException(Strings.Web_Busy);
            }

            status?.Invoke(Strings.Web_Making);
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
            bool printed;
            try
            {
                printed = await web.PrintToPdfAsync(temp, print).WaitAsync(PrintTimeout, cancel);
            }
            catch (TimeoutException)
            {
                throw new InvalidOperationException(Loc.Format(Strings.Web_PrintTimeout, PrintTimeout.TotalSeconds));
            }
            if (!printed) throw new InvalidOperationException(Strings.Web_PrintFailed);
            cancel.ThrowIfCancellationRequested();
            return await File.ReadAllBytesAsync(temp, CancellationToken.None);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            throw new InvalidOperationException(Unavailable);
        }
        finally
        {
            // Stop whatever the page still does, then close the WebView (its browser processes end with it).
            try { controller?.CoreWebView2?.Stop(); }
            catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
            controller?.Close();
            host.Close();
            try { File.Delete(temp); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }

    private static string Describe(CoreWebView2WebErrorStatus status, int http) => status switch
    {
        CoreWebView2WebErrorStatus.HostNameNotResolved => Strings.Web_NotFound,
        CoreWebView2WebErrorStatus.CannotConnect or CoreWebView2WebErrorStatus.ServerUnreachable or CoreWebView2WebErrorStatus.Disconnected
            => Strings.Web_Unreachable,
        CoreWebView2WebErrorStatus.Timeout => Strings.Web_Timeout,
        CoreWebView2WebErrorStatus.CertificateCommonNameIsIncorrect or CoreWebView2WebErrorStatus.CertificateExpired
            or CoreWebView2WebErrorStatus.ClientCertificateContainsErrors or CoreWebView2WebErrorStatus.CertificateRevoked
            or CoreWebView2WebErrorStatus.CertificateIsInvalid => Strings.Web_BadCertificate,
        CoreWebView2WebErrorStatus.ConnectionAborted or CoreWebView2WebErrorStatus.ConnectionReset => Strings.Web_Interrupted,
        CoreWebView2WebErrorStatus.OperationCanceled => Strings.Web_Stopped,
        _ when http >= 400 => Loc.Format(Strings.Web_HttpError, http),
        _ => Loc.Format(Strings.Web_LoadFailed, status),
    };
}
