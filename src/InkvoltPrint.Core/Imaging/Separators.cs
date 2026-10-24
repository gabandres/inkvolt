namespace InkvoltPrint.Core.Imaging;

/// <summary>What starts a new file in a batch scan (one feeder run split into several files).</summary>
public enum SplitAt { None, PatchCode, BlankPage, PatchCodeOrBlankPage }

/// <summary>How a page came to be a separator: a patch code, a blank page, or marked in the review.</summary>
public enum SeparatorKind { None, PatchCode, BlankPage, ByHand }

/// <summary>A separator sheet found on a page: what kind, and for a patch code, which.</summary>
public readonly record struct SeparatorFound(SeparatorKind Kind, PatchCode? Code = null)
{
    public static readonly SeparatorFound None = new(SeparatorKind.None);

    public bool IsSeparator => Kind != SeparatorKind.None;

    /// <summary>"Patch T sheet", "blank page", or "".</summary>
    public string Description => Kind switch
    {
        SeparatorKind.PatchCode => $"{PatchCodes.Name(Code ?? Imaging.PatchCode.PatchT)} sheet",
        SeparatorKind.BlankPage => "blank page",
        SeparatorKind.ByHand => "marked by hand",
        _ => "",
    };
}

/// <summary>Separator sheets: a page with a separating patch code (<see cref="PatchCodes"/>) or a blank page (<see cref="BlankPage"/>).</summary>
public static class Separators
{
    public static SeparatorFound Detect(GrayImage img, double pixelsPerInch, SplitAt splitAt)
    {
        if (splitAt is SplitAt.PatchCode or SplitAt.PatchCodeOrBlankPage && PatchCodes.Find(img, pixelsPerInch) is { } code && PatchCodes.Separates(code))
            return new(SeparatorKind.PatchCode, code);
        if (splitAt is SplitAt.BlankPage or SplitAt.PatchCodeOrBlankPage && BlankPage.IsBlank(img))
            return new(SeparatorKind.BlankPage);
        return SeparatorFound.None;
    }

    public static string Label(SplitAt splitAt) => splitAt switch
    {
        SplitAt.PatchCode => "Patch codes",
        SplitAt.BlankPage => "Blank pages",
        SplitAt.PatchCodeOrBlankPage => "Patch codes or blank pages",
        _ => "Don't split",
    };
}

/// <summary>A page of a batch as the split sees it.</summary>
/// <param name="Separator">A separator sheet: a new file starts after it.</param>
/// <param name="StartsFile">Marked by hand: a new file starts with this page.</param>
/// <param name="Skipped">Left out (a blank page when blank pages aren't separators).</param>
public readonly record struct BatchPage(bool Separator, bool StartsFile, bool Skipped);

/// <summary>
/// One feeder run split into files: a new file starts after each separator sheet and at each page marked by hand. Separators
/// are left out, or kept as the first page of the file they start (like a cover sheet; the ones after the last page end the
/// last file). Skipped pages are left out, and no file is made of separators alone, so separators at the start or end, or
/// several in a row (both sides of a sheet), never make an empty file.
/// </summary>
public static class BatchSplit
{
    /// <summary>The files, each as the indexes of its pages in order.</summary>
    public static List<List<int>> Parts(IReadOnlyList<BatchPage> pages, bool keepSeparators)
    {
        var parts = new List<List<int>>();
        var current = new List<int>();
        var hasContent = false;
        var pending = new List<int>(); // kept separators waiting for the next page
        for (var i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            if (page.Separator)
            {
                Close();
                if (keepSeparators) pending.Add(i);
                continue;
            }
            if (page.Skipped) continue;
            if (page.StartsFile) Close();
            current.AddRange(pending);
            pending.Clear();
            current.Add(i);
            hasContent = true;
        }
        Close();
        if (pending.Count > 0 && parts.Count > 0) parts[^1].AddRange(pending);
        return parts;

        void Close()
        {
            if (!hasContent) return;
            parts.Add(current);
            current = [];
            hasContent = false;
        }
    }

    /// <summary>For each page, the file (1-based) it is the first page of; 0 for every other page.</summary>
    public static int[] FileStarts(IReadOnlyList<BatchPage> pages, bool keepSeparators)
    {
        var starts = new int[pages.Count];
        var parts = Parts(pages, keepSeparators);
        for (var p = 0; p < parts.Count; p++) starts[parts[p][0]] = p + 1;
        return starts;
    }
}
