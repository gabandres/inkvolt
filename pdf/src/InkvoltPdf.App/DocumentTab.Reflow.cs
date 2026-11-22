using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using InkvoltPdf.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace InkvoltPdf.App;

/// <summary>
/// The Reflow view (roadmap 4.16, View › Reflow, Ctrl+3): the document as one readable column inside the tab, over the
/// page view. The column is Core's <see cref="Reflow"/> (Export's HTML, no script, no request), shown by the WebView2
/// runtime Windows provides (the same as PDF from Web Page), with page scripts off and nothing loaded but that page; a
/// composition control, so the tab's bars, the page pill and toasts still draw over it. The text size follows Windows'
/// Text size and the view's zoom, the colors Dark pages; the page is kept both ways (<see cref="ReflowPosition"/>); a web
/// or mail link opens in the browser. Read-only: only <see cref="Reflow.Runs"/>' commands work while it shows.
/// </summary>
public partial class DocumentTab
{
    private static readonly TimeSpan ReflowPoll = TimeSpan.FromMilliseconds(400);

    private WebView2CompositionControl? _reflowWeb;
    private CoreWebView2Environment? _reflowEnv;
    private ReflowPosition? _reflowPos;
    private ReflowDocument? _reflowDoc;
    private byte[]? _reflowPage; // the page served at Reflow.Address
    private CancellationTokenSource? _reflowCancel;
    private DispatcherTimer? _reflowTimer;
    private bool _reflowAsking;
    private bool _reflowStale;
    private double _reflowZoom = 1;
    private EventHandler? _reflowRescale;

    /// <summary>The Reflow view shows instead of the pages.</summary>
    public bool IsReflowing { get; private set; }

    /// <summary>What the Reflow view shows now (DevScript's <c>reflowstate</c>): preparing, the column, or a message.</summary>
    internal string ReflowState { get; private set; } = "off";

    private ReflowLook ReflowLookNow => new(TextScale.Factor, _reflowZoom, AppSettings.Current.DarkPages);

    /// <summary>Reflow on or off. On: from the page in view; off: Pages at the page Reflow was at.</summary>
    public void SetReflow(bool on)
    {
        if (on == IsReflowing || _disposed) return;
        if (on && Viewer.PageCount == 0) return;
        if (on)
        {
            if (IsOrganizing) SetOrganizing(false);
            HideFindBar();
            IsReflowing = true;
            _reflowPos = new ReflowPosition(Viewer.PageCount);
            _reflowPos.Enter(Viewer.CurrentPage);
            ReflowHost.Visibility = Visibility.Visible;
            _reflowRescale = (_, _) => Restyle();
            TextScale.Changed += _reflowRescale;
            _ = ShowReflowAsync();
        }
        else
        {
            var page = _reflowPos?.Leave();
            EndReflow();
            if (page is { } p && p != Viewer.CurrentPage) Viewer.GoToPage(p, record: false);
            Viewer.Focus();
        }
        RaiseState();
        System.Windows.Input.CommandManager.InvalidateRequerySuggested();
    }

    private void EndReflow()
    {
        IsReflowing = false;
        ReflowState = "off";
        _reflowCancel?.Cancel();
        _reflowCancel = null;
        _reflowTimer?.Stop();
        _reflowTimer = null;
        if (_reflowRescale is not null) TextScale.Changed -= _reflowRescale;
        _reflowRescale = null;
        ReflowHost.Children.Clear();
        ReflowHost.Visibility = Visibility.Collapsed;
        _reflowWeb?.Dispose();
        _reflowWeb = null;
        _reflowPage = null;
        _reflowDoc = null;
    }

