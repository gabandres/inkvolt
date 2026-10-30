# Show HN

DRAFT: not posted. The owner reviews, then posts from their own HN account (a post from a fresh account sinks). Post
on a weekday between 8 and 10 am US Eastern; Tuesday to Thursday do best. Don't ask anyone to upvote. Stay in the
thread for the first three hours and answer every question plainly; the comments are the post.

## Title (80 characters at most)

Show HN: Inkvolt PDF – open-source PDF editor that checks redactions really removed text

(85 characters; if HN trims it, use: `Show HN: Inkvolt PDF – open-source PDF editor with a redaction check`)

## URL

https://github.com/gabandres/inkvolt

## Text

I'm a one-person shop and I built a PDF editor for Windows (and now a Mac version) because the free tiers of the
usual apps charge for the things I needed and the "free" ones collect usage data. Inkvolt PDF is AGPL, has no account,
no telemetry, no ads, and everything is free during the launch.

The two parts I think are technically interesting:

**The redaction check.** Redaction in most tools means "draw a black rectangle and remove the text under it". The
failures are elsewhere: the same name in the document's XMP, in a comment's appearance stream, in a form field, in an
attached file, in the incremental-update history, or in text that was recolored white instead of removed. After you
apply redactions, Inkvolt PDF re-renders each page without the covers and compares, draws every character individually
to find text hidden by color or covers, measures the gap beside a box to tell whether the text positions still leak the
removed width, opens every earlier version kept by incremental saves, decompresses every stream, and searches the raw
bytes. It also runs on PDFs redacted elsewhere, and "Fix" rewrites the file as one version and checks again. Code:
`pdf/src/InkvoltPdf.Core/Redaction/` (Windows) and `mac/InkvoltPdfKit/Sources/PdfCore/Redaction/` (Mac); the tests
plant a name in every place the check looks and assert it is found.

**What's in This PDF.** One report of everything a file carries besides its pages: every script with the external
calls it makes (open URL, submit form, launch, timers, eval), every address it can reach and whether it is reached
without a click, attachments (including inside zipped Office files), metadata of the document, pages, images and
fonts, signatures, earlier versions with the text they showed that the current one doesn't, hidden layers, white text,
form values. Nothing is executed or contacted; each row says whether Sanitize removes it. It exists because I wanted
to know what I was sending before I sent it.

Stack: .NET 10 + WPF on MuPDF (native x64 and ARM64), and a Swift app on the same MuPDF build for the Mac, so pages
render and export identically. OCR uses Windows' and macOS's built-in recognizers, so nothing leaves the machine. The
AI assistant is off by default and only talks to an endpoint you configure (Ollama, LM Studio, or your own key), and
shows the exact text before sending.

What it doesn't do, on purpose: send-for-signature workflows, cloud review, anything that needs a server of mine.

Windows: Microsoft Store (`winget install 9MXDTSFJ9W28`). Mac: notarized DMG on the releases page, or
`brew install --cask gabandres/inkvolt/inkvolt-pdf`. Site: https://bermudezsystems.com/products/inkvolt/

Happy to answer anything about MuPDF, the redaction heuristics, or shipping a WPF app through the Store.

## Likely questions, and the honest answers

- "Why AGPL?" MuPDF is AGPL; a commercial MuPDF licence is quoted per customer. The whole app, Pro features included,
  stays AGPL.
- "How will you make money?" A $19 one-time Pro for power features (saved redaction patterns, batch presets, PDF/UA
  output, LTV signatures, folder search), switched off during the launch; business licences by email. No ads, no data.
- "Does the redaction check guarantee anything?" No. It finds what covers, metadata, history and raw bytes give away.
  A cover that leaks a few pixels, or text rasterized into an image, is beyond it; the README's "Known limits" says so.
- "Linux?" Not planned; the code that isn't WPF or AppKit (the Core libraries) is portable, and PRs are welcome.
- "Why not the Mac App Store?" AGPL and the App Store's terms don't mix; it's a notarized DMG with Sparkle updates.
