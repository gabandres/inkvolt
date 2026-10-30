# Visibility log

Where Inkvolt is listed, what was submitted, and what comes next. One row per channel; newest state wins. Decisions
that hold: no paid code signing (so no winget community manifest, Scoop or Chocolatey: the Store IDs install through
`winget install <StoreId>` already), no ads, no telemetry, nothing paid for placement. Pro is $19 one-time and switched
off during the launch; business licences by email.

## Baseline (2026-10-30)

| Measure | Inkvolt PDF | Inkvolt Print | Where |
|---|---|---|---|
| Store page views, last month | 6 | 9 | Partner Center › Insights › Acquisitions |
| Store installs, last month | 3 | 7 | same |
| Conversion | 50% | 77.8% | same |
| Ratings | 1 (five stars), no written review | none | Partner Center › Insights › Ratings & reviews |
| GitHub stars / forks / watchers | 0 / 0 / 0 | | `gh api repos/gabandres/inkvolt` |
| Mac DMG downloads | 1.2.0: 5 · 1.1.0: 2 · 1.0.0: 4 | | `gh api repos/gabandres/inkvolt/releases` (the owner's own test downloads are in these) |

Both apps have been in the Store since 2026-10-25, so "last month" is their whole life. Re-read these the same way in
30 days (`docs/visibility/` has nothing automated; Partner Center needs the signed-in browser).

## Channels

| Channel | Date | URL | Status | What's next |
|---|---|---|---|---|
| GitHub repo description and topics | 2026-10-29 | https://github.com/gabandres/inkvolt | Live (20 topics) | Set the social preview image in the repo settings (a page only the owner can open) |
| README screenshots and comparison table | 2026-10-29 | https://github.com/gabandres/inkvolt#how-inkvolt-compares | Live | |
| Website comparison page | 2026-10-29 | https://bermudezsystems.com/products/inkvolt/compare/ | Live | |
| AlternativeTo: Inkvolt PDF | 2026-10-29 | https://alternativeto.net/software/inkvolt-pdf/about/ | Live (2026-10-30: Free, AGPL-3.0, Windows and Mac, 34 alternatives linked) | Add Inkvolt Print as its own app (needs the owner's AlternativeTo sign-in; Cloudflare blocks the check without a browser session) |
| awesome-free-apps | 2026-10-29 | PRs #458, #459 | Open | |
| thechampagne/awesome-windows | 2026-10-29 | PRs #125, #126 | Open | |
| awesome-foss-alternatives | 2026-10-29 | PR #84 | Open | |
| pluja/awesome-privacy | 2026-10-29 | PR #1256 | Open | |
| open-source-mac-os-apps | 2026-10-29 | PR #1864 | Open | |
| jaywcjlove/awesome-mac | 2026-10-29 | PR #4045 | Open | |
| Homebrew tap | 2026-10-30 | https://github.com/gabandres/homebrew-inkvolt | Live: `brew install --cask gabandres/inkvolt/inkvolt-pdf` (installed, audited and uninstalled on the owner's Mac) | Bump `version` and `sha256` with each Mac release (`release.sh` could do it). homebrew-cask itself needs 225 stars, 90 forks or 90 watchers for a self-submission (75/30/30 when someone else submits) and a repository older than 30 days: not yet |
| Website: Pro page and six guides | 2026-10-30 | /products/inkvolt/pro/, /redact-pdf/, /pdf-to-word/, /fill-and-sign/, /acrobat-alternative/, /pdfgear-alternative/, /whats-in-a-pdf/ | Live, all 200 (deployed; portfolio 86921ff pushed; IndexNow 200). See "Website" below | |
| SaaSHub | 2026-10-30 | https://www.saashub.com/inkvolt-pdf (live once approved) | Submitted, free queue (1–12 weeks); categories PDF Editor, PDF Tools, PDF Readers And Editors, Document Management; competitors PDFgear, PDF-XChange Editor, Okular, Adobe Acrobat DC, Foxit Reader; contact gabriel@bermudezsystems.com | Register at saashub.com with that address to claim and verify it (verification needs an address on bermudezsystems.com: it has one); add the logo and Mac screenshots |
| MacUpdate | 2026-10-30 | https://www.macupdate.com/content/submit | Account created for gabriel@bermudezsystems.com (password in `~/.inkvolt-visibility/accounts.txt`); verification mail sent, not yet clicked | Click the verification link, sign in, Add App: Inkvolt PDF 1.2.0, the GitHub release DMG as the download, Free, macOS 15, Apple silicon |
| Softpedia | 2026-10-30 | https://www.softpedia.com/user/submit.shtml | Not submitted: the form requires ticking "No AI-written code", and Inkvolt is written with Claude Code | None, unless Softpedia changes the rule. Don't tick it |
| FileHorse | 2026-10-30 | https://www.filehorse.com/submit/ | Not submitted: requests go through a contact form behind reCAPTCHA | The owner sends the contact form (text below, "Directory texts") |
| OpenAlternative | 2026-10-30 | https://openalternative.co/submit | Not submitted: submitting needs a sign-in (an email magic link, Google or GitHub); the Gmail connector isn't authorized in these sessions and the browser has no GitHub sign-in | The owner signs in with GitHub and submits https://github.com/gabandres/inkvolt (free queue; the paid options aren't for us) |
| Slant | 2026-10-30 | https://www.slant.co/ | Not submitted: the site answered Cloudflare 526 (its certificate broken) all session | Try again; add Inkvolt PDF as an option to "best PDF editors" and the Acrobat-alternatives question (needs a Slant sign-in) |
| Uptodown | 2026-10-30 | | Skipped: it hosts the installer itself, and the Windows apps are Store-only (no binary of ours to give it; never a repackaged one) | Revisit if a signed installer ever exists |
| Social kit | 2026-10-30 | `docs/visibility/` | Drafts, none posted: show-hn.md, reddit.md (8 subreddits with their rules), product-hunt.md, one-liners.md, press-pitches.md (8) | See "Next 30 days" |

## Website (2026-10-30)

New under https://bermudezsystems.com/products/inkvolt/: `pro/` (what stays free, what Pro unlocks, how a licence
works, business licences) and six guides written for the searches people make: `redact-pdf/`, `pdf-to-word/`,
`fill-and-sign/`, `acrobat-alternative/`, `pdfgear-alternative/`, `whats-in-a-pdf/`. Each has the site's shell, a
how-to with the real menu names from `pdf/README.md`, a Questions section with the same text as its FAQPage JSON-LD,
Article and BreadcrumbList JSON-LD, Open Graph and Twitter cards (the existing suite image; a dedicated 1200×630 per
page is a next step), and a canonical address. The product page gained a Guides section, a link to Pro in "Is it
really free?", `softwareVersion` in the SoftwareApplication JSON-LD (1.2.1, 1.0.8), the brew line on the Mac card and
under Requirements, and a corrected "not on the Mac yet" note (redaction, Sanitize and What's in This PDF arrived in
1.1 and 1.2). No `aggregateRating`: one five-star rating isn't a rating to show. Sitemap, cache-bust page list and the
no-cache regex in `firebase.json` include the new pages. The pages are generated from fragments by a script outside the
repo (`~/.inkvolt-visibility/gen-pages.mjs`), so the inline theme script stays byte-identical to the CSP hash; the
generated HTML is what's committed.

