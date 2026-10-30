# Reddit, one subreddit at a time

DRAFT: not posted. Rules read from each subreddit's sidebar on 2026-10-30; read them again on the day, they change.
Post from the owner's own account, one subreddit a day at most, never the same text twice (Reddit's spam filter and
every mod team catch cross-posts). Say "I made this" in the first line of every post and comment. Stay in the thread
for two hours and answer every comment. Times are US Eastern; weekday mornings (8–11 am) reach the US and Europe both.

**AI-assisted development.** Inkvolt is written with Claude Code. r/degoogle (rule 12) requires saying so, r/opensource
(rule 3) removes AI-generated *posts*, and Softpedia refused the app for it. Write each post in your own words from
these drafts, and if someone asks, answer plainly: you design, review and test every change; an AI writes much of the
code. Hiding it costs more than saying it.

| Subreddit | Can we post the app? | Where and when | Notes |
|---|---|---|---|
| r/software | Yes: open source is allowed any day; Wednesday is the safe day for self-promotion (rule 3) | A post, Wednesday 9–11 am, the Release flair | Rule 5: new programs or big updates, not every version. Hidden karma threshold (rule 6) |
| r/opensource | Yes, with the Promotional flair; the repo needs an OSI licence (AGPL-3.0 is) | A post, Tuesday–Thursday 9–11 am | No drive-by: stay and discuss (rule 6). Rule 3 removes AI-written posts |
| r/macapps | Only in the monthly megathread until the account qualifies (rule 8; 10 r/MacApps karma first, rule 1) | The current Megathread, any weekday morning | Title prefix `[OS]`, Free flair, download link from the official source (the GitHub release, rule 2); once per developer per 30 days (rule 3) |
| r/Windows11 | Only in the weekly "Software Showoff Sunday" thread (rule 7) | That thread, Sunday morning | A standalone post is removed |
| r/degoogle | Only in the pinned Degoogle Showcase megathread (rule 3) | That thread, any weekday | Prefix the comment `[DEV]`; disclose AI-written code (rule 12); no x.com links (rule 8) |
| r/pdf | No standalone post; free or open-source tools may be named in answers that directly help (rule 3) | Answer questions about redaction, filling forms, PDF to Word, as they come | Disclose "I made it" every time; never paste the same comment twice (rule 1) |
| r/privacy | No: self-promotion is banned (rule 3) and app posts, open source included, are on hold (rule 13) | Don't post. Comment only where a thread asks how to check a PDF for hidden data, and link the guide, not the store | |
| r/printers | No ads at all (rule 4); sharing a site uses the sidebar's template | Read the sidebar template first; better to answer "printer offline / ink level" questions with what Inkvolt Print does | Account must be 24 hours old (rule 5); AI-generated text discouraged (rule 7) |

---

## r/software (Wednesday, Release flair)

**Title:** I made Inkvolt PDF, a free and open-source PDF editor for Windows and Mac (no account, no telemetry)

I've been building a PDF editor because the free tiers of the usual apps charge for one thing at a time (export to
Word here, OCR there, redaction only in the top tier) and the free all-in-one apps collect usage data.

Inkvolt PDF edits text and images on the page, fills and signs forms, organizes and merges pages, exports to Word and
Excel, runs OCR with the OS's own recognizer (nothing leaves the PC), compares two versions, and redacts. After you
redact it checks the whole file for anything left of what you removed: metadata, comments, form fields, attachments,
hidden layers and the earlier versions a PDF keeps. "What's in This PDF" lists every script, link, attachment and
hidden element a file carries before you send it.

- Windows 10/11, x64 and ARM64: Microsoft Store (`winget install 9MXDTSFJ9W28`)
- Mac (Apple silicon, macOS 15): notarized DMG on GitHub, or `brew install --cask gabandres/inkvolt/inkvolt-pdf`.
  The Mac app is behind Windows; the README lists what's there.
- Source (AGPL-3.0): https://github.com/gabandres/inkvolt

Everything is free. A one-time $19 Pro for a few power features is planned and switched off for now. Tell me what's
missing; that's the list I work from.

---

## r/opensource (Promotional flair)

**Title:** Inkvolt PDF: an AGPL PDF editor for Windows and Mac on MuPDF, with a redaction check

