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
| AlternativeTo: Inkvolt PDF | 2026-10-29 | https://alternativeto.net/software/inkvolt-pdf/ (expected address) | Submitted; moderation pending | Add the Mac platform and Inkvolt Print (needs the owner's AlternativeTo sign-in) |
| awesome-free-apps | 2026-10-29 | PRs #458, #459 | Open | |
| thechampagne/awesome-windows | 2026-10-29 | PRs #125, #126 | Open | |
| awesome-foss-alternatives | 2026-10-29 | PR #84 | Open | |
| pluja/awesome-privacy | 2026-10-29 | PR #1256 | Open | |
| open-source-mac-os-apps | 2026-10-29 | PR #1864 | Open | |
| jaywcjlove/awesome-mac | 2026-10-29 | PR #4045 | Open | |
| Homebrew tap | 2026-10-30 | https://github.com/gabandres/homebrew-inkvolt | Live: `brew install --cask gabandres/inkvolt/inkvolt-pdf` (installed, audited and uninstalled on the owner's Mac) | Bump `version` and `sha256` with each Mac release (`release.sh` could do it). homebrew-cask itself needs 225 stars, 90 forks or 90 watchers for a self-submission (75/30/30 when someone else submits) and a repository older than 30 days: not yet |
| Website: Pro page and six guides | 2026-10-30 | /products/inkvolt/pro/, /redact-pdf/, /pdf-to-word/, /fill-and-sign/, /acrobat-alternative/, /pdfgear-alternative/, /whats-in-a-pdf/ | See "Website" below | |

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
