using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using InkvoltPdf.Core;
using InkvoltPrint.Windows.Ocr;

namespace InkvoltPdf.App;

/// <summary>
/// Spell check where people type (roadmap 4.1): Windows' own spell checker (its dictionaries and the user's own words), in
/// the document's language, else the interface's (<see cref="SpellChecker.Languages"/>). Plain text boxes (sticky notes,
/// text boxes, callouts, form fields, a run of page text) get WPF's underlines from the same dictionary
/// (<see cref="Attach"/>); Edit Text &amp; Images' paragraph editor draws its own from <see cref="SpellChecker"/>
/// (<c>PageViewer.Spelling.cs</c>). Both offer the same menu: suggestions, Ignore, Add to dictionary. Settings › "Check
/// spelling as I type" turns it all off.
/// </summary>
internal static class Spelling
{
    /// <summary>Windows' dictionary for one language, as Core's <see cref="ISpellingDictionary"/>.</summary>
    private sealed class WindowsDictionary(WindowsSpelling windows) : ISpellingDictionary
    {
        private readonly HashSet<string> _addedThisRun = new(StringComparer.Ordinal);
        public string Language => windows.Language;
        public bool IsKnown(string word) => _addedThisRun.Contains(word) || windows.IsKnown(word);
        public IReadOnlyList<string> Suggest(string word) => windows.Suggest(word);
        public bool Add(string word)
        {
            if (!KeepUserDictionary) return windows.Add(word);
            _addedThisRun.Add(word);
            return true;
        }
    }

    /// <summary>The dev script's runs: Add to dictionary keeps the word for the run only, and never writes the user's dictionary.</summary>
    public static bool KeepUserDictionary { get; set; }

    private static readonly Lock Gate = new();
    private static readonly Dictionary<string, SpellChecker?> ByDocument = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, SpellChecker> ByLanguage = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Settings › "Check spelling as I type".</summary>
    public static bool On => AppSettings.Current.SpellCheck;

