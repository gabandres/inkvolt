# Press and newsletter pitches

DRAFT: not sent. Eight emails the owner sends from gabriel@bermudezsystems.com, one at a time, each to one person or
address; no mass mail, no "press release" attachment. Find the current tips address on each site's contact page
before sending (they change; none is written here from memory). Attach nothing: link the screenshots in the README
(`docs/screenshots/`) and the site. Subject lines are 60 characters or fewer. If a writer answers, reply the same day
and offer a 20-minute call or a written Q&A, their choice. One follow-up after a week, then stop.

Facts every pitch can use (all in the README): free; AGPL-3.0 (Print: MIT); no account, no ads, no telemetry; Windows
10/11 x64 and native ARM64 through the Microsoft Store; Mac (Apple silicon, macOS 15) as a notarized DMG and a
Homebrew cask; one developer, Bermudez Systems, Puerto Rico; the redaction check; What's in This PDF; OCR on the
machine; export to Word and Excel; Pro planned at a one-time $19, switched off during the launch.

---

## 1. gHacks (Martin Brinkmann)

Subject: Free, open-source PDF editor for Windows with a redaction check

Hi Martin,

I read gHacks for its software reviews, and I think Inkvolt PDF fits what you cover: a free, open-source PDF editor for
Windows that does what Acrobat Reader, Foxit and PDF-XChange charge for (edit text, organize and merge pages, export
to Word and Excel, OCR, create forms, compare, redact), with no account, no ads and no telemetry. It runs natively on
ARM64 as well as x64 and installs from the Microsoft Store.

The part I'd point you at first: after you redact, it checks the whole file for anything left of what you removed, in
metadata, comments, form fields, attachments, hidden layers and the earlier versions a PDF keeps when saved
incrementally. It also checks PDFs redacted in other apps. A second tool, What's in This PDF, lists every script,
address, attachment and hidden element a file carries before you share it.

I'm a one-person shop in Puerto Rico. Everything is free; a one-time $19 Pro for a few power features is planned and
switched off while it launches.

Store: https://apps.microsoft.com/detail/9MXDTSFJ9W28 · Source: https://github.com/gabandres/inkvolt ·
Comparison with the free tiers, from the vendors' own pages: https://bermudezsystems.com/products/inkvolt/compare/

Happy to answer anything, or to send a build of the Mac version.

Gabriel Bermudez
Bermudez Systems, Puerto Rico

---

## 2. How-To Geek

Subject: A free way to redact a PDF and check it's really gone

Hi,

How-To Geek has written about why black boxes don't redact PDFs. I built a free tool that does it properly and then
proves it: Inkvolt PDF removes the text and pictures under a redaction mark, then checks the file for anything left,
including other pages, comments, form fields, metadata, attachments and the earlier versions a PDF keeps. It also
checks PDFs redacted in other apps, and a Fix button cleans what it finds.

It's an open-source PDF editor for Windows (Microsoft Store, x64 and native ARM64) and Mac, with no account, no ads
and no telemetry, and everything else is free too: edit text, fill and sign, merge pages, PDF to Word, OCR on the PC.

A step-by-step with the menu names: https://bermudezsystems.com/products/inkvolt/redact-pdf/
Source: https://github.com/gabandres/inkvolt

I'm the one developer behind it and glad to answer questions.

Gabriel Bermudez
Bermudez Systems, Puerto Rico

---

## 3. MakeUseOf

Subject: Free Adobe Acrobat alternative that collects nothing (Windows, Mac)

Hi,

For your coverage of free Acrobat alternatives: Inkvolt PDF is free and open source, and does what Acrobat Reader
keeps for Standard and Pro: edit text, organize and merge pages, export to Word and Excel, OCR, create forms, compare
two versions, redact. No account, no ads, no usage data; documents are processed on the PC. Windows 10/11 (x64 and
native ARM64) from the Microsoft Store, and a native Mac app for Apple silicon.

Two things the others don't have at any price: a redaction check that finds text left in metadata, comments,
attachments and the file's earlier versions, and What's in This PDF, a report of every script, link and hidden element
a file carries before you share it.

Comparison table from the vendors' own pages: https://bermudezsystems.com/products/inkvolt/compare/
Source: https://github.com/gabandres/inkvolt

One developer, Puerto Rico. Happy to help with a review.

Gabriel Bermudez
Bermudez Systems

---

## 4. Windows Central

Subject: Native ARM64 PDF editor in the Microsoft Store, free and open source

Hi,

For Snapdragon PC readers: Inkvolt PDF is a free, open-source PDF editor that runs natively on Windows on ARM (and
x64), from the Microsoft Store. Acrobat still runs emulated there. It edits text, fills and signs, organizes and
merges pages, exports to Word and Excel, OCRs with Windows' own recognizer, creates forms, compares versions and
redacts, with a check afterwards that nothing of the redacted text is left anywhere in the file. No account, no ads,
no telemetry.

