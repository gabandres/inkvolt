# Product Hunt launch kit

DRAFT: not posted. Product Hunt launches go live at 12:01 am Pacific; schedule for a Tuesday, Wednesday or Thursday,
and have the first comment ready to post the minute it is live. The maker account is the owner's. No upvote asks in
DMs or groups (Product Hunt penalizes them); tell people who already use Inkvolt, once, where to find the page.

## Name

Inkvolt PDF

## Tagline (60 characters at most)

Free, open-source PDF editor. No account, no telemetry.

(54 characters. Alternate: `Edit, sign, redact and OCR PDFs. Free, open source, offline.` 59.)

## Topics

Productivity · Open Source · Privacy · Windows · Mac

## Description (260 characters at most)

Inkvolt PDF edits text, fills and signs forms, merges and organizes pages, exports to Word, OCRs scans and redacts for
real, with a check that nothing is left. Free, AGPL, no account, no ads, no telemetry. Windows (x64, ARM64) and Mac.

(259 characters.)

## Links

- Website: https://bermudezsystems.com/products/inkvolt/
- Windows: https://apps.microsoft.com/detail/9MXDTSFJ9W28
- Mac: https://github.com/gabandres/inkvolt/releases/tag/pdf-mac-v1.2.0
- Source: https://github.com/gabandres/inkvolt
- Pricing: Free (the Pro page says what a one-time $19 will unlock later: https://bermudezsystems.com/products/inkvolt/pro/)

## Gallery (in this order; 1270×760 or larger, PNG or JPG)

1. `docs/screenshots/pdf-reading.jpg`: two-page view with thumbnails (the first image is the one people see in the feed).
2. `docs/screenshots/pdf-fill-sign.png`: the W-9 filled and signed.
3. A screenshot of the redaction check report after redacting a name that was also in the metadata (take it with the
   dev script: `pdf/src/InkvoltPdf.App/DevScript.cs`, `redaction-check-sample.pdf` from `RedactionCheckTests`).
4. A screenshot of What's in This PDF on a file with a script and an attachment.
5. `docs/screenshots/pdf-dark.png`: dark theme.
6. The Mac app on the same document (ask the owner for one from the Mac; `screencapture` doesn't work over SSH).

Optional: a 30-second screen recording of redact → apply → check → report (no narration needed).

## First comment (the maker's)

Hi, I'm Gabriel, the one person behind Inkvolt.

I built Inkvolt PDF because I kept paying for one PDF feature at a time (export to Word here, OCR there, redaction only
in the top tier) and the free apps that did it all were collecting usage data. So: everything is free, there's no
account, no ads and no telemetry, and the source is on GitHub under the AGPL.

Two things I'm proud of:

- After you redact, Inkvolt PDF checks the whole file for anything left of what you removed: under the boxes, in
  comments, form fields, bookmarks, metadata, attachments, hidden layers, and in earlier versions the file still
  carries. It can check files redacted in other apps too.
- "What's in This PDF" lists every script, address, attachment, earlier version and hidden element a file carries,
  and whether Sanitize removes it, before you share it.

It's a native Windows app for Windows 10 and 11 (x64 and ARM64) on the MuPDF engine, and there's a Mac version on the same engine that is
catching up release by release. OCR runs on your machine with the OS's own recognizer. If you want an AI assistant you
connect your own (Ollama, LM Studio, or a service with your key); nothing is sent until you see the text and confirm.

What it won't do: anything that needs a server of mine, so no send-for-signature or cloud review.

A Pro tier for a few power features (saved redaction patterns, batch presets, PDF/UA output) is planned at a one-time
$19 and is switched off while we launch. Everything free today stays free.

I'd love to hear what you redact, export or sign most, and what's missing. I'll be here all day.

## Replies to have ready

- "Linux?" Not planned; the Core libraries are portable and PRs are welcome.
- "iOS/Android?" There's an Inkvolt app for iPhone, iPad and Android (free, not open source): App Store and Google Play
  links on the website.
- "Why the Microsoft Store?" Signed, updated, no installer to trust; `winget install 9MXDTSFJ9W28` works too. There's
  also an unpackaged install script in the repo.
- "Why not the Mac App Store?" MuPDF's AGPL and the App Store's terms don't mix; it's a notarized DMG with Sparkle
  updates, also on Homebrew: `brew install --cask gabandres/inkvolt/inkvolt-pdf`.