    /// <summary>Lays the document out as one column (off the UI thread) and shows it at the page kept.</summary>
    private async Task ShowReflowAsync()
    {
        _reflowCancel?.Cancel();
        var cancel = (_reflowCancel = new CancellationTokenSource()).Token;
        _reflowStale = false;
        ShowReflowMessage(Strings.Tab_ReflowPreparing, busy: true);
        ReflowState = "preparing";
        if (WebCapture.RuntimeVersion is null)
        {
            ShowReflowMessage(Strings.Tab_ReflowNoRuntime);
            ReflowState = "no WebView2";
            return;
        }
        var data = Session.Data;
        var (type, password, title) = (Session.FileType, Session.Password, DisplayTitle);
        ReflowDocument doc;
        try
        {
            doc = await Task.Run(() => Reflow.Make(data, type, password, title, cancel), cancel);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"Reflow failed: {ex}");
            if (!cancel.IsCancellationRequested) ShowReflowMessage(Loc.Format(Strings.Tab_ReflowFailed, ex.Message));
            ReflowState = "failed";
            return;
        }
        if (cancel.IsCancellationRequested || !IsReflowing) return;
        if (!doc.HasContent)
        {
            ShowReflowMessage(Strings.Tab_ReflowNothing);
            ReflowState = "nothing to reflow";
            return;
        }
        _reflowDoc = doc;
        _reflowPage = Encoding.UTF8.GetBytes(Reflow.Style(doc.Html, ReflowLookNow));
        _reflowPos = new ReflowPosition(doc.Pages);
        _reflowPos.Enter(Viewer.CurrentPage);
        try
        {
            await ShowReflowPageAsync(cancel);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"Reflow view failed: {ex}");
            if (!cancel.IsCancellationRequested) ShowReflowMessage(Loc.Format(Strings.Tab_ReflowFailed, ex.Message));
            ReflowState = "failed";
        }
    }

    private async Task ShowReflowPageAsync(CancellationToken cancel)
    {
        if (_reflowWeb is null)
        {
            _reflowEnv ??= await CoreWebView2Environment.CreateAsync(null, Path.Combine(AppPaths.DataDirectory, "WebView2"));
            var web = new WebView2CompositionControl
            {
                DefaultBackgroundColor = AppSettings.Current.DarkPages ? System.Drawing.Color.FromArgb(0x1e, 0x1e, 0x1e) : System.Drawing.Color.White,
            };
            System.Windows.Automation.AutomationProperties.SetName(web, Strings.Tab_ReflowName);
            ReflowHost.Children.Clear();
            ReflowHost.Children.Add(web);
            var options = _reflowEnv.CreateCoreWebView2ControllerOptions();
            options.IsInPrivateModeEnabled = true; // nothing kept between runs
            await web.EnsureCoreWebView2Async(_reflowEnv, options);
            if (cancel.IsCancellationRequested || !IsReflowing)
            {
                web.Dispose();
                return;
            }
            _reflowWeb = web;
            Lockdown(web.CoreWebView2);
        }
        var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Done(object? s, CoreWebView2NavigationCompletedEventArgs e) => loaded.TrySetResult();
        var core = _reflowWeb.CoreWebView2;
        core.NavigationCompleted += Done;
        core.Navigate(Reflow.Address);
        try
        {
            await loaded.Task.WaitAsync(TimeSpan.FromSeconds(30), cancel);
        }
        finally
        {
            core.NavigationCompleted -= Done;
        }
        if (_reflowWeb is null || !IsReflowing) return;
        await _reflowWeb.ExecuteScriptAsync(Reflow.ScrollScript(_reflowPos!.Page));
        ReflowState = "showing";
        _reflowTimer ??= new DispatcherTimer(ReflowPoll, DispatcherPriority.Background, (_, _) => _ = PollReflowAsync(), Dispatcher);
        _reflowTimer.Start();
    }

    /// <summary>
    /// The view loads only its page: page scripts, the browser's keys and menus, pop-ups, downloads and permissions are off,
    /// and a link leaves for the browser (<see cref="Reflow.Follow"/>).
    /// </summary>
    private void Lockdown(CoreWebView2 web)
    {
        var s = web.Settings;
        s.IsScriptEnabled = false; // the page's own; the view's scripts (ExecuteScriptAsync) still run
        s.AreDevToolsEnabled = false;
        s.AreDefaultScriptDialogsEnabled = false;
        s.AreHostObjectsAllowed = false;
        s.IsWebMessageEnabled = false;
        s.IsPasswordAutosaveEnabled = false;
        s.IsGeneralAutofillEnabled = false;
        s.AreBrowserAcceleratorKeysEnabled = false; // the app's keys (Ctrl+3, Ctrl+P…) are the app's
        s.IsZoomControlEnabled = false; // Zoom In and Out size the text (ReflowZoom)
        s.IsBuiltInErrorPageEnabled = false;
        web.AddWebResourceRequestedFilter(new Uri(new Uri(Reflow.Address), "/").AbsoluteUri + "*", CoreWebView2WebResourceContext.All);
        web.WebResourceRequested += (_, e) =>
        {
            var address = new Uri(e.Request.Uri).GetLeftPart(UriPartial.Path);
            e.Response = address == Reflow.Address && _reflowPage is { } page && _reflowEnv is { } env
                ? env.CreateWebResourceResponse(new MemoryStream(page), 200, "OK", "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store")
                : _reflowEnv?.CreateWebResourceResponse(null, 404, "Not Found", "");
        };
        web.NavigationStarting += (_, e) =>
        {
            if (new Uri(e.Uri).GetLeftPart(UriPartial.Path) == Reflow.Address) return;
            e.Cancel = true;
            FollowReflowLink(e.Uri);
        };
        web.NewWindowRequested += (_, e) =>
        {
            e.Handled = true;
            FollowReflowLink(e.Uri);
        };
        web.DownloadStarting += (_, e) => e.Cancel = true;
        web.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        // Right-click: Copy and Select All (and a link's Copy link), nothing that would print, save or inspect the page.
        web.ContextMenuRequested += (_, e) =>
        {
            var keep = new HashSet<string>(StringComparer.Ordinal) { "copy", "selectAll", "copyLinkLocation" };
            for (var i = e.MenuItems.Count - 1; i >= 0; i--)
                if (!keep.Contains(e.MenuItems[i].Name)) e.MenuItems.RemoveAt(i);
        };
    }

    /// <summary>A link clicked in the view: a web or mail address opens in the browser; anything else does nothing.</summary>
    internal void FollowReflowLink(string uri)
    {
        var link = Reflow.Follow(uri, _reflowDoc?.Pages ?? Viewer.PageCount);
        switch (link.Kind)
        {
            case ReflowLinkKind.External:
                Shell.Open(link.Address!);
                break;
            case ReflowLinkKind.InDocument when link.Page >= 0 && _reflowWeb is not null:
                _ = _reflowWeb.ExecuteScriptAsync(Reflow.ScrollScript(link.Page));
                break;
            case ReflowLinkKind.Blocked:
                Log.Write("Reflow: a link that isn't a web or mail address was ignored");
                break;
        }
    }

    /// <summary>Which page is at the top of the view; the page box follows it.</summary>
    private async Task PollReflowAsync()
    {
        if (_reflowAsking || _reflowWeb?.CoreWebView2 is null || _reflowPos is null || !IsReflowing) return;
        _reflowAsking = true;
        try
        {
            var answer = await _reflowWeb.ExecuteScriptAsync(Reflow.TopPageScript);
            if (!IsReflowing || _reflowPos is null) return;
            var id = JsonSerializer.Deserialize<string>(answer);
            if (_reflowPos.Scrolled(Reflow.PageOf(id, _reflowPos.Pages)) is { } page) Viewer.GoToPage(page, record: false);
            if (_reflowStale && !IsBusy) _ = ShowReflowAsync(); // the document changed: laid out again
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or System.Runtime.InteropServices.COMException or ObjectDisposedException)
        {
        }
        finally
        {
            _reflowAsking = false;
        }
    }

    /// <summary>The page view moved (the page box, Next Page, a bookmark): the view scrolls there.</summary>
    private void ReflowFollowViewer()
    {
        if (!IsReflowing || _reflowPos is null || _reflowWeb?.CoreWebView2 is null) return;
        if (_reflowPos.ViewerMoved(Viewer.CurrentPage) is { } page) _ = _reflowWeb.ExecuteScriptAsync(Reflow.ScrollScript(page));
    }

    /// <summary>Zoom In (+1), Zoom Out (-1) or Actual Size (0) in the Reflow view: the text's size.</summary>
    public void ReflowZoom(int steps)
    {
        _reflowZoom = steps == 0 ? 1 : Reflow.ZoomStep(_reflowZoom, steps);
        Restyle();
    }

    /// <summary>Dark pages or Windows' Text size changed: the view takes the new look where it is.</summary>
    private void Restyle()
    {
        if (!IsReflowing || _reflowDoc is null) return;
        _reflowPage = Encoding.UTF8.GetBytes(Reflow.Style(_reflowDoc.Html, ReflowLookNow));
        if (_reflowWeb is { CoreWebView2: not null } web)
        {
            web.DefaultBackgroundColor = AppSettings.Current.DarkPages ? System.Drawing.Color.FromArgb(0x1e, 0x1e, 0x1e) : System.Drawing.Color.White;
            // Larger or smaller text moves everything: the page kept comes back to the top, in the same script, so the
            // page box never sees the page in between.
            var page = _reflowPos?.Page ?? 0;
            _ = web.ExecuteScriptAsync(Reflow.RestyleScript(ReflowLookNow) + ";" + Reflow.ScrollScript(page));
        }
    }

    private void ShowReflowMessage(string text, bool busy = false)
    {
        _reflowWeb?.Dispose();
        _reflowWeb = null;
        _reflowTimer?.Stop();
        ReflowHost.Children.Clear();
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 460, Margin = new Thickness(24) };
        if (busy) panel.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 200, Height = 4, Margin = new Thickness(0, 0, 0, 14) });
        var message = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
        System.Windows.Automation.AutomationProperties.SetLiveSetting(message, System.Windows.Automation.AutomationLiveSetting.Polite);
        panel.Children.Add(message);
        if (!busy)
        {
            var back = new Button { Content = Strings.Tab_ReflowBack, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 16, 0, 0) };
            back.Click += (_, _) => SetReflow(false);
            panel.Children.Add(back);
        }
        TextScale.SetScales(panel, true);
        ReflowHost.Children.Add(panel);
    }

    /// <summary>Wires the view to the tab: the page view's moves, the document's changes, Dark pages.</summary>
    private void InitReflow()
    {
        Viewer.CurrentPageChanged += (_, _) => ReflowFollowViewer();
        // An edit, undo or reload while Reflow shows (a reload, a form value from a script): laid out again once idle.
        Session.ContentChanged += (_, _) =>
        {
            if (IsReflowing) _reflowStale = true;
        };
    }

    /// <summary>DevScript's <c>reflowstate</c>: the view, its page, look, and the first words it shows.</summary>
    internal async Task<string> DevReflowState()
    {
        var text = "";
        if (_reflowWeb?.CoreWebView2 is not null)
        {
            var js = "(function(){var s=getComputedStyle(document.documentElement);return s.fontSize+' '+getComputedStyle(document.body).backgroundColor+' | '+document.body.innerText.replace(/\\s+/g,' ').slice(0,100);})()";
            text = JsonSerializer.Deserialize<string>(await _reflowWeb.ExecuteScriptAsync(js)) ?? "";
        }
        return $"reflow: {(IsReflowing ? "on" : "off")}, {ReflowState}, page {(_reflowPos?.Page ?? -1) + 1} (pages view {Viewer.CurrentPage + 1}), zoom {_reflowZoom:0.##}, dark {AppSettings.Current.DarkPages}: {text}";
    }

    /// <summary>DevScript's <c>reflowscroll N</c>: scrolls the view itself to page N, as a reader would.</summary>
    internal Task DevReflowScroll(int page) =>
        _reflowWeb is null ? Task.CompletedTask : _reflowWeb.ExecuteScriptAsync(Reflow.ScrollScript(page));

    /// <summary>DevScript's <c>reflowshot out.png</c>: the view's own picture (the composition control draws it).</summary>
    internal async Task DevReflowShot(string path)
    {
        if (_reflowWeb?.CoreWebView2 is null) return;
        await using var file = File.Create(path);
        await _reflowWeb.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, file);
    }
}
