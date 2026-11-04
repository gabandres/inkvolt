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
    private static string[] PresetLabels => [Strings.Ai_PresetOllama, Strings.Ai_PresetLmStudio, Strings.Ai_PresetCustom];

    /// <summary>The settings dialog. Returns true when saved. <paramref name="why"/> heads it when a use found the assistant off.</summary>
    public static bool ShowSettings(Window owner, string? why = null)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, Strings.Ai_Assistant, Strings.Common_Save, 580);
        if (why is not null) dlg.AddNote(why).FontWeight = FontWeights.SemiBold;
        dlg.AddNote(Strings.Ai_SettingsNote);
        var enabled = dlg.Add(null, new CheckBox
        {
            IsChecked = s.AiEnabled,
            Content = new TextBlock { Text = Strings.Ai_UseAssistantLong, TextWrapping = TextWrapping.Wrap },
        });
        AutomationProperties.SetName(enabled, Strings.Ai_UseAssistant);

        var preset = dlg.AddChoice(Strings.Ai_Endpoint, PresetLabels, Math.Max(0, Array.IndexOf(AiService.PresetNames, s.AiPreset)));
        AutomationProperties.SetName(preset, Strings.Ai_Endpoint);
        var url = dlg.Add(null, new TextBox { Text = AiService.UrlOf(s.AiPreset, s.AiCustomUrl) });
        AutomationProperties.SetName(url, Strings.Ai_BaseUrl);
        url.ToolTip = Strings.Ai_BaseUrlTip;
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
        AutomationProperties.SetName(model, Strings.Ai_Model);
        AutomationProperties.SetHelpText(model, Strings.Ai_ModelHelp);
        var test = new Button { Content = Strings.Ai_TestConnection, MinWidth = 120, Margin = new Thickness(8, 0, 0, 0), ToolTip = Strings.Ai_TestTip };
        var modelRow = new DockPanel();
        DockPanel.SetDock(test, Dock.Right);
        modelRow.Children.Add(test);
        modelRow.Children.Add(model);
        dlg.Add(Strings.Ai_Model, modelRow);
        var testResult = dlg.AddNote("");
        testResult.Visibility = Visibility.Collapsed;
        AutomationProperties.SetLiveSetting(testResult, AutomationLiveSetting.Polite);

        var key = new PasswordBox();
        AutomationProperties.SetName(key, Strings.Ai_ApiKey);
        var forgetKey = new Button { Content = Strings.Ai_RemoveKey, Margin = new Thickness(8, 0, 0, 0) };
        var keyRow = new DockPanel();
        DockPanel.SetDock(forgetKey, Dock.Right);
        keyRow.Children.Add(forgetKey);
        keyRow.Children.Add(key);
        dlg.Add(Strings.Ai_ApiKeyOptional, keyRow);
        var keyNote = dlg.AddNote("");

        var sizes = AiText.ContextSizes.Select(n => n.ToString("N0")).ToList();
        // Ollama is asked for the model's context before each use; other servers can't be asked, so the size is set here.
        var context = new ComboBox { IsEditable = true, ItemsSource = sizes, Text = s.AiContextTokens.ToString("N0"), Width = 160, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetName(context, Strings.Ai_ContextName);
        var contextPanel = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        contextPanel.Children.Add(new TextBlock { Text = Strings.Ai_ContextLabel, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
        contextPanel.Children.Add(context);
        contextPanel.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0),
            Style = (Style)Application.Current.FindResource("Caption"),
            Text = Strings.Ai_ContextNote,
        });
        dlg.Add(null, contextPanel);
        var ollamaContext = dlg.AddNote(Strings.Ai_OllamaContextNote);

        var trusted = s.AiNoPreview.ToList();
        var trustNote = dlg.AddNote("");
        var resetTrust = dlg.Add(null, new Button { Content = Strings.Ai_AskAgain, HorizontalAlignment = HorizontalAlignment.Left });
        void ShowTrust()
        {
            trustNote.Text = Loc.Format(Strings.Ai_TrustNote, string.Join(", ", trusted));
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

        // A typed key (or "remove") belongs to the endpoint it was entered for: any change of endpoint drops it.
        var draft = new AiKeyDraft(Parsed(out _)?.Key);
        key.PasswordChanged += (_, _) => draft.Type(key.Password);

        void Refresh()
        {
            var on = enabled.IsChecked == true;
            foreach (var c in new UIElement[] { preset, url, model, key, context, test, forgetKey }) c.IsEnabled = on;
            url.IsReadOnly = preset.SelectedIndex != 2;
            contextPanel.Visibility = preset.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible;
            ollamaContext.Visibility = preset.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
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
                    ? Loc.Format(Strings.Ai_ReachInternet, ep.ReachText)
                    : Loc.Format(ep.Reach == AiReach.ThisPc ? Strings.Ai_ReachThisPc : Strings.Ai_ReachOther, ep.ReachText);
                reachIcon.Text = ep.Reach == AiReach.Internet ? "\uE7BA" : "\uE73E"; // warning / check mark
                reachBox.SetResourceReference(Border.BackgroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBackgroundBrush" : "SubtleFillColorSecondaryBrush");
                reachIcon.SetResourceReference(TextBlock.ForegroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBrush" : "SystemFillColorSuccessBrush");
            }
            if (draft.EndpointChanged(ep?.Key) && key.Password.Length > 0) key.Password = "";
            var saved = ep is not null && AiKeyStore.Has(ep.Key) && !draft.Remove;
            keyNote.Text = saved
                ? Strings.Ai_KeySaved
                : Strings.Ai_KeyOnlyIf;
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
            draft.RemoveSaved();
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
            testResult.Text = Loc.Format(Strings.Scan_Connecting, ep.Host);
            try
            {
                var apiKey = draft.KeyToUse(AiKeyStore.Get);
                using var client = AiService.CreateClient(ep, model.Text.Trim(), apiKey);
                var models = await client.ListModelsAsync(mine.Token);
                if (mine.IsCancellationRequested) return;
                var typed = model.Text.Trim();
                model.ItemsSource = models;
                model.Text = typed.Length > 0 ? typed : models.FirstOrDefault() ?? "";
                testResult.Text = models.Count == 0
                    ? Loc.Format(Strings.Ai_ConnectedNoList, ep.Host)
                    : typed.Length > 0 && !models.Contains(typed, StringComparer.OrdinalIgnoreCase)
                        ? Loc.Plural(models.Count, Strings.Ai_ConnectedNotTyped_One, Strings.Ai_ConnectedNotTyped_Many, typed)
                        : Loc.Plural(models.Count, Strings.Ai_Connected_One, Strings.Ai_Connected_Many, ep.Host);
                if (preset.SelectedIndex == 0 && model.Text.Trim() is { Length: > 0 } chosen)
                {
                    using var probe = AiService.CreateClient(ep, chosen, apiKey);
                    var (ctx, source) = await probe.OllamaContextAsync(mine.Token);
                    if (!mine.IsCancellationRequested)
                        testResult.Text += ctx is { } n ? " " + Loc.Format(Strings.Ai_ModelReads, chosen, n, source)
                            : " " + Loc.Format(Strings.Ai_OllamaDidntSay, chosen, AiText.DefaultContextTokens);
                }
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
                return Strings.Ai_ContextRange;
            if (enabled.IsChecked != true) return null;
            if (Parsed(out var error) is null) return error;
            if (model.Text.Trim().Length == 0) return Strings.Ai_ChooseModelTest;
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
        if (draft.EndpointKey is { } endpointKey)
        {
            try
            {
                if (draft.Typed is { } typedKey) AiKeyStore.Set(endpointKey, typedKey);
                else if (draft.Remove) AiKeyStore.Set(endpointKey, null);
            }
            catch (InvalidOperationException ex)
            {
                Prompt.Error(owner, Strings.Ai_KeyNotSavedTitle, ex.Message);
            }
        }
        s.Save();
        return true;
    }

    /// <summary>The one-line state for Settings: "Off", or "On: model at host (stays on this PC)".</summary>
    public static string Describe()
    {
        if (!AppSettings.Current.AiEnabled) return Strings.Ai_DescribeOff;
        return AiService.Current(out var problem) is { } c
            ? Loc.Format(Strings.Ai_DescribeOn, c.Model, c.ServerLabel, c.Endpoint.ReachText)
            : Loc.Format(Strings.Ai_DescribeNotSetUp, problem);
    }

    /// <summary>
    /// Asks before sending, showing where (host, model, whether it leaves this PC), how much (characters, an estimate of
    /// tokens, requests) and exactly what (an expandable preview of every message). Skipped for an endpoint the user
    /// chose "don't ask again" for, except for the first send to an internet endpoint and for text the PDF forbids copying.
    /// </summary>
    /// <param name="force">Ask even when the user chose "don't ask again" for this endpoint.</param>
    public static bool ConfirmSend(Window owner, AiConfig config, AiOutgoing outgoing, bool copyRestricted, bool force = false, string? title = null)
    {
        var ep = config.Endpoint;
        var firstCloud = !AiService.WarnedAbout(ep);
        if (AiService.SkipsPreview(ep) && !copyRestricted && !firstCloud && !force) return true;

        var dlg = new FormDialog(owner, title ?? Strings.Ai_SendTitle, Strings.Ai_Send, 600);
        var to = new DockPanel();
        var icon = new TextBlock { Style = (Style)Application.Current.FindResource("Icon"), FontSize = 16, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(icon, Dock.Left);
        to.Children.Add(icon);
        var toText = new TextBlock { TextWrapping = TextWrapping.Wrap };
        toText.Inlines.Add(new System.Windows.Documents.Run(Loc.Format(Strings.Ai_To, ep.Host)) { FontWeight = FontWeights.SemiBold });
        toText.Inlines.Add(new System.Windows.Documents.Run((config.ServerLabel == ep.Host ? "" : $" ({config.ServerLabel})") + Loc.Format(Strings.Ai_ModelReach, config.Model, ep.ReachText)));
        to.Children.Add(toText);
        var toBox = dlg.Add(Strings.Ai_Where, new Border { Child = to, CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 8, 12, 8) });
        icon.Text = ep.Reach == AiReach.Internet ? "\uE7BA" : "\uE73E";
        icon.SetResourceReference(TextBlock.ForegroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBrush" : "SystemFillColorSuccessBrush");
        toBox.SetResourceReference(Border.BackgroundProperty, ep.Reach == AiReach.Internet ? "SystemFillColorCautionBackgroundBrush" : "SubtleFillColorSecondaryBrush");

        dlg.Add(Strings.Ai_What, new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = outgoing.FollowUp is null
                ? Loc.Plural(outgoing.Requests.Count, Strings.Ai_Outgoing_One, Strings.Ai_Outgoing_Many, outgoing.What, outgoing.Characters, outgoing.Tokens)
                : Loc.Plural(outgoing.Requests.Count, Strings.Ai_OutgoingThen_One, Strings.Ai_OutgoingThen_Many, outgoing.What, outgoing.Characters, outgoing.Tokens, outgoing.FollowUp),
        });
        dlg.AddNote(Strings.Ai_OnlyThisText);

        var preview = new TextBox
        {
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = 300,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
        };
        AutomationProperties.SetName(preview, Strings.Ai_ExactlySent);
        const int MaxShown = 400_000;
        string? full = null;
        var copyAll = new Button { Content = Strings.Ai_CopyAll, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        var previewPanel = new StackPanel();
        previewPanel.Children.Add(preview);
        previewPanel.Children.Add(copyAll);
        var expander = dlg.Add(null, new Expander { Header = Strings.Ai_ShowExactly, Content = previewPanel, Margin = new Thickness(0, 10, 0, 0) });
        expander.Expanded += (_, _) =>
        {
            if (full is not null) return;
            full = AiPrompts.Preview(outgoing.Requests);
            preview.Text = full.Length <= MaxShown ? full : full[..MaxShown] + "\n" + Loc.Format(Strings.Ai_MoreChars, full.Length - MaxShown);
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
            dlg.AddNote(Loc.Format(Strings.Ai_FirstCloud, ep.Host)).FontWeight = FontWeights.SemiBold;
            cloudOk = dlg.AddCheck(Loc.Format(Strings.Ai_IUnderstand, ep.Host));
        }
        if (copyRestricted)
        {
            dlg.AddNote(Strings.Ai_RestrictedNote).FontWeight = FontWeights.SemiBold;
            restrictedOk = dlg.AddCheck(Strings.Ai_SendAnyway);
        }
        // A window shown regardless of that choice (combining partial summaries for an internet endpoint) doesn't offer it.
        CheckBox? dontAsk = null;
        if (!force)
        {
            dontAsk = dlg.AddCheck(Loc.Format(Strings.Ai_DontAsk, ep.Host), AiService.SkipsPreview(ep));
            dontAsk.Margin = new Thickness(0, 14, 0, 0);
        }
        dlg.Validate(() =>
            cloudOk is { IsChecked: not true } ? Loc.Format(Strings.Ai_TickUnderstand, ep.Host)
            : restrictedOk is { IsChecked: not true } ? Strings.Ai_TickAnyway
            : null);
        if (!dlg.ShowModal()) return false;

        var s = AppSettings.Current;
        if (dontAsk is not null)
        {
            s.AiNoPreview.RemoveAll(k => string.Equals(k, ep.Key, StringComparison.OrdinalIgnoreCase));
            if (dontAsk.IsChecked == true) s.AiNoPreview.Add(ep.Key);
        }
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
        if (!s.IsPdf || !s.HasEncryption) return false;
        var password = s.Password;
        try
        {
            return await Task.Run(() =>
            {
                if (SecurityActions.Read(s) is not { IsEncrypted: true } info || info.Permissions.Copy) return false;
                var hasOwnerPassword = !string.IsNullOrEmpty(password) && !PdfSecurity.IsOpenPassword(data, password);
                return !hasOwnerPassword;
            });
        }
        catch (Exception ex)
        {
            Log.Write($"AI: permissions unreadable ({ex.GetType().Name}); asking as if copying were restricted");
            return true;
        }
    }

    /// <summary>Review › AI Assistant › Summarize: which pages. Null when cancelled.</summary>
    public static int[]? AskSummaryPages(Window owner, DocumentTab tab)
    {
        var dlg = new FormDialog(owner, Strings.Ai_SummarizeTitle, Strings.Common_Next, 440);
        var range = dlg.AddRange(tab, Strings.Ai_PagesToSummarize, preferSelection: tab.SelectedPages.Length > 1);
        if (tab.SelectedPages.Length <= 1) range.SelectAll();
        dlg.AddNote(Strings.Ai_NextShows);
        int[] pages = [];
        dlg.Validate(() => range.TryGet(out pages, out var error) ? null : error);
        return dlg.ShowModal() ? pages : null;
    }

    /// <summary>Review › AI Assistant › Translate: into what, and which pages. Null when cancelled.</summary>
    public static (string Language, string? Tag, int[] Pages)? AskTranslate(Window owner, DocumentTab tab)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, Strings.Ai_TranslateTitle, Strings.Common_Next, 480);
        dlg.AddNote(Strings.Ai_TranslateNote);
        var names = Translation.Languages.Select(l => l.Name).ToList();
        var language = dlg.Add(Strings.Ai_Into, new ComboBox { IsEditable = true, ItemsSource = names, Text = s.AiTranslateLanguage });
        AutomationProperties.SetName(language, Strings.Ai_TranslateInto);
        AutomationProperties.SetHelpText(language, Strings.Ai_TranslateIntoHelp);
        var range = dlg.AddRange(tab, Strings.Ai_PagesToTranslate, preferSelection: tab.SelectedPages.Length > 1);
        if (tab.SelectedPages.Length <= 1) range.SelectAll();
        dlg.AddNote(Strings.Ai_TranslateNextNote);
        int[] pages = [];
        dlg.Validate(() => language.Text.Trim().Length == 0 ? Strings.Ai_ChooseLanguage
            : range.TryGet(out pages, out var error) ? null : error);
        if (!dlg.ShowModal()) return null;
        var chosen = language.Text.Trim();
        s.AiTranslateLanguage = chosen;
        s.Save();
        return (chosen, Translation.Languages.FirstOrDefault(l => l.Name.Equals(chosen, StringComparison.OrdinalIgnoreCase))?.Tag, pages);
    }

    /// <summary>Speaks <paramref name="message"/> through <paramref name="target"/> (a polite live region).</summary>
    public static void Announce(FrameworkElement target, string message)
    {
        AutomationProperties.SetName(target, message);
        UIElementAutomationPeer.CreatePeerForElement(target)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }
}