No GitHub Sponsors link: github.com/sponsors/gabandres has no listing. If the owner wants one, create it at
https://github.com/sponsors/accounts and add the link to the Pro page's "How do I support Inkvolt" answer.

Fact-check (2026-10-30): the guides were read against `pdf/README.md`, `pdf/ROADMAP.md` and `print/README.md`; eight
errors fixed (portfolio 86921ff), each FAQPage JSON-LD re-copied from its visible Questions. The fixes are in the
generated HTML; `gen-pages.mjs`'s fragments are older, so regenerating would bring the errors back: port the fixes into
the fragments first, or keep editing the HTML. Two things left for the owner: the Pro page lists regex redaction and
Batch's pattern redaction as free while `pdf/ROADMAP.md`'s table puts them in Pro (its "what's free today stays free"
rule decides); "Big documents open at once" on the product page meets the bench's targets except on the drawing set.

## Directory texts

FileHorse contact form (subject "Program submission: Inkvolt PDF for Mac"; Windows is Store-only, so only the Mac
DMG is offered):

> I'm the developer (Bermudez Systems LLC). Inkvolt PDF for Mac 1.2.0, https://bermudezsystems.com/products/inkvolt/ ·
> download: https://github.com/gabandres/inkvolt/releases/tag/pdf-mac-v1.2.0 (notarized DMG) · licence: open source,
> AGPL-3.0, free · icon and screenshots: https://github.com/gabandres/inkvolt/tree/master/docs/screenshots · a PDF
> editor: read, annotate, fill forms, organize pages, OCR with Apple's text recognition, redaction with a check of the
> whole file, Sanitize, What's in This PDF. No account, ads or telemetry. No affiliate programme. The Windows version
> is in the Microsoft Store only (9MXDTSFJ9W28).

## Next 30 days (in order)

1. **Show HN** (`docs/visibility/show-hn.md`), a Tuesday–Thursday 8–10 am Eastern, from the owner's own HN account; stay
   three hours. Biggest single reach for a free, open-source tool. Be ready for "was this written with AI?": say yes,
   plainly.
2. **Verify and finish the half-done listings** (15 minutes): click MacUpdate's verification mail and Add App; register
   at SaaSHub with gabriel@bermudezsystems.com to claim Inkvolt PDF; sign in to OpenAlternative with GitHub and submit
   the repo; send FileHorse the text above; add Inkvolt Print on AlternativeTo. Log each here.
3. **r/software** on a Wednesday (Release flair), then **r/opensource** a week later (Promotional), then the
   **r/macapps**, **r/Windows11** (Sunday Software Showoff) and **r/degoogle** megathreads, one a day at most
   (`docs/visibility/reddit.md`). r/privacy: don't post.
4. **Press pitches** (`docs/visibility/press-pitches.md`): one a day, gHacks and How-To Geek first; one follow-up after a
   week.
5. **Product Hunt** (`docs/visibility/product-hunt.md`) once the Mac Print app is through App Review, so the gallery can
   show both apps; take gallery shots 3, 4 and 6 first.
6. **Merge state of the awesome-list PRs** (#458 #459 #125 #126 #84 #1256 #1864 #4045): answer reviewers within a day;
   `gh pr list --author @me --state all` shows them.
7. **Store listings**: send the keyword and description proposals in `pdf/packaging/README.md` and
   `print/packaging/README.md` with the next submission.
8. **GitHub social preview** image (repo Settings › Social preview, owner only): `assets/inkvolt-suite-og.png` from the
   website works.
9. **Re-read the baseline** on 2026-11-29 the same way (Partner Center Insights, `gh api`), and add a column here.
10. **homebrew-cask**: when the repo passes 225 stars (or 75 if someone else submits) and is older than 30 days,
    open the PR to Homebrew/homebrew-cask with the tap's cask; until then the tap is the brew route.
