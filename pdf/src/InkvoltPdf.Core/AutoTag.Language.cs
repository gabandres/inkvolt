namespace InkvoltPdf.Core;

public static partial class AutoTag
{
    /// <summary>
    /// Tells a text's language from its most common short words (English, Spanish, French, German, Italian, Portuguese,
    /// Dutch). Only a proposal: the person confirms the document's language before it is written.
    /// </summary>
    internal static class Language
    {
        private static readonly (string Code, HashSet<string> Words)[] Lists =
        [
            ("en", ["the", "and", "of", "to", "in", "is", "that", "for", "it", "with", "as", "was", "on", "are", "be", "this", "by", "from", "or", "have", "which", "not", "at", "we", "an", "they", "you"]),
            ("es", ["el", "la", "de", "que", "y", "en", "los", "las", "del", "se", "por", "con", "una", "para", "es", "su", "al", "lo", "como", "más", "pero", "sus", "le", "ha", "este", "esta", "son"]),
            ("fr", ["le", "la", "les", "de", "des", "et", "est", "un", "une", "du", "en", "que", "qui", "dans", "pour", "pas", "sur", "au", "avec", "ce", "il", "sont", "par", "ne", "se", "nous", "vous"]),
            ("de", ["der", "die", "und", "in", "den", "von", "zu", "das", "mit", "sich", "des", "auf", "für", "ist", "im", "dem", "nicht", "ein", "eine", "als", "auch", "es", "an", "werden", "aus", "er", "sie"]),
            ("it", ["il", "di", "che", "e", "la", "per", "un", "in", "del", "della", "non", "una", "sono", "le", "si", "con", "dei", "gli", "da", "al", "è", "lo", "come", "anche", "nel", "alla", "ha"]),
            ("pt", ["de", "a", "o", "que", "e", "do", "da", "em", "um", "para", "com", "não", "uma", "os", "no", "se", "na", "por", "mais", "as", "dos", "como", "mas", "ao", "das", "à", "seu"]),
            ("nl", ["de", "het", "een", "en", "van", "in", "is", "dat", "op", "te", "zijn", "met", "voor", "niet", "aan", "er", "om", "ook", "als", "bij", "door", "naar", "worden", "wordt", "maar", "deze", "die"]),
        ];

        /// <summary>The language code, or null when there are too few words or no clear winner.</summary>
        /// <param name="strict">A passage: more words and a wider margin before saying it is in another language.</param>
        public static string? Guess(string text, bool strict = false)
        {
            var words = text.ToLowerInvariant()
                .Split([' ', '\n', '\r', '\t', ',', '.', ';', ':', '(', ')', '"', '“', '”', '¿', '?', '¡', '!'], StringSplitOptions.RemoveEmptyEntries)
                .Take(5000).ToList();
            if (words.Count < (strict ? 25 : 8)) return null;
            var scores = Lists.Select(l => (l.Code, Hits: words.Count(l.Words.Contains))).OrderByDescending(s => s.Hits).ToList();
            var (best, second) = (scores[0], scores[1]);
            if (best.Hits < words.Count * (strict ? 0.2 : 0.1)) return null;
            if (best.Hits < second.Hits * (strict ? 2.0 : 1.3)) return null;
            return best.Code;
        }
    }
}
