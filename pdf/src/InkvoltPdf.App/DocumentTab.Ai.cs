using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// The AI assistant (bring your own; off by default): its pane at the right of the document, and Summarize, Ask about
/// this document and Explain selection. Only the text the user asks about is read, shown before it is sent, and sent
/// to the endpoint in Settings › AI assistant. One request at a time per document, with Stop.
/// </summary>
public partial class DocumentTab
{
    private AiPane? _aiPane;
    private ColumnDefinition? _aiColumn;
    private GridSplitter? _aiSplitter;
    private CancellationTokenSource? _aiCancel;
    private bool _aiCopyRestricted;
    private readonly List<AiTurn> _aiTurns = [];
    private MenuItem? _ctxExplain;
    // Page text already read for the AI, for the engine it came from (an edit replaces the engine and so the cache).
    private PdfEngine? _aiTextEngine;
    private readonly Dictionary<int, string> _aiText = [];

    public bool IsAiPaneOpen => _aiPane is { Visibility: Visibility.Visible };

    /// <summary>True while a request of this document's AI assistant runs.</summary>
    public bool IsAiBusy => _aiCancel is not null;

    internal AiPane? AiPaneView => _aiPane;

    /// <summary>"Explain with AI" in the page's context menu, shown for a text selection while the assistant is on.</summary>
    private void InitAi()
    {
        if (Viewer.ContextMenu is not { } menu) return;
        _ctxExplain = new MenuItem { Command = Cmd.AiExplain, Header = "E_xplain with AI" };
        menu.Items.Insert(menu.Items.IndexOf(CtxMarkupSeparator), _ctxExplain);
        Viewer.ContextMenuOpening += (_, _) =>
            _ctxExplain.Visibility = AiService.IsEnabled && Viewer.HasSelection ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Opens the pane (made on first use) and puts the caret in the question box.</summary>
    public void ShowAiPane(bool focusQuestion = true)
    {
        if (_disposed) return;
        if (_aiPane is null)
        {
            var root = (Grid)Content;
            _aiPane = new AiPane();
            _aiSplitter = new GridSplitter
            {
                Width = 4,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Background = System.Windows.Media.Brushes.Transparent,
                ResizeBehavior = GridResizeBehavior.PreviousAndNext,
                KeyboardIncrement = 24,
                Focusable = true,
            };
            System.Windows.Automation.AutomationProperties.SetName(_aiSplitter, "Resize the AI assistant");
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _aiColumn = new ColumnDefinition { Width = new GridLength(360), MinWidth = 260, MaxWidth = 900 };
            root.ColumnDefinitions.Add(_aiColumn);
            Grid.SetColumn(_aiSplitter, root.ColumnDefinitions.Count - 2);
            Grid.SetColumn(_aiPane, root.ColumnDefinitions.Count - 1);
            root.Children.Add(_aiSplitter);
            root.Children.Add(_aiPane);

            _aiPane.CloseRequested += (_, _) => CloseAiPane();
            _aiPane.StopRequested += (_, _) => _aiCancel?.Cancel();
            _aiPane.ClearRequested += (_, _) =>
            {
                _aiCancel?.Cancel();
                _aiTurns.Clear();
                _aiPane.Clear();
                _aiPane.ShowStatus("Conversation cleared");
            };
            _aiPane.AskRequested += (_, q) => _ = AiAsk(q);
            _aiPane.SummarizeRequested += (_, _) => Cmd.AiSummarize.Execute(null, Window.GetWindow(this));
            _aiPane.SettingsRequested += (_, _) =>
            {
                if (Window.GetWindow(this) is { } w && AiActions.ShowSettings(w)) RefreshAiPane();
            };
            _aiPane.PageRequested += (_, page) =>
            {
                if (page >= 0 && page < Viewer.PageCount) ActiveView.GoToPage(page);
            };
        }
        _aiPane.Visibility = Visibility.Visible;
        if (_aiSplitter is not null) _aiSplitter.Visibility = Visibility.Visible;
        if (_aiColumn is not null) _aiColumn.MinWidth = 260;
        RefreshAiPane();
        if (focusQuestion) Dispatcher.BeginInvoke(() => _aiPane.Input.Focus(), System.Windows.Threading.DispatcherPriority.Input);
        RaiseState();
    }

    public void CloseAiPane()
    {
        if (_aiPane is null) return;
        _aiPane.Visibility = Visibility.Collapsed;
        if (_aiSplitter is not null) _aiSplitter.Visibility = Visibility.Collapsed;
        if (_aiColumn is not null)
        {
            _aiColumn.MinWidth = 0;
            _aiColumn.Width = GridLength.Auto; // collapsed content: the column takes no room
        }
        ActiveView.Focus();
        RaiseState();
    }

    /// <summary>Shows the current endpoint in the pane (after Settings changed it).</summary>
    public void RefreshAiPane()
    {
        if (_aiPane is null) return;
        var config = AiService.Current(out var problem);
        _aiPane.ShowDestination(config, problem);
        if (_aiColumn is { Width.IsAuto: true } && _aiPane.Visibility == Visibility.Visible) _aiColumn.Width = new GridLength(360);
    }

    // ───────────────────────────── Uses ─────────────────────────────

    /// <summary>Summarizes the pages (map-reduce when they don't fit the model's context).</summary>
    public async Task AiSummarize(int[] pages)
    {
        if (await AiPrepare() is not { } config) return;
        var texts = await AiReadPages(pages);
        if (texts is null) return;
        var chunks = AiText.Chunk(texts, config.InputTokens);
        if (chunks.Count == 0)
        {
            _aiPane!.ShowStatus($"Not sent: {AiText.PagesText(pages)} {(pages.Length == 1 ? "has" : "have")} no text. Scanned pages need Recognize Text (OCR) first.");
            return;
        }
        var first = AiPrompts.SummaryRequests(chunks);
        var label = $"Summarize {AiText.PagesText(pages)}";
        // The combining requests carry the model's own partial summaries: they are shown before they go (always for an
        // internet endpoint; on this PC or the network unless the user chose not to be asked for it).
        var showCombine = config.Endpoint.Reach == AiReach.Internet || !AiService.SkipsPreview(config.Endpoint);
        var outgoing = new AiOutgoing(first, $"The text of {AiText.PagesText(pages)}",
            first.Count == 1 ? null
            : showCombine ? "the partial summaries the model writes, which you'll see before they're sent back to it to be combined"
            : "the partial summaries the model writes, sent back to it to be combined (without asking, as chosen for this endpoint)");
        await AiRun(config, label, outgoing, async (client, onFinal, onStep, ct) =>
        {
            string? finish = null;
            var declined = false;
            var text = await AiPrompts.SummarizeAsync(chunks, config.InputTokens, async (messages, step, c) =>
            {
                onStep(step);
                var reply = await client.ChatAsync(messages, step.IsFinal ? onFinal : null, c);
                if (step.IsFinal) finish = reply.FinishReason;
                return AiText.WithoutThinking(reply.Text, out _);
            }, ct, async (round, c) =>
            {
                await Task.Yield();
                var ok = Window.GetWindow(this) is { } w && !_disposed && AiActions.ConfirmSend(w, config,
                    new AiOutgoing(round, $"The partial summaries the model wrote about {AiText.PagesText(pages)}", null),
                    _aiCopyRestricted, force: config.Endpoint.Reach == AiReach.Internet, title: "Send the partial summaries to combine them?");
                declined = !ok;
                return ok;
            });
            return new AiReply(text, declined ? NotCombined : finish);
        });
    }

    /// <summary>The finish reason of a summary whose parts the user chose not to send back to be combined.</summary>
    private const string NotCombined = "inkvolt:not-combined";

    /// <summary>A question about the pages in the pane's Pages box, with the conversation so far.</summary>
    public async Task AiAsk(string question)
    {
        if (question.Trim().Length == 0) return;
        if (await AiPrepare() is not { } config) return;
        var scope = _aiPane!.Scope.Text.Trim();
        int[] pages;
        if (scope.Length == 0 || scope.Equals("all", StringComparison.OrdinalIgnoreCase)) pages = [.. Enumerable.Range(0, Viewer.PageCount)];
        else if (!Core.PageRange.TryParse(scope, Viewer.PageCount, out pages, out var error))
        {
            _aiPane.ShowStatus($"Pages: {error}");
            _aiPane.Scope.Focus();
            return;
        }
        var texts = await AiReadPages(pages);
        if (texts is null) return;
        var request = AiPrompts.Ask(question, _aiTurns, texts, config.InputTokens);
        if (request.Pages.Count == 0)
        {
            _aiPane.ShowStatus($"Not sent: {AiText.PagesText(pages)} {(pages.Length == 1 ? "has" : "have")} no text to ask about.");
            return;
        }
        var what = request.Trimmed
            ? $"Your question, the parts of {AiText.PagesText(request.Pages)} most related to it (all of {AiText.PagesText(pages)} doesn't fit the model's context)"
            : $"Your question and the text of {AiText.PagesText(request.Pages)}";
        if (_aiTurns.Count > 0) what += $", and the conversation so far ({_aiTurns.Count} earlier {(_aiTurns.Count == 1 ? "answer" : "answers")})";
        if (await AiRun(config, question, new AiOutgoing([request.Messages], what, null), async (client, onFinal, onStep, ct) =>
            {
                onStep(new AiStep(1, 1, true, "Asking"));
                return await client.ChatAsync(request.Messages, onFinal, ct);
            }))
            _aiPane.Input.Clear();
    }

    /// <summary>Explains the main view's selected text.</summary>
    public async Task AiExplainSelection()
    {
        if (!Viewer.HasSelection || Viewer.SelectionFirstPage is not { } page) return;
        if (await AiPrepare() is not { } config) return;
        string selection;
        try
        {
            selection = await Viewer.GetSelectedTextAsync();
        }
        catch (Exception ex) when (ex is ObjectDisposedException or OperationCanceledException)
        {
            _aiPane!.ShowStatus("Not sent: the document changed meanwhile. Select the text again.");
            return;
        }
        IReadOnlyList<AiMessage> messages;
        try
        {
            messages = AiPrompts.Explain(selection, page, config.InputTokens);
        }
        catch (AiException ex)
        {
            _aiPane!.ShowStatus(ex.Message);
            return;
        }
        var shown = AiText.Clean(selection);
        var label = $"Explain: “{AiProtocol.Shorten(shown.Replace('\n', ' '), 120)}”";
        await AiRun(config, label, new AiOutgoing([messages], $"The selected text ({AiText.PagesText(page, page)})", null), async (client, onFinal, onStep, ct) =>
        {
            onStep(new AiStep(1, 1, true, "Explaining"));
            return await client.ChatAsync(messages, onFinal, ct);
        }, historyQuestion: $"Explain this passage from page {page + 1}: \"{AiProtocol.Shorten(shown, 600)}\"");
    }

    // ───────────────────────────── Plumbing ─────────────────────────────

    /// <summary>The configuration to use, with the pane open; null (after asking for setup) when the assistant is off or busy.</summary>
    private async Task<AiConfig?> AiPrepare()
    {
        if (_disposed || Window.GetWindow(this) is not { } owner) return null;
        if (AiService.Current(out var problem) is not { } config)
        {
            if (!AiActions.ShowSettings(owner, problem + " Set it up here, or Cancel.")) return null;
            if (AiService.Current(out _) is not { } now) return null;
            config = now;
        }
        ShowAiPane(focusQuestion: false);
        if (IsAiBusy)
        {
            _aiPane!.ShowStatus("Wait for the current answer, or Stop it first.");
            return null;
        }
        if (config.IsOllama)
        {
            // Ollama cuts a prompt longer than its context without a word: ask it how much this model gets.
            using var cts = new CancellationTokenSource();
            _aiCancel = cts;
            _aiPane!.SetBusy(true);
            _aiPane.ShowStatus("Asking Ollama how much text the model reads at once…");
            try
            {
                config = await AiService.ResolveAsync(config, cts.Token);
            }
            catch (OperationCanceledException)
            {
                _aiPane.ShowStatus("Stopped. Nothing was sent.");
                return null;
            }
            finally
            {
                _aiCancel = null;
                if (!_disposed) _aiPane.SetBusy(false);
            }
            _aiPane.ShowStatus($"{config.Model} reads {config.ContextTokens:N0} tokens at once ({config.ContextSource}).");
        }
        await Task.Yield();
        return config;
    }

    /// <summary>The pages' text as shown (chosen layers applied), read in the background; null when cancelled or failed.</summary>
    private async Task<List<AiPageText>?> AiReadPages(int[] pages)
    {
        var engine = ViewEngine;
        if (!ReferenceEquals(engine, _aiTextEngine))
        {
            _aiText.Clear();
            _aiTextEngine = engine;
        }
        var missing = pages.Where(p => !_aiText.ContainsKey(p)).ToArray();
        if (missing.Length > 0)
        {
            using var cts = new CancellationTokenSource();
            _aiCancel = cts;
            _aiPane!.SetBusy(true);
            _aiPane.ShowStatus($"Reading the text of {AiText.PagesText(missing)}…");
            try
            {
                var progress = new Progress<int>(done => _aiPane.ShowStatus($"Reading the text… {done:N0} of {missing.Length:N0} pages"));
                var read = await Task.Run(() =>
                {
                    var result = new Dictionary<int, string>();
                    var reporter = (IProgress<int>)progress;
                    for (var i = 0; i < missing.Length; i++)
                    {
                        cts.Token.ThrowIfCancellationRequested();
                        try
                        {
                            result[missing[i]] = engine.GetText(missing[i], cache: false, cts.Token).Text;
                        }
                        catch (MuPDFCore.MuPDFException ex)
                        {
                            Log.Write($"AI: page {missing[i] + 1} can't be read: {ex.Message}");
                            result[missing[i]] = "";
                        }
                        if (i % 25 == 24) reporter.Report(i + 1);
                    }
                    return result;
                }, cts.Token);
                if (!ReferenceEquals(engine, ViewEngine)) throw new ObjectDisposedException(nameof(PdfEngine));
                foreach (var (p, t) in read) _aiText[p] = t;
            }
            catch (OperationCanceledException)
            {
                _aiPane.ShowStatus("Stopped. Nothing was sent.");
                return null;
            }
            catch (ObjectDisposedException)
            {
                _aiPane.ShowStatus("Not sent: the document changed while its text was read. Try again.");
                return null;
            }
            catch (Exception ex)
            {
                Log.Write($"AI: reading the pages' text failed: {ex.GetType().Name}");
                _aiPane.ShowStatus("Not sent: the pages' text couldn't be read.");
                return null;
            }
            finally
            {
                _aiCancel = null;
                if (!_disposed) _aiPane.SetBusy(false);
            }
        }
        return [.. pages.Select(p => new AiPageText(p, _aiText.GetValueOrDefault(p, "")))];
    }

    /// <summary>
    /// Confirms the send (unless the user chose not to be asked for this endpoint), then runs the job, streaming the final
    /// answer into a new card. Returns true when an answer came back.
    /// </summary>
    private async Task<bool> AiRun(AiConfig config, string question, AiOutgoing outgoing,
        Func<AiClient, Action<string>, Action<AiStep>, CancellationToken, Task<AiReply>> job, string? historyQuestion = null)
    {
        if (_disposed || Window.GetWindow(this) is not { } owner || _aiPane is null) return false;
        var restricted = await AiActions.IsCopyRestrictedAsync(Session);
        if (_disposed) return false;
        _aiCopyRestricted = restricted;
        if (!AiActions.ConfirmSend(owner, config, outgoing, restricted))
        {
            _aiPane.ShowStatus("Not sent.");
            return false;
        }

        _aiPane.AddQuestion(question);
        var card = _aiPane.AddAnswer(config.Model, Viewer.PageCount);
        using var cts = new CancellationTokenSource();
        _aiCancel = cts;
        _aiPane.SetBusy(true);
        _aiPane.ShowStatus($"Sending to {config.Endpoint.Host}…");
        RaiseState();
        Log.Write($"AI: {outgoing.Requests.Count} request(s), {outgoing.Characters:N0} characters to {config.Endpoint.Host}"); // never the text
        var dispatcher = Dispatcher;
        var finished = false;
        // Streamed pieces arrive on the HTTP thread; progress may be reported on this one (then shown at once, so a
        // failure right after it isn't overwritten by a late "Asking…").
        void Ui(Action a)
        {
            if (dispatcher.CheckAccess()) a();
            else dispatcher.BeginInvoke(() => { if (!finished) a(); });
        }
        try
        {
            using var client = AiService.CreateClient(config);
            var reply = await job(client,
                piece => Ui(() => card.Append(piece)),
                step => Ui(() =>
                {
                    var text = step.Total > 1 ? $"{step.What} ({step.Index} of {step.Total})…" : $"{step.What}…";
                    _aiPane.ShowStatus(text);
                    card.Progress(text);
                }),
                cts.Token);
            await dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.Background); // streamed pieces first
            finished = true;
            var answer = AiText.WithoutThinking(reply.Text, out _).Trim();
            card.Finish(answer, reply.FinishReason == NotCombined ? "The partial summaries, not combined: you chose not to send them back to the model."
                : reply.WasCutOff ? "The answer was cut off at the model's length limit."
                : answer.Length == 0 ? "The model sent an empty answer." : null);
            if (answer.Length > 0) _aiTurns.Add(new AiTurn(historyQuestion ?? question, answer));
            _aiPane.ShowStatus("Answer ready. AI-generated: check it against the pages.");
            return true;
        }
        catch (OperationCanceledException)
        {
            finished = true;
            card.Finish(null, "Stopped.");
            _aiPane.ShowStatus("Stopped.");
        }
        catch (AiException ex)
        {
            finished = true;
            Log.Write($"AI: the request to {config.Endpoint.Host} failed"); // not the message: a server may echo text back
            card.Finish(null, ex.Message, error: true);
            _aiPane.ShowStatus(ex.Message);
        }
        catch (Exception ex)
        {
            // Anything unexpected still ends the card (the callers don't await this): an error, never a lasting "…".
            finished = true;
            Log.Write($"AI: the request to {config.Endpoint.Host} failed unexpectedly: {ex.GetType().Name}");
            var message = $"Something went wrong with the answer from {config.Endpoint.Host} ({ex.GetType().Name}). Nothing more was sent.";
            card.Finish(null, message, error: true);
            _aiPane.ShowStatus(message);
        }
        finally
        {
            _aiCancel = null;
            if (!_disposed)
            {
                _aiPane.SetBusy(false);
                RaiseState();
            }
        }
        return false;
    }

    private void DisposeAi()
    {
        _aiCancel?.Cancel();
        _aiText.Clear();
        _aiTextEngine = null;
    }

    internal string DevAiState() => _aiPane is null ? "ai pane: not opened" : $"ai pane: open={IsAiPaneOpen} {_aiPane.DevState()} turns={_aiTurns.Count}";
}
