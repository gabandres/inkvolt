using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Developer aid: <c>InkvoltPdf.exe file.pdf --script steps.txt</c> runs UI steps off-screen and saves window snapshots,
/// so the UI can be verified without capturing the user's screen. One step per line:
/// <c>wait ms · shot out.png · page N · zoom 150|fitwidth|fitpage · layout Continuous|Facing|… · find text ·
/// findnext · tool hand|select|snapshot|addtext|check|note|redact|pen|marker|rect|ellipse|line|arrow|textbox|callout · selectall · rotateview cw|ccw|0|90|180|270 · keys text (real key messages, Shift
/// for capitals and symbols; {tab} {enter} {sp}; sent to the open dialog if there is one) · editor · nav pages|bookmarks|search · select 1,3 · rotate 90 ·
/// delete · undo · redo · scroll dy · scrollbench [ms] [px/s]</c> (the frame rate of a scroll and its blank pages, for `tools/bench`) <c>· log text · exit</c>, plus <c>key Delete ctrl shift</c> (one WPF Key with modifiers),
/// <c>focus</c> (log the focused element) and <c>annots</c> (log the comments). Drawing: <c>drawings</c> (log them with their bounds and look) <c>·
/// selectdrawing i|none · drawsel</c> (the selection, tool and style bar) <c>· drawstyle color #RRGGBB|thinner|thicker|smaller|larger|clearer|opaque|fill|border|start|end|delete</c>; draw with <c>tool pen</c> + <c>drag</c>. Review steps: <c>selecttext p x1 y1 x2 y2 ·
/// highlight · underline · strikeout · note p x y text · editcomment i text · deletecomment i · selectcomment i ·
/// commentfilter text · pane comments|attachments|layers|signatures · redact p x y w h · redact-text · redact-search · redact-patterns [phrase] ·
/// apply-redactions [confirm] (then the redaction check runs: its report or toast) · redaction-check (Check Redaction's findings, logged) ·
/// inventory (What's in This PDF's report, logged) ·
/// a11y (Accessibility Check: the pane opens, the result logged) · a11yselect i (choose a failure: the page scrolls to it) · a11ytick id (tick a person's check) ·
/// a11yreport path (save the report) · tag title|language (Make Accessible without its window) · ro (the reading order
/// pane: opens it, logs this page's pieces) · suspects (the Suspect words pane: opens it, logs its words) · suspectsel i ·
/// suspectfix text|keep · findcount word (how often search finds it) · rosel i|pic · romove i by · ropage i by · roshow by · roalt text · rodecorative · roapply · pdfa2a (with
/// <c>savepath</c>) · attachments · attach path · extract i path · open-attachment i · remove-attachment i ·
/// layers · layer name on|off · sigs · bars · labels · gotopage label · title · open path · pane-state</c>. Signing:
/// <c>makepfx path password name · sign pfx password [box p x y w h | field name | invisible] [ts url] · addsig p x y ·
/// movesig i p x y w h · delsig i</c> (these two move any placed signature or picture). Pictures and links: <c>addimage p x y file ·
/// placed · tool link · linktarget url|#page|cancel · addlink p x y w h · links · selectlink i|none · editlink i · movelink i p x y w h · dellink i</c>.
/// Stamps: <c>addstamp p x y Approved|Rejected|…|approvedby|custom:file</c> (moved and deleted with movesig / delsig). Inkvolt suite: <c>scandialog</c> (the open Scan dialog's scanners and choices) <c>·
/// scanselect text · scanchoose glass|feeder|duplex Color|Grayscale|BlackAndWhite dpi</c> (choose the open Scan dialog's scanner and settings; "-" keeps one) <c>·
/// scanpage file.jpg [dpi]</c> (give the open Scan dialog a page, as if scanned) <c>·
/// printercheck queue[|port]</c> (printer status for a Windows queue) <c>· inkvolt</c> (is Inkvolt Print found). Create PDF: <c>convert path · webpage address|file · converters</c>. PDF/A: <c>pdfa</c> (with <c>savepath</c>). Measuring: <c>measure distance|perimeter|area|calibrate p x1 y1 … · setscale ratio [all] · measurements</c>, <c>tool measure-distance|measure-perimeter|measure-area</c>. Batch: <c>batch [paths] · batchadd · batchstep · batchout · batchoption · batchpw · batchrun · batchshot · batchstate · batchclose ·
/// presetsave name · presetload name · watch folder;preset · watchshot out.png · watchstate</c>. Inkvolt Pro: <c>prowindow [presets|watched|cli|tag|ro|pdfa2a] ·
/// pro key|remove · proenforce on|off · proshot out.png · prostate</c>. Split view: <c>split h|v|off · switchpane · splitstate</c>. AI assistant (no network): <c>aiconfig Ollama|LMStudio|url model [context] · aioff ·
/// aifake answer text|error401|refused|missing · aipane on|off · aisummarize all|range · aiask question · aiexplain · aistate ·
/// dialogfill check0=on … [expand]</c>. Store updates (no Store): <c>updatefake none|ready|mandatory|error · updatecheck [startup] · updatestate</c>. Compare: <c>compare old.pdf new.pdf ·
/// compareshot out.png · comparemode text|visual · comparenext [n] · compareselect i · comparezoom percent|fit · comparestate · comparereport</c>.
/// Prepare Form: <c>prepareform on|off · designkind text|check|radio|combo|list|signature|button|select · addfield kind p x y w h ·
/// fieldsel i|none · fieldprop name|tooltip|default|options|format|required|size|fill value · movefield i x y w h ·
/// fieldaction delete|duplicate|properties|accept|reject · detect · suggestion i · acceptall · designfields · designstate ·
/// suggestions · taborder on|off</c>. Edit Text &amp; Images: <c>editcontent on|off · contentstate · edittext p i [text]</c> (open
/// the editor on text run i, then <c>key Enter</c> commits) <c>· editpara p i [text]</c> (the editor on paragraph i, a
/// literal \n in the text a line break) <c>· paragraphs p</c> (the page's paragraphs, logged) <c>· imagesel p i|none · moveimage p i x y w h · imageaction delete|replace file</c>.
/// Mouse (page points, top-left origin): <c>mouse move|down|up|click|dbl|right p x y · drag p x1 y1 x2 y2 · tip</c> (the
/// hover tip's text) <c>· menu Header</c> (click an item of the open context menu) <c>· tabmenu</c> (the selected tab's menu) <c>· tablabels · recover</c> (offer the documents a crashed run left) <c>· mouselog</c>. Prompts and file
/// pickers: <c>prompt Button · answer Button</c> (for the prompt the next step opens) <c>· windows · dialogok Cmd …
/// answer=Button{sp}Text · savepath path|cancel</c> (the next Save As/extract picker returns it, and the comment and form data import pickers) <c>· later ms step</c>
/// (run a step while the next one is blocked in a modal) <c>· copyfile src dst</c> (another program writes a file)
/// <c>· closedialog</c> (close the topmost dialog) <c>· dialogbutton Text</c> (press its button with that text) <c>· dialogshot out.png</c> (snapshot it) <c>· theme dark|light</c> (the app's Toggle Dark Mode) <c>· highcontrast on|off|system</c> (the page view's
/// high-contrast palette) <c>· size W H</c> (resize the window) <c>· barstate</c> (the command bar: labels or icons, shown, overflow) <c>· barclick Id|More</c> (press a bar button: a group drops its menu) <c>· menushot out.png</c> (a shot with the open menus) <c>· bounds Name</c> (a named element's position and visibility) <c>· textscale 1.5|system</c> (as if Windows' Text size were set) <c>· a11yaudit</c> (every visible
/// window's controls without an accessible name or under 24 × 24, logged). Results and errors go to <c>steps.txt.log</c> (rewritten after every step). Debug builds
/// only, or any build with INKVOLTPDF_DEVSCRIPT=1.
/// </summary>
internal static class DevScript
{
    public static long Started { get; } = Environment.TickCount64;

