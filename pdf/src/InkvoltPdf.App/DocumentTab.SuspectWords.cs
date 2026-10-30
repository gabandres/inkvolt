using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>A suspect word in the Suspect words pane: where it is, what was read, why it is suspect, and its picture.</summary>
public sealed class SuspectWordItem(int page, int index, OcrWord word, string pageLabel, string? language) : INotifyPropertyChanged
{
    private ImageSource? _image;

    public int Page { get; } = page;
    /// <summary>The word's index in its page's text layer.</summary>
    public int Index { get; } = index;
    public OcrWord Word { get; } = word;
    public string? Language { get; } = language;
    public string Text => Word.Text;
    public string Where { get; } = $"Page {pageLabel}";

    /// <summary>The turn that shows the word's picture level (it was cut from the page at the word's angle).</summary>
    public double Level => -Word.Angle;

    public string Why
    {
        get
        {
            var why = new List<string>();
            if (Word.Suspect.HasFlag(SuspectReasons.NotInDictionary)) why.Add("not in the dictionary");
            if (Word.Suspect.HasFlag(SuspectReasons.LettersAndDigits)) why.Add("letters and digits mixed");
            if (Word.Suspect.HasFlag(SuspectReasons.OddCharacters)) why.Add("odd characters");
            if (Word.Suspect.HasFlag(SuspectReasons.ReadDifferently)) why.Add("read differently before cleaning");
            return string.Join(", ", why);
        }
    }

    public string Caption => $"{Where} · {Why}";

    /// <summary>The word as it is on the page (rendered when the item is shown).</summary>
    public ImageSource? Image
    {
        get => _image;
        set
        {
            _image = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Image)));
        }
    }

    /// <summary>What a screen reader says for the item.</summary>
    public string Spoken => $"{Text}. {Where}. {Why}";

    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>
/// The Suspect words pane: the words Recognize Text marked as suspect (<see cref="SuspectWords"/>: Windows' recognizer
/// gives no confidence, so these are dictionary misses, letters and digits mixed, odd characters, readings that differ
/// before and after cleaning), each beside its picture cut from the page. Choosing one shows it on the page; it is
/// corrected in place (the text layer is written again, so search finds the correction) or kept as read. Each is one
/// undo step. Enter corrects, Esc goes back to the list.
/// </summary>
public partial class DocumentTab
{
    private bool _suspectFilling;
    private bool _suspectAgain;
    private int _suspectSelect;

