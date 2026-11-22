using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Threading;
using InkvoltPdf.Core;
using InkvoltPrint.Windows.Ocr;

namespace InkvoltPdf.App;

/// <summary>
/// Spell check where people type (roadmap 4.1): Windows' own spell checker (its dictionaries and the user's own words), in
/// the document's language, else the interface's (<see cref="SpellChecker.Languages"/>). Plain text boxes (sticky notes,
/// text boxes, callouts, form fields, a run of page text) get WPF's underlines from the same dictionary
/// (<see cref="Attach"/>); Edit Text &amp; Images' paragraph editor draws its own from <see cref="SpellChecker"/>
/// (<c>PageViewer.Spelling.cs</c>). Both offer the same menu: suggestions, Ignore, Add to dictionary; Ignore goes through
/// the one <see cref="SpellChecker"/> of the language, so a word ignored anywhere is left alone everywhere. Settings ›
/// "Check spelling as I type" turns it all off.
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
    /// Windows has a dictionary for none of the languages tried. Which language is tried depends on the interface's too.
    /// </summary>
    public static SpellChecker? For(string? documentLanguage)
    {
        if (!On) return null;
        var ui = AppLanguage.Current.Name;
        var key = ui + "|" + documentLanguage;
        lock (Gate)
        {
            if (ByDocument.TryGetValue(key, out var known)) return known;
            SpellChecker? found = null;
            foreach (var tag in SpellChecker.Languages(documentLanguage, ui, CultureInfo.CurrentCulture.Name))
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

    private static readonly ConditionalWeakTable<TextBox, SpellChecker> Attached = new();

    /// <summary>
    /// WPF's spell check on a text box people type into, in the dictionary's language, with <see cref="Menu"/> on
    /// right-click, the context menu key and Shift+F10. Nothing when spell check is off or no dictionary is there; again
    /// on a box already attached, it turns its spell check back on.
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
        var first = !Attached.TryGetValue(box, out _);
        Attached.AddOrUpdate(box, checker);
        SpellCheck.SetIsEnabled(box, true);
        if (!first)
        {
            LeaveIgnored(box);
            return;
        }
        HookMenu(box, (menu, clicked) =>
        {
            var index = clicked ? box.GetCharacterIndexFromPoint(Mouse.GetPosition(box), snapToText: true) : box.CaretIndex;
            FillAt(box, menu, index < 0 ? box.CaretIndex : index);
        });
        // WPF's speller checks with Windows' dictionary alone: the words ignored here are left alone once it has checked.
        box.TextChanged += (_, _) => LeaveIgnored(box);
        box.Loaded += (_, _) => LeaveIgnored(box);
    }

    /// <summary>
    /// The words WPF underlined in <paramref name="box"/> that <see cref="SpellChecker.Ignore"/> was told to leave alone are
    /// ignored by its speller too, once it has checked the text (it checks when the application is idle).
    /// </summary>
    private static void LeaveIgnored(TextBox box) =>
        box.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            if (!SpellCheck.GetIsEnabled(box) || !Attached.TryGetValue(box, out var checker) || box.Text.Length > 50_000) return;
            var i = box.GetNextSpellingErrorCharacterIndex(0, LogicalDirection.Forward);
            for (var guard = 0; i >= 0 && i < box.Text.Length && guard < SpellChecker.MaxWords; guard++)
            {
                var start = box.GetSpellingErrorStart(i);
                var length = box.GetSpellingErrorLength(i);
                if (start < 0 || length <= 0 || start + length > box.Text.Length) break;
                if (checker.IsIgnored(box.Text.Substring(start, length))) box.GetSpellingError(start)?.IgnoreAll();
                i = box.GetNextSpellingErrorCharacterIndex(start + length, LogicalDirection.Forward);
            }
        });

    /// <summary>Spell check off in a text box (the setting was turned off while it was open).</summary>
    public static void Detach(TextBox box) => SpellCheck.SetIsEnabled(box, false);

    /// <summary>Fills a text box's menu (<see cref="Attach"/>) about the word at <paramref name="index"/>.</summary>
    public static void FillAt(TextBox box, ContextMenu menu, int index)
    {
        var error = SpellCheck.GetIsEnabled(box) ? box.GetSpellingError(index) ?? (index > 0 ? box.GetSpellingError(index - 1) : null) : null;
        if (error is null || !Attached.TryGetValue(box, out var checker))
        {
            Fill(menu, box, null, [], _ => { }, () => { }, () => { });
            return;
        }
        var at = box.GetSpellingErrorStart(index) is var s and >= 0 ? s : box.GetSpellingErrorStart(index - 1);
        var length = at >= 0 ? box.GetSpellingErrorLength(at) : 0;
        var word = at >= 0 && length > 0 && at + length <= box.Text.Length ? box.Text.Substring(at, length) : null;
        Fill(menu, box, word, [.. error.Suggestions.Take(SpellChecker.MaxSuggestions)],
            error.Correct,
            () =>
            {
                if (word is null) return;
                checker.Ignore(word);
                LeaveIgnored(box);
            },
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
                LeaveIgnored(box);
            });
    }

    private static readonly ConditionalWeakTable<Control, ContextMenu> Hooked = new();

    /// <summary>
    /// The context menu of an editor that spell checks. It is set at once: WPF's text editor puts up its own Cut, Copy and
    /// Paste menu (and says the opening was handled) when a box has none. It is filled just before it opens, from the input
    /// that opens it: a right-button press (the word under the pointer), the context menu key or Shift+F10 (the word at
    /// the caret); and on ContextMenuOpening, for any other way, when it isn't open yet. Once per editor.
    /// </summary>
    /// <param name="fill">Fills the menu; true: opened with the mouse (the word under the pointer), false: from the keyboard.</param>
    public static ContextMenu HookMenu(Control box, Action<ContextMenu, bool> fill)
    {
        if (Hooked.TryGetValue(box, out var hooked)) return hooked;
        var menu = new ContextMenu { PlacementTarget = box };
        // The menu takes the focus while it is open; the box gets it back after (the page view's editors close when it leaves).
        menu.Closed += (_, _) => box.Dispatcher.BeginInvoke(() =>
        {
            if (box.IsVisible) box.Focus();
        });
        Fill(menu, box, null, [], _ => { }, () => { }, () => { });
        box.ContextMenu = menu;
        Hooked.Add(box, menu);
        box.PreviewMouseRightButtonDown += (_, _) => fill(menu, true);
        box.PreviewKeyDown += (_, e) =>
        {
            var shiftF10 = (e.Key == Key.F10 || (e.Key == Key.System && e.SystemKey == Key.F10)) && Keyboard.Modifiers == ModifierKeys.Shift;
            if (e.Key == Key.Apps || shiftF10) fill(menu, false);
        };
        box.AddHandler(FrameworkElement.ContextMenuOpeningEvent, new ContextMenuEventHandler((_, e) =>
        {
            if (!menu.IsOpen) fill(menu, !(e.CursorLeft < 0 && e.CursorTop < 0));
        }), handledEventsToo: true);
        return menu;
    }

    /// <summary>A new menu for a word (the developer script's look at one).</summary>
    public static ContextMenu Menu(Control target, string? word, IReadOnlyList<string> suggestions, Action<string> correct, Action ignore, Action add)
    {
        var menu = new ContextMenu { PlacementTarget = target };
        Fill(menu, target, word, suggestions, correct, ignore, add);
        return menu;
    }

    /// <summary>
    /// The menu for a word: its suggestions (or "No suggestions"), Ignore and Add to dictionary when
    /// <paramref name="word"/> is misspelled, then Cut, Copy and Paste on <paramref name="target"/>.
    /// </summary>
    public static void Fill(ContextMenu menu, Control target, string? word, IReadOnlyList<string> suggestions, Action<string> correct, Action ignore, Action add)
    {
        menu.Items.Clear();
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
    }

    /// <summary>Windows didn't take the word: said, never silently dropped.</summary>
    public static void AddFailed(FrameworkElement owner, string? word) =>
        Prompt.Error(Window.GetWindow(owner), Strings.Spell_AddFailedTitle, Loc.Format(Strings.Spell_AddFailed, word ?? ""));
}