    public static async Task RunAsync(MainWindow window, string scriptPath)
    {
        var log = new List<string>();
        try
        {
            await Task.Delay(1500);
            foreach (var raw in await File.ReadAllLinesAsync(scriptPath))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith('#')) continue;
                await Step(window, line, log);
                log.Add($"ok: {line}");
                await File.WriteAllLinesAsync(scriptPath + ".log", log.ToArray()); // so far, in case a later step hangs
                await Task.Delay(150);
            }
        }
        catch (Exception ex)
        {
            log.Add($"FAILED: {ex}");
        }
        await File.WriteAllLinesAsync(scriptPath + ".log", log.ToArray());
        Application.Current.Shutdown();
    }

    /// <summary>
    /// <c>scrollbench [ms] [px/s]</c>: waits for the document (up to 10 minutes: a huge file), then scrolls the active view
    /// down for <c>ms</c> (3,000) at <c>px/s</c> (1,500), one step per rendered frame, and logs the frame rate, the longest
    /// gap between frames, how many frames showed a visible page with no picture yet, and how many pages were still blank
    /// 200 ms after the scroll stopped (roadmap 3.6: 60 fps, no blank pages after a 200 ms pause).
    /// </summary>
    private static async Task<string> ScrollBench(MainWindow window, string arg)
    {
        var parts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var ms = parts.Length > 0 ? int.Parse(parts[0]) : 3000;
        var speed = parts.Length > 1 ? double.Parse(parts[1]) : 1500;
        var waited = System.Diagnostics.Stopwatch.StartNew();
        while ((window.ActiveTab?.ActiveView.PageCount ?? 0) == 0 && waited.ElapsedMilliseconds < 600_000) await Task.Delay(100);
        var v = window.ActiveTab?.ActiveView;
        if (v is null || v.PageCount == 0) return "scrollbench: no document";
        var opened = waited.ElapsedMilliseconds;
        await Task.Delay(500);

        int frames = 0, blankFrames = 0;
        double last = 0, maxGap = 0;
        var lastTime = TimeSpan.MinValue;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var done = new TaskCompletionSource();
        EventHandler? onFrame = null;
        onFrame = (_, e) =>
        {
            var t = ((RenderingEventArgs)e).RenderingTime;
            if (t == lastTime) return; // the same frame reported twice
            lastTime = t;
            var now = sw.Elapsed.TotalMilliseconds;
            if (frames > 0) maxGap = Math.Max(maxGap, now - last);
            v.ScrollToVerticalOffset(v.VerticalOffset + speed * (now - last) / 1000);
            last = now;
            frames++;
            if (v.DevBlankVisiblePages() > 0) blankFrames++;
            if (now >= ms)
            {
                CompositionTarget.Rendering -= onFrame;
                done.TrySetResult();
            }
        };
        CompositionTarget.Rendering += onFrame;
        if (await Task.WhenAny(done.Task, Task.Delay(ms + 5000)) != done.Task)
        {
            CompositionTarget.Rendering -= onFrame;
            return $"scrollbench: no frames in {ms + 5000} ms (the window isn't being rendered)";
        }
        await Task.Delay(200);
        var blankAfter = v.DevBlankVisiblePages();
        return $"scrollbench: {frames} frames in {last:0} ms = {frames * 1000 / Math.Max(1, last):0.0} fps; longest gap {maxGap:0} ms; " +
               $"frames with a blank page {blankFrames} of {frames}; blank pages 200 ms after the stop: {blankAfter}; page {v.CurrentPage + 1} of {v.PageCount}; document ready after {opened} ms";
    }

    private static Core.DesignFieldKind? DesignKindOf(string name) => name.ToLowerInvariant() switch
    {
        "text" => Core.DesignFieldKind.Text,
        "check" => Core.DesignFieldKind.CheckBox,
        "radio" => Core.DesignFieldKind.Radio,
        "combo" => Core.DesignFieldKind.ComboBox,
        "list" => Core.DesignFieldKind.ListBox,
        "signature" => Core.DesignFieldKind.Signature,
        "button" => Core.DesignFieldKind.Button,
        _ => null,
    };

    /// <summary>Waits for a Prepare Form edit to land and the fields to be read again.</summary>
    private static async Task DesignSettle(DocumentTab tab)
    {
        await Task.Delay(300);
        await tab.SettleAsync();
        await Task.Delay(500);
    }

    private static async Task Step(MainWindow window, string line, List<string> log)
    {
        var sp = line.IndexOf(' ');
        var cmd = sp < 0 ? line : line[..sp];
        var arg = sp < 0 ? "" : line[(sp + 1)..].Trim();
        var tab = window.ActiveTab;
        var v = tab?.PageView;
        switch (cmd.ToLowerInvariant())
        {
            case "wait": await Task.Delay(int.Parse(arg)); break;
            case "shot": Shot(window, arg); break;
            // dialogshot out.png: the topmost open dialog (use with "later" while a modal is open)
            case "dialogshot":
            {
                var dialog = Application.Current.Windows.OfType<Window>().Last(w => w != window && w.IsVisible);
                log.Add($"dialog '{dialog.Title}': {dialog.ActualWidth:0}×{dialog.ActualHeight:0} (Width {dialog.Width:0})");
                Shot(dialog, arg);
                break;
            }
            // page / zoom / scroll act on the active pane of a split view (the only pane otherwise)
            case "page": tab!.ActiveView.GoToPage(int.Parse(arg) - 1); break;
            case "zoom" when arg == "fitwidth": tab!.ActiveView.SetZoomMode(ZoomMode.FitWidth); break;
            case "zoom" when arg == "fitpage": tab!.ActiveView.SetZoomMode(ZoomMode.FitPage); break;
            case "zoom": tab!.ActiveView.SetZoom(double.Parse(arg) / 100); break;
            // Split view: split h|v|off · switchpane · splitstate
            case "split": tab!.SetSplit(arg switch { "h" => SplitMode.TopAndBottom, "v" => SplitMode.SideBySide, _ => SplitMode.None }); await Task.Delay(600); break;
            case "switchpane": tab!.SwitchPane(); break;
            case "splitstate": log.Add(tab!.DevSplitState()); break;
            case "layout": v!.SetLayout(Enum.Parse<ViewLayout>(arg, true)); break;
            case "rotateview" when arg is "cw" or "ccw": (arg == "cw" ? Cmd.RotateViewRight : Cmd.RotateViewLeft).Execute(null, window); break;
            case "rotateview": v!.SetViewRotation(int.Parse(arg)); break;
            case "tool": v!.Tool = arg switch { "select" => ViewerTool.SelectText, "snapshot" => ViewerTool.Snapshot, "addtext" => ViewerTool.AddText, "check" => ViewerTool.AddCheck, "note" => ViewerTool.AddNote, "redact" => ViewerTool.Redact,
                "pen" => ViewerTool.Pen, "marker" or "highlighter" => ViewerTool.Highlighter, "rect" or "rectangle" => ViewerTool.Rectangle, "ellipse" => ViewerTool.Ellipse,
                "line" => ViewerTool.Line, "arrow" => ViewerTool.Arrow, "textbox" => ViewerTool.TextBox, "callout" => ViewerTool.Callout, "link" => ViewerTool.AddLink, "measure-distance" => ViewerTool.MeasureDistance,
                "measure-perimeter" => ViewerTool.MeasurePerimeter, "measure-area" => ViewerTool.MeasureArea, _ => ViewerTool.Hand }; break;
            case "selectall": v!.SelectAll(); break;
            case "find": Cmd.Find.Execute(null, window); SetFindText(tab!, arg); tab!.FindNext(false); break;
            case "findnext": tab!.FindNext(false); break;
            case "nav": Nav(tab!, arg); break;
            case "select": tab!.SelectPages(arg.Split(',').Select(s => int.Parse(s) - 1)); break;
            case "rotate": await Organize.RotateSelected(tab!, int.Parse(arg)); break;
            case "delete": await Organize.DeleteSelected(tab!); break;
            case "undo": tab!.Undo(); break;
            case "redo": tab!.Redo(); break;
            case "scroll": tab!.ActiveView.ScrollToVerticalOffset(tab.ActiveView.VerticalOffset + double.Parse(arg)); break;
            case "scrollbench": log.Add(await ScrollBench(window, arg)); break;
            case "copytext": log.Add($"selected text: {v!.GetSelectedText().Length} chars: {Trunc(v.GetSelectedText())}"); break;
            case "state": log.Add($"page={v!.CurrentPage + 1}/{v.PageCount} zoom={v.Zoom:P0} mode={v.ZoomMode} layout={v.Layout} rotation={v.ViewRotation} dirty={tab!.Session.IsDirty} undo={tab.Session.UndoLabel ?? "-"} redo={tab.Session.RedoLabel ?? "-"} selected={string.Join(',', tab.SelectedPages.Select(p => p + 1))} {v.Diagnostics}"); break;
            case "log": log.Add(arg); break;
            case "cmd":
            {
                var c = (System.Windows.Input.RoutedUICommand)typeof(Cmd).GetField(arg)!.GetValue(null)!;
                log.Add($"cmd {arg}: can={c.CanExecute(null, window)}");
                c.Execute(null, window);
                break;
            }
            case "fields":
                log.Add($"fillable widgets: {v!.FillableCount}");
                for (var i = 0; i < Math.Min(v.FillableCount, int.TryParse(arg, out var nf) ? nf : 6); i++) log.Add("  " + v.DevDescribeField(i));
                break;
            case "click":
            {
                var a = arg.Split(' ');
                log.Add($"click consumed: {v!.DevClick(int.Parse(a[0]) - 1, double.Parse(a[1], System.Globalization.CultureInfo.InvariantCulture), double.Parse(a[2], System.Globalization.CultureInfo.InvariantCulture))}");
                break;
            }
            case "type": v!.DevType(arg); break;
            case "keys": await PostKeys(KeyTarget(window), arg); break;
            case "mouse": await MouseStep(window, v!, arg, log); break;
            case "drag": await Drag(window, v!, arg); break;
            case "tip": log.Add($"tip: {v!.DevTipText ?? "(none)"}"); break;
            case "mouselog":
                // mouselog: log the mouse events WPF raises from here on (to check what posted messages do).
                window.PreviewMouseMove += (_, e) => log.Add($"  [move {e.GetPosition(window):0},{e.GetPosition(window):0} on {e.OriginalSource.GetType().Name} L={e.LeftButton}]");
                window.PreviewMouseDown += (_, e) => log.Add($"  [down {e.ChangedButton} x{e.ClickCount} {e.GetPosition(window):0} on {e.OriginalSource.GetType().Name}]");
                window.PreviewMouseUp += (_, e) => log.Add($"  [up {e.ChangedButton} {e.GetPosition(window):0}]");
                window.MouseLeave += (_, _) => log.Add("  [leave]");
                break;
            case "savepath": SavePaths.Enqueue(arg == "cancel" ? null : arg); break;
            case "key": await PostKey(KeyTarget(window), arg); break;
            case "focus":
            {
                var f = System.Windows.Input.Keyboard.FocusedElement;
                log.Add($"focus: {f?.GetType().Name ?? "(none)"}{(f is FrameworkElement { Name.Length: > 0 } fe ? $" '{fe.Name}'" : "")}");
                break;
            }
            case "annots": log.Add(Annotations(tab!)); break;
            case "drawings": log.Add(Drawings(tab!)); break;
            case "drawsel": log.Add($"selected drawing: {v!.SelectedDrawing?.Id ?? "(none)"} {(v.SelectedDrawing is { } sd ? CommentItem.TitleOf(sd) : "")}; tool={v.Tool}; editing text={v.EditingText?.Tool.ToString() ?? "no"}; style bar: {tab!.DevStyleBar}"); break;
            case "selectdrawing": v!.SelectDrawing(arg == "none" ? null : tab!.DevDrawings[int.Parse(arg)].Id); break;
            case "drawstyle":
            {
                // drawstyle color #RRGGBB | thinner | thicker | smaller | larger | clearer | opaque | fill | border | start | end | delete
                var a = arg.Split(' ', 2);
                tab!.DevStyle(a[0], a.Length > 1 ? a[1] : null);
                await Task.Delay(500);
                log.Add($"style bar: {tab.DevStyleBar}");
                break;
            }
            case "selecttext":
            {
                // selecttext <page> <x1> <y1> <x2> <y2>: select the text between two page points (points, top-left origin).
                var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var n = a.Skip(1).Select(Num).ToArray();
                log.Add($"selecttext: {v!.DevSelect(int.Parse(a[0]) - 1, n[0], n[1], n[2], n[3])} '{Trunc(v.GetSelectedText())}'");
                break;
            }
            case "highlight": log.Add($"highlight: {await tab!.MarkupSelection(Core.TextMarkupKind.Highlight)}"); break;
            case "underline": log.Add($"underline: {await tab!.MarkupSelection(Core.TextMarkupKind.Underline)}"); break;
            case "strikeout": log.Add($"strikeout: {await tab!.MarkupSelection(Core.TextMarkupKind.StrikeOut)}"); break;
            case "note":
            {
                // note <page> <x> <y> <text…>
                var a = arg.Split(' ', 4);
                log.Add($"note: {await tab!.AddNoteAt(int.Parse(a[0]) - 1, Num(a[1]), Num(a[2]), a[3])}");
                break;
            }
            case "editcomment":
            {
                var a = arg.Split(' ', 2);
                log.Add($"editcomment: {await tab!.EditComment(tab.Comments.Where(c => !c.IsInkvoltPdfStamp).ElementAt(int.Parse(a[0])), a[1])}");
                break;
            }
            case "deletecomment": log.Add($"deletecomment: {await tab!.DeleteComment(tab.Comments.Where(c => !c.IsInkvoltPdfStamp).ElementAt(int.Parse(arg)))}"); break;
            case "selectcomment":
                if (tab!.FindName("CommentList") is System.Windows.Controls.ListBox cl)
                {
                    cl.SelectedIndex = -1; // a fresh pick, like a click
                    cl.SelectedIndex = int.Parse(arg);
                }
                break;
            case "commentfilter":
                if (tab!.FindName("CommentFilter") is System.Windows.Controls.TextBox cf) cf.Text = arg;
                log.Add($"comments shown: {(tab.FindName("CommentList") as System.Windows.Controls.ListBox)?.Items.Count}");
                break;
            case "pane":
                tab!.ShowReviewPane(Enum.Parse<ReviewPane>(arg, true));
                break;
            case "redact":
            {
                // redact <page> <x> <y> <w> <h>: mark an area (points, top-left origin)
                var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                tab!.MarkRedaction(int.Parse(a[0]) - 1, new Core.RectD(Num(a[1]), Num(a[2]), Num(a[3]), Num(a[4])));
                log.Add($"redaction marks: {v!.Redactions.Count}");
                break;
            }
            case "redact-text": log.Add($"redact-text: {await tab!.RedactSelection()} marks"); break;
            case "redact-search": log.Add($"redact-search: {tab!.RedactSearchHits()} marks"); break;
            case "redaction-check":
            {
                var report = await Task.Run(() => RedactionCheck.Run(tab!.Session.Data, tab.Session.Password));
                log.Add($"redaction-check: {report.Summary}");
                foreach (var f in report.Findings) log.Add($"  {f.Kind} p{f.Page + 1} {f.Where}: {f.Text} ({f.Fix})");
                break;
            }
            case "inventory":
            {
                // inventory: What's in This PDF's report, logged (the dialog itself: cmd WhatsInThisPdf with later dialogshot).
                var report = await Task.Run(() => DocumentInventory.Run(tab!.Session.Data, tab.Session.Password));
                log.Add($"inventory: {report.Summary}");
                foreach (var i in report.Items) log.Add($"  {i.Section} {(i.Page >= 0 ? $"p{i.Page + 1} " : "")}{i.What} | {i.Where}{(i.WithoutClick ? " | no click" : "")}: {Trunc(i.Detail)}");
                break;
            }
            case "a11y":
            {
                var report = await tab!.DevCheckAccessibility();
                log.Add($"a11y: {report.Summary}");
                foreach (var f in report.Failures) log.Add($"  {f.Condition} p{f.Page + 1} {f.Element}: {f.Problem}");
                break;
            }
            case "a11yselect": tab!.A11yList.SelectedIndex = int.Parse(arg); break;
            case "tag":
            {
                var parts = arg.Split('|', 2);
                if (await AccessibleActions.PlanAsync(window, tab!) is not { } tags) { log.Add("tag: no plan"); break; }
                tags = tags with { Title = parts[0].Length > 0 ? parts[0] : tags.Title ?? "Untitled", Language = parts.Length > 1 ? parts[1] : tags.Language ?? "en" };
                log.Add($"tag: {await AccessibleActions.WriteAsync(window, tab!, tags, ask: false)}, {tags.Blocks.Count} pieces, {tags.FiguresWithoutAlt} without alt text");
                break;
            }
            case "ro":
                if (window.ActiveTab is { } rt && rt.ReadingOrderPanel.Visibility != Visibility.Visible) await rt.ShowReadingOrderAsync();
                log.Add($"ro: {tab!.RoSummary.Text}");
                foreach (var item in tab.RoList.Items.OfType<ReadingOrderItem>()) log.Add($"  {item.Number} {item.Kind}: {Trunc(item.Preview)}");
                break;
            case "suspects": // the Suspect words pane: opens it, logs its words
                if (window.ActiveTab is { } st && st.SuspectPanel.Visibility != Visibility.Visible) await st.ShowSuspectWordsAsync();
                else await tab!.FillSuspectWordsAsync();
                log.Add($"suspects: {tab!.SuspectSummary.Text}");
                foreach (var w in tab.DevSuspectWords()) log.Add($"  {w}");
                break;
            case "suspectsel": tab!.DevSelectSuspect(int.Parse(arg)); break;
            case "suspectfix": await tab!.DevCorrectSuspect(arg == "keep" ? null : arg); break;
            case "findcount": // how many times the document's text has a word (what search finds)
            {
                var hits = 0;
                for (var p = 0; p < tab!.Session.Engine.PageCount; p++) hits += tab.Session.Engine.GetText(p).Find(arg, true, false).Count();
                log.Add($"findcount {arg}: {hits}");
                break;
            }
            case "rosel": // an index, or "pic": the page's first picture still without alternate text
                tab!.RoList.SelectedIndex = arg == "pic"
                    ? tab.RoList.Items.OfType<ReadingOrderItem>().ToList().FindIndex(i => i.NeedsAlt)
                    : int.Parse(arg);
                break;
            case "romove":
            {
                var a = arg.Split(' ');
                tab!.RoList.SelectedIndex = int.Parse(a[0]);
                tab.RoList.Focus();
                var by = int.Parse(a[1]);
                for (var i = 0; i < Math.Abs(by); i++) tab.RoMove(Math.Sign(by));
                break;
            }
            case "ropage": // i by: the piece read with the page before (-1) or after (1), as Alt+Page Up/Down
            {
                var a = arg.Split(' ');
                tab!.RoList.SelectedIndex = int.Parse(a[0]);
                tab.RoMoveToPage(int.Parse(a[1]));
                break;
            }
            case "roshow": tab!.RoShowPage(int.Parse(arg)); break; // -1 or 1: the page before's or after's pieces, as Page Up/Down
            case "roalt": tab!.RoAlt.Text = arg; break;
            case "rodecorative": tab!.RoDecorative.IsChecked = !(tab.RoDecorative.IsChecked == true); tab.RoDecorative.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)); break;
            case "roapply": tab!.RoApply.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)); await Task.Delay(50); while (tab.IsBusy) await Task.Delay(50); break;
            case "a11ytick":
                foreach (var item in tab!.A11yChecklist.Items.OfType<A11yCheckItem>()) if (item.Question.StartsWith(arg, StringComparison.OrdinalIgnoreCase)) item.Done = true;
                tab.A11yChecklist.Items.Refresh();
                break;
            case "a11yreport":
                if (tab!.AccessibilityReport is { } a11y) File.WriteAllText(arg, AccessibilityReportHtml.Write(a11y, tab.Session.DisplayName, DateTime.Now));
                log.Add($"a11yreport: {File.Exists(arg)}");
                break;
            case "redact-patterns": log.Add($"redact-patterns: {(await tab!.MarkPatternMatches(new RedactionPatternOptions { Phrases = arg.Length > 0 ? [arg] : [] }))?.Count ?? -1} matches"); break;
            case "apply-redactions": log.Add($"apply-redactions: {await tab!.ApplyRedactions(confirm: arg == "confirm")}"); break;
            case "attachments":
                log.Add($"attachments: {tab!.AttachedFiles.Count}");
                foreach (var f in tab.AttachedFiles) log.Add($"  {f.FileName} {f.Size} bytes {f.Source} p{f.PageIndex + 1} '{f.Description}'");
                break;
            case "attach": log.Add($"attach: {await tab!.AddAttachment(arg, "Added by the dev script")}"); break;
            case "extract":
            {
                var a = arg.Split(' ', 2);
                await tab!.SaveAttachment(Attachment(tab, a[0]), a[1]);
                log.Add($"extract: {new FileInfo(a[1]).Length} bytes");
                break;
            }
            case "open-attachment":
                await tab!.OpenAttachment(Attachment(tab, arg));
                log.Add($"tabs: {window.TabCount}, active: {window.ActiveTab?.DisplayTitle}");
                break;
            case "remove-attachment": log.Add($"remove-attachment: {await tab!.RemoveAttachment(Attachment(tab, arg))}"); break;
            case "layers":
                log.Add($"layers: {tab!.LayerList.Count}, override={tab.HasLayerOverride}");
                foreach (var l in tab.LayerList) log.Add($"  {l.Id} {l.Name} default={l.DefaultVisible} locked={l.Locked}");
                break;
            case "layer":
            {
                // layer <name> on|off
                var at = arg.LastIndexOf(' ');
                tab!.SetLayerVisible(arg[..at], arg[(at + 1)..] == "on");
                await Task.Delay(800);
                log.Add($"layer: override={tab.HasLayerOverride}");
                break;
            }
            case "sigs":
                log.Add($"signatures: {tab!.SignatureResults.Count}, bar: {BarText(tab, "SigBar", "SigBarText")}");
                foreach (var s in tab.SignatureResults) log.Add($"  {s.FieldName}: {s.Status} signer={s.SignerName} trusted={s.CertificateTrusted} brokenByEdits={tab.BrokenByEdits(s)}: {DocumentTab.SignatureSummary(s, tab.BrokenByEdits(s))}");
                break;
            case "makepfx":
            {
                // makepfx <path> <password> <name>: a self-signed personal ID as a file (never touches the certificate store).
                var a = arg.Split(' ', 3);
                await File.WriteAllBytesAsync(a[0], Core.DigitalIds.CreatePersonalPfx(a[2], null, null, a[1]));
                break;
            }
            case "sign":
            {
                // sign <pfx> <password> [box p x y w h | field name | invisible] [ts url]: Sign Digitally with a file ID
                // (the dialog's choices given here); queue the Save As path with "savepath" first.
                var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var cert = Core.DigitalIds.LoadPfx(await File.ReadAllBytesAsync(a[0]), a[1]);
                string? field = null;
                Viewer.SignaturePlacement? box = null;
                var visible = true;
                var ts = Array.IndexOf(a, "ts");
                if (a.Length > 2 && a[2] == "box") box = new Viewer.SignaturePlacement(int.Parse(a[3]) - 1, new Core.RectD(Num(a[4]), Num(a[5]), Num(a[6]), Num(a[7])));
                else if (a.Length > 2 && a[2] == "field") field = a[3];
                else visible = false;
                var choice = new SignChoice(cert, "I approve this document", "Dev script", visible, new Core.SignatureLook(), ts > 0, ts > 0 ? a[ts + 1] : "", Core.CertificationLevel.None);
                await window.SignDigitallyAsync(tab!, field, choice, box);
                log.Add($"signed: dirty={tab!.Session.IsDirty} file={tab.Session.DisplayName}");
                break;
            }
            case "addsig":
            {
                // addsig p x y: draw a handwritten signature (saved in the data folder) and place it centered there.
                var a = arg.Split(' ');
                var dlg = new SignatureCaptureDialog(window, false, "Dev");
                dlg.Loaded += (_, _) => dlg.DevDrawAndAccept();
                dlg.ShowDialog();
                var saved = SignatureLibrary.Save(dlg.Result!, false) ?? SignatureLibrary.List().First(s => !s.Initials);
                tab!.BeginPlaceSignature(saved);
                v!.DevPlaceSignature(int.Parse(a[0]) - 1, Num(a[1]), Num(a[2]));
                await Task.Delay(800);
                log.Add($"signature stamps: {string.Join("; ", tab.DevSignatureStamps.Select(s => $"p{s.PageIndex + 1} {s.Rect.X:0},{s.Rect.Y:0} {s.Rect.Width:0}x{s.Rect.Height:0}"))}");
                break;
            }
            case "movesig" or "delsig":
            {
                // movesig i p x y w h · delsig i
                var a = arg.Split(' ');
                var s = tab!.DevSignatureStamps[int.Parse(a[0])];
                v!.DevChangeSignature(s.Id, cmd == "delsig" ? s.PageIndex : int.Parse(a[1]) - 1, cmd == "delsig" ? null : new Core.RectD(Num(a[2]), Num(a[3]), Num(a[4]), Num(a[5])));
                await Task.Delay(800);
                log.Add($"signature stamps: {string.Join("; ", tab.DevSignatureStamps.Select(x => $"p{x.PageIndex + 1} {x.Rect.X:0},{x.Rect.Y:0} {x.Rect.Width:0}x{x.Rect.Height:0}"))}");
                break;
            }
            case "addimage":
            {
                // addimage p x y file: pick a picture (as the Image tool's file dialog would) and click it onto the page there.
                var a = arg.Split(' ', 4);
                log.Add($"addimage armed: {await tab!.BeginAddImage(a[3])}");
                v!.DevPlaceSignature(int.Parse(a[0]) - 1, Num(a[1]), Num(a[2]));
                await Task.Delay(800);
                log.Add(Placed(tab));
                break;
            }
            case "placed": log.Add(Placed(tab!)); break;
            case "addstamp":
            {
                // addstamp p x y name|approvedby|custom:file: arm a stamp (built-in by label, "Approved by", or a new custom
                // stamp made from an image file, saved in the data folder) and click it onto the page there.
                var a = arg.Split(' ', 4);
                if (a[3] == "approvedby") tab!.BeginPlaceStamp(DocumentTab.ApprovedByNow());
                else if (a[3].StartsWith("custom:", StringComparison.Ordinal)) window.AddCustomStamp(tab!, a[3][7..], Path.GetFileNameWithoutExtension(a[3][7..]));
                else tab!.BeginPlaceStamp(Core.RubberStamps.BuiltIn.First(d => d.Label.Equals(a[3], StringComparison.OrdinalIgnoreCase)));
                log.Add($"stamp armed: {tab!.DevPendingStamp}, tool {v!.Tool}");
                v.DevPlaceSignature(int.Parse(a[0]) - 1, Num(a[1]), Num(a[2]));
                await Task.Delay(800);
                log.Add(Placed(tab));
                break;
            }
            case "linktarget":
                // linktarget url | #N | cancel: the answer the next Add/Edit Link dialog gives (#N: page N).
                LinkTargets.Enqueue(arg == "cancel" ? null : arg.StartsWith('#') ? (null, int.Parse(arg[1..]) - 1) : (Core.Links.Normalize(arg), -1));
                break;
            case "addlink":
            {
                // addlink p x y w h: draw a link box with the Link tool (queue its target with "linktarget" first).
                var a = arg.Split(' ');
                v!.DevDrawLink(int.Parse(a[0]) - 1, new Core.RectD(Num(a[1]), Num(a[2]), Num(a[3]), Num(a[4])));
                await Task.Delay(800);
                log.Add(LinkList(tab!));
                break;
            }
            case "links": log.Add(LinkList(tab!)); break;
            case "selectlink": v!.DevSelectLink(arg == "none" ? null : tab!.DevLinks[int.Parse(arg)].Id); break;
            case "editlink": log.Add($"editlink: {await tab!.EditLink(tab.DevLinks[int.Parse(arg)])}"); break;
            case "movelink" or "dellink":
            {
                // movelink i p x y w h · dellink i
                var a = arg.Split(' ');
                var l = tab!.DevLinks[int.Parse(a[0])];
                v!.DevChangeLink(l.Id, cmd == "dellink" ? l.PageIndex : int.Parse(a[1]) - 1, cmd == "dellink" ? null : new Core.RectD(Num(a[2]), Num(a[3]), Num(a[4]), Num(a[5])));
                await Task.Delay(800);
                log.Add(LinkList(tab));
                break;
            }
            // Prepare Form (DocumentTab.FormDesign.cs)
            case "prepareform": log.Add($"prepareform: {await tab!.SetFormDesign(arg != "off")}"); await Task.Delay(600); break;
            case "designkind": v!.DesignKind = DesignKindOf(arg); break;
            case "addfield":
            {
                // addfield text|check|radio|combo|list|signature|button p x y w h: draw a field with a field tool
                var a = arg.Split(' ');
                v!.DevDrawField(DesignKindOf(a[0]) ?? Core.DesignFieldKind.Text, int.Parse(a[1]) - 1, new Core.RectD(Num(a[2]), Num(a[3]), Num(a[4]), Num(a[5])));
                await DesignSettle(tab!);
                log.Add($"fields: {tab!.DevDesignFields()}");
                break;
            }
            case "fieldsel": v!.SelectDesignField(arg == "none" ? null : v.DesignFields[int.Parse(arg)].Id, reveal: true); break;
            case "fieldprop":
            {
                // fieldprop name|tooltip|default|options|format|required|size|fill value
                var a = arg.Split(' ', 2);
                tab!.DevSetProperty(a[0], a.Length > 1 ? a[1] : "");
                await DesignSettle(tab);
                log.Add($"design: {tab.DevDesignState()}");
                break;
            }
            case "movefield":
            {
                // movefield i x y w h
                var a = arg.Split(' ');
                v!.DevMoveField(v.DesignFields[int.Parse(a[0])].Id, new Core.RectD(Num(a[1]), Num(a[2]), Num(a[3]), Num(a[4])));
                await DesignSettle(tab!);
                log.Add($"fields: {tab!.DevDesignFields()}");
                break;
            }
            case "fieldaction":
                v!.DevDesignAction(Enum.Parse<DesignAction>(arg, true));
                await DesignSettle(tab!);
                log.Add($"design: {tab!.DevDesignState()}");
                break;
            case "detect": await tab!.DevDetect(); log.Add($"suggestions: {tab.DevSuggestions()}"); break;
            case "suggestion": v!.SelectSuggestion(int.Parse(arg), reveal: true); break;
            case "acceptall": await tab!.DevAcceptAll(); await DesignSettle(tab); log.Add($"fields: {tab.DevDesignFields()}"); break;
            case "designfields": log.Add($"fields: {tab!.DevDesignFields()}"); break;
            case "designstate": log.Add($"design: {tab!.DevDesignState()}"); break;
            case "suggestions": log.Add($"suggestions: {tab!.DevSuggestions()}"); break;
            case "taborder": v!.ShowTabOrder = arg != "off"; break;
            case "editcontent": tab!.SetEditContent(arg != "off"); await Task.Delay(800); log.Add($"content: {tab.DevContentState()}"); break;
            case "contentstate": log.Add($"content: {tab!.DevContentState()}"); break;
            case "edittext":
            {
                // edittext p i [text]: open the editor on run i of page p (and type text); commit with "key Enter"
                var a = arg.Split(' ', 3);
                var run = v!.DevContent(int.Parse(a[0]) - 1)!.Runs[int.Parse(a[1])];
                v.DevEditRun(run, a.Length > 2 ? a[2] : null);
                await Task.Delay(300);
                log.Add($"content: {tab!.DevContentState()}");
                break;
            }
            case "editpara":
            {
                // editpara p i [text]: open the paragraph editor on paragraph i of page p (and type text); commit with "key Enter"
                var a = arg.Split(' ', 3);
                var para = v!.DevContent(int.Parse(a[0]) - 1)!.Paragraphs[int.Parse(a[1])];
                v.DevEditParagraph(para, a.Length > 2 ? a[2] : null);
                await Task.Delay(300);
                log.Add($"content: {tab!.DevContentState()}");
                break;
            }
            case "parastyle":
            {
                // parastyle start length bold|italic|plain|size N|color RRGGBB|font Name: a look for text of the open paragraph editor
                var a = arg.Split(' ', 4);
                var value = a.Length > 3 ? a[3] : "";
                TextLook look = a[2] switch
                {
                    "bold" => new TextLook(Bold: true),
                    "italic" => new TextLook(Italic: true),
                    "size" => new TextLook(Size: double.Parse(value, System.Globalization.CultureInfo.InvariantCulture)),
                    "color" => new TextLook(Color: Convert.ToInt32(value, 16)),
                    "font" => new TextLook(Font: value),
                    _ => TextLook.Plain,
                };
                v!.DevStyleParagraph(int.Parse(a[0]), int.Parse(a[1]), look);
                await Task.Delay(200);
                log.Add($"looks: {v.DevParagraphLooks()} | {tab!.DevContentState()}");
                break;
            }
            case "paragraphs":
            {
                var c = v!.DevContent(int.Parse(arg) - 1);
                foreach (var (p, i) in (c?.Paragraphs ?? []).Select((p, i) => (p, i)))
                    log.Add($"paragraph {i}: {p.Lines.Count} lines {p.Align} step {p.LineStep:0.#} box {p.Box.X:0},{p.Box.Y:0} {p.Box.Width:0}x{p.Box.Height:0}" +
                            $"{(p.Blocked is null ? "" : $" blocked ({p.Blocked})")} '{(p.Text.Length > 60 ? p.Text[..60] + "…" : p.Text)}'");
                break;
            }
            case "imagesel":
            {
                // imagesel p i|none
                var a = arg.Split(' ');
                var page = int.Parse(a[0]) - 1;
                v!.SelectImage(page, a[1] == "none" ? null : v.DevContent(page)!.Images[int.Parse(a[1])].Box);
                log.Add($"content: {tab!.DevContentState()}");
                break;
            }
            case "moveimage":
            {
                // moveimage p i x y w h
                var a = arg.Split(' ');
                var page = int.Parse(a[0]) - 1;
                v!.DevMoveImage(v.DevContent(page)!.Images[int.Parse(a[1])], new Core.RectD(Num(a[2]), Num(a[3]), Num(a[4]), Num(a[5])));
                await DesignSettle(tab!);
                await Task.Delay(500);
                log.Add($"content: {tab!.DevContentState()}");
                break;
            }
            case "imageaction":
                // imageaction delete | imageaction replace file
                if (arg.StartsWith("replace ", StringComparison.Ordinal)) await tab!.DevReplaceImage(arg[8..]);
                else v!.DevContentAction(ContentAction.Delete);
                await DesignSettle(tab!);
                await Task.Delay(500);
                log.Add($"content: {tab!.DevContentState()}");
                break;
            case "bars":
                foreach (var bar in new[] { "DiskBar", "FormBar", "XfaBar", "SigBar", "RedactBar" })
                    if (tab!.FindName(bar) is FrameworkElement { Visibility: Visibility.Visible }) log.Add($"bar {bar} visible");
                log.Add($"redact bar: {BarText(tab!, "RedactBar", "RedactBarText")}");
                break;
            case "labels":
                log.Add($"labels: {string.Join(' ', Enumerable.Range(0, v!.PageCount).Take(12).Select(tab!.PageLabel))}; pill: " +
                        $"'{(tab.FindName("PageBox") as System.Windows.Controls.TextBox)?.Text}' '{(tab.FindName("PageCountText") as System.Windows.Controls.TextBlock)?.Text}'");
                break;
            case "gotopage":
                // gotopage <label or number>: what typing it into the page box does
                log.Add($"gotopage {arg}: page index {tab!.FindPage(arg)?.ToString() ?? "none"}");
                if (tab.FindPage(arg) is { } gp) v!.GoToPage(gp);
                break;
            case "title": log.Add($"title: tab '{tab!.DisplayTitle}', window '{window.Title}'"); break;
            case "open": await window.OpenFileAsync(arg); log.Add($"tabs: {window.TabCount}"); break;
            case "pane-state": log.Add($"pane: {tab!.CurrentPane} layout={v!.Layout} zoom={v.ZoomMode} page={v.CurrentPage + 1}"); break;
            case "throw":
                // throw N: N identical unhandled UI-thread exceptions (checks the error dialog's rate limiting).
                for (var i = 0; i < int.Parse(arg); i++)
                    _ = window.Dispatcher.BeginInvoke(new Action(() => throw new InvalidOperationException("Dev script test exception")));
                break;
            case "prompt": log.Add(ClickButton(window, arg) ?? $"prompt: no window with a '{arg}' button"); break;
            case "shotwin":
                // shotwin out.png: snapshot of the topmost open dialog.
                Shot(Application.Current.Windows.OfType<Window>().Last(w => w != window && w.IsVisible), arg);
                break;
            case "dialogbutton":
            {
                // dialogbutton Text: press the topmost dialog's button whose text is Text ({sp} for spaces; use with "later").
                var text = arg.Replace("{sp}", " ");
                var top = Application.Current.Windows.OfType<Window>().LastOrDefault(w => w != window && w.IsVisible);
                var button = top is null ? null : Descendants<System.Windows.Controls.Button>(top).FirstOrDefault(b => b.Content as string == text);
                log.Add($"dialogbutton {text}: {(button is null ? "not found" : "pressed")}");
                button?.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
                break;
            }
            case "closedialog":
                // closedialog: close the topmost open dialog, as its Cancel button would (use with "later").
                Application.Current.Windows.OfType<Window>().LastOrDefault(w => w != window && w.IsVisible)?.Close();
                break;
            case "scandialog":
                // scandialog: the open Scan dialog's scanners and choices (use with "later" while Cmd Scan is open).
                log.Add(Application.Current.Windows.OfType<ScanDialog>().FirstOrDefault()?.DevDescribe() ?? "scandialog: none open");
                break;
            case "scanselect":
                // scanselect text: choose the open Scan dialog's first scanner whose label has text ({sp} for spaces; use with "later").
                log.Add($"scanselect: {Application.Current.Windows.OfType<ScanDialog>().First().DevSelect(arg.Replace("{sp}", " "))}");
                break;
            case "scanchoose":
            {
                // scanchoose glass|feeder|duplex|- Color|Grayscale|BlackAndWhite|- dpi|-: the open Scan dialog's choices (use with "later").
                var a = arg.Split(' ');
                Application.Current.Windows.OfType<ScanDialog>().First().DevChoose(a[0], a[1], a[2]);
                break;
            }
            case "scanpage":
            {
                // scanpage <file.jpg> [dpi]: hand the open Scan dialog a page as if scanned (then press its finish button).
                var a = arg.Split(' ');
                var dlg = Application.Current.Windows.OfType<ScanDialog>().First();
                await dlg.DevAddPageAsync(await File.ReadAllBytesAsync(a[0]), a.Length > 1 ? int.Parse(a[1]) : 150);
                log.Add($"scanpage: {dlg.DevDescribe()}");
                break;
            }
            case "printercheck":
            {
                // printercheck <queue name>[|port]: the Inkvolt printer-status check for a Windows queue (read-only probe).
                var q = arg.Split('|', 2);
                var r = await PrinterCheck.CheckAsync(new InkvoltPrint.Core.Suite.QueueInfo(q[0], q.Length > 1 ? q[1] : null));
                log.Add(r is null ? $"printercheck '{q[0]}': no Inkvolt Print printer" : $"printercheck '{q[0]}': {r.Printer.Name} ({r.Printer.Host}) {r.Health.State} warn={r.Health.ShouldWarn} '{r.Health.Summary}' supplies=[{string.Join("; ", r.Health.Supplies)}]");
                break;
            }
            case "inkvolt":
                log.Add($"inkvolt: InkvoltPrint={(Inkvolt.InkvoltPrintPath is { } pd ? Log.Name(pd) : "not installed")} menu={window.InkvoltPrintMenu.Visibility}");
                break;
            case "windows":
                // windows: the open secondary windows (prompts, dialogs, menus), with their heading and buttons.
                foreach (var w in Application.Current.Windows.OfType<Window>().Where(w => w != window))
                    log.Add($"window '{w.Title}' visible={w.IsVisible}: '{Trunc(string.Join(" | ", Descendants<System.Windows.Controls.TextBlock>(w).Where(t => t.Text.Length > 2 && t.TemplatedParent is null).Select(t => t.Text)))}' " +
                            $"[{string.Join(", ", Descendants<System.Windows.Controls.Button>(w).Select(b => b.Content as string).Where(s => s is not null))}]");
                log.Add($"busy={tab?.IsBusy} pending={tab?.HasPendingEdits}");
                break;
            case "answer":
            {
                // answer <button>: the next step may open a modal prompt; click <button> in it once it shows (up to ~6 s).
                var tries = 0;
                var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
                var button = arg;
                timer.Tick += (_, _) =>
                {
                    if (ClickButton(window, button) is { } clicked) log.Add($"answer: {clicked}");
                    else if (++tries < 20) return;
                    else log.Add($"answer: no prompt with a '{button}' button appeared");
                    timer.Stop();
                };
                timer.Start();
                break;
            }
            case "dialogok":
            {
                // dialogok <CommandName> [combo<N>=<index>] [text<N>=<value>] [check<N>=on|off] [answer=<button>]:
                // open a command's FormDialog, set its Nth combo/text/check box, press OK, then (optionally) press
                // <button> in the prompts that follow. Logs the dialog's validation error if it stays open.
                var parts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var command = (System.Windows.Input.RoutedUICommand)typeof(Cmd).GetField(parts[0])!.GetValue(null)!;
                var settings = parts.Skip(1).Select(p => p.Split('=', 2)).ToList();
                var answer = settings.FirstOrDefault(s => s[0] == "answer")?[1].Replace("{sp}", " ");
                var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
                var stage = 0;
                timer.Tick += (_, _) =>
                {
                    if (stage++ == 0)
                    {
                        if (Application.Current.Windows.OfType<FormDialog>().FirstOrDefault(w => w.IsVisible) is not { } dlg)
                        {
                            timer.Stop();
                            log.Add($"dialogok {parts[0]}: no dialog appeared");
                            return;
                        }
                        FillDialog(dlg, settings);
                        var ok = Descendants<System.Windows.Controls.Button>(dlg).First(b => b.IsDefault);
                        ok.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
                        if (dlg.IsVisible)
                        {
                            var error = Descendants<System.Windows.Controls.TextBlock>(dlg).Where(t => t.IsVisible).Select(t => t.Text).LastOrDefault();
                            log.Add($"dialogok {parts[0]}: stayed open: {error}");
                            dlg.Close();
                            timer.Stop();
                        }
                        return;
                    }
                    if (answer is null || stage > 8)
                    {
                        timer.Stop();
                        return;
                    }
                    if (ClickButton(window, answer) is { } clicked) log.Add($"dialogok {parts[0]}: {clicked}");
                };
                timer.Start();
                command.Execute(null, window);
                await Task.Delay(answer is null ? 1200 : 3000);
                timer.Stop();
                break;
            }
            case "editor": log.Add($"editor: {v!.DevEditorText ?? "(closed)"}"); break;
            case "commit": v!.CommitEditor(); break;
            case "save":
                tab!.Session.SaveAs(arg);
                log.Add($"saved {new FileInfo(arg).Length} bytes");
                break;
            case "screen": await ScreenShot(window, arg); break;
            case "organize": tab!.SetOrganizing(arg != "off"); break;
            case "theme":
                // theme dark|light: the app's own Toggle Dark Mode command (saves the choice, re-themes every window).
                if ((arg == "dark") != App.IsDark) Cmd.ToggleDarkMode.Execute(null, window);
                log.Add($"theme: dark={App.IsDark} mode={Application.Current.ThemeMode.Value}");
                break;
            case "menu": log.Add(ClickMenuItem(arg)); break;
            case "tabmenu": window.OpenTabMenu(window.ActiveTabModel!, atMouse: false); break;
            case "tablabels": log.Add($"tabs: {string.Join(" | ", window.TabLabelsShown)}"); break;
            case "toolcard":
            {
                // toolcard Title[|file.pdf]: click a start-page Tools card; with a file, as if picked in its Open dialog.
                var parts = arg.Split('|', 2);
                if (window.ToolGrid.Children.OfType<System.Windows.Controls.Button>().FirstOrDefault(b => b.Content is StartTool t && t.Title == parts[0]) is not { } card)
                {
                    log.Add($"toolcard {parts[0]}: not found");
                    break;
                }
                if (parts.Length == 2 && card.Tag is System.Windows.Input.RoutedCommand command) await window.RunOnFileAsync(parts[1], command, parts[0]);
                else card.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent, card));
                var t2 = window.ActiveTab;
                log.Add($"toolcard {parts[0]}: tabs={window.TabCount} organizing={t2?.IsOrganizing} editing={t2?.IsEditingContent} tool={t2?.ActiveView.Tool}");
                break;
            }
            case "recover":
                // recover: what a normal start does first: offer the documents a run left unsaved (answer the prompt with "answer").
                await window.OfferRecoveryAsync();
                log.Add($"tabs: {string.Join(" | ", window.TabLabelsShown)}; dirty: {string.Join(",", window.OpenTabs.Select(t => t.Session.IsDirty))}");
                break;
            case "highcontrast":
                // highcontrast on|off|system: the page view's high-contrast palette without changing Windows' setting.
                PageViewer.DevForceHighContrast = arg switch { "on" => true, "off" => false, _ => null };
                v!.DevApplyContrast();
                break;
            case "copyfile":
            {
                // copyfile <src> <dst>: another program writes a file (e.g. the open document changing on disk).
                var a = arg.Split(' ', 2);
                File.Copy(a[0], a[1], overwrite: true);
                break;
            }
            case "darkpages": Cmd.DarkPages.Execute(null, window); break;
            case "barclick":
            {
                // barclick Id|More: press a command bar button by its CommandBarLayout id (a group drops its menu).
                var bar = (ToolbarPanel)window.FindName("DocCommands");
                var button = bar.Children.OfType<System.Windows.Controls.Primitives.ButtonBase>()
                    .First(b => arg == "More" ? ToolbarPanel.GetIsOverflowButton(b) : b.Tag as string == arg);
                button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent, button));
                break;
            }
            case "menushot": Shot(window, arg, withMenus: true); break;
            case "barstate":
            {
                // barstate: the command bar as shown (labels or icons only), and what is in its "…" overflow.
                if (window.FindName("DocCommands") is ToolbarPanel bar)
                {
                    static string Name(UIElement e) => e is FrameworkElement { Tag: string id } ? id : System.Windows.Automation.AutomationProperties.GetName(e);
                    var shown = bar.Children.OfType<System.Windows.Controls.Primitives.ButtonBase>()
                        .Where(b => b.IsVisible && !ToolbarPanel.GetIsOverflowButton(b)).Select(Name);
                    var over = bar.OverflowItems.OfType<System.Windows.Controls.Primitives.ButtonBase>().Select(Name);
                    log.Add($"bar {window.ActualWidth:0}: {(bar.IsCompact ? "icons only" : "labels")}; shown {string.Join(" ", shown)}; overflow {string.Join(" ", over)}");
                }
                break;
            }
            case "bounds":
            {
                // bounds Name: where a named element of the window is, and whether it shows.
                if (window.FindName(arg) is FrameworkElement fe)
                {
                    var at = fe.IsVisible ? fe.TranslatePoint(new Point(0, 0), window) : default;
                    log.Add($"bounds {arg}: {at.X:0},{at.Y:0} {fe.ActualWidth:0}x{fe.ActualHeight:0} visibility={fe.Visibility} visible={fe.IsVisible}");
                }
                else log.Add($"bounds {arg}: not found");
                break;
            }
            case "size":
            {
                // size W H: resize the window (DIPs), e.g. to see the command bar overflow on a narrow window.
                var a = arg.Split(' ');
                window.Width = double.Parse(a[0], System.Globalization.CultureInfo.InvariantCulture);
                window.Height = double.Parse(a[1], System.Globalization.CultureInfo.InvariantCulture);
                window.UpdateLayout();
                break;
            }
            case "toast": window.ShowToast(new Toast(arg, "Undo", () => { })); break;
            case "palette":
                Cmd.CommandPalette.Execute(null, window);
                if (window.FindName("PaletteBox") is System.Windows.Controls.TextBox pb) pb.Text = arg;
                break;
            case "closepalette": window.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(window)!, 0, System.Windows.Input.Key.Escape) { RoutedEvent = UIElement.PreviewKeyDownEvent }); break;
            case "mem":
            {
                GC.Collect();
                GC.WaitForPendingFinalizers();
                using var proc = System.Diagnostics.Process.GetCurrentProcess();
                log.Add($"mem: working set {proc.WorkingSet64 / 1048576} MB, private {proc.PrivateMemorySize64 / 1048576} MB, managed {GC.GetTotalMemory(false) / 1048576} MB");
                break;
            }
            case "time": log.Add($"time: {Environment.TickCount64 - Started} ms since start"); break;
            case "xps":
            case "xpsjob":
            {
                // xps <file> [fill | nup <n> [down] [borders] | booklet [right] | poster <percent> [overlap DIPs] [nomarks]]:
                // the print pipeline into an XPS file (Letter), with a page handling; each sheet also as <file>.<n>.png.
                // xpsjob: the same through the Windows 11 dialog's job writer (ModernPrint: a sheet at a time, XPS object model).
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var setup = a.Length < 2 ? new Core.PrintSetup() : a[1] switch
                {
                    "fill" => new Core.PrintSetup { Sizing = Core.PrintSizing.FitToPaper },
                    "nup" => new Core.PrintSetup { Handling = Core.PrintHandling.PagesPerSheet, PagesPerSheet = int.Parse(a[2]), Order = a.Contains("down") ? Core.PagesOrder.Down : Core.PagesOrder.Across, Borders = a.Contains("borders") },
                    "booklet" => new Core.PrintSetup { Handling = Core.PrintHandling.Booklet, RightBinding = a.Contains("right") },
                    "poster" => new Core.PrintSetup { Handling = Core.PrintHandling.Poster, PosterScale = Num(a[2]) / 100, Overlap = a.Length > 3 && a[3] != "nomarks" ? Num(a[3]) : 0, CutMarks = !a.Contains("nomarks") },
                    _ => new Core.PrintSetup(),
                };
                var all = setup.Handling == Core.PrintHandling.Fit ? Math.Min(6, v!.PageCount) : v!.PageCount;
                var n = cmd.Equals("xpsjob", StringComparison.OrdinalIgnoreCase)
                    ? await ModernPrint.WriteJobXps(tab!.Session.Engine, [.. Enumerable.Range(0, all)], a[0], setup)
                    : await FileActions.WriteXps(tab!.Session.Engine, [.. Enumerable.Range(0, all)], a[0], setup);
                log.Add($"xps: {n} sheets, {new FileInfo(a[0]).Length / 1024} KB in {sw.ElapsedMilliseconds} ms");
                using (var xps = Core.PdfEngine.Open(File.ReadAllBytes(a[0]), MuPDFCore.InputFileTypes.XPS, null))
                    for (var i = 0; i < xps.PageCount; i++) xps.SaveImage(i, 40, $"{a[0]}.{i + 1}.png", jpeg: false);
                break;
            }
            case "printdialog":
            {
                // printdialog [options]: brings the window on screen and runs Print (with Options): the Windows 11 print
                // dialog when it can be used; drive it from outside (UI Automation), the step returns once it is up.
                window.Left = 80;
                window.Top = 40;
                window.Activate();
                await FileActions.Print(window, tab!, arg.Contains("options"));
                log.Add($"printdialog: modern={ModernPrint.Available}");
                break;
            }
            case "printhandling":
            {
                // printhandling <Fit|PagesPerSheet|Booklet|Poster> [duplex]: the Page Sizing & Handling dialog for the
                // document on Letter paper, opened on that choice (answer it with "later … shotwin / dialogok / closedialog").
                var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                AppSettings.Current.PrintHandling = a[0];
                var chosen = PrintHandlingDialog.Ask(window, [.. Enumerable.Range(0, v!.PageCount)], FileActions.SizesOf(tab!.Session.Engine),
                    new Size(816, 1056), new Core.RectD(24, 24, 768, 1008), a.Contains("duplex"));
                log.Add($"printhandling: {(chosen is null ? "cancelled" : $"{chosen.Handling} {chosen.Sizing} n={chosen.PagesPerSheet} {chosen.Order} borders={chosen.Borders} right={chosen.RightBinding} poster={chosen.PosterScale:P0} overlap={chosen.Overlap} marks={chosen.CutMarks}")}");
                break;
            }
            case "dialog":
            {
                // dialog <CommandName> <png>: open a dialog, snapshot it, cancel it.
                var parts = arg.Split(' ', 2);
                var command = (System.Windows.Input.RoutedUICommand)typeof(Cmd).GetField(parts[0])!.GetValue(null)!;
                var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(900) };
                timer.Tick += (_, _) =>
                {
                    timer.Stop();
                    var dlg = Application.Current.Windows.OfType<Window>().FirstOrDefault(w => w != window && w.IsVisible);
                    if (dlg is null)
                    {
                        log.Add($"dialog {parts[0]}: no window appeared");
                        return;
                    }
                    Shot(dlg, parts[1]);
                    log.Add($"dialog {parts[0]}: '{dlg.Title}' {dlg.ActualWidth:0}x{dlg.ActualHeight:0}");
                    dlg.Close();
                };
                timer.Start();
                command.Execute(null, window);
                await Task.Delay(1200);
                break;
            }
            // Compare: compare old.pdf new.pdf (opens the compare window off-screen, waits for the result) · compareshot out.png ·
            // comparemode text|visual · comparenext [n] · compareselect i · comparezoom percent|fit · comparestate · comparereport
            case "compare":
            {
                var a = arg.Split(' ', 2);
                var cw = CompareWindow.Open(window, new CompareSide(Path.GetFileName(a[0]), await File.ReadAllBytesAsync(a[0]), null),
                    new CompareSide(Path.GetFileName(a[1]), await File.ReadAllBytesAsync(a[1]), null), offScreen: true);
                await CompareIdle(cw);
                log.Add(cw.DevDescribe());
                break;
            }
            case "compareshot":
            {
                var cw = Application.Current.Windows.OfType<CompareWindow>().Last();
                await CompareIdle(cw);
                Shot(cw, arg);
                break;
            }
            case "comparemode": Application.Current.Windows.OfType<CompareWindow>().Last().DevMode(arg == "visual"); break;
            case "comparenext":
                for (var i = 0; i < (int.TryParse(arg, out var steps) ? steps : 1); i++) Application.Current.Windows.OfType<CompareWindow>().Last().Step(1);
                break;
            case "compareselect": Application.Current.Windows.OfType<CompareWindow>().Last().DevSelect(int.Parse(arg)); break;
            case "comparezoom": Application.Current.Windows.OfType<CompareWindow>().Last().DevZoom(arg == "fit" ? 0 : double.Parse(arg, System.Globalization.CultureInfo.InvariantCulture) / 100); break;
            case "comparestate": log.Add(Application.Current.Windows.OfType<CompareWindow>().Last().DevDescribe()); break;
            case "comparereport":
                await Application.Current.Windows.OfType<CompareWindow>().Last().DevReportAsync();
                log.Add($"tabs: {window.TabCount}, active '{window.ActiveTab?.Session.DisplayName}' {Annotations(window.ActiveTab!)}");
                break;
            case "later":
            {
                // later <ms> <step>: run <step> after <ms> even while the next step is blocked (e.g. inside a
                // modal prompt that step opened): starts an edit while a warning is open, or answers a prompt.
                var a = arg.Split(' ', 2);
                var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(int.Parse(a[0])) };
                timer.Tick += async (_, _) =>
                {
                    timer.Stop();
                    try
                    {
                        await Step(window, a[1], log);
                        log.Add($"ok (later): {a[1]}");
                    }
                    catch (Exception ex)
                    {
                        log.Add($"FAILED (later) {a[1]}: {ex.Message}");
                    }
                };
                timer.Start();
                break;
            }
            // File tools, bookmarks, Read Aloud: openpw pw|drop|cancel (answers the active tab's next open-password prompt) · security ·
            // bookmarks · bookmark add Title | child path Title | rename path Title | delete path | move path parent index |
            // dest path (paths are 0-based, dotted: 1.0) · readaloud (toggle) · readaloud-state · readaloud-skip 1|-1
            case "openpw": ScriptOpenPassword(tab!, arg == "cancel" ? null : arg == "drop" ? new OpenPasswordAnswer(null, true) : new OpenPasswordAnswer(arg, false)); break;
            case "security": log.Add($"security: {SecurityActions.Describe(tab!.Session)} password={(tab.Session.Password is null ? "none" : "set")} open={(tab.Session.OpenPassword is null ? "none" : "set")}"); break;
            case "bookmarks": log.Add($"bookmarks: {tab!.DevBookmarks()}"); break;
            case "bookmark": log.Add($"bookmark: {await tab!.DevBookmark(arg)}"); break;
            case "readaloud": await tab!.ToggleReadAloud(); break;
            case "readaloud-state": log.Add($"readaloud: {tab!.ReadAloudPlayer.State}"); break;
            case "readaloud-skip": tab!.ReadAloudPlayer.DevSkip(int.Parse(arg)); break;
            // AI assistant (no network: aifake answers instead): aiconfig Ollama|LMStudio|url model [context] · aioff ·
            // aifake answer text|error401|refused|missing · aipane on|off · aisummarize all|range · aiask question ·
            // aiexplain · aistate · dialogfill check0=on text1=… [expand] (the topmost open FormDialog, like dialogok's settings; expand opens its expanders)
            case "aiconfig":
            {
                var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var s = AppSettings.Current;
                s.AiEnabled = true;
                if (AiService.PresetNames.Contains(a[0])) s.AiPreset = a[0];
                else (s.AiPreset, s.AiCustomUrl) = ("Custom", a[0]);
                s.AiModel = a.Length > 1 ? a[1] : "";
                if (a.Length > 2) s.AiContextTokens = int.Parse(a[2]);
                tab?.RefreshAiPane();
                log.Add($"ai: {AiActions.Describe()}");
                break;
            }
            case "aioff": AppSettings.Current.AiEnabled = false; tab?.RefreshAiPane(); break;
            case "aifake": AiService.DevHandler = _ => new DevAiHandler(arg); break;
            // Store updates (no Store): updatefake none|ready|mandatory|error · updatecheck [startup] · updatestate
            case "updatefake": window.DevFakeStoreUpdates(new DevStoreUpdates(arg)); break;
            case "updatecheck": await window.DevCheckForUpdatesAsync(user: arg != "startup"); log.Add(window.DevUpdateState()); break;
            case "updatestate": log.Add(window.DevUpdateState()); break;
            case "aipane" when arg == "off": tab!.CloseAiPane(); break;
            case "aipane": tab!.ShowAiPane(); await Task.Delay(300); break;
            case "aisummarize":
                await tab!.AiSummarize(arg is "" or "all" ? [.. Enumerable.Range(0, v!.PageCount)] : Core.PageRange.TryParse(arg, v!.PageCount, out var aiPages, out _) ? aiPages : []);
                log.Add(tab.DevAiState());
                break;
            case "aiask":
                if (tab!.AiPaneView is null) tab.ShowAiPane();
                tab.AiPaneView!.Input.Text = arg;
                await tab.AiAsk(arg);
                log.Add(tab.DevAiState());
                break;
            case "aiexplain": await tab!.AiExplainSelection(); log.Add(tab.DevAiState()); break;
            case "aistate": log.Add(tab!.DevAiState()); break;
            case "dialogfill":
                if (Application.Current.Windows.OfType<FormDialog>().LastOrDefault(w => w.IsVisible) is { } fd)
                {
                    FillDialog(fd, [.. arg.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(p => p.Split('=', 2))]);
                    if (arg.Contains("expand", StringComparison.Ordinal))
                        foreach (var ex in Descendants<System.Windows.Controls.Expander>(fd)) ex.IsExpanded = true;
                }
                else log.Add("dialogfill: no dialog open");
                break;
            // Batch: batch [path;path] (opens the window, modeless) · batchadd path;path · batchstep optimize|protect open [owner]|unprotect|
            // sanitize|redactpatterns [phrase]|watermark text|footer text|bates PREFIX [continue]|rotate 90|flatten|ocr|pdfa|export word|excel|text|png|jpeg ·
            // batchout folder [template] · batchoption signed=edit passwords=skip overwrite=on subfolders=off recursive=off images=a4 ·
            // batchpw password|skip (answers the next password prompt) · batchrun (waits for the result) · batchshot out.png · batchstate · batchclose
            case "batch":
                BatchWindow.Open(window, arg.Length > 0 ? arg.Split(';') : null, modal: false);
                await Task.Delay(500);
                break;
            case "batchadd": OpenBatch().AddPaths(arg.Split(';')); break;
            case "batchstep": OpenBatch().DevAddStep(arg); break;
            case "batchout":
            {
                var a = arg.Split(' ', 2);
                OpenBatch().DevOutput(a[0], a.Length > 1 ? a[1] : null);
                break;
            }
            case "batchoption":
                foreach (var kv in arg.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(p => p.Split('=', 2)))
                    OpenBatch().DevOption(kv[0], kv.ElementAtOrDefault(1) ?? "");
                break;
            case "batchpw":
                lock (BatchPasswords) BatchPasswords.Enqueue(arg == "skip" ? null : arg);
                break;
            case "batchrun":
                await OpenBatch().StartAsync();
                log.Add(OpenBatch().DevState());
                break;
            case "batchshot": await Task.Delay(300); Shot(OpenBatch(), arg); break;
            case "batchstate": log.Add(OpenBatch().DevState()); break;
            case "batchask":
            {
                // batchask kind png: an action's settings dialog, snapshotted and cancelled.
                var a = arg.Split(' ', 2);
                var batchWindow = OpenBatch();
                var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(900) };
                timer.Tick += (_, _) =>
                {
                    timer.Stop();
                    if (Application.Current.Windows.OfType<FormDialog>().LastOrDefault(w => w.IsVisible) is not { } dlg)
                    {
                        log.Add($"batchask {a[0]}: no dialog appeared");
                        return;
                    }
                    Shot(dlg, a[1]);
                    log.Add($"batchask {a[0]}: '{dlg.Title}' {dlg.ActualWidth:0}x{dlg.ActualHeight:0}");
                    dlg.Close();
                };
                timer.Start();
                batchWindow.DevAsk(a[0]);
                break;
            }
            case "batchclose": OpenBatch().Close(); break;
            // Presets and watched folders: presetsave name · presetload name (the open Batch window) · watch folder;preset name
            // (watched until the script ends) · watchshot out.png (the Watched Folders window) · watchstate
            case "presetsave": OpenBatch().DevSavePreset(arg); break;
            case "presetload": OpenBatch().DevLoadPreset(arg); log.Add(OpenBatch().DevState()); break;
            case "watch":
            {
                var a = arg.Split(';', 2);
                var preset = PresetLibrary.List().FirstOrDefault(p => p.Name == a[1]).Path ?? throw new ArgumentException($"no preset {a[1]}");
                FolderWatches.Add(window, a[0], preset, "");
                break;
            }
            case "watchshot": WatchWindow.Open(window); await Task.Delay(500); Shot(WatchWindow.Open(window), arg); break;
            case "watchstate": log.Add($"watch: {WatchWindow.Open(window).DevState()}; title '{FolderWatches.Summary}'"); break;
            // Inkvolt Pro: prowindow [presets|watched|cli|tag|ro|pdfa2a] (Help › Inkvolt Pro, or as a locked feature opens it) · pro <key>|remove (enter or
            // remove a key in that window) · proenforce on|off (the gate, to see the locked views) · proshot out.png · prostate
            case "prowindow":
                ProWindow.Open(window, arg switch { "presets" => ProFeature.BatchPresets, "watched" => ProFeature.WatchedFolders, "cli" => ProFeature.CommandLine, "tag" => ProFeature.AutoTagging, "ro" => ProFeature.ReadingOrder, "pdfa2a" => ProFeature.AccessibleOutput, _ => null });
                await Task.Delay(300);
                break;
            case "pro" when arg == "remove": ProWindow.Open(window, null).DevRemove(); break;
            case "pro": ProWindow.Open(window, null).DevEnter(arg); break;
            case "proenforce": Pro.Enforced = arg == "on"; FolderWatches.RaiseChanged(); break;
            case "proshot": Shot(ProWindow.Open(window, null), arg); break;
            case "prostate": log.Add($"pro: {ProWindow.Open(window, null).DevState()}"); break;
            // Create PDF: convert path (an Office file or a saved web page, as File › Open does) · webpage address|file
            // (Create PDF from Web Page with the saved options) · converters (what is installed)
            case "convert":
                await Converting.OpenConverted(window, arg);
                log.Add($"convert: tabs {window.TabCount}, active '{window.ActiveTab?.Session.DisplayName}' pages={window.ActiveTab?.PageView.PageCount}");
                break;
            case "webpage":
            {
                var source = File.Exists(arg) ? new Uri(Path.GetFullPath(arg)) : Core.WebFiles.TryParseAddress(arg, out var u, out var err) ? u! : throw new ArgumentException(err);
                var pdf = await WebCapture.PrintAsync(source, new Core.WebPdfOptions(), s => log.Add($"  webpage: {s}"), CancellationToken.None);
                window.OpenSession(Core.DocumentSession.FromBytes(pdf, source.IsFile ? Path.GetFileNameWithoutExtension(source.LocalPath) + ".pdf" : Core.WebFiles.PdfName(source)));
                await Task.Delay(800);
                log.Add($"webpage: {pdf.Length} bytes, active '{window.ActiveTab?.Session.DisplayName}' pages={window.ActiveTab?.PageView.PageCount}");
                break;
            }
            // Measuring: measure distance|perimeter|area|calibrate p x1 y1 x2 y2 … (as if clicked; calibrate opens its dialog) ·
            // setscale 1 in = 10 ft [all] · measurements (the current page's, and one in progress)
            case "measure":
            {
                var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var tool = a[0] switch { "perimeter" => ViewerTool.MeasurePerimeter, "area" => ViewerTool.MeasureArea, "calibrate" => ViewerTool.MeasureCalibrate, _ => ViewerTool.MeasureDistance };
                var nums = a.Skip(2).Select(n => double.Parse(n, System.Globalization.CultureInfo.InvariantCulture)).ToList();
                tab!.PageView.DevMeasure(int.Parse(a[1]) - 1, tool, [.. Enumerable.Range(0, nums.Count / 2).Select(i => new Core.PointD(nums[2 * i], nums[2 * i + 1]))]);
                await Task.Delay(400);
                await tab.SettleAsync();
                log.Add(tab.DevMeasurements());
                break;
            }
            case "setscale":
                await tab!.DevSetScale(arg.Replace(" all", "", StringComparison.Ordinal), arg.EndsWith(" all", StringComparison.Ordinal));
                await tab.SettleAsync();
                log.Add(tab.DevMeasurements());
                break;
            case "measurements": log.Add(tab!.DevMeasurements()); break;
            case "pdfa": await PdfAActions.SaveAs(window, tab!); break;
            case "pdfa2a": await PdfAActions.SaveAs(window, tab!, PdfAConformance.A); break; // savepath out.pdf first; answer the prompts with later/prompt
            case "converters":
                log.Add($"converters: office=[{string.Join(", ", OfficeConverter.InstalledApps)}] webview2={WebCapture.RuntimeVersion ?? "none"} menu={window.OfficeMenu.Visibility}");
                break;
            case "dropimages": log.Add($"dropimages handled: {FileTools.HandleWindowDrop(window, arg.Split(';'))}"); break; // as if dropped on the window
            case "textscale":
                // textscale 1.5|150|system: as if Windows' Text size were set to that (TextScale); system follows the real setting again.
                TextScale.Override(arg is "system" or "" ? null : InkvoltPrint.Core.Suite.TextSize.Parse(arg));
                log.Add($"textscale: {TextScale.Factor}");
                break;
            case "a11yaudit":
            {
                // a11yaudit: every visible window's interactive controls without an accessible name or under 24 × 24 (UiAudit's rules).
                foreach (var w in Application.Current.Windows.OfType<Window>().Where(w => w.IsVisible))
                {
                    var findings = UiInspection.Audit(w);
                    log.Add($"a11yaudit '{w.Title}': {findings.Count} findings");
                    foreach (var f in findings) log.Add("  " + f);
                }
                break;
            }
            case "exit": break;
            default: log.Add($"unknown step: {line}"); break;
        }
    }

    private static BatchWindow OpenBatch() => Application.Current.Windows.OfType<BatchWindow>().LastOrDefault() ?? throw new InvalidOperationException("no Batch window open (step: batch)");

    private static string Trunc(string s) => (s.Length > 120 ? s[..120] + "…" : s).Replace("\r\n", " ⏎ ");

    private static string Placed(DocumentTab tab) =>
        $"placed: {string.Join("; ", tab.DevSignatureStamps.Select(s => $"{s.Kind} '{s.Text}' p{s.PageIndex + 1} {s.Rect.X:0},{s.Rect.Y:0} {s.Rect.Width:0}x{s.Rect.Height:0}"))}";

    private static string LinkList(DocumentTab tab) =>
        $"links: {string.Join("; ", tab.DevLinks.Select(l => $"p{l.PageIndex + 1} {l.Rect.X:0},{l.Rect.Y:0} {l.Rect.Width:0}x{l.Rect.Height:0} → {l.Describe()}"))}";

    private static readonly Queue<(string? Uri, int Page)?> LinkTargets = new();

    /// <summary>The scripted answer to the next Add/Edit Link dialog (<c>linktarget</c>), if any (null = cancel).</summary>
    internal static bool TakeLinkTarget(out (string? Uri, int Page)? target) => LinkTargets.TryDequeue(out target);

    private static void SetFindText(DocumentTab tab, string text)
    {
        if (tab.FindName("FindBox") is System.Windows.Controls.TextBox box) box.Text = text;
    }

    private static void Nav(DocumentTab tab, string which) =>
        tab.ShowPane(Enum.TryParse<NavPaneKind>(which, true, out var kind) ? kind : NavPaneKind.Pages);

    /// <summary>
    /// Types like a keyboard (WM_KEYDOWN, WM_KEYUP; the message loop's TranslateMessage makes the WM_CHAR), unlike "type",
    /// which sets the editor's text directly. {tab} = Tab, {enter} = Enter, {sp} = space. Characters that need Shift on
    /// this keyboard layout (VkKeyScanW's shift bit: capitals, !@#…) are sent as Shift down, key, Shift up, with Shift
    /// also set in the thread's key state (SetKeyboardState) while they are processed: posted messages don't change it,
    /// and both TranslateMessage and WPF's Keyboard.Modifiers read it. Characters that need Ctrl/Alt (AltGr) or that the
    /// layout can't type are posted as WM_CHAR only (text input without key events).
    /// </summary>
    private static async Task PostKeys(Window window, string text)
    {
        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        foreach (var ch in text.Replace("{tab}", "\t").Replace("{enter}", "\r").Replace("{sp}", " "))
        {
            var scan = VkKeyScanW(ch);
            var vk = (nint)(scan & 0xFF);
            var shifts = (scan >> 8) & 0xFF;
            if (scan == -1 || (shifts & ~1) != 0)
            {
                PostMessageW(hwnd, 0x0102, ch, 1); // WM_CHAR
            }
            else if (shifts == 1)
            {
                var saved = new byte[256];
                GetKeyboardState(saved);
                var state = (byte[])saved.Clone();
                state[0x10] |= 0x80;
                state[0xA0] |= 0x80;
                SetKeyboardState(state);
                try
                {
                    PostMessageW(hwnd, 0x0100, 0x10, 1);
                    PostMessageW(hwnd, 0x0100, vk, 1);
                    PostMessageW(hwnd, 0x0101, vk, unchecked((nint)0xC0000001));
                    PostMessageW(hwnd, 0x0101, 0x10, unchecked((nint)0xC0000001));
                    await Task.Delay(60); // processed (and translated) while Shift is down
                }
                finally
                {
                    SetKeyboardState(saved);
                }
            }
            else
            {
                PostMessageW(hwnd, 0x0100, vk, 1);
                PostMessageW(hwnd, 0x0101, vk, unchecked((nint)0xC0000001));
            }
            await Task.Delay(40);
        }
    }

    /// <summary>Keys go to the open dialog or prompt (the last visible secondary window), else the main window.</summary>
    private static Window KeyTarget(Window main) =>
        Application.Current.Windows.OfType<Window>().LastOrDefault(w => w != main && w.IsVisible) ?? main;

    private static readonly Queue<string?> SavePaths = new();

    /// <summary>
    /// File pickers ask this first: true with the path the <c>savepath</c> step queued (null = "the user cancelled"),
    /// false when nothing is queued (show the real dialog).
    /// </summary>
    internal static bool TakeSavePath(out string? path) => SavePaths.TryDequeue(out path);

    private static readonly Queue<string?> BatchPasswords = new();

    /// <summary>The scripted answer to the next batch password prompt (<c>batchpw</c>), if any (null = skip the file).</summary>
    internal static bool TakeBatchPassword(out string? answer)
    {
        lock (BatchPasswords) return BatchPasswords.TryDequeue(out answer);
    }

    private static readonly Queue<OpenPasswordAnswer?> OpenPasswords = new();

    /// <summary>
    /// <c>openpw</c>: the active tab's edit transaction takes the next open-password answer (a null answer = cancel) from
    /// the script while it has one; every other question still shows its dialog.
    /// </summary>
    private sealed class ScriptedEditPrompts(IEditPrompts dialogs) : IEditPrompts
    {
        public bool ConfirmSignedEdit() => dialogs.ConfirmSignedEdit();
        public OpenPasswordAnswer? AskOpenPassword(byte[] data) => OpenPasswords.TryDequeue(out var answer) ? answer : dialogs.AskOpenPassword(data);
        public string? AskOwnerPassword(bool wrong) => dialogs.AskOwnerPassword(wrong);
        public bool ConfirmSignatureRewrite(string label, int signatures, string reason) => dialogs.ConfirmSignatureRewrite(label, signatures, reason);
        public bool ConfirmBreakingEdit(string label, IReadOnlyList<SignatureInfo> broken) => dialogs.ConfirmBreakingEdit(label, broken);
    }

    private static void ScriptOpenPassword(DocumentTab tab, OpenPasswordAnswer? answer)
    {
        OpenPasswords.Enqueue(answer);
        if (tab.EditPrompts is not ScriptedEditPrompts) tab.EditPrompts = new ScriptedEditPrompts(tab.EditPrompts);
    }

    /// <summary>
    /// <c>mouse move|down|up|click|dbl|right page x y</c>: mouse messages at a page point (points, top-left origin; scrolled
    /// into view first), posted to the window with client coordinates. The button is also set in the thread's key state
    /// while held, since WPF reads button state with GetKeyState. The real pointer stays where it is (the window is
    /// off-screen), so WPF may see the mouse leave right after a move; hover tips are read with the <c>tip</c> step.
    /// </summary>
    private static async Task MouseStep(Window window, PageViewer v, string arg, List<string> log)
    {
        var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var lp = ClientPoint(window, v, int.Parse(a[1]) - 1, Num(a[2]), Num(a[3]));
        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        // WPF drops mouse messages for a window the real pointer isn't over, unless that window has the capture.
        SetCapture(hwnd);
        switch (a[0])
        {
            case "move":
                PostMessageW(hwnd, 0x0200, MouseHeld(), lp);
                await Task.Delay(120);
                break;
            case "down": await ButtonDown(hwnd, lp, right: false); break;
            case "up": await ButtonUp(hwnd, lp, right: false); break;
            case "click":
                await ButtonDown(hwnd, lp, right: false);
                await ButtonUp(hwnd, lp, right: false);
                break;
            case "dbl":
                for (var i = 0; i < 2; i++)
                {
                    await ButtonDown(hwnd, lp, right: false);
                    await ButtonUp(hwnd, lp, right: false);
                }
                break;
            case "right":
                await ButtonDown(hwnd, lp, right: true);
                await ButtonUp(hwnd, lp, right: true);
                break;
            default: throw new ArgumentException($"Unknown mouse action '{a[0]}' (move, down, up, click, dbl, right).");
        }
        // After a move, keep the capture so the pointer stays "over" the window (hover tips stay up) until the next step.
        if (a[0] != "move" && System.Windows.Input.Mouse.Captured is null) ReleaseCapture();
        log.Add($"mouse {a[0]} at client {lp & 0xFFFF},{lp >> 16}");
    }

    /// <summary><c>drag page x1 y1 x2 y2</c>: left button down at the first point, moves in steps, up at the second.</summary>
    private static async Task Drag(Window window, PageViewer v, string arg)
    {
        var a = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var page = int.Parse(a[0]) - 1;
        double x1 = Num(a[1]), y1 = Num(a[2]), x2 = Num(a[3]), y2 = Num(a[4]);
        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        SetCapture(hwnd);
        await ButtonDown(hwnd, ClientPoint(window, v, page, x1, y1), right: false);
        nint last = 0;
        for (var i = 1; i <= 8; i++)
        {
            last = ClientPoint(window, v, page, x1 + (x2 - x1) * i / 8, y1 + (y2 - y1) * i / 8);
            PostMessageW(hwnd, 0x0200, MouseHeld(), last);
            await Task.Delay(30);
        }
        await ButtonUp(hwnd, last, right: false);
        if (System.Windows.Input.Mouse.Captured is null) ReleaseCapture();
    }

    private static nint ClientPoint(Window window, PageViewer v, int page, double x, double y)
    {
        var p = v.DevPointIn(window, page, x, y) ?? throw new ArgumentException($"No page {page + 1}.");
        var dpi = VisualTreeHelper.GetDpi(window);
        var cx = (int)Math.Round(p.X * dpi.DpiScaleX);
        var cy = (int)Math.Round(p.Y * dpi.DpiScaleY);
        return (cy << 16) | (cx & 0xFFFF);
    }

    private static nint MouseHeld()
    {
        var state = new byte[256];
        GetKeyboardState(state);
        return ((state[0x01] & 0x80) != 0 ? 1 : 0) | ((state[0x02] & 0x80) != 0 ? 2 : 0); // MK_LBUTTON, MK_RBUTTON
    }

    private static void SetHeld(int vk, bool down)
    {
        var state = new byte[256];
        GetKeyboardState(state);
        state[vk] = (byte)(down ? state[vk] | 0x80 : state[vk] & 0x7F);
        SetKeyboardState(state);
    }

    private static async Task ButtonDown(IntPtr hwnd, nint lp, bool right)
    {
        PostMessageW(hwnd, 0x0200, MouseHeld(), lp); // the pointer arrives first, like a real click
        await Task.Delay(40);
        SetHeld(right ? 0x02 : 0x01, true);
        PostMessageW(hwnd, right ? 0x0204u : 0x0201u, MouseHeld(), lp);
        await Task.Delay(60);
    }

    private static async Task ButtonUp(IntPtr hwnd, nint lp, bool right)
    {
        SetHeld(right ? 0x02 : 0x01, false);
        PostMessageW(hwnd, right ? 0x0205u : 0x0202u, MouseHeld(), lp);
        await Task.Delay(80);
    }

    /// <summary>
    /// <c>key Delete ctrl shift</c>: posts WM_KEYDOWN/UP for one WPF <see cref="System.Windows.Input.Key"/>, with the modifier
    /// keys pressed around it. Posted messages don't change the thread's key state, so the modifiers are also set in it
    /// (SetKeyboardState) while the key is processed; WPF reads Keyboard.Modifiers from there. Alt combos are sent as
    /// WM_SYSKEYDOWN. Limits: no character messages for Alt (menus' access keys may not react), and the key state is
    /// restored after ~150 ms, so a handler that runs later sees no modifiers.
    /// </summary>
    private static async Task PostKey(Window window, string spec)
    {
        var parts = spec.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var key = Enum.Parse<System.Windows.Input.Key>(parts[0], ignoreCase: true);
        var mods = parts.Skip(1).Select(m => m.ToLowerInvariant() switch
        {
            "ctrl" or "control" => 0x11,
            "shift" => 0x10,
            "alt" => 0x12,
            _ => throw new ArgumentException($"Unknown modifier '{m}' (use ctrl, shift, alt)."),
        }).Distinct().ToList();
        var alt = mods.Contains(0x12);
        uint down = alt ? 0x0104u : 0x0100u, up = alt ? 0x0105u : 0x0101u;
        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        var vk = System.Windows.Input.KeyInterop.VirtualKeyFromKey(key);

        var saved = new byte[256];
        GetKeyboardState(saved);
        var state = (byte[])saved.Clone();
        foreach (var m in mods)
        {
            state[m] |= 0x80;
            state[m switch { 0x11 => 0xA2, 0x10 => 0xA0, _ => 0xA4 }] |= 0x80; // left-hand variant too
        }
        SetKeyboardState(state);
        try
        {
            nint context = alt ? 1 << 29 : 0; // lParam bit 29: Alt is down
            foreach (var m in mods) PostMessageW(hwnd, down, m, 1 | context);
            PostMessageW(hwnd, down, vk, 1 | context);
            PostMessageW(hwnd, up, vk, unchecked((nint)0xC0000001) | context);
            foreach (var m in Enumerable.Reverse(mods)) PostMessageW(hwnd, up, m, unchecked((nint)0xC0000001) | context);
            await Task.Delay(150);
        }
        finally
        {
            SetKeyboardState(saved);
        }
    }

    private static void FillDialog(Window dlg, List<string[]> settings)
    {
        var combos = Descendants<System.Windows.Controls.ComboBox>(dlg).ToList();
        var texts = Descendants<System.Windows.Controls.TextBox>(dlg).Where(t => t.TemplatedParent is null).ToList();
        var checks = Descendants<System.Windows.Controls.CheckBox>(dlg).ToList();
        var passwords = Descendants<System.Windows.Controls.PasswordBox>(dlg).ToList();
        foreach (var s in settings.Where(s => s.Length == 2))
        {
            if (s[0].StartsWith("pw")) passwords[int.Parse(s[0][2..])].Password = s[1].Replace("{sp}", " ");
            else if (s[0].StartsWith("combo")) combos[int.Parse(s[0][5..])].SelectedIndex = int.Parse(s[1]);
            else if (s[0].StartsWith("text")) texts[int.Parse(s[0][4..])].Text = s[1].Replace("{sp}", " ");
            else if (s[0].StartsWith("check")) checks[int.Parse(s[0][5..])].IsChecked = s[1] == "on";
        }
    }

    /// <summary>Clicks the button labelled <paramref name="text"/> in a visible secondary window; returns what it did, or null.</summary>
    private static string? ClickButton(Window main, string text)
    {
        foreach (var w in Application.Current.Windows.OfType<Window>().Where(w => w != main && w.IsVisible).Reverse())
        {
            var button = Descendants<System.Windows.Controls.Button>(w).FirstOrDefault(b => b.Content as string == text && b.IsEnabled);
            if (button is null) continue;
            var title = Descendants<System.Windows.Controls.TextBlock>(w).FirstOrDefault(t => t.FontSize >= 18 && t.Text.Length > 2)?.Text ?? w.Title;
            button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            return $"clicked '{text}' in '{title}'";
        }
        return null;
    }

    /// <summary>
    /// <c>menu Header</c>: invokes the item with that header (access-key underscores ignored) in an open context menu or
    /// menu popup, like a click (commands run). Logs the menu's items either way.
    /// </summary>
    private static string ClickMenuItem(string header)
    {
        var items = PresentationSource.CurrentSources.OfType<PresentationSource>()
            .Where(s => s.RootVisual is not null && s.RootVisual.GetType().Name == "PopupRoot")
            .SelectMany(s => Descendants<System.Windows.Controls.MenuItem>(s.RootVisual))
            .Where(m => m.IsVisible)
            .ToList();
        string Name(System.Windows.Controls.MenuItem m) => (m.Header as string ?? (m.Command as System.Windows.Input.RoutedUICommand)?.Text ?? "").Replace("_", "");
        var listing = $"menu items: {string.Join(", ", items.Select(m => Name(m) + (m.IsEnabled ? "" : " (disabled)")))}";
        var item = items.FirstOrDefault(m => Name(m).TrimEnd('…') == header.TrimEnd('…'));
        if (item is null) return $"{listing}; no '{header}'";
        if (!item.IsEnabled) return $"{listing}; '{header}' is disabled";
        ((System.Windows.Automation.Provider.IInvokeProvider)new System.Windows.Automation.Peers.MenuItemAutomationPeer(item)).Invoke();
        return $"{listing}; clicked '{header}'";
    }

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T t) yield return t;
            foreach (var d in Descendants<T>(child)) yield return d;
        }
    }

    /// <summary>The comments the tab has read (Fill &amp; Sign items excluded), one line each.</summary>
    private static string Annotations(DocumentTab tab)
    {
        var list = tab.Comments.Where(c => !c.IsInkvoltPdfStamp).ToList();
        return $"annots: {list.Count}" + string.Concat(list.Select(c =>
            $"\n  {c.Subtype} p{c.PageIndex + 1} {c.Rect.X:0},{c.Rect.Y:0} {c.Rect.Width:0}x{c.Rect.Height:0} quads={c.QuadRects.Count} by '{c.Author}' replyTo={c.ReplyTo ?? "-"}: '{Trunc(c.Contents)}'"));
    }

    /// <summary>The drawing annotations (index, kind, where, look), one line each.</summary>
    private static string Drawings(DocumentTab tab)
    {
        var list = tab.DevDrawings;
        return $"drawings: {list.Count}" + string.Concat(list.Select((a, i) =>
        {
            var b = a.Geometry!.Bounds;
            var s = a.Style!;
            return $"\n  [{i}] {CommentItem.TitleOf(a)} ({a.Subtype}) p{a.PageIndex + 1} bounds {b.X:0.#},{b.Y:0.#} {b.Width:0.#}x{b.Height:0.#} box {a.Geometry.Box.X:0.#},{a.Geometry.Box.Y:0.#} {a.Geometry.Box.Width:0.#}x{a.Geometry.Box.Height:0.#} " +
                   $"paths={a.Geometry.Paths.Count}/{a.Geometry.Paths.Sum(p => p.Count)}pts callout={a.Geometry.Callout.Count} color={DrawStyles.Hex(s.Color) ?? "-"} fill={DrawStyles.Hex(s.Fill) ?? "-"} " +
                   $"w={s.Width:0.#} op={s.Opacity:0.##} font={s.FontSize:0.#} ends={s.StartEnding}/{s.EndEnding} hl={s.Highlighter} '{Trunc(a.Contents)}'";
        }));
    }

    private static Core.AttachmentInfo Attachment(DocumentTab tab, string nameOrIndex) =>
        tab.AttachedFiles.FirstOrDefault(f => f.FileName == nameOrIndex) ?? tab.AttachedFiles[int.Parse(nameOrIndex)];

    private static double Num(string s) => double.Parse(s, System.Globalization.CultureInfo.InvariantCulture);

    private static string BarText(DocumentTab tab, string bar, string text) =>
        tab.FindName(bar) is FrameworkElement { Visibility: Visibility.Visible } && tab.FindName(text) is System.Windows.Controls.TextBlock tb ? tb.Text : "(hidden)";

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetKeyboardState(byte[] state);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr SetCapture(IntPtr hwnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetKeyboardState(byte[] state);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern short VkKeyScanW(char ch);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr hwnd, uint msg, nint wParam, nint lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out Rect32 r);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    private struct Rect32 { public int Left, Top, Right, Bottom; }

    /// <summary>Shows the window on screen for a moment and captures only its own rectangle (real Mica and caption buttons).</summary>
    private static async Task ScreenShot(Window window, string path)
    {
        var (left, top, topmost) = (window.Left, window.Top, window.Topmost);
        window.Left = 40;
        window.Top = 40;
        window.Topmost = true;
        await Task.Delay(1200);
        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        GetWindowRect(hwnd, out var r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        var screen = GetDC(IntPtr.Zero);
        var mem = CreateCompatibleDC(screen);
        var hbm = CreateCompatibleBitmap(screen, w, h);
        var old = SelectObject(mem, hbm);
        BitBlt(mem, 0, 0, w, h, screen, r.Left, r.Top, 0x00CC0020 | 0x40000000);
        SelectObject(mem, old);
        var bmp = System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(hbm, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
        DeleteObject(hbm);
        DeleteDC(mem);
        ReleaseDC(IntPtr.Zero, screen);
        window.Topmost = topmost;
        window.Left = left;
        window.Top = top;
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(path);
        enc.Save(fs);
    }

    /// <summary>Waits (up to 30 s) until the compare window has its result and has rendered what's in view.</summary>
    private static async Task CompareIdle(CompareWindow cw)
    {
        for (var i = 0; i < 300 && !cw.DevIdle; i++) await Task.Delay(100);
        await Task.Delay(400);
        for (var i = 0; i < 100 && !cw.DevIdle; i++) await Task.Delay(100);
    }

    private static void Shot(Window window, string path, bool withMenus = false)
    {
        // The window's visual root, not its Content: the adorner layer (placeholders, focus rings) sits above the content.
        var content = VisualTreeHelper.GetChildrenCount(window) > 0 ? (FrameworkElement)VisualTreeHelper.GetChild(window, 0) : (FrameworkElement)window.Content;
        var dpi = VisualTreeHelper.GetDpi(window);
        var bmp = new RenderTargetBitmap((int)(content.ActualWidth * dpi.DpiScaleX), (int)(content.ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var bg = window.TryFindResource("SolidBackgroundFillColorBaseBrush") as Brush ?? Brushes.White;
            dc.DrawRectangle(bg, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
            dc.DrawRectangle(new VisualBrush(content) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top, ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(0, 0, content.ActualWidth, content.ActualHeight), ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, content.ActualWidth, content.ActualHeight) }, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
            // menushot: the open menus and submenus (popups, windows of their own) drawn where they are over the window.
            // An off-screen window's menus open on the screen, so each is placed by its target: a menu under its button, a
            // submenu beside its item.
            if (withMenus)
            {
                var origins = new Dictionary<Visual, Point>();
                var popups = PresentationSource.CurrentSources.OfType<PresentationSource>()
                    .Select(src => src.RootVisual).OfType<FrameworkElement>()
                    .Where(r => r.IsVisible && r.GetType().Name == "PopupRoot").ToList();
                for (var pass = 0; pass < 3; pass++)
                    foreach (var root in popups)
                    {
                        if (origins.ContainsKey(root) || root.Parent is not System.Windows.Controls.Primitives.Popup { PlacementTarget: FrameworkElement target } popup) continue;
                        Point at;
                        if (content.IsAncestorOf(target)) at = target.TranslatePoint(new Point(0, target.ActualHeight), content);
                        else if (popups.FirstOrDefault(r => r.IsAncestorOf(target)) is { } host && origins.TryGetValue(host, out var o))
                            at = target.TranslatePoint(new Point(target.ActualWidth, 0), host) + (Vector)o;
                        else continue;
                        origins[root] = at;
                        dc.DrawRectangle(new VisualBrush(root) { Stretch = Stretch.None }, null, new Rect(at, new Size(root.ActualWidth, root.ActualHeight)));
                    }
            }
        }
        bmp.Render(visual);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(path);
        enc.Save(fs);
    }

    /// <summary><c>updatefake</c>: the Store's answer without the Store. Installing comes back canceled, so the app stays open.</summary>
    private sealed class DevStoreUpdates(string spec) : IStoreUpdates
    {
        public Task<StoreUpdateInfo> FindAsync(CancellationToken cancel = default) => spec switch
        {
            "error" => Task.FromException<StoreUpdateInfo>(new System.Runtime.InteropServices.COMException("Dev: the Store didn't answer")),
            "ready" => Task.FromResult(new StoreUpdateInfo(1, false)),
            "mandatory" => Task.FromResult(new StoreUpdateInfo(1, true)),
            _ => Task.FromResult(new StoreUpdateInfo(0, false)),
        };

        public Task<StoreInstallOutcome> InstallAsync(CancellationToken cancel = default) => Task.FromResult(StoreInstallOutcome.Canceled);
    }

    /// <summary>
    /// <c>aifake</c>: answers AI requests as an OpenAI-compatible server would, without any network. "answer text" streams
    /// the text word by word (for every request: map-reduce parts get it too); "error401", "refused" and "missing" fail
    /// like a wrong key, a server that isn't running and an unknown model.
    /// </summary>
    private sealed class DevAiHandler(string spec) : System.Net.Http.HttpMessageHandler
    {
        protected override async Task<System.Net.Http.HttpResponseMessage> SendAsync(System.Net.Http.HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var mode = spec.Split(' ', 2);
            var json = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
            if (mode[0] == "refused")
                throw new System.Net.Http.HttpRequestException(System.Net.Http.HttpRequestError.ConnectionError, "No connection could be made",
                    new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.ConnectionRefused));
            if (request.RequestUri!.AbsolutePath == "/api/ps") // Ollama's own API: the model as loaded
                return new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK)
                {
                    Content = new System.Net.Http.StringContent("""{"models":[{"name":"llama3.2:latest","context_length":4096}]}""") { Headers = { ContentType = json } },
                };
            if (request.RequestUri.AbsolutePath.StartsWith("/api/", StringComparison.Ordinal))
                return new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.NotFound) { Content = new System.Net.Http.StringContent("{}") };
            if (request.RequestUri.AbsolutePath.EndsWith("/models", StringComparison.Ordinal))
                return new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK)
                {
                    Content = new System.Net.Http.StringContent("""{"object":"list","data":[{"id":"llama3.2:latest"},{"id":"qwen3:8b"},{"id":"gemma3:4b"}]}""") { Headers = { ContentType = json } },
                };
            if (mode[0] is "error401" or "missing")
                return new System.Net.Http.HttpResponseMessage(mode[0] == "missing" ? System.Net.HttpStatusCode.NotFound : System.Net.HttpStatusCode.Unauthorized)
                {
                    Content = new System.Net.Http.StringContent(mode[0] == "missing" ? """{"error":{"message":"model \"phi4\" not found, try pulling it first"}}""" : """{"error":{"message":"Incorrect API key provided"}}""")
                        { Headers = { ContentType = json } },
                };
            var text = (mode.Length > 1 ? mode[1] : "An answer.").Replace("\\n", "\n"); // a typed \n is a line break
            var sb = new System.Text.StringBuilder();
            foreach (var word in System.Text.RegularExpressions.Regex.Split(text, @"(?<=\s)"))
            {
                if (word.Length == 0) continue;
                sb.Append("data: ").Append(System.Text.Json.JsonSerializer.Serialize(new { choices = new[] { new { index = 0, delta = new { content = word } } } })).Append("\n\n");
            }
            sb.Append("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n");
            await Task.Delay(150, cancellationToken);
            return new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new System.Net.Http.StringContent(sb.ToString(), System.Text.Encoding.UTF8, "text/event-stream"),
            };
        }
    }
}