    private void InitSuspectWords()
    {
        SuspectRail.Click += (_, _) =>
        {
            if (_pane == NavPaneKind.SuspectWords) TogglePane(NavPaneKind.SuspectWords);
            else _ = ShowSuspectWordsAsync();
        };
        SuspectList.SelectionChanged += (_, _) => ShowSelectedSuspect();
        SuspectList.PreviewKeyDown += (_, e) =>
        {
            if (e.Key is Key.Enter or Key.F2 && SuspectEditor.Visibility == Visibility.Visible)
            {
                SuspectText.Focus();
                SuspectText.SelectAll();
                e.Handled = true;
            }
        };
        SuspectText.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                _ = CorrectSuspectAsync(SuspectText.Text);
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                (SuspectList.ItemContainerGenerator.ContainerFromItem(SuspectList.SelectedItem) as ListBoxItem ?? (UIElement)SuspectList).Focus();
                e.Handled = true;
            }
        };
        SuspectCorrect.Click += (_, _) => _ = CorrectSuspectAsync(SuspectText.Text);
        SuspectKeep.Click += (_, _) => _ = KeepSuspectAsync();
        // A correction, an undo or any other edit: the list follows the document.
        Session.ContentChanged += (_, _) =>
        {
            if (_pane == NavPaneKind.SuspectWords) _ = FillSuspectWordsAsync();
        };
    }

    /// <summary>Opens the pane on the document's suspect words.</summary>
    public async Task ShowSuspectWordsAsync()
    {
        if (!Session.IsPdf || !await SettleAsync()) return;
        SuspectRail.Visibility = Visibility.Visible;
        ShowPane(NavPaneKind.SuspectWords);
        await FillSuspectWordsAsync();
        _ = Dispatcher.BeginInvoke(() => SuspectList.Focus(), System.Windows.Threading.DispatcherPriority.Input);
    }

    /// <summary>The suspect words of the document as it is now, read from its text layers.</summary>
    internal async Task FillSuspectWordsAsync()
    {
        if (_suspectFilling)
        {
            _suspectAgain = true; // read again once this one is done: the document changed meanwhile
            return;
        }
        _suspectFilling = true;
        try
        {
            do
            {
                _suspectAgain = false;
                var (data, password, engine) = (Session.Data, Session.Password, Session.Engine);
                var layers = await Task.Run(() =>
                {
                    try
                    {
                        return TextLayer.Words(data, password);
                    }
                    catch (Exception ex) when (ex is not OutOfMemoryException)
                    {
                        Log.Write($"Reading the recognized text failed: {ex.Message}");
                        return [];
                    }
                });
                var items = layers.OrderBy(kv => kv.Key)
                    .SelectMany(kv => kv.Value.Words.Select((w, i) => (w, i)).Where(x => x.w.Suspect != SuspectReasons.None)
                        .Select(x => new SuspectWordItem(kv.Key, x.i, x.w, PageLabel(kv.Key), kv.Value.Language)))
                    .ToList();
                SuspectList.ItemsSource = items;
                var pages = items.Select(i => i.Page).Distinct().Count();
                SuspectSummary.Text = items.Count > 0
                    ? $"{items.Count} suspect word{(items.Count == 1 ? "" : "s")} on {pages} page{(pages == 1 ? "" : "s")}. Correct a word or keep it as read."
                    : layers.Count == 0
                        ? "No recognized text to check here. Use Recognize Text (OCR) on scanned pages first."
                        : "No suspect words left: every recognized word has been checked or looked right.";
                UpdatePaneDetail();
                if (items.Count > 0) SuspectList.SelectedIndex = Math.Clamp(_suspectSelect, 0, items.Count - 1);
                else ShowSelectedSuspect();
                _ = LoadSuspectImagesAsync(items, engine);
            }
            while (_suspectAgain);
        }
        finally
        {
            _suspectFilling = false;
        }
    }

    /// <summary>Cuts each word's picture from its page (with a little room around it), a few at a time, off the UI thread.</summary>
    private async Task LoadSuspectImagesAsync(List<SuspectWordItem> items, PdfEngine engine)
    {
        foreach (var item in items)
        {
            if (!ReferenceEquals(SuspectList.ItemsSource, items)) return; // the list was filled again
            try
            {
                var bmp = await Task.Run(() =>
                {
                    var g = engine.GetPage(item.Page);
                    var box = TurnedBounds(item.Word);
                    var (padX, padY) = (Math.Max(3, item.Word.Rect.Height * 0.4), Math.Max(1, item.Word.Rect.Height * 0.12));
                    var region = RectD.FromEdges(Math.Max(0, box.X - padX), Math.Max(0, box.Y - padY), Math.Min(g.Width, box.Right + padX), Math.Min(g.Height, box.Bottom + padY));
                    if (region.IsEmpty) return null;
                    var scale = Math.Clamp(44 / Math.Max(1, item.Word.Rect.Height), 1, 4);
                    var bitmap = PageViewer.ToBitmap(engine.Render(item.Page, scale, region));
                    bitmap.Freeze();
                    return bitmap;
                });
                item.Image = bmp;
            }
            catch (Exception ex) when (ex is ObjectDisposedException or InvalidOperationException)
            {
                return; // the document changed under it
            }
        }
    }

    /// <summary>The upright box around a word's turned box.</summary>
    private static RectD TurnedBounds(OcrWord w)
    {
        if (w.Angle == 0) return w.Rect;
        var (sin, cos) = Math.SinCos(w.Angle * Math.PI / 180);
        var (hw, hh) = (w.Rect.Width / 2, w.Rect.Height / 2);
        var ex = Math.Abs(hw * cos) + Math.Abs(hh * sin);
        var ey = Math.Abs(hw * sin) + Math.Abs(hh * cos);
        return RectD.FromEdges(w.Rect.CenterX - ex, w.Rect.CenterY - ey, w.Rect.CenterX + ex, w.Rect.CenterY + ey);
    }

    private void ShowSelectedSuspect()
    {
        if (SuspectList.SelectedItem is not SuspectWordItem item)
        {
            SuspectEditor.Visibility = Visibility.Collapsed;
            return;
        }
        _suspectSelect = SuspectList.SelectedIndex;
        SuspectEditor.Visibility = Visibility.Visible;
        SuspectText.Text = item.Text;
        SuspectSuggestions.Children.Clear();
        var core = SuspectWords.Core(item.Text);
        var suggestions = item.Word.Suspect.HasFlag(SuspectReasons.NotInDictionary) && PageOcr.Spelling(item.Language) is { } spelling
            ? spelling.Suggest(core).Take(4).ToList()
            : [];
        foreach (var s in suggestions)
        {
            // Keep what was around the word ("rlver," → "river,").
            var start = item.Text.IndexOf(core, StringComparison.Ordinal);
            var whole = start < 0 ? s : item.Text[..start] + s + item.Text[(start + core.Length)..];
            var b = new Button { Content = whole, Margin = new Thickness(0, 0, 6, 4), ToolTip = $"Correct to \"{whole}\"" };
            b.Click += (_, _) => _ = CorrectSuspectAsync(whole);
            SuspectSuggestions.Children.Add(b);
        }
        SuspectSuggestions.Visibility = suggestions.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        Viewer.Flash(item.Page, TurnedBounds(item.Word));
    }

    private async Task CorrectSuspectAsync(string text)
    {
        if (SuspectList.SelectedItem is not SuspectWordItem item) return;
        text = text.Trim();
        if (text.Length == 0)
        {
            Notify("A word can't be empty: type the correction, or choose Keep as read.");
            return;
        }
        if (text.Contains(' ') || text.Contains('\n'))
        {
            Notify("Type one word: a correction replaces one recognized word.");
            return;
        }
        var outcome = await TryEdit("Correct recognized word", (d, pw) => TextLayer.Correct(d, pw, item.Page, item.Index, text), quiet: true);
        if (outcome == EditOutcome.Done) Notify($"\"{item.Text}\" is now \"{text}\" on page {PageLabel(item.Page)}; search finds it.");
    }

    private async Task KeepSuspectAsync()
    {
        if (SuspectList.SelectedItem is not SuspectWordItem item) return;
        await TryEdit("Keep recognized word", (d, pw) => TextLayer.Keep(d, pw, item.Page, item.Index), quiet: true);
    }

    /// <summary>Dev/test: the pane's words as "text (page, why)".</summary>
    internal IEnumerable<string> DevSuspectWords() =>
        (SuspectList.ItemsSource as IEnumerable<SuspectWordItem> ?? []).Select(i => $"{i.Text} (p{i.Page + 1}, {i.Why})");

    /// <summary>Dev/test: select a suspect word.</summary>
    internal void DevSelectSuspect(int index) => SuspectList.SelectedIndex = index;

    /// <summary>Dev/test: correct the selected suspect word, or keep it (null).</summary>
    internal Task DevCorrectSuspect(string? text) => text is null ? KeepSuspectAsync() : CorrectSuspectAsync(text);
}