I made this and I'd like feedback from people who read code. Inkvolt PDF is a desktop PDF editor (.NET/WPF on Windows,
Swift on the Mac, both on the same MuPDF build), AGPL-3.0 because MuPDF is.

The part I'd most like reviewed is the redaction check: after redactions are applied it renders each page without
the covers and compares, draws each character on its own to find text hidden by color or covers, opens every earlier
version kept by incremental saves, decompresses every stream and searches the raw bytes. It also runs on files redacted
in other apps. The README's "Known limits" section says what it can't find.

No account, no telemetry, no ads; OCR on the machine; an optional AI assistant that only talks to an endpoint you
configure and shows the text before sending.

Repo: https://github.com/gabandres/inkvolt · Issues and PRs welcome, especially for the Mac app and Linux (the Core
libraries are portable; the UI isn't).

---

## r/macapps (the monthly Megathread; as a post only once the account qualifies)

**Title (if posting):** [OS] Inkvolt PDF: free, open-source PDF editor with redaction and a check that it worked

I made this. Inkvolt PDF for Mac is a native Swift app (Apple silicon, macOS 15) on MuPDF: read, annotate, fill forms,
organize pages, OCR with Apple's text recognition, redact with a check of the whole file afterwards, Sanitize, and What's in This
PDF. It's AGPL, notarized, updates through Sparkle, and has no account or telemetry.

It's a port of the Windows app and doesn't have everything yet (no signing, compare or batch on the Mac so far);
the README lists what's there.

Download (official): https://github.com/gabandres/inkvolt/releases/tag/pdf-mac-v1.2.0 · Homebrew:
`brew install --cask gabandres/inkvolt/inkvolt-pdf` · Free, no in-app purchase.

---

## r/Windows11 (Software Showoff Sunday thread)

Inkvolt PDF (I made it): a free, open-source PDF editor built for Windows 11 (WPF, Mica, native ARM64 as well as x64).
Edit text, fill and sign, merge and organize pages, PDF to Word/Excel, OCR with Windows' own recognizer, redaction with
a check that nothing was left. No account, no ads, no telemetry. Microsoft Store: https://apps.microsoft.com/detail/9MXDTSFJ9W28
· Source: https://github.com/gabandres/inkvolt

Also mine, for printers: Inkvolt Print (ink and toner levels, the print queue, scanning to PDF, fixing a printer that
shows offline), free and MIT: https://apps.microsoft.com/detail/9PNR76HJ62SK

---

## r/degoogle (Degoogle Showcase megathread)

[DEV] I made Inkvolt PDF, a free AGPL PDF editor for Windows and Mac that never needs an account or a cloud: OCR runs
on your machine with the OS recognizer, no telemetry, no ads, and the optional AI assistant only talks to a local or
self-chosen endpoint. A replacement for Google Drive's PDF viewer and the "upload your PDF" sites when you need to
fill, sign, merge, convert or redact. Disclosure per rule 12: much of the code is written with an AI coding assistant;
I design, review and test it. https://github.com/gabandres/inkvolt

---

## r/pdf (answers only, when a question fits)

Template for a thread asking how to redact properly:

> Disclosure: I made the app I mention. Drawing a black box isn't redaction; the text is still under it. Whatever app
> you use, apply the redaction (it should delete the text and image pixels underneath), then check the file:
> search for the word, copy-paste from under the box, look at File › Properties and any attachments. Inkvolt PDF
> (free, open source) has a check that does that across the whole file, including earlier saved versions:
> https://bermudezsystems.com/products/inkvolt/redact-pdf/

Write each answer for the question in front of you; never paste this twice.

---

## r/printers (answers only)

Template for "printer says offline" on Windows:

> Disclosure: I made a free tool for this. First check the printer's IP hasn't changed (print a network config page)
> and that the Windows port points at that IP. Inkvolt Print (free, MIT, Microsoft Store) finds the printer on the
> network and re-points the queue for you, and shows ink levels without the maker's app:
> https://apps.microsoft.com/detail/9PNR76HJ62SK

## r/privacy

Don't post (rules 3 and 13). If a thread asks how to see what a PDF carries before sending it, a link to
https://bermudezsystems.com/products/inkvolt/whats-in-a-pdf/ with "I made this" is the most that fits, and only once.
