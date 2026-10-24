using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>What one use of the AI assistant will send: the first requests (shown in the preview) and how it is described.</summary>
/// <param name="What">"The text of pages 1–12" and the like.</param>
/// <param name="FollowUp">More requests the job makes later from the model's own answers (map-reduce), or null.</param>
public sealed record AiOutgoing(IReadOnlyList<IReadOnlyList<AiMessage>> Requests, string What, string? FollowUp)
{
    public int Characters => Requests.Sum(r => r.Sum(m => m.Content.Length));
    public int Tokens => Requests.Sum(AiText.EstimateTokens);
}

/// <summary>
/// Settings › AI assistant (the endpoint, model, key and context size, with Test connection) and the confirmation
/// before each send, which shows exactly what goes where.
/// </summary>
public static class AiActions
{
    private static readonly string[] PresetLabels = ["Ollama (on this PC)", "LM Studio (on this PC)", "Custom: any OpenAI-compatible endpoint"];

    /// <summary>The settings dialog. Returns true when saved. <paramref name="why"/> heads it when a use found the assistant off.</summary>
    public static bool ShowSettings(Window owner, string? why = null)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, "AI assistant", "Save", 580);
        if (why is not null) dlg.AddNote(why).FontWeight = FontWeights.SemiBold;
        dlg.AddNote("Inkvolt PDF has no AI of its own. If you want one, connect a model you run (Ollama, LM Studio) or an " +
                    "OpenAI-compatible service you have an account with. Only text you pick is sent, after you see it, to the " +
                    "endpoint below. Bermudez Systems receives nothing.");
        var enabled = dlg.Add(null, new CheckBox
        {
            IsChecked = s.AiEnabled,
            Content = new TextBlock { Text = "Use an AI assistant: Summarize, Ask about this document, Explain selection", TextWrapping = TextWrapping.Wrap },
        });
        AutomationProperties.SetName(enabled, "Use an AI assistant");

        var preset = dlg.AddChoice("Endpoint", PresetLabels, Math.Max(0, Array.IndexOf(AiService.PresetNames, s.AiPreset)));
        AutomationProperties.SetName(preset, "Endpoint");
        var url = dlg.Add(null, new TextBox { Text = AiService.UrlOf(s.AiPreset, s.AiCustomUrl) });
        AutomationProperties.SetName(url, "Base URL");
        url.ToolTip = "The endpoint's base URL, usually ending in /v1";
        var reach = new TextBlock { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        var reachIcon = new TextBlock { Style = (Style)Application.Current.FindResource("Icon"), FontSize = 14, Margin = new Thickness(0, 0, 8, 0) };
        var reachRow = new DockPanel();
        DockPanel.SetDock(reachIcon, Dock.Left);
        reachRow.Children.Add(reachIcon);
        reachRow.Children.Add(reach);
        var reachBox = dlg.Add(null, new Border { Child = reachRow, CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(0, 6, 0, 0) });
        AutomationProperties.SetLiveSetting(reach, AutomationLiveSetting.Polite);

        // Model, with Test connection beside it (it fills the list)
        var model = new ComboBox { IsEditable = true, Text = s.AiModel };
        AutomationProperties.SetName(model, "Model");
        AutomationProperties.SetHelpText(model, "Pick one of the endpoint's models (Test connection lists them) or type its name, as in \"ollama list\"");
        var test = new Button { Content = "Test connection", MinWidth = 120, Margin = new Thickness(8, 0, 0, 0), ToolTip = "Asks the endpoint for its models: sends the API key (if any), no document text" };
        var modelRow = new DockPanel();
        DockPanel.SetDock(test, Dock.Right);
        modelRow.Children.Add(test);
        modelRow.Children.Add(model);
        dlg.Add("Model", modelRow);
        var testResult = dlg.AddNote("");
        testResult.Visibility = Visibility.Collapsed;
        AutomationProperties.SetLiveSetting(testResult, AutomationLiveSetting.Polite);

        var key = new PasswordBox();
        AutomationProperties.SetName(key, "API key");
        var forgetKey = new Button { Content = "Remove saved key", Margin = new Thickness(8, 0, 0, 0) };
        var keyRow = new DockPanel();
        DockPanel.SetDock(forgetKey, Dock.Right);
        keyRow.Children.Add(forgetKey);
        keyRow.Children.Add(key);
        dlg.Add("API key (optional)", keyRow);
        var keyNote = dlg.AddNote("");
        var removeKey = false;

        var sizes = AiText.ContextSizes.Select(n => n.ToString("N0")).ToList();
        var context = dlg.Add("Context size (tokens the model reads at once)", new ComboBox { IsEditable = true, ItemsSource = sizes, Text = s.AiContextTokens.ToString("N0"), Width = 160, HorizontalAlignment = HorizontalAlignment.Left });
        AutomationProperties.SetName(context, "Context size in tokens");
        dlg.AddNote("Match the model's own context length (Ollama: its settings, or OLLAMA_CONTEXT_LENGTH). Longer documents are summarized in parts.");

        var trusted = s.AiNoPreview.ToList();
        var trustNote = dlg.AddNote("");
        var resetTrust = dlg.Add(null, new Button { Content = "Ask before every send again", HorizontalAlignment = HorizontalAlignment.Left });
        void ShowTrust()
        {
            trustNote.Text = $"Sends without showing what goes first to: {string.Join(", ", trusted)}. (Text the PDF forbids copying is always asked about.)";
            trustNote.Visibility = resetTrust.Visibility = trusted.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        resetTrust.Click += (_, _) =>
        {
            trusted.Clear();
            ShowTrust();
        };
        ShowTrust();

        AiEndpoint? Parsed(out string? error)
        {
            AiEndpoint.TryParse(url.Text, out var ep, out error);
            return ep;
        }

        void Refresh()
        {
            var on = enabled.IsChecked == true;
            foreach (var c in new UIElement[] { preset, url, model, key, context, test, forgetKey }) c.IsEnabled = on;
            url.IsReadOnly = preset.SelectedIndex != 2;
            var ep = Parsed(out var error);
            if (ep is null)
            {
                reach.Text = error;
                reachIcon.Text = "\uE783"; // error badge
                reachBox.SetResourceReference(Border.BackgroundProperty, "SystemFillColorCriticalBackgroundBrush");
                reachIcon.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
            }
            else
            {
                reach.Text = ep.Reach == AiReach.Internet
                    ? $"{ep.ReachText}. Text you send is handled under that provider's terms."
                    : ep.ReachText + (ep.Reach == AiReach.ThisPc ? ": text goes only to the server running on this computer." : ".");
                reachIcon.Text = ep.Reach == AiReach.Internet ? "\uE7BA" : "\uE73E"; // warning / check mark
                reachBox.SetResourceReference(Border.BackgroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBackgroundBrush" : "SubtleFillColorSecondaryBrush");
                reachIcon.SetResourceReference(TextBlock.ForegroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBrush" : "SystemFillColorSuccessBrush");
            }
            var saved = ep is not null && AiKeyStore.Has(ep.Key) && !removeKey;
            keyNote.Text = saved
                ? "A key is saved for this endpoint, encrypted for your Windows account. Leave the box empty to keep it."
                : "Only if the endpoint needs one (local servers don't). Kept encrypted for your Windows account (DPAPI), sent only to this endpoint.";
            forgetKey.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
        }

        var customUrl = s.AiCustomUrl;
        preset.SelectionChanged += (_, _) =>
        {
            if (preset.SelectedIndex == 2) url.Text = customUrl;
            else url.Text = AiService.UrlOf(AiService.PresetNames[preset.SelectedIndex], "");
            model.ItemsSource = null;
            testResult.Text = "";
            testResult.Visibility = Visibility.Collapsed;
            Refresh();
        };
        url.TextChanged += (_, _) =>
        {
            if (preset.SelectedIndex == 2) customUrl = url.Text;
            Refresh();
        };
        enabled.Checked += (_, _) => Refresh();
        enabled.Unchecked += (_, _) => Refresh();
        forgetKey.Click += (_, _) =>
        {
            removeKey = true;
            key.Password = "";
            Refresh();
        };

        CancellationTokenSource? testing = null;
        test.Click += async (_, _) =>
        {
            if (Parsed(out var error) is not { } ep)
            {
                testResult.Text = error;
                testResult.Visibility = Visibility.Visible;
                return;
            }
            testing?.Cancel();
            testing = new CancellationTokenSource();
            var mine = testing;
            test.IsEnabled = false;
            testResult.Visibility = Visibility.Visible;
            testResult.Text = $"Connecting to {ep.Host}…";
            try
            {
                var apiKey = key.Password.Length > 0 ? key.Password : removeKey ? null : AiKeyStore.Get(ep.Key);
                using var client = AiService.CreateClient(ep, model.Text.Trim(), apiKey);
                var models = await client.ListModelsAsync(mine.Token);
                if (mine.IsCancellationRequested) return;
                var typed = model.Text.Trim();
                model.ItemsSource = models;
                model.Text = typed.Length > 0 ? typed : models.FirstOrDefault() ?? "";
                testResult.Text = models.Count == 0
                    ? $"Connected to {ep.Host}, but it doesn't list its models: type the model's name."
                    : typed.Length > 0 && !models.Contains(typed, StringComparer.OrdinalIgnoreCase)
                        ? $"Connected: {Plural(models.Count, "model")}, but not \"{typed}\". Pick one from the list."
                        : $"Connected to {ep.Host}: {Plural(models.Count, "model")} available.";
            }
            catch (AiException ex)
            {
                if (!mine.IsCancellationRequested) testResult.Text = ex.Message;
            }
            catch (OperationCanceledException)
            {
            }
            finally
            {
                test.IsEnabled = enabled.IsChecked == true;
            }
        };
        dlg.Closed += (_, _) => testing?.Cancel();

        int contextTokens = s.AiContextTokens;
        dlg.Validate(() =>
        {
            if (!int.TryParse(context.Text.Replace(",", "").Replace(".", "").Replace(" ", "").Replace(" ", ""), out contextTokens) || contextTokens < 1024 || contextTokens > 2_000_000)
                return "Enter a context size from 1,024 to 2,000,000 tokens.";
            if (enabled.IsChecked != true) return null;
            if (Parsed(out var error) is null) return error;
            if (model.Text.Trim().Length == 0) return "Choose or type a model (Test connection lists the endpoint's models).";
            return null;
        });
        Refresh();
        if (!dlg.ShowModal()) return false;

        s.AiEnabled = enabled.IsChecked == true;
        s.AiPreset = AiService.PresetNames[Math.Max(0, preset.SelectedIndex)];
        s.AiCustomUrl = customUrl.Trim();
        s.AiModel = model.Text.Trim();
        s.AiContextTokens = contextTokens;
        s.AiNoPreview = trusted;
        if (Parsed(out _) is { } saved)
        {
            try
            {
                if (key.Password.Length > 0) AiKeyStore.Set(saved.Key, key.Password);
                else if (removeKey) AiKeyStore.Set(saved.Key, null);
            }
            catch (InvalidOperationException ex)
            {
                Prompt.Error(owner, "API key not saved", ex.Message);
            }
        }
        s.Save();
        return true;
    }

    /// <summary>The one-line state for Settings: "Off", or "On: model at host (stays on this PC)".</summary>
    public static string Describe()
    {
        if (!AppSettings.Current.AiEnabled) return "Off. Inkvolt PDF has no AI of its own; you can connect one you choose.";
        return AiService.Current(out var problem) is { } c
            ? $"On: {c.Model} at {c.ServerLabel}. {c.Endpoint.ReachText}."
            : $"On, but not set up: {problem}";
    }

    /// <summary>
    /// Asks before sending, showing where (host, model, whether it leaves this PC), how much (characters, an estimate of
    /// tokens, requests) and exactly what (an expandable preview of every message). Skipped for an endpoint the user
    /// chose "don't ask again" for, except for the first send to an internet endpoint and for text the PDF forbids copying.
    /// </summary>
    public static bool ConfirmSend(Window owner, AiConfig config, AiOutgoing outgoing, bool copyRestricted)
    {
        var ep = config.Endpoint;
        var firstCloud = !AiService.WarnedAbout(ep);
        if (AiService.SkipsPreview(ep) && !copyRestricted && !firstCloud) return true;

        var dlg = new FormDialog(owner, "Send to the AI assistant?", "Send", 600);
        var to = new DockPanel();
        var icon = new TextBlock { Style = (Style)Application.Current.FindResource("Icon"), FontSize = 16, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(icon, Dock.Left);
        to.Children.Add(icon);
        var toText = new TextBlock { TextWrapping = TextWrapping.Wrap };
        toText.Inlines.Add(new System.Windows.Documents.Run($"To {ep.Host}") { FontWeight = FontWeights.SemiBold });
        toText.Inlines.Add(new System.Windows.Documents.Run((config.ServerLabel == ep.Host ? "" : $" ({config.ServerLabel})") + $", model {config.Model}\n{ep.ReachText}."));
        to.Children.Add(toText);
        var toBox = dlg.Add("Where", new Border { Child = to, CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 8, 12, 8) });
        icon.Text = ep.Reach == AiReach.Internet ? "\uE7BA" : "\uE73E";
        icon.SetResourceReference(TextBlock.ForegroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBrush" : "SystemFillColorSuccessBrush");
        toBox.SetResourceReference(Border.BackgroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBackgroundBrush" : "SubtleFillColorSecondaryBrush");

        var requests = outgoing.Requests.Count == 1 ? "1 request" : $"{outgoing.Requests.Count} requests";
        dlg.Add("What", new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = $"{outgoing.What}: {outgoing.Characters:N0} characters (about {outgoing.Tokens:N0} tokens) in {requests}" +
                   (outgoing.FollowUp is null ? "." : $", then {outgoing.FollowUp}."),
        });
        dlg.AddNote("Only this text, the instructions shown below and the model's name are sent: no file name, folder, document properties or other documents.");

        var preview = new TextBox
        {
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = 300,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
        };
        AutomationProperties.SetName(preview, "Exactly what will be sent");
        const int MaxShown = 400_000;
        string? full = null;
        var copyAll = new Button { Content = "Copy all", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        var previewPanel = new StackPanel();
        previewPanel.Children.Add(preview);
        previewPanel.Children.Add(copyAll);
        var expander = dlg.Add(null, new Expander { Header = "Show exactly what will be sent", Content = previewPanel, Margin = new Thickness(0, 10, 0, 0) });
        expander.Expanded += (_, _) =>
        {
            if (full is not null) return;
            full = AiPrompts.Preview(outgoing.Requests);
            preview.Text = full.Length <= MaxShown ? full : full[..MaxShown] + $"\n… and {full.Length - MaxShown:N0} more characters (Copy all has everything).";
        };
        copyAll.Click += (_, _) =>
        {
            full ??= AiPrompts.Preview(outgoing.Requests);
            try
            {
                Clipboard.SetText(full);
            }
            catch (System.Runtime.InteropServices.COMException)
            {
            }
        };

        CheckBox? cloudOk = null, restrictedOk = null;
        if (firstCloud)
        {
            dlg.AddNote($"This is the first time you send text to {ep.Host}. It leaves this PC, and that provider may keep and use it under its own " +
                        "terms, not Inkvolt PDF's. Only send documents you're allowed to share with it.").FontWeight = FontWeights.SemiBold;
            cloudOk = dlg.AddCheck($"I understand: this text leaves this PC for {ep.Host}");
        }
        if (copyRestricted)
        {
            dlg.AddNote("The author of this PDF restricted copying its text. Sending it to an AI copies it out of the document.").FontWeight = FontWeights.SemiBold;
            restrictedOk = dlg.AddCheck("Send it anyway: I'm allowed to use this text");
        }
        var dontAsk = dlg.AddCheck($"Don't ask again for {ep.Host} (change this in Settings › AI assistant)", AiService.SkipsPreview(ep));
        dontAsk.Margin = new Thickness(0, 14, 0, 0);
        dlg.Validate(() =>
            cloudOk is { IsChecked: not true } ? $"Tick \"I understand\" to send text to {ep.Host}, or Cancel."
            : restrictedOk is { IsChecked: not true } ? "Tick \"Send it anyway\" to send text the author restricted, or Cancel."
            : null);
        if (!dlg.ShowModal()) return false;

        var s = AppSettings.Current;
        s.AiNoPreview.RemoveAll(k => string.Equals(k, ep.Key, StringComparison.OrdinalIgnoreCase));
        if (dontAsk.IsChecked == true) s.AiNoPreview.Add(ep.Key);
        if (firstCloud) s.AiCloudWarned.Add(ep.Key);
        s.Save();
        return true;
    }

    /// <summary>
    /// True when the PDF's permissions forbid copying its text and it wasn't opened with its permissions password (as the
    /// author would). Inkvolt PDF lets the user copy anyway, as other readers do; sending it elsewhere is asked about.
    /// </summary>
    public static async Task<bool> IsCopyRestrictedAsync(DocumentSession s)
    {
        var data = s.Data;
        // MuPDF opens a file that needs no open password as unencrypted, so look for the encryption dictionary itself
        // (a quick byte scan) before reading the permissions with PDFsharp.
        if (!s.IsPdf || data.AsSpan().IndexOf("/Encrypt"u8) < 0) return false;
        var password = s.Password;
        return await Task.Run(() =>
        {
            if (SecurityActions.Read(s) is not { IsEncrypted: true } info || info.Permissions.Copy) return false;
            var hasOwnerPassword = !string.IsNullOrEmpty(password) && !PdfSecurity.IsOpenPassword(data, password);
            return !hasOwnerPassword;
        });
    }

    /// <summary>Review › AI Assistant › Summarize: which pages. Null when cancelled.</summary>
    public static int[]? AskSummaryPages(Window owner, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, "Summarize with AI", "Next", 440);
        var range = dlg.AddRange(tab, "Pages to summarize", preferSelection: tab.SelectedPages.Length > 1);
        if (tab.SelectedPages.Length <= 1) range.SelectAll();
        dlg.AddNote("Next shows exactly what will be sent before anything is.");
        int[] pages = [];
        dlg.Validate(() => range.TryGet(out pages, out var error) ? null : error);
        return dlg.ShowModal() ? pages : null;
    }

    /// <summary>Speaks <paramref name="message"/> through <paramref name="target"/> (a polite live region).</summary>
    public static void Announce(FrameworkElement target, string message)
    {
        AutomationProperties.SetName(target, message);
        UIElementAutomationPeer.CreatePeerForElement(target)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private static string Plural(int n, string word) => n == 1 ? $"1 {word}" : $"{n:N0} {word}s";
}
