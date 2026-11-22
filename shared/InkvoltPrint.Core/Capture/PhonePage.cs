using System.Net;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace InkvoltPrint.Core.Capture;

/// <summary>
/// The page a phone's browser opens from the QR code (roadmap 4.6): no app, no account, no outside address. Its camera button is
/// <c>input type=file accept=image/* capture=environment</c> (the back camera, one photo a tap), with a second to choose photos
/// already taken; each photo is turned upright and made at most <see cref="MaxSide"/> pixels a side by the browser (a canvas: a
/// smaller upload, and iPhone's HEIC sent as JPEG) and sent alone, in turn, with <see cref="PhoneSession.PageHeader"/>. Its text is
/// in the app's language; the PC's name is encoded; script and style carry the response's nonce (its CSP allows nothing else).
/// </summary>
public static class PhonePage
{
    /// <summary>The longest side the page sends (pixels): about 360 dpi for a Letter page filling the photo.</summary>
    public const int MaxSide = 4032;

    public static string Html(string pcName, string nonce)
    {
        var text = new Dictionary<string, string>
        {
            ["sending"] = CoreStrings.Phone_Sending,
            ["sent"] = CoreStrings.Phone_Sent,
            ["failed"] = CoreStrings.Phone_PageFailed,
            ["notAPhoto"] = CoreStrings.Phone_NotAPhoto,
            ["tooBig"] = CoreStrings.Phone_TooBig,
            ["tooMany"] = CoreStrings.Phone_TooMany,
            ["lost"] = CoreStrings.Phone_Lost,
            ["used"] = CoreStrings.Phone_Used,
            ["ended"] = CoreStrings.Phone_Ended,
            ["finishedOne"] = CoreStrings.Phone_Finished_One,
            ["finishedMany"] = CoreStrings.Phone_Finished_Many,
        };
        // Default JavaScriptEncoder escapes <, >, &, quotes and non-ASCII: safe inside a script element.
        var json = JsonSerializer.Serialize(text, new JsonSerializerOptions { Encoder = JavaScriptEncoder.Default });
        var lang = CoreStrings.Culture?.TwoLetterISOLanguageName ?? "en";
        string H(string s) => WebUtility.HtmlEncode(s);
        return $$"""
            <!doctype html>
            <html lang="{{H(lang)}}">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="no-referrer">
            <title>Inkvolt Print</title>
            <style nonce="{{nonce}}">
            :root { color-scheme: light dark; --bg: #f6f6f8; --fg: #1b1b1f; --muted: #5d5d66; --card: #fff; --accent: #2b5fd9; --bad: #b3261e; }
            @media (prefers-color-scheme: dark) { :root { --bg: #17171a; --fg: #ececf1; --muted: #a4a4ad; --card: #232328; --accent: #8fb0ff; --bad: #ffb4ab; } }
            body { margin: 0; padding: 20px 16px 40px; font: 17px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--fg); }
            main { max-width: 480px; margin: 0 auto; }
            h1 { font-size: 22px; margin: 0 0 6px; }
            p { margin: 0 0 16px; color: var(--muted); }
            label.button, button { display: block; width: 100%; box-sizing: border-box; text-align: center; padding: 16px; margin: 0 0 12px; border-radius: 12px;
              font: inherit; font-weight: 600; border: 0; cursor: pointer; }
            label.primary { background: var(--accent); color: #fff; }
            @media (prefers-color-scheme: dark) { label.primary { color: #10131c; } }
            label.secondary, button { background: var(--card); color: var(--fg); border: 1px solid #8884; }
            input[type=file] { position: absolute; width: 1px; height: 1px; opacity: 0; }
            ol { padding-left: 22px; margin: 16px 0; }
            li.bad { color: var(--bad); }
            #state { font-weight: 600; color: var(--fg); }
            p.small { font-size: 14px; }
            .off { opacity: .45; pointer-events: none; }
            </style>
            </head>
            <body>
            <main>
            <h1>{{H(string.Format(CoreStrings.Phone_Heading, pcName))}}</h1>
            <p>{{H(CoreStrings.Phone_Tip)}}</p>
            <p class="small">{{H(string.Format(CoreStrings.Phone_CertExpected, pcName))}}</p>
            <div id="controls">
            <label class="button primary" for="take">{{H(CoreStrings.Phone_Take)}}</label>
            <input id="take" type="file" accept="image/*" capture="environment">
            <label class="button secondary" for="choose">{{H(CoreStrings.Phone_Choose)}}</label>
            <input id="choose" type="file" accept="image/jpeg,image/png,image/*" multiple>
            <button id="done" type="button">{{H(CoreStrings.Phone_Done)}}</button>
            </div>
            <p id="state" role="status" aria-live="polite"></p>
            <ol id="pages"></ol>
            <noscript><p>{{H(CoreStrings.Phone_NoScript)}}</p></noscript>
            </main>
            <script nonce="{{nonce}}">
            (() => {
              const T = {{json}};
              const base = location.pathname;
              const H = { "{{PhoneSession.PageHeader}}": "1" };
              const state = document.getElementById("state"), list = document.getElementById("pages"), controls = document.getElementById("controls");
              const queue = []; let busy = false, sent = 0, closed = false;
              const f = (s, ...a) => s.replace(/\{(\d)\}/g, (_, i) => a[i]);
              const say = s => { state.textContent = s; };
              function end(s) { closed = true; controls.classList.add("off"); say(s); }
              function reason(status) {
                return status === 415 ? T.notAPhoto : status === 413 ? T.tooBig : status === 429 ? T.tooMany : status === 410 ? T.ended : status === 403 ? T.used : T.lost;
              }
              async function post(path, body) {
                return fetch(base + path, { method: "POST", headers: H, body, credentials: "same-origin", cache: "no-store" });
              }
              async function shrink(file) {
                try {
                  const bmp = await createImageBitmap(file, { imageOrientation: "from-image" });
                  const s = Math.min(1, {{MaxSide}} / Math.max(bmp.width, bmp.height));
                  const c = document.createElement("canvas");
                  c.width = Math.max(1, Math.round(bmp.width * s)); c.height = Math.max(1, Math.round(bmp.height * s));
                  c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
                  bmp.close();
                  const blob = await new Promise(r => c.toBlob(r, "image/jpeg", 0.92));
                  return blob || file;
                } catch (e) { return file; }
              }
              async function next() {
                if (busy || closed) return;
                const item = queue.shift(); if (!item) return;
                busy = true;
                const n = sent + 1; item.li.textContent = f(T.sending, n); say(item.li.textContent);
                try {
                  const r = await post("/photo", await shrink(item.file));
                  if (r.ok) { sent = n; item.li.textContent = f(T.sent, n); say(item.li.textContent); }
                  else if (r.status === 429 && r.headers.get("Retry-After")) { queue.unshift(item); busy = false; setTimeout(next, 2000); return; }
                  else { item.li.className = "bad"; item.li.textContent = f(T.failed, n, reason(r.status)); say(item.li.textContent); if (r.status === 403 || r.status === 410) end(reason(r.status)); }
                } catch (e) { item.li.className = "bad"; item.li.textContent = f(T.failed, n, T.lost); say(item.li.textContent); }
                busy = false; next();
              }
              function add(files) {
                for (const file of files) { const li = document.createElement("li"); list.appendChild(li); queue.push({ file, li }); }
                next();
              }
              for (const id of ["take", "choose"]) {
                const input = document.getElementById(id);
                input.addEventListener("change", () => { add(Array.from(input.files || [])); input.value = ""; });
              }
              document.getElementById("done").addEventListener("click", async () => {
                while (!closed && (busy || queue.length)) await new Promise(r => setTimeout(r, 300));
                if (closed) return;
                try { const r = await post("/done"); end(r.ok ? (sent === 1 ? T.finishedOne : f(T.finishedMany, sent)) : reason(r.status)); }
                catch (e) { say(T.lost); }
              });
              post("/pair").then(r => { if (!r.ok) end(reason(r.status)); }, () => end(T.lost));
            })();
            </script>
            </body>
            </html>
            """;
    }
}
