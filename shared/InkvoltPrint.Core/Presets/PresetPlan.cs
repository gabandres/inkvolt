using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Presets;

/// <summary>A preset matched to one scanner: the request to send, whether to run text recognition, and what had to give.</summary>
/// <param name="Notes">Plain sentences for the status line when the scanner can't do what the preset asks.</param>
public sealed record PresetPlan(ScanRequest Request, bool Ocr, IReadOnlyList<string> Notes)
{
    /// <summary>Both sides on a one-sided feeder: scan the fronts, then ask for the stack turned over (<see cref="Imaging.TurnedStack"/>).</summary>
    public bool TurnStack { get; init; }

    /// <summary>
    /// The PDF's pages in black and white: a smaller file (<see cref="ScanPresets.SavesSmallerFile"/>, scanned in grey) or a
    /// black-and-white preset's, saved at 1 bit; never a JPEG preset's or photos found on the glass.
    /// </summary>
    public bool OneBit { get; init; }

    /// <param name="feederLoaded">The scanner's feeder holds pages (eSCL AdfState); null = unknown.</param>
    /// <param name="metric">Region uses A4 rather than Letter (for presets without a page size).</param>
    /// <param name="turnsStacks">The app can scan a turned stack's backs (Inkvolt Print); without it a one-sided feeder scans one side, as noted.</param>
    public static PresetPlan For(ScanPreset preset, ScannerCapabilities caps, bool? feederLoaded, bool ocrAvailable, bool metric, bool turnsStacks = false)
    {
        var notes = new List<string>();
        var hasGlass = caps.Platen is not null;
        var hasFeeder = caps.Adf is not null;

        var useFeeder = preset.Source switch
        {
            PresetSource.Glass => !hasGlass,
            PresetSource.Feeder => hasFeeder,
            _ => hasFeeder && (feederLoaded == true || !hasGlass),
        };
        if (preset.Source == PresetSource.Glass && !hasGlass) notes.Add(CoreStrings.Preset_NoGlass);
        if (preset.Source == PresetSource.Feeder && !hasFeeder) notes.Add(CoreStrings.Preset_NoFeeder);

        var source = ScanSource.Platen;
        var turnStack = false;
        if (useFeeder)
        {
            source = preset.TwoSided && caps.AdfDuplex ? ScanSource.AdfDuplex : ScanSource.Adf;
            turnStack = preset.TwoSided && !caps.AdfDuplex && preset.TurnStack && turnsStacks;
            if (preset.TwoSided && !caps.AdfDuplex && !turnStack) notes.Add(CoreStrings.Preset_OneSideOnly);
        }

        // A smaller file is black and white at 1 bit, made from grey (a scan in color would only take longer); a black-and-white
        // scan (Inkvolt PDF's presets) is saved at 1 bit too. Neither for pictures: JPEG files, photos found on the glass.
        var smaller = ScanPresets.SavesSmallerFile(preset, source);
        var pictures = preset.FileType == PresetFileType.Jpeg || (preset.FindPhotos && source == ScanSource.Platen);
        var color = ScanChoices.Pick(ScanChoices.Colors(caps, source), preset.Color && !smaller, preset.BlackAndWhite && !smaller);
        var oneBit = smaller || (!pictures && preset.BlackAndWhite && !preset.Color);

        // The closest the source offers; between two equally close, the sharper one.
        var supported = caps.For(source)?.Resolutions ?? [];
        var dpi = supported.Count == 0 ? preset.Resolution
            : supported.OrderBy(r => Math.Abs(r - preset.Resolution)).ThenByDescending(r => r).First();

        var offered = ScanChoices.PageSizesFor(caps, source);
        var size = ScanChoices.DefaultPageSize(offered, preset.PageSize, metric);
        if (preset.PageSize is { } wanted && size.Key != wanted && ScanChoices.PageSizes.FirstOrDefault(p => p.Key == wanted) is { } missing)
            notes.Add(string.Format(CoreStrings.Preset_SizeDoesntFit, missing.Label, size.Label));

        var ocr = preset.FileType == PresetFileType.SearchablePdf && ocrAvailable;
        if (preset.FileType == PresetFileType.SearchablePdf && !ocrAvailable)
            notes.Add(CoreStrings.Preset_NoOcr);

        return new(ScanChoices.ToRequest(source, color, dpi, size), ocr, notes) { TurnStack = turnStack, OneBit = oneBit };
    }
}
