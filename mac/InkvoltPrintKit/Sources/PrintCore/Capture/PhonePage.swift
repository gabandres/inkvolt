import Foundation

/// The page a phone's browser opens from the QR code (roadmap 4.6; the Windows Core's `PhonePage`): no app, no account, no
/// outside address. Its camera button is `input type=file accept=image/* capture=environment` (the back camera, one photo a
/// tap), with a second to choose photos already taken; each photo is turned upright and made at most `maxSide` pixels a side
/// by the browser (a canvas: a smaller upload, and iPhone's HEIC sent as JPEG) and sent alone, in turn, with
/// `PhoneSession.pageHeader`. Its text is in the app's language; the Mac's name is encoded; script and style carry the
/// response's nonce (its CSP allows nothing else).
public enum PhonePage {
    /// The longest side the page sends (pixels): about 360 dpi for a Letter page filling the photo.
    public static let maxSide = 4032

    public static func html(_ macName: String, nonce: String) -> String {
        let text: KeyValuePairs<String, String> = [
            "sending": loc("Sending page {0}…"),
            "sent": loc("Page {0} is on the Mac."),
            "failed": loc("Page {0} didn't arrive. {1}"),
            "notAPhoto": loc("It isn't a JPEG or PNG photo."),
            "tooBig": loc("The photo is too large."),
            "tooMany": loc("That's the most pages one scan takes: tap Done, then start a new scan on the Mac."),
            "lost": loc("The Mac can't be reached. Check that the phone is on the same Wi-Fi as the Mac."),
            "used": loc("Another phone already used this code. On the Mac, scan with your phone again for a new code."),
            "ended": loc("This scan has ended on the Mac. Start a new one there for a new code."),
            "finishedOne": loc("Done: 1 page sent. You can close this page."),
            "finishedMany": loc("Done: {0} pages sent. You can close this page."),
        ]
        let json = "{" + text.map { "\"\($0.key)\":\(script($0.value))" }.joined(separator: ",") + "}"
        let lang = html(CoreLanguage.page.language)
        let page = """
            <!doctype html>
            <html lang="\(lang)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="no-referrer">
            <title>Inkvolt Print</title>
            <style nonce="\(nonce)">
            \(style)
            </style>
            </head>
            <body>
            <main>
            <h1>\(html(loc("Scan to {0}", macName)))</h1>
            <p>\(html(loc("Lay the page on a darker table and hold the phone above it so the page fills most of the screen. One photo per page: each shows up on the Mac as you go.")))</p>
            <p class="small">\(html(loc("The warning before this page was expected: {0} made its own certificate for it.", macName)))</p>
            <div id="controls">
            <label class="button primary" for="take">\(html(loc("Take a photo of a page")))</label>
            <input id="take" type="file" accept="image/*" capture="environment">
            <label class="button secondary" for="choose">\(html(loc("Choose photos")))</label>
            <input id="choose" type="file" accept="image/jpeg,image/png,image/*" multiple>
            <button id="done" type="button">\(html(loc("Done", context: "phone page")))</button>
            </div>
            <p id="state" role="status" aria-live="polite"></p>
            <ol id="pages"></ol>
            <noscript><p>\(html(loc("This page needs JavaScript to send photos.")))</p></noscript>
            </main>
            <script nonce="\(nonce)">
            (() => {
              const T = \(json);
              const H = { "\(PhoneSession.pageHeader)": "1" };
            \(code)
            })();
            </script>
            </body>
            </html>
            """
        return page
    }

    /// Text for an HTML element's content or a quoted attribute.
    static func html(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// A JavaScript string literal safe inside a script element: quotes, backslashes, `<`, `>`, `&`, controls and everything
    /// past ASCII as `\uXXXX` (what .NET's `JavaScriptEncoder.Default` does).
    static func script(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            let safe = unit >= 0x20 && unit < 0x7F && unit != 0x22 && unit != 0x5C && unit != 0x3C && unit != 0x3E && unit != 0x26 && unit != 0x27
            if safe {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                out += String(format: "\\u%04X", unit)
            }
        }
        return out + "\""
    }

    private static let style = """
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
        """

    /// Windows' script, line for line.
    private static let code = """
          const base = location.pathname;
          const state = document.getElementById("state"), list = document.getElementById("pages"), controls = document.getElementById("controls");
          const queue = []; let busy = false, sent = 0, closed = false;
          const f = (s, ...a) => s.replace(/\\{(\\d)\\}/g, (_, i) => a[i]);
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
              const s = Math.min(1, \(maxSide) / Math.max(bmp.width, bmp.height));
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
        """
}
