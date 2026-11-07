# Forms corpus (Mac)

Windows' [`pdf/tools/forms-corpus`](../../../pdf/tools/forms-corpus/README.md) on the Mac: the same public forms (its
`corpus.json`, read in place) and synthetic edge cases, filled through PdfCore's real form path and read back with
FormEditor, MuPDF and pdf.js. Results go in [RESULTS.md](RESULTS.md). Builds only on a Mac (PdfCore needs MuPDF's XCFramework).

```sh
# On the PC, once: downloads the PDFs into the git-ignored .cache, checks their SHA-256s; then copy them to the Mac,
# outside the repo. They are never committed.
pwsh -File pdf/tools/forms-corpus/fetch.ps1
scp -r pdf/tools/forms-corpus/.cache/pdfs/. ignia-mac:inkvolt-forms-corpus/pdfs/
# On the Mac (from the PC: `bash mac/tools/mac.sh bg forms "…"`, then `mac.sh wait forms`), once: (cd pdf/tools/pdfjs-check && npm ci)
swift build -c release -Xswiftc -enable-testing --package-path mac/tools/forms-corpus    # it reads PdfCore's objects
B=mac/tools/forms-corpus/.build/release/InkvoltFormsCorpus
$B run --pdfs ~/inkvolt-forms-corpus/pdfs --out ~/inkvolt-forms-corpus/out --damaged     # summary.md, results.json in --out
$B run --pdfs … --only irs-fw9,synth-special           # some forms
$B run --pdfs … --files /path/form.pdf                 # also a user's file: never baselined or committed
$B run --pdfs … --update-baseline                      # accept the run's failures (after a fix)
$B one form.pdf out-dir name [password]                # one form, in this process
$B probe form.pdf                                      # how MuPDF reads its trailer, catalog, bookmarks and widgets
```

**What a run does, per form** (each in its own process, killed after 120 s: a hang; a crash is reported as one). As Windows'
(its README has the values and the steps), through `FormEditor.read`, `dataFields` and `fill`, the bytes as `DocumentSession`
opens them (`StaleTail.normalized`); a signed file that can't take an update is rewritten, as the app does once the person
agrees. Beyond Windows':

- **Typing**: up to 3 fields of each AF format per form are typed one character at a time through `FieldKeystrokes.typed` (the
  app's editor step: its length limit, then the keystroke script). What they hold must be the digits sent, and the commit
  must take it. Windows has `run-ui.ps1` for this; here the app's own typing is in its self-test (`FormFillTest`).
- **Before and after**: the tab order (same fields, same pages, same order), the encryption (handler, permissions, whether it
  opens without a password), pages, other annotations and bookmarks.
- **`--damaged`**: each real form twice more, `name~tail` (a longer older copy's tail after its %%EOF, holding an old object
  numbered 4) and `name~cut` (its last 64 bytes gone). Each keeps every field, widget and bookmark of the sound copy, and fills
  like it. pdf.js's reading of the damaged original isn't compared (that's pdf.js's own repair), only the filled file.

Failures are grouped by signature (`summary.md`). `baseline.json` holds each failing form's groups: `run` exits 1 when a form
fails in a way the baseline doesn't list. It is empty: any failure is new.

**The forms**: `corpus.json`'s 286 downloads (not the XFA-only one, which isn't fillable by design) and `SyntheticForms.swift`: Windows' 17,
plus masked AFSpecial fields, encrypted forms (empty user password, an owner password: AES-256, AES-128, RC4 128 and 40, the annotate bit
alone), the traits Windows' real forms showed (widgets left out of /Kids, a widget's stale /I, check boxes with no faces, a shared
widget, a kid without /Parent) and damaged files (offsets off by two, a stale tail, cut off, an object stream's row wrong, an encrypted
form with a stale tail).

Downloads are untrusted: they are only ever read as PDFs, by the harness, pdf.js and MuPDF. Nothing goes to an online service.
