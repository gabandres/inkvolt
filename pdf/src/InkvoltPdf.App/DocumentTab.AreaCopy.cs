using System.IO;
using System.Windows;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Copy Text from Area and Copy Area as Table (roadmap 4.6): the box drawn with Snapshot, its words from the page's text or,
/// on a scan, read by the recognizer Recognize Text uses (<see cref="AreaCopy"/>), to the clipboard as text, or as
/// tab-separated text and HTML so a spreadsheet pastes cells.
/// </summary>
public partial class DocumentTab
{
    private bool _copyingArea;

    /// <summary>A page view's Snapshot boxes: the toast after a picture offers its text; a box drawn for words copies them.</summary>
    private void WatchSnapshots(PageViewer view)
    {
        view.SnapshotCopied += (_, message) => Notify(message, Strings.Area_CopyTextAction, () => _ = CopyAreaAsync(AreaCopyKind.Text));
        view.SnapshotForWords += (_, e) => _ = CopyAreaAsync(e.Kind, e.Page, e.Area);
    }

    /// <summary>The Snapshot box shown, copied as <paramref name="kind"/> says; with none, Snapshot is chosen to draw one.</summary>
    public async Task CopyAreaAsync(AreaCopyKind kind)
    {
        var view = ActiveView;
        if (view.SnapshotArea is { } shown)
        {
            await CopyAreaAsync(kind, shown.Page, shown.Area);
            return;
        }
        view.Tool = ViewerTool.Snapshot;
        view.SnapshotCopies = kind;
        Notify(kind == AreaCopyKind.Table ? Strings.Area_BoxTable : Strings.Area_BoxText);
    }

    private async Task CopyAreaAsync(AreaCopyKind kind, int page, RectD area)
    {
        if (_copyingArea || _disposed || page < 0 || page >= Session.Engine.PageCount) return;
        _copyingArea = true;
        try
        {
            var engine = Session.Engine;
            // An edit meanwhile retires this engine and may move the page: what was boxed is gone, and that is said.
            bool Changed()
            {
                if (!_disposed && ReferenceEquals(engine, Session.Engine)) return false;
                if (!_disposed) Notify(Strings.Viewer_SnapshotChanged, error: true);
                return true;
            }
            var read = await Task.Run(() => engine.GetExportPage(page, images: false));
            if (Changed()) return;
            var clipped = AreaCopy.Clip(read, area);
            var recognized = false;
            if (!clipped.HasText)
            {
                // A scan: read the box as Recognize Text would (its language; offered for download first when needed).
                var ocr = await PageOcr.ReadyAsync(Window.GetWindow(this));
                if (ocr is null || Changed()) return;
                Notify(Strings.Area_Reading);
                var words = await Task.Run(() => AreaCopy.Recognize(engine, page, area, ocr));
                if (Changed()) return;
                clipped = AreaCopy.FromWords(read, words);
                recognized = true;
            }

            var data = new DataObject();
            string done;
            if (kind == AreaCopyKind.Table)
            {
                var table = AreaCopy.Table(clipped);
                if (table.IsEmpty)
                {
                    Notify(Strings.Area_NoText);
                    return;
                }
                data.SetData(DataFormats.UnicodeText, table.Tsv());
                data.SetData(DataFormats.Html, new MemoryStream(ClipboardHtml.Wrap(table.Html())));
                done = Loc.Format(Strings.Area_TableCopied, table.Rows.Count, table.ColumnCount);
            }
            else
            {
                var text = AreaCopy.Text(clipped);
                if (text.Length == 0)
                {
                    Notify(Strings.Area_NoText);
                    return;
                }
                data.SetData(DataFormats.UnicodeText, text);
                var count = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
                done = recognized ? Loc.Plural(count, Strings.Area_TextRead_One, Strings.Area_TextRead_Many)
                    : Loc.Plural(count, Strings.Area_TextCopied_One, Strings.Area_TextCopied_Many);
            }
            try
            {
                Clipboard.SetDataObject(data, copy: true);
                Notify(done);
            }
            catch (System.Runtime.InteropServices.COMException ex)
            {
                Notify(Loc.Format(Strings.Viewer_CopyFailed, ex.Message), error: true);
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // Run from a click without anyone awaiting it: whatever stops it (the engine retired by an edit, the recognizer,
            // a damaged page) is logged and said, never left as "Reading…".
            Log.Write($"Copy from an area failed: {ex.GetType().Name}: {ex.Message}");
            if (!_disposed) Notify(Strings.Area_CouldntRead, error: true);
        }
        finally
        {
            _copyingArea = false;
        }
    }
}