Its companion, Inkvolt Print, is a lean replacement for the printer makers' apps: live status, ink and toner, scan to
searchable PDF, copy, the print queue, for HP, Canon, Epson, Brother and any AirPrint or IPP Everywhere printer, with
no printer-maker account and no promotions.

Store: https://apps.microsoft.com/detail/9MXDTSFJ9W28 and https://apps.microsoft.com/detail/9PNR76HJ62SK
Source: https://github.com/gabandres/inkvolt

I'm the one developer, in Puerto Rico. Glad to answer anything.

Gabriel Bermudez
Bermudez Systems

---

## 5. MacStories

Subject: Native Mac PDF editor, open source, with a redaction check

Hi,

Inkvolt PDF for Mac is a native Swift app (Apple silicon, macOS 15) on the MuPDF engine, free and AGPL, with no
account and no telemetry. It reads in tabs, comments and draws, fills and signs, edits text and pictures, organizes
pages, OCRs with macOS's own text recognition, exports to Word and Excel, prints booklets and posters, scans from
AirScan scanners, and redacts with a check afterwards for anything left in the file (metadata, comments, attachments,
earlier versions). What's in This PDF lists every script, link and hidden element a file carries.

It's outside the Mac App Store because of MuPDF's licence: a notarized DMG that updates itself, or
`brew install --cask gabandres/inkvolt/inkvolt-pdf`. The Windows version came first and the Mac app is catching up
release by release; the site says exactly what is still missing.

Release: https://github.com/gabandres/inkvolt/releases/tag/pdf-mac-v1.2.0
Site: https://bermudezsystems.com/products/inkvolt/

One developer, Puerto Rico.

Gabriel Bermudez
Bermudez Systems

---

## 6. 9to5Mac

Subject: Free, open-source PDF editor for Apple silicon Macs (not an Electron app)

Hi,

Inkvolt PDF for Mac is a native Swift PDF editor for Apple silicon, free and open source, with no account and no
telemetry. Edit text, fill and sign, organize pages, OCR on the Mac, export to Word and Excel, redaction with a check
that nothing is left in the file, and a report of everything a PDF carries besides its pages (scripts, links,
attachments, earlier versions) before you share it.

Notarized DMG with its own updates, or Homebrew: `brew install --cask gabandres/inkvolt/inkvolt-pdf`.

Release: https://github.com/gabandres/inkvolt/releases/tag/pdf-mac-v1.2.0
Source: https://github.com/gabandres/inkvolt

I'm the one developer, in Puerto Rico, and glad to answer anything.

Gabriel Bermudez
Bermudez Systems

---

## 7. Privacy Guides forum (a post, not an email)

Post in the "Tool Suggestions" category, following the forum's template (name, description, link, why it fits the
criteria). Subject: Inkvolt PDF: open-source PDF editor, no account, no telemetry (Windows, Mac)

Inkvolt PDF is a free, AGPL-3.0 PDF editor for Windows (Microsoft Store, x64 and native ARM64) and Mac (Apple silicon,
notarized DMG or Homebrew). No account, no ads, no telemetry, no cloud service. Documents, OCR and export are processed
on the machine; the privacy policy lists the few network uses, each on the user's action (a timestamp server when
signing with a timestamp, a web page turned into a PDF, links clicked, and an AI endpoint only if the user connects
one and confirms each send).

Why it may fit: redaction that removes content and then checks the whole file (metadata, comments, form fields,
attachments, hidden layers, earlier versions) for anything left, also on PDFs redacted elsewhere; Sanitize Document;
and What's in This PDF, a report of every script, address, attachment and hidden element a file carries, without
running or contacting any of it.

Source: https://github.com/gabandres/inkvolt · Privacy policy: https://bermudezsystems.com/products/inkvolt/privacy/
Disclosure: I'm the developer.

---

## 8. Console.dev (open-source tools newsletter)

Console accepts submissions through the form on console.dev; this is the text for it.

Name: Inkvolt PDF
URL: https://github.com/gabandres/inkvolt
What it is: A free, AGPL PDF editor for Windows (.NET/WPF on MuPDF, native x64 and ARM64) and Mac (Swift on the same
MuPDF build). Edit text, forms, digital signatures, OCR with the OS recognizers, export to Word and Excel, PDF/A,
batch with watched folders and a CLI, a PDF/UA accessibility checker, and redaction with a check that re-renders pages,
opens every incremental version and searches the raw bytes for anything left. "What's in This PDF" statically lists
every script, action, external address, attachment and hidden element in a file. No account, no telemetry; the AI
assistant is off by default and only talks to an endpoint the user configures.
Why it's interesting to developers: the redaction check's tests plant a secret in every place a PDF can hide one;
the Mac port was written test-first from the .NET code, with the same test names; the whole app ships through the
Microsoft Store from a single `pack-msix.ps1`.
