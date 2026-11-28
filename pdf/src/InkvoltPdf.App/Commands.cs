using System.Globalization;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace InkvoltPdf.App;

/// <summary>App commands. Gestures here are window-wide, so none are bare letters (those would eat typing in text boxes).</summary>
public static class Cmd
{
    private static RoutedUICommand Make(string text, string name, params InputGesture[] gestures) =>
        new(text, name, typeof(Cmd), new InputGestureCollection(gestures));

    private static KeyGesture K(Key key, ModifierKeys mods = ModifierKeys.None, string? display = null) =>
        display is null ? new KeyGesture(key, mods) : new KeyGesture(key, mods, display);

    /// <summary>The character a key types in the keyboard layout in use (upper case), or <paramref name="fallback"/>.</summary>
    private static string KeyText(Key key, char fallback)
    {
        var ch = MapVirtualKeyW((uint)KeyInterop.VirtualKeyFromKey(key), 2 /* MAPVK_VK_TO_CHAR */) & 0x7FFFFFFF; // the top bit marks a dead key
        return ch is > 32 and < 0xD800 ? char.ToUpper((char)ch, CultureInfo.CurrentCulture).ToString() : fallback.ToString();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint MapVirtualKeyW(uint code, uint mapType);

    /// <summary>The command's first shortcut as users see it ("Ctrl+S"), or null when it has none.</summary>
    public static string? GestureText(ICommand? command) =>
        (command as RoutedCommand)?.InputGestures.OfType<KeyGesture>().FirstOrDefault()?.GetDisplayStringForCulture(CultureInfo.CurrentCulture);

    /// <summary>"<paramref name="text"/> (Ctrl+S)": a tooltip naming the command's current shortcut, if it has one.</summary>
    public static string Tip(string text, ICommand? command) => GestureText(command) is { } g ? $"{text} ({g})" : text;

    /// <summary>The close button on a title-bar tab (in a template, so <see cref="AddShortcutsToTips"/> doesn't reach it).</summary>
    public static string CloseTabTip => Tip(Strings.Common_Close, CloseDoc);

    /// <summary>
    /// Adds each command button's shortcut to its tooltip, read from the command's gestures, so tooltips never drift from
    /// the bindings. Call once after InitializeComponent; tooltips should name the action only.
    /// </summary>
    public static void AddShortcutsToTips(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is ButtonBase { ToolTip: string tip } b && GestureText(b.Command) is { } g && !tip.EndsWith($"({g})", StringComparison.Ordinal))
                b.ToolTip = $"{tip} ({g})";
            AddShortcutsToTips(child);
        }
    }

    // File
    public static readonly RoutedUICommand Open = Make(Strings.Cmd_Open, nameof(Open), K(Key.O, ModifierKeys.Control));
    public static readonly RoutedUICommand Combine = Make(Strings.Cmd_Combine, nameof(Combine));
    public static readonly RoutedUICommand Compare = Make(Strings.Cmd_Compare, nameof(Compare));
    public static readonly RoutedUICommand Batch = Make(Strings.Cmd_Batch, nameof(Batch));
    public static readonly RoutedUICommand Save = Make(Strings.Cmd_Save, nameof(Save), K(Key.S, ModifierKeys.Control));
    public static readonly RoutedUICommand SaveAs = Make(Strings.Cmd_SaveAs, nameof(SaveAs), K(Key.S, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand CloseDoc = Make(Strings.Cmd_CloseDoc, nameof(CloseDoc), K(Key.W, ModifierKeys.Control), K(Key.F4, ModifierKeys.Control));
    public static readonly RoutedUICommand CloseAll = Make(Strings.Cmd_CloseAll, nameof(CloseAll), K(Key.W, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand Print = Make(Strings.Cmd_Print, nameof(Print), K(Key.P, ModifierKeys.Control));
    public static readonly RoutedUICommand PrintWithOptions = Make(Strings.Cmd_PrintWithOptions, nameof(PrintWithOptions), K(Key.P, ModifierKeys.Control | ModifierKeys.Alt));
    public static readonly RoutedUICommand Scan = Make(Strings.Cmd_Scan, nameof(Scan));
    public static readonly RoutedUICommand ExportImages = Make(Strings.Cmd_ExportImages, nameof(ExportImages));
    // Export to editable formats (see ExportActions)
    public static readonly RoutedUICommand ExportWord = Make(Strings.Cmd_ExportWord, nameof(ExportWord));
    public static readonly RoutedUICommand ExportExcel = Make(Strings.Cmd_ExportExcel, nameof(ExportExcel));
    public static readonly RoutedUICommand ExportText = Make(Strings.Cmd_ExportText, nameof(ExportText));
    public static readonly RoutedUICommand ExportPowerPoint = Make(Strings.Cmd_ExportPowerPoint, nameof(ExportPowerPoint));
    public static readonly RoutedUICommand ExportHtml = Make(Strings.Cmd_ExportHtml, nameof(ExportHtml));
    public static readonly RoutedUICommand Properties = Make(Strings.Cmd_Properties, nameof(Properties), K(Key.D, ModifierKeys.Control));
    public static readonly RoutedUICommand ShowInFolder = Make(Strings.Cmd_ShowInFolder, nameof(ShowInFolder));
    public static readonly RoutedUICommand Share = Make(Strings.Cmd_Share, nameof(Share));
    public static readonly RoutedUICommand CustomizeBar = Make(Strings.Cmd_CustomizeBar, nameof(CustomizeBar));
    public static readonly RoutedUICommand Exit = Make(Strings.Cmd_Exit, nameof(Exit));

    // Edit
    public static readonly RoutedUICommand Undo = Make(Strings.Cmd_Undo, nameof(Undo), K(Key.Z, ModifierKeys.Control));
    public static readonly RoutedUICommand Redo = Make(Strings.Cmd_Redo, nameof(Redo), K(Key.Y, ModifierKeys.Control), K(Key.Z, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand Copy = Make(Strings.Cmd_Copy, nameof(Copy), K(Key.C, ModifierKeys.Control));
    public static readonly RoutedUICommand SelectAll = Make(Strings.Cmd_SelectAll, nameof(SelectAll), K(Key.A, ModifierKeys.Control));
    public static readonly RoutedUICommand Find = Make(Strings.Cmd_Find, nameof(Find), K(Key.F, ModifierKeys.Control));
    public static readonly RoutedUICommand FindNext = Make(Strings.Cmd_FindNext, nameof(FindNext), K(Key.F3));
    public static readonly RoutedUICommand FindPrevious = Make(Strings.Cmd_FindPrevious, nameof(FindPrevious), K(Key.F3, ModifierKeys.Shift));
    // Find & Replace across the document (DocumentTab.Replace.cs). Ctrl+H as in Word, Acrobat and Foxit; Ctrl+Shift+H is Highlight.
    public static readonly RoutedUICommand Replace = Make(Strings.Cmd_Replace, nameof(Replace), K(Key.H, ModifierKeys.Control));
    public static readonly RoutedUICommand SearchPane = Make(Strings.Cmd_SearchPane, nameof(SearchPane), K(Key.F, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand SearchFolders = Make(Strings.Cmd_SearchFolders, nameof(SearchFolders), K(Key.F, ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Shift));
    // A question over the indexed folders or a set of PDFs, answered by the user's AI (FolderAsk; Pro)
    public static readonly RoutedUICommand AskFolders = Make(Strings.Cmd_AskFolders, nameof(AskFolders));
    public static readonly RoutedUICommand ToolHand = Make(Strings.Cmd_ToolHand, nameof(ToolHand));
    public static readonly RoutedUICommand ToolSelect = Make(Strings.Cmd_ToolSelect, nameof(ToolSelect));
    public static readonly RoutedUICommand ToolSnapshot = Make(Strings.Cmd_ToolSnapshot, nameof(ToolSnapshot));
    public static readonly RoutedUICommand CopyAreaText = Make(Strings.Cmd_CopyAreaText, nameof(CopyAreaText));
    public static readonly RoutedUICommand CopyAreaTable = Make(Strings.Cmd_CopyAreaTable, nameof(CopyAreaTable));
    public static readonly RoutedUICommand ToolAddText = Make(Strings.Cmd_ToolAddText, nameof(ToolAddText));
    public static readonly RoutedUICommand ToolCheck = Make(Strings.Cmd_ToolCheck, nameof(ToolCheck));
    public static readonly RoutedUICommand ToolCross = Make(Strings.Cmd_ToolCross, nameof(ToolCross));
    public static readonly RoutedUICommand AddSignature = Make(Strings.Cmd_AddSignature, nameof(AddSignature));

    // Pictures and links (Review menu). Their keys (I, N) are page-view keys like H and T.
    public static readonly RoutedUICommand AddImage = Make(Strings.Cmd_AddImage, nameof(AddImage));
    public static readonly RoutedUICommand AddImageFromClipboard = Make(Strings.Cmd_AddImageFromClipboard, nameof(AddImageFromClipboard));
    public static readonly RoutedUICommand ToolLink = Make(Strings.Cmd_ToolLink, nameof(ToolLink));
    public static readonly RoutedUICommand LinkSelection = Make(Strings.Cmd_LinkSelection, nameof(LinkSelection));
    public static readonly RoutedUICommand LinkAddresses = Make(Strings.Cmd_LinkAddresses, nameof(LinkAddresses));
    public static readonly RoutedUICommand HighlightAllMatches = Make(Strings.Cmd_HighlightAllMatches, nameof(HighlightAllMatches));
    public static readonly RoutedUICommand UnderlineAllMatches = Make(Strings.Cmd_UnderlineAllMatches, nameof(UnderlineAllMatches));
    public static readonly RoutedUICommand StrikeOutAllMatches = Make(Strings.Cmd_StrikeOutAllMatches, nameof(StrikeOutAllMatches));
    public static readonly RoutedUICommand AddStamp = Make(Strings.Cmd_AddStamp, nameof(AddStamp));
    public static readonly RoutedUICommand HighlightFields = Make(Strings.Cmd_HighlightFields, nameof(HighlightFields));

    // Forms: authoring (see DocumentTab.FormDesign)
    public static readonly RoutedUICommand PrepareForm = Make(Strings.Cmd_PrepareForm, nameof(PrepareForm), K(Key.F, ModifierKeys.Control | ModifierKeys.Alt));
    public static readonly RoutedUICommand DetectFields = Make(Strings.Cmd_DetectFields, nameof(DetectFields));
    // Prepare Form: several fields lined up with the first one picked, and the calculation order (roadmap 4.12)
    public static readonly RoutedUICommand AlignLeft = Make(Strings.Cmd_AlignLeft, nameof(AlignLeft));
    public static readonly RoutedUICommand AlignCenter = Make(Strings.Cmd_AlignCenter, nameof(AlignCenter));
    public static readonly RoutedUICommand AlignRight = Make(Strings.Cmd_AlignRight, nameof(AlignRight));
    public static readonly RoutedUICommand AlignTop = Make(Strings.Cmd_AlignTop, nameof(AlignTop));
    public static readonly RoutedUICommand AlignMiddle = Make(Strings.Cmd_AlignMiddle, nameof(AlignMiddle));
    public static readonly RoutedUICommand AlignBottom = Make(Strings.Cmd_AlignBottom, nameof(AlignBottom));
    public static readonly RoutedUICommand SameWidth = Make(Strings.Cmd_SameWidth, nameof(SameWidth));
    public static readonly RoutedUICommand SameHeight = Make(Strings.Cmd_SameHeight, nameof(SameHeight));
    public static readonly RoutedUICommand SameSize = Make(Strings.Cmd_SameSize, nameof(SameSize));
    public static readonly RoutedUICommand SpaceAcross = Make(Strings.Cmd_SpaceAcross, nameof(SpaceAcross));
    public static readonly RoutedUICommand SpaceDown = Make(Strings.Cmd_SpaceDown, nameof(SpaceDown));
    public static readonly RoutedUICommand CalculationOrder = Make(Strings.Cmd_CalculationOrder, nameof(CalculationOrder));

    /// <summary>Arrange Fields' commands and what each does.</summary>
    public static IReadOnlyList<(RoutedUICommand Command, FieldArrange How)> ArrangeCommands =>
    [
        (AlignLeft, FieldArrange.AlignLeft), (AlignCenter, FieldArrange.AlignCenter), (AlignRight, FieldArrange.AlignRight),
        (AlignTop, FieldArrange.AlignTop), (AlignMiddle, FieldArrange.AlignMiddle), (AlignBottom, FieldArrange.AlignBottom),
        (SameWidth, FieldArrange.SameWidth), (SameHeight, FieldArrange.SameHeight), (SameSize, FieldArrange.SameSize),
        (SpaceAcross, FieldArrange.SpaceAcross), (SpaceDown, FieldArrange.SpaceDown),
    ];

    // Edit Text & Images (see DocumentTab.EditContent)
    public static readonly RoutedUICommand EditContent = Make(Strings.Cmd_EditContent, nameof(EditContent));
    public static readonly RoutedUICommand TurnContent = Make(Strings.Cmd_TurnContent, nameof(TurnContent));

    // View
    public static readonly RoutedUICommand ZoomIn = Make(Strings.Cmd_ZoomIn, nameof(ZoomIn), K(Key.OemPlus, ModifierKeys.Control, "Ctrl+="), K(Key.Add, ModifierKeys.Control));
    public static readonly RoutedUICommand ZoomOut = Make(Strings.Cmd_ZoomOut, nameof(ZoomOut), K(Key.OemMinus, ModifierKeys.Control, "Ctrl+-"), K(Key.Subtract, ModifierKeys.Control));
    public static readonly RoutedUICommand ActualSize = Make(Strings.Cmd_ActualSize, nameof(ActualSize), K(Key.D1, ModifierKeys.Control));
    public static readonly RoutedUICommand FitPage = Make(Strings.Cmd_FitPage, nameof(FitPage), K(Key.D0, ModifierKeys.Control));
    public static readonly RoutedUICommand FitWidth = Make(Strings.Cmd_FitWidth, nameof(FitWidth), K(Key.D2, ModifierKeys.Control));
    public static readonly RoutedUICommand LayoutSingle = Make(Strings.Cmd_LayoutSingle, nameof(LayoutSingle), K(Key.D4, ModifierKeys.Control));
    public static readonly RoutedUICommand LayoutContinuous = Make(Strings.Cmd_LayoutContinuous, nameof(LayoutContinuous), K(Key.D5, ModifierKeys.Control));
    public static readonly RoutedUICommand LayoutFacing = Make(Strings.Cmd_LayoutFacing, nameof(LayoutFacing), K(Key.D6, ModifierKeys.Control));
    // Reflow (4.16): Acrobat's is Ctrl+4, which is Single Page here; Ctrl+3 sits beside the zoom keys
    public static readonly RoutedUICommand Reflow = Make(Strings.Cmd_Reflow, nameof(Reflow), K(Key.D3, ModifierKeys.Control));
    public static readonly RoutedUICommand LayoutCover = Make(Strings.Cmd_LayoutCover, nameof(LayoutCover), K(Key.D7, ModifierKeys.Control));
    // Rulers, guides, a grid and snapping (roadmap 4.19; DocumentTab.Layout.cs)
    public static readonly RoutedUICommand ShowRulers = Make(Strings.Cmd_ShowRulers, nameof(ShowRulers), K(Key.R, ModifierKeys.Control));
    public static readonly RoutedUICommand ShowGrid = Make(Strings.Cmd_ShowGrid, nameof(ShowGrid), K(Key.U, ModifierKeys.Control));
    public static readonly RoutedUICommand SnapToGuides = Make(Strings.Cmd_SnapToGuides, nameof(SnapToGuides));
    public static readonly RoutedUICommand SnapToGrid = Make(Strings.Cmd_SnapToGrid, nameof(SnapToGrid));
    public static readonly RoutedUICommand SnapToObjects = Make(Strings.Cmd_SnapToObjects, nameof(SnapToObjects));
    public static readonly RoutedUICommand GridSpacing = Make(Strings.Cmd_GridSpacing, nameof(GridSpacing));
    public static readonly RoutedUICommand RulerUnits = Make(Strings.Cmd_RulerUnits, nameof(RulerUnits));
    public static readonly RoutedUICommand ClearGuides = Make(Strings.Cmd_ClearGuides, nameof(ClearGuides));
    public static readonly RoutedUICommand RotateViewRight = Make(Strings.Cmd_RotateViewRight, nameof(RotateViewRight), K(Key.OemPlus, ModifierKeys.Control | ModifierKeys.Shift, "Ctrl+Shift++"), K(Key.Add, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand RotateViewLeft = Make(Strings.Cmd_RotateViewLeft, nameof(RotateViewLeft), K(Key.OemMinus, ModifierKeys.Control | ModifierKeys.Shift, "Ctrl+Shift+-"), K(Key.Subtract, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand NavPane = Make(Strings.Cmd_NavPane, nameof(NavPane), K(Key.F4));
    // Split view: two places of the same document (DocumentTab.Split.cs). Ctrl+F6 moves between the panes, as it moves
    // between document windows in classic Windows apps; F6 visits both panes in its cycle.
    public static readonly RoutedUICommand SplitHorizontal = Make(Strings.Cmd_SplitHorizontal, nameof(SplitHorizontal));
    public static readonly RoutedUICommand SplitVertical = Make(Strings.Cmd_SplitVertical, nameof(SplitVertical));
    public static readonly RoutedUICommand RemoveSplit = Make(Strings.Cmd_RemoveSplit, nameof(RemoveSplit));
    public static readonly RoutedUICommand SwitchPane = Make(Strings.Cmd_SwitchPane, nameof(SwitchPane), K(Key.F6, ModifierKeys.Control));
    public static readonly RoutedUICommand FullScreen = Make(Strings.Cmd_FullScreen, nameof(FullScreen), K(Key.F11), K(Key.L, ModifierKeys.Control));
    public static readonly RoutedUICommand FirstPage = Make(Strings.Cmd_FirstPage, nameof(FirstPage), K(Key.Home, ModifierKeys.Control));
    public static readonly RoutedUICommand PrevPage = Make(Strings.Cmd_PrevPage, nameof(PrevPage));
    public static readonly RoutedUICommand NextPage = Make(Strings.Cmd_NextPage, nameof(NextPage));
    public static readonly RoutedUICommand LastPage = Make(Strings.Cmd_LastPage, nameof(LastPage), K(Key.End, ModifierKeys.Control));
    public static readonly RoutedUICommand GoToPage = Make(Strings.Cmd_GoToPage, nameof(GoToPage), K(Key.G, ModifierKeys.Control), K(Key.N, ModifierKeys.Control | ModifierKeys.Shift));
    // The Mac's ⌥⌘] and ⌥⌘[ without Option: Ctrl+Alt is AltGr on Windows. The keys are the ones right of P; the menu
    // names the character they type in the keyboard layout in use (KeyText).
    public static readonly RoutedUICommand NextComment = Make(Strings.Cmd_NextComment, nameof(NextComment), K(Key.OemCloseBrackets, ModifierKeys.Control, "Ctrl+" + KeyText(Key.OemCloseBrackets, ']')));
    public static readonly RoutedUICommand PrevComment = Make(Strings.Cmd_PrevComment, nameof(PrevComment), K(Key.OemOpenBrackets, ModifierKeys.Control, "Ctrl+" + KeyText(Key.OemOpenBrackets, '[')));
    public static readonly RoutedUICommand Back = Make(Strings.Cmd_Back, nameof(Back), K(Key.Left, ModifierKeys.Alt));
    public static readonly RoutedUICommand Forward = Make(Strings.Cmd_Forward, nameof(Forward), K(Key.Right, ModifierKeys.Alt));

    // Tabs (handled before the focused control sees the keys, so the page view or a list can't take them)
    public static readonly RoutedUICommand NextTab = Make(Strings.Cmd_NextTab, nameof(NextTab),
        K(Key.Tab, ModifierKeys.Control, "Ctrl+Tab"), K(Key.PageDown, ModifierKeys.Control, "Ctrl+PgDn"));
    public static readonly RoutedUICommand PrevTab = Make(Strings.Cmd_PrevTab, nameof(PrevTab),
        K(Key.Tab, ModifierKeys.Control | ModifierKeys.Shift, "Ctrl+Shift+Tab"), K(Key.PageUp, ModifierKeys.Control, "Ctrl+PgUp"));
    public static readonly RoutedUICommand ReopenClosed = Make(Strings.Cmd_ReopenClosed, nameof(ReopenClosed), K(Key.T, ModifierKeys.Control | ModifierKeys.Shift));

    // Windows (roadmap 4.9: two documents side by side; MainWindow.Windows.cs)
    public static readonly RoutedUICommand NewWindow = Make(Strings.Cmd_NewWindow, nameof(NewWindow), K(Key.N, ModifierKeys.Control));
    public static readonly RoutedUICommand MoveToNewWindow = Make(Strings.Cmd_MoveToNewWindow, nameof(MoveToNewWindow));

    // App
    public static readonly RoutedUICommand CommandPalette = Make(Strings.Cmd_CommandPalette, nameof(CommandPalette), K(Key.K, ModifierKeys.Control), K(Key.P, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand WhatsNew = Make(Strings.Cmd_WhatsNew, nameof(WhatsNew));
    public static readonly RoutedUICommand ReportProblem = Make(Strings.Cmd_ReportProblem, nameof(ReportProblem));
    public static readonly RoutedUICommand CheckForUpdates = Make(Strings.Cmd_CheckForUpdates, nameof(CheckForUpdates));
    public static readonly RoutedUICommand InkvoltPro = Make(Strings.Cmd_InkvoltPro, nameof(InkvoltPro));
    public static readonly RoutedUICommand Settings = Make(Strings.Cmd_Settings, nameof(Settings), K(Key.OemComma, ModifierKeys.Control, "Ctrl+,"));
    public static readonly RoutedUICommand Shortcuts = Make(Strings.Cmd_Shortcuts, nameof(Shortcuts), K(Key.F1));
    public static readonly RoutedUICommand DarkPages = Make(Strings.Cmd_DarkPages, nameof(DarkPages));
    public static readonly RoutedUICommand ToggleDarkMode = Make(Strings.Cmd_ToggleDarkMode, nameof(ToggleDarkMode), K(Key.L, ModifierKeys.Control | ModifierKeys.Shift));

    // Organize
    public static readonly RoutedUICommand Organize = Make(Strings.Cmd_Organize, nameof(Organize), K(Key.O, ModifierKeys.Control | ModifierKeys.Shift));
    // Rotating pages changes the file, so it has no default shortcut: Ctrl+Shift+- / + rotate the view (as in Acrobat).
    public static readonly RoutedUICommand RotateRight = Make(Strings.Cmd_RotateRight, nameof(RotateRight));
    public static readonly RoutedUICommand RotateLeft = Make(Strings.Cmd_RotateLeft, nameof(RotateLeft));
    public static readonly RoutedUICommand RotatePages = Make(Strings.Cmd_RotatePages, nameof(RotatePages));
    public static readonly RoutedUICommand DeletePages = Make(Strings.Cmd_DeletePages, nameof(DeletePages), K(Key.D, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand DeleteSelected = Make(Strings.Cmd_DeleteSelected, nameof(DeleteSelected));
    public static readonly RoutedUICommand InsertPages = Make(Strings.Cmd_InsertPages, nameof(InsertPages), K(Key.I, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand InsertBlank = Make(Strings.Cmd_InsertBlank, nameof(InsertBlank));
    public static readonly RoutedUICommand InsertFromScanner = Make(Strings.Cmd_InsertFromScanner, nameof(InsertFromScanner));
    public static readonly RoutedUICommand ExtractPages = Make(Strings.Cmd_ExtractPages, nameof(ExtractPages), K(Key.E, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand SplitDocument = Make(Strings.Cmd_SplitDocument, nameof(SplitDocument));
    public static readonly RoutedUICommand MovePages = Make(Strings.Cmd_MovePages, nameof(MovePages), K(Key.M, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand DuplicatePages = Make(Strings.Cmd_DuplicatePages, nameof(DuplicatePages));
    public static readonly RoutedUICommand CropPages = Make(Strings.Cmd_CropPages, nameof(CropPages));
    public static readonly RoutedUICommand ReversePages = Make(Strings.Cmd_ReversePages, nameof(ReversePages));
    public static readonly RoutedUICommand InterleavePages = Make(Strings.Cmd_InterleavePages, nameof(InterleavePages));
    public static readonly RoutedUICommand ScanBacks = Make(Strings.Cmd_ScanBacks, nameof(ScanBacks));
    public static readonly RoutedUICommand RemoveBlankPages = Make(Strings.Cmd_RemoveBlankPages, nameof(RemoveBlankPages));
    public static readonly RoutedUICommand SplitAtBlankPages = Make(Strings.Cmd_SplitAtBlankPages, nameof(SplitAtBlankPages));
    public static readonly RoutedUICommand ResizePages = Make(Strings.Cmd_ResizePages, nameof(ResizePages));
    public static readonly RoutedUICommand ReplacePages = Make(Strings.Cmd_ReplacePages, nameof(ReplacePages));
    public static readonly RoutedUICommand EditPageLabels = Make(Strings.Cmd_EditPageLabels, nameof(EditPageLabels));

    // Organize: text and images written into the pages (see PageMarkActions)
    public static readonly RoutedUICommand AddHeaderFooter = Make(Strings.Cmd_AddHeaderFooter, nameof(AddHeaderFooter));
    public static readonly RoutedUICommand RemoveHeaderFooter = Make(Strings.Cmd_RemoveHeaderFooter, nameof(RemoveHeaderFooter));
    public static readonly RoutedUICommand AddWatermark = Make(Strings.Cmd_AddWatermark, nameof(AddWatermark));
    public static readonly RoutedUICommand RemoveWatermark = Make(Strings.Cmd_RemoveWatermark, nameof(RemoveWatermark));

    // Review: panes and markup (bound by MainWindow when the UI for them lands)
    public static readonly RoutedUICommand ShowComments = Make(Strings.Cmd_ShowComments, nameof(ShowComments));
    public static readonly RoutedUICommand ShowAttachments = Make(Strings.Cmd_ShowAttachments, nameof(ShowAttachments));
    public static readonly RoutedUICommand ShowLayers = Make(Strings.Cmd_ShowLayers, nameof(ShowLayers));
    public static readonly RoutedUICommand ShowSignatures = Make(Strings.Cmd_ShowSignatures, nameof(ShowSignatures));
    public static readonly RoutedUICommand Sign = Make(Strings.Cmd_Sign, nameof(Sign));
    public static readonly RoutedUICommand AddVerification = Make(Strings.Cmd_AddVerification, nameof(AddVerification));
    public static readonly RoutedUICommand CheckSignaturesOnline = Make(Strings.Cmd_CheckSignaturesOnline, nameof(CheckSignaturesOnline));
    public static readonly RoutedUICommand Highlight = Make(Strings.Cmd_Highlight, nameof(Highlight), K(Key.H, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand Underline = Make(Strings.Cmd_Underline, nameof(Underline), K(Key.U, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand StrikeOut = Make(Strings.Cmd_StrikeOut, nameof(StrikeOut), K(Key.X, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand AddNote = Make(Strings.Cmd_AddNote, nameof(AddNote), K(Key.C, ModifierKeys.Control | ModifierKeys.Shift));
    public static readonly RoutedUICommand ReplyToComment = Make(Strings.Cmd_ReplyToComment, nameof(ReplyToComment), K(Key.R, ModifierKeys.Control | ModifierKeys.Shift));
    // Proofreading marks (DocumentTab.Proofreading): a caret with the text to insert; the selection struck out with its replacement
    public static readonly RoutedUICommand InsertText = Make(Strings.Cmd_InsertText, nameof(InsertText));
    public static readonly RoutedUICommand ReplaceText = Make(Strings.Cmd_ReplaceText, nameof(ReplaceText));
    public static readonly RoutedUICommand Redact = Make(Strings.Cmd_Redact, nameof(Redact));
    // Applies the redaction marks (DocumentTab.ApplyRedactions): its icon is the bar's only red (BarColors)
    public static readonly RoutedUICommand ApplyRedactions = Make(Strings.Main_MenuApplyRedactions, nameof(ApplyRedactions));
    public static readonly RoutedUICommand RedactPatterns = Make(Strings.Cmd_RedactPatterns, nameof(RedactPatterns));
    // What to redact, proposed by the user's AI endpoint or found from their names and terms list (Pro; RedactSuggestActions)
    public static readonly RoutedUICommand SuggestRedactions = Make(Strings.Cmd_SuggestRedactions, nameof(SuggestRedactions));
    public static readonly RoutedUICommand CheckRedaction = Make(Strings.Cmd_CheckRedaction, nameof(CheckRedaction));
    public static readonly RoutedUICommand CheckAccessibility = Make(Strings.Cmd_CheckAccessibility, nameof(CheckAccessibility));
    public static readonly RoutedUICommand MakeAccessible = Make(Strings.Cmd_MakeAccessible, nameof(MakeAccessible));
    public static readonly RoutedUICommand ReadingOrder = Make(Strings.Cmd_ReadingOrder, nameof(ReadingOrder));
    public static readonly RoutedUICommand Sanitize = Make(Strings.Cmd_Sanitize, nameof(Sanitize));
    public static readonly RoutedUICommand WhatsInThisPdf = Make(Strings.Cmd_WhatsInThisPdf, nameof(WhatsInThisPdf));

    // Comments and form data in and out (see CommentFileActions, FormDataActions)
    public static readonly RoutedUICommand ExportComments = Make(Strings.Cmd_ExportComments, nameof(ExportComments));
    public static readonly RoutedUICommand ImportComments = Make(Strings.Cmd_ImportComments, nameof(ImportComments));
    public static readonly RoutedUICommand SummarizeComments = Make(Strings.Cmd_SummarizeComments, nameof(SummarizeComments));
    public static readonly RoutedUICommand ExportFormData = Make(Strings.Cmd_ExportFormData, nameof(ExportFormData));
    public static readonly RoutedUICommand ImportFormData = Make(Strings.Cmd_ImportFormData, nameof(ImportFormData));
    public static readonly RoutedUICommand FillFormsFromCsv = Make(Strings.Cmd_FillFormsFromCsv, nameof(FillFormsFromCsv));
    public static readonly RoutedUICommand ResetForm = Make(Strings.Cmd_ResetForm, nameof(ResetForm));

    // Drawing tools. Their keys (P, M, R, E, L, W, V, Z, B, C) are page-view keys like H and T, not commands: see DrawTools.KeyOf.
    public static readonly RoutedUICommand ToolPen = Make(Strings.Cmd_ToolPen, nameof(ToolPen));
    public static readonly RoutedUICommand ToolHighlighter = Make(Strings.Cmd_ToolHighlighter, nameof(ToolHighlighter));
    public static readonly RoutedUICommand ToolRectangle = Make(Strings.Cmd_ToolRectangle, nameof(ToolRectangle));
    public static readonly RoutedUICommand ToolEllipse = Make(Strings.Cmd_ToolEllipse, nameof(ToolEllipse));
    public static readonly RoutedUICommand ToolLine = Make(Strings.Cmd_ToolLine, nameof(ToolLine));
    public static readonly RoutedUICommand ToolArrow = Make(Strings.Cmd_ToolArrow, nameof(ToolArrow));
    public static readonly RoutedUICommand ToolTextBox = Make(Strings.Cmd_ToolTextBox, nameof(ToolTextBox));
    public static readonly RoutedUICommand ToolCallout = Make(Strings.Cmd_ToolCallout, nameof(ToolCallout));
    public static readonly RoutedUICommand ToolPolygon = Make(Strings.Cmd_ToolPolygon, nameof(ToolPolygon));
    public static readonly RoutedUICommand ToolPolyline = Make(Strings.Cmd_ToolPolyline, nameof(ToolPolyline));

    /// <summary>The command that picks a drawing tool.</summary>
    public static RoutedUICommand DrawTool(Viewer.ViewerTool tool) => tool switch
    {
        Viewer.ViewerTool.Pen => ToolPen,
        Viewer.ViewerTool.Highlighter => ToolHighlighter,
        Viewer.ViewerTool.Rectangle => ToolRectangle,
        Viewer.ViewerTool.Ellipse => ToolEllipse,
        Viewer.ViewerTool.Line => ToolLine,
        Viewer.ViewerTool.Arrow => ToolArrow,
        Viewer.ViewerTool.TextBox => ToolTextBox,
        Viewer.ViewerTool.Callout => ToolCallout,
        Viewer.ViewerTool.Polygon => ToolPolygon,
        Viewer.ViewerTool.PolyLine => ToolPolyline,
        _ => throw new ArgumentOutOfRangeException(nameof(tool)),
    };
    public static readonly RoutedUICommand RecognizeText = Make(Strings.Cmd_RecognizeText, nameof(RecognizeText));
    public static readonly RoutedUICommand ReviewSuspectWords = Make(Strings.Cmd_ReviewSuspectWords, nameof(ReviewSuspectWords));
    public static readonly RoutedUICommand MakeTextEditable = Make(Strings.Cmd_MakeTextEditable, nameof(MakeTextEditable));
    public static readonly RoutedUICommand ReloadFromDisk = Make(Strings.Cmd_ReloadFromDisk, nameof(ReloadFromDisk), K(Key.F5));

    // File: create, protect, reduce (see FileTools, SecurityActions)
    public static readonly RoutedUICommand MeasureDistance = Make(Strings.Cmd_MeasureDistance, nameof(MeasureDistance));
    public static readonly RoutedUICommand MeasurePerimeter = Make(Strings.Cmd_MeasurePerimeter, nameof(MeasurePerimeter));
    public static readonly RoutedUICommand MeasureArea = Make(Strings.Cmd_MeasureArea, nameof(MeasureArea));
    public static readonly RoutedUICommand MeasureScale = Make(Strings.Cmd_MeasureScale, nameof(MeasureScale));
    public static readonly RoutedUICommand MeasureCalibrate = Make(Strings.Cmd_MeasureCalibrate, nameof(MeasureCalibrate));
    public static readonly RoutedUICommand SaveAsPdfA = Make(Strings.Cmd_SaveAsPdfA, nameof(SaveAsPdfA));
    public static readonly RoutedUICommand SaveAsPdfA2a = Make(Strings.Cmd_SaveAsPdfA2a, nameof(SaveAsPdfA2a));
    public static readonly RoutedUICommand CreateFromOffice = Make(Strings.Cmd_CreateFromOffice, nameof(CreateFromOffice));
    public static readonly RoutedUICommand CreateFromWeb = Make(Strings.Cmd_CreateFromWeb, nameof(CreateFromWeb));
    public static readonly RoutedUICommand NewFromImages = Make(Strings.Cmd_NewFromImages, nameof(NewFromImages));
    public static readonly RoutedUICommand NewFromClipboard = Make(Strings.Cmd_NewFromClipboard, nameof(NewFromClipboard), K(Key.N, ModifierKeys.Control | ModifierKeys.Alt));
    public static readonly RoutedUICommand ProtectPassword = Make(Strings.Cmd_ProtectPassword, nameof(ProtectPassword));
    public static readonly RoutedUICommand RemoveProtection = Make(Strings.Cmd_RemoveProtection, nameof(RemoveProtection));
    public static readonly RoutedUICommand ReduceSize = Make(Strings.Cmd_ReduceSize, nameof(ReduceSize));
    public static readonly RoutedUICommand Flatten = Make(Strings.Cmd_Flatten, nameof(Flatten));

    // Bookmarks pane (Ctrl+B adds one for the current view, as in Acrobat)
    public static readonly RoutedUICommand AddBookmark = Make(Strings.Cmd_AddBookmark, nameof(AddBookmark), K(Key.B, ModifierKeys.Control));
    public static readonly RoutedUICommand BookmarksFromHeadings = Make(Strings.Cmd_BookmarksFromHeadings, nameof(BookmarksFromHeadings));

    // AI assistant (bring your own, off by default; see DocumentTab.Ai and AiActions)
    public static readonly RoutedUICommand AiSummarize = Make(Strings.Cmd_AiSummarize, nameof(AiSummarize));
    public static readonly RoutedUICommand AiAsk = Make(Strings.Cmd_AiAsk, nameof(AiAsk));
    public static readonly RoutedUICommand AiExplain = Make(Strings.Cmd_AiExplain, nameof(AiExplain));
    public static readonly RoutedUICommand AiTranslate = Make(Strings.Cmd_AiTranslate, nameof(AiTranslate));
    // Edit by Asking: the user's AI proposes palette commands as steps, each shown and confirmed (DocumentTab.AskEdit)
    public static readonly RoutedUICommand AskEdit = Make(Strings.Cmd_AskEdit, nameof(AskEdit));
    // A summary read aloud to a WAV or MP3 file with Read Aloud's voice (DocumentTab.AiSave)
    public static readonly RoutedUICommand AiSummaryAudio = Make(Strings.Cmd_AiSummaryAudio, nameof(AiSummaryAudio));
    // Save an AI answer (DocumentTab.AiSave): the last answer or the conversation, to Word, a PDF or a comment
    public static readonly RoutedUICommand AiSaveAnswer = Make(Strings.Cmd_AiSaveAnswer, nameof(AiSaveAnswer));
    public static readonly RoutedUICommand AiSaveConversation = Make(Strings.Cmd_AiSaveConversation, nameof(AiSaveConversation));
    public static readonly RoutedUICommand AiSettings = Make(Strings.Cmd_AiSettings, nameof(AiSettings));

    // Read Aloud (Ctrl+Shift+Y, as in Acrobat)
    public static readonly RoutedUICommand ReadAloud = Make(Strings.Cmd_ReadAloud, nameof(ReadAloud), K(Key.Y, ModifierKeys.Control | ModifierKeys.Shift));
}