    /// <summary>
    /// The spell checker for text typed into a document whose text is in <paramref name="documentLanguage"/> (null: it
    /// doesn't say), one per language for the app's session (so Ignore holds everywhere); null when spell check is off or
    /// Windows has a dictionary for none of the languages tried.
    /// </summary>
    public static SpellChecker? For(string? documentLanguage)
    {
        if (!On) return null;
        var key = documentLanguage ?? "";
        lock (Gate)
        {
            if (ByDocument.TryGetValue(key, out var known)) return known;
            SpellChecker? found = null;
            foreach (var tag in SpellChecker.Languages(documentLanguage, AppLanguage.Current.Name, CultureInfo.CurrentCulture.Name))
            {
                // Its own checker, made and used on the UI thread (Recognize Text's, PageOcr's, are used on its workers).
                WindowsSpelling? windows;
                try
                {
                    windows = WindowsSpelling.Create(tag);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"Spell check: no spell checker for {tag}: {ex.Message}");
                    windows = null;
                }
                if (windows is null) continue;
                if (!ByLanguage.TryGetValue(windows.Language, out found))
                    ByLanguage[windows.Language] = found = new SpellChecker(new WindowsDictionary(windows));
                break;
            }
            if (found is null) Log.Write($"Spell check: Windows has no dictionary for {documentLanguage ?? "-"} or the interface's language.");
            return ByDocument[key] = found;
        }
    }

    /// <summary>
    /// WPF's spell check on a text box people type into, in the dictionary's language, with <see cref="Menu"/> on right-click
    /// and the context menu key. Nothing when spell check is off or no dictionary is there.
    /// </summary>
    public static void Attach(TextBox box, string? documentLanguage)
    {
        if (For(documentLanguage) is not { } checker) return;
        try
        {
            box.Language = XmlLanguage.GetLanguage(checker.Language);
        }
        catch (ArgumentException)
        {
            return;
        }
        SpellCheck.SetIsEnabled(box, true);
        Attached.AddOrUpdate(box, checker);
        box.ContextMenuOpening += (_, e) =>
        {
            // From the keyboard (the context menu key, Shift+F10): the word at the caret.
            var index = e.CursorLeft < 0 && e.CursorTop < 0 ? box.CaretIndex : box.GetCharacterIndexFromPoint(Mouse.GetPosition(box), snapToText: true);
            box.ContextMenu = MenuAt(box, index < 0 ? box.CaretIndex : index);
        };
    }

    private static readonly ConditionalWeakTable<TextBox, SpellChecker> Attached = new();

    /// <summary>The menu of a text box <see cref="Attach"/> turned spell check on for, about the word at <paramref name="index"/>.</summary>
    public static ContextMenu MenuAt(TextBox box, int index)
    {
        var error = box.GetSpellingError(index) ?? (index > 0 ? box.GetSpellingError(index - 1) : null);
        if (error is null || !Attached.TryGetValue(box, out var checker)) return Menu(box, null, [], _ => { }, () => { }, () => { });
        var at = box.GetSpellingErrorStart(index) is var s and >= 0 ? s : box.GetSpellingErrorStart(index - 1);
        var length = at >= 0 ? box.GetSpellingErrorLength(at) : 0;
        var word = at >= 0 && length > 0 && at + length <= box.Text.Length ? box.Text.Substring(at, length) : null;
        return Menu(box, word, [.. error.Suggestions.Take(SpellChecker.MaxSuggestions)],
            error.Correct,
            error.IgnoreAll,
            () =>
            {
                if (word is null || !checker.Add(word))
                {
                    AddFailed(box, word);
                    return;
                }
                if (KeepUserDictionary)
                {
                    error.IgnoreAll(); // WPF reads Windows' dictionary, which a dev run leaves alone
                    return;
                }
                // WPF checks the box again only when its spell check is turned on again.
                SpellCheck.SetIsEnabled(box, false);
                SpellCheck.SetIsEnabled(box, true);
            });
    }

    /// <summary>
    /// The menu for a word: its suggestions (or "No suggestions"), Ignore and Add to dictionary when
    /// <paramref name="word"/> is misspelled, then Cut, Copy and Paste on <paramref name="target"/>.
    /// </summary>
    public static ContextMenu Menu(Control target, string? word, IReadOnlyList<string> suggestions, Action<string> correct, Action ignore, Action add)
    {
        var menu = new ContextMenu { PlacementTarget = target };
        if (word is not null)
        {
            foreach (var s in suggestions)
            {
                var item = new MenuItem { Header = s, FontWeight = FontWeights.SemiBold };
                item.Click += (_, _) => correct(s);
                menu.Items.Add(item);
            }
            if (suggestions.Count == 0) menu.Items.Add(new MenuItem { Header = Strings.Spell_NoSuggestions, IsEnabled = false });
            menu.Items.Add(new Separator());
            var ig = new MenuItem { Header = Strings.Spell_Ignore };
            ig.Click += (_, _) => ignore();
            menu.Items.Add(ig);
            var ad = new MenuItem { Header = Strings.Spell_AddToDictionary };
            ad.Click += (_, _) => add();
            menu.Items.Add(ad);
            menu.Items.Add(new Separator());
        }
        foreach (var command in new[] { ApplicationCommands.Cut, ApplicationCommands.Copy, ApplicationCommands.Paste })
            menu.Items.Add(new MenuItem { Command = command, CommandTarget = target });
        // The menu takes the focus while it is open; the box gets it back after (the page view's editors close when it leaves).
        menu.Closed += (_, _) => target.Dispatcher.BeginInvoke(() =>
        {
            if (target.IsVisible) target.Focus();
        });
        return menu;
    }

    /// <summary>Windows didn't take the word: said, never silently dropped.</summary>
    public static void AddFailed(FrameworkElement owner, string? word) =>
        Prompt.Error(Window.GetWindow(owner), Strings.Spell_AddFailedTitle, Loc.Format(Strings.Spell_AddFailed, word ?? ""));
}
