using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Windows.Ocr;

/// <summary>
/// Windows' spell checker (the Spell Checking API, spellcheck.h: the dictionaries Windows has for its languages, and the
/// user's own added words) for one language. Read only: nothing is added to or ignored in the user's dictionary.
/// </summary>
public sealed class WindowsSpelling : ISpelling
{
    private readonly ISpellChecker _checker;
    private readonly Lock _gate = new();

    private WindowsSpelling(ISpellChecker checker, string language)
    {
        _checker = checker;
        Language = language;
    }

    public string Language { get; }

    /// <summary>
    /// The spell checker for <paramref name="language"/> ("es-MX"), else one for the same language in another region
    /// ("es-ES"); null when Windows has none.
    /// </summary>
    public static WindowsSpelling? Create(string language)
    {
        try
        {
            var factory = (ISpellCheckerFactory)new SpellCheckerFactory();
            var tags = new List<string>();
            if (factory.get_SupportedLanguages() is { } e)
            {
                var one = new string[1];
                while (e.Next(1, one, IntPtr.Zero) == 0) tags.Add(one[0]);
            }
            var candidates = new List<string> { language };
            var prefix = language.Split('-')[0] + "-";
            candidates.AddRange(tags.Where(t => t.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)));
            foreach (var tag in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
                if (factory.IsSupported(tag) != 0)
                    return new WindowsSpelling(factory.CreateSpellChecker(tag), tag);
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException or ArgumentException)
        {
        }
        return null;
    }

    public bool IsKnown(string word)
    {
        if (string.IsNullOrWhiteSpace(word)) return true;
        lock (_gate)
        {
            var errors = _checker.Check(word);
            try
            {
                return errors.Next(out var error) != 0 || ReleaseFalse(error);
            }
            finally
            {
                Marshal.ReleaseComObject(errors);
            }
        }

        static bool ReleaseFalse(ISpellingError? e)
        {
            if (e is not null) Marshal.ReleaseComObject(e);
            return false;
        }
    }

    public IReadOnlyList<string> Suggest(string word)
    {
        if (string.IsNullOrWhiteSpace(word)) return [];
        lock (_gate)
        {
            var result = new List<string>();
            var e = _checker.Suggest(word);
            try
            {
                var one = new string[1];
                while (result.Count < 8 && e.Next(1, one, IntPtr.Zero) == 0) result.Add(one[0]);
            }
            finally
            {
                Marshal.ReleaseComObject(e);
            }
            return result;
        }
    }

    [ComImport, Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC")]
    private class SpellCheckerFactory;

    [ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellCheckerFactory
    {
        IEnumString get_SupportedLanguages();
        int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
        ISpellChecker CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
    }

    [ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellChecker
    {
        [return: MarshalAs(UnmanagedType.LPWStr)] string get_LanguageTag();
        IEnumSpellingError Check([MarshalAs(UnmanagedType.LPWStr)] string text);
        IEnumString Suggest([MarshalAs(UnmanagedType.LPWStr)] string word);
        // Add, Ignore, AutoCorrect and the rest follow; never called.
    }

    [ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumSpellingError
    {
        /// <summary>S_OK with an error, S_FALSE (1) when there are no more.</summary>
        [PreserveSig] int Next(out ISpellingError? value);
    }

    [ComImport, Guid("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellingError
    {
        uint get_StartIndex();
        uint get_Length();
    }
}
