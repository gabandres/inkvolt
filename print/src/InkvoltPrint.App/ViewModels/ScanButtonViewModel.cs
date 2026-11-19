using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using InkvoltPrint.App.Presets;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The Scan tab's "Scan from the printer's button" card for one printer (roadmap 2.2): what <see cref="Core.Presets.ScanButton"/>
/// says, its switch and the preset a press runs. What it decides lives in Core; this only shows it, on the dispatcher.
/// </summary>
public sealed partial class ScanButtonViewModel : ObservableObject, IDisposable
{
    private readonly ScanPresetLibrary _presets;
    private readonly Action<string> _log;

    public ScanButtonViewModel(ScanButton button, ScanPresetLibrary presets, Action<string> log)
    {
        Button = button;
        _presets = presets;
        _log = log;
        button.Changed += OnChanged;
        presets.Changed += OnChanged;
        Refresh();
    }

    private void OnChanged() => Ui(Refresh);

    /// <summary>The printer is gone: the presets (which outlive it) no longer hold on to this, nor through it the printer.</summary>
    public void Dispose()
    {
        Button.Changed -= OnChanged;
        _presets.Changed -= OnChanged;
    }

    public ScanButton Button { get; }

    /// <summary>Known (a connection or scanner has been looked at): the card shows, also to say there's no way.</summary>
    public bool IsShown => Button.Way != ScanButtonWay.Unknown;

    /// <summary>A way exists: the switch and the preset show.</summary>
    public bool IsOffered => Button.Way is ScanButtonWay.Panel or ScanButtonWay.Driver;

    public string Text => Button.Text(Preset?.Name);

    public string SwitchText => Button.SwitchText;

    public bool IsOn
    {
        get => Button.On;
        set
        {
            if (value == Button.On) return;
            _ = SetOnAsync(value);
        }
    }

    private async Task SetOnAsync(bool on)
    {
        try
        {
            await Button.SetOnAsync(on);
        }
        catch (Exception ex) // fire and forget: never unobserved
        {
            _log($"Scan button not switched: {ex.Message}");
        }
        Refresh();
    }

    /// <summary>A preset as the box lists it. By id and name only: a preset whose counter went up after a save is the same choice.</summary>
    public sealed record PresetChoice(string Id, string Name);

    /// <summary>The presets to choose from; a new list only when a name or the order changes, so the box keeps its choice.</summary>
    public IReadOnlyList<PresetChoice> Choices { get; private set; } = [];

    /// <summary>The preset a press runs: the one chosen, or the first while none is (or it was deleted).</summary>
    public ScanPreset? Preset => (Button.Choice.PresetId is { } id ? _presets.FindById(id) : null) ?? _presets.Items.FirstOrDefault();

    /// <summary>The box's choice (<see cref="Preset"/>'s id).</summary>
    public string? PresetId
    {
        get => Preset?.Id;
        set
        {
            if (value is null || _presets.FindById(value) is null) return;
            Button.SetPreset(value);
            Refresh();
        }
    }

    private void Refresh()
    {
        var choices = _presets.Items.Select(p => new PresetChoice(p.Id, p.Name)).ToList();
        if (!choices.SequenceEqual(Choices))
        {
            Choices = choices;
            OnPropertyChanged(nameof(Choices));
        }
        OnPropertyChanged(nameof(IsShown));
        OnPropertyChanged(nameof(IsOffered));
        OnPropertyChanged(nameof(Text));
        OnPropertyChanged(nameof(SwitchText));
        OnPropertyChanged(nameof(IsOn));
        OnPropertyChanged(nameof(PresetId));
    }

    private static void Ui(Action action)
    {
        if (Application.Current?.Dispatcher is not { } ui) return;
        if (ui.CheckAccess()) action();
        else ui.InvokeAsync(action);
    }
}
