# Inkvolt PDF for the Microsoft Store (MSIX)

The repository's `packaging/pack-msix.ps1 -App Pdf` (shared with Inkvolt Print) builds Inkvolt PDF as MSIX packages for x64
and ARM64, bundles them, and writes the Store upload file. This folder holds Inkvolt PDF's manifest template and images. The
unpackaged per-user install (`install.ps1`) keeps working unchanged next to it. Paths below are in `pdf/` unless they start
with `packaging/` (the repository root's).

Inkvolt PDF is licensed under the GNU AGPL v3 (`../LICENSE`; MuPDF requires it); dependencies are listed in
`../THIRD-PARTY-NOTICES.md`. Every Store build must point to its source: https://github.com/gabandres/inkvolt (Inkvolt PDF is `pdf/`;
https://github.com/gabandres/inkvolt-pdf, the address before the move, redirects there).

## Build

From the repository root:

```powershell
pwsh -File packaging/pack-msix.ps1 -App Pdf                    # Store build with the Partner Center identity, unsigned
pwsh -File packaging/pack-msix.ps1 -App Pdf -Version 1.1.0.0   # a later submission
```

Before packing a release, rename `## Next` in `pdf/WHATS-NEW.md` to the version (three numbers, `## 1.1.0`): the app's
What's New shows that entry once after the update, and its lines are the Store's "What's new in this version". The script
warns when the heading is missing.

The defaults are the app's Partner Center identity (below); pass `-IdentityName`, `-Publisher` and
`-PublisherDisplayName` only to build under another one.

After packing, it installs this PC's layout as a Store install would (Developer Mode), runs it, and removes it
(`packaging/smoke-msix.ps1 -App Pdf`). It also refuses a layout whose native libraries link the Visual C++ runtime
without the VCLibs dependency. Upload only a package that passed both; `-NoSmoke` skips the run (e.g. while a Store
copy is installed).

Other parameters: `-DisplayName` (default `Inkvolt PDF`), `-Architectures x64,arm64`, `-OutDir` (default `pdf/publish/msix`), `-NoBuild` (reuse the last
publish), `-SignWithTestCert` (below).

What it does:

1. Restores `Microsoft.Windows.SDK.BuildTools` (version in `packaging/tools/BuildTools.csproj`) into the NuGet cache and uses its
   `makeappx`, `makepri` and `signtool`. No Windows SDK install.
2. `dotnet publish` per architecture: Release, self-contained, folder layout (not single-file), version = `-Version`.
   Checks that the MuPDF and HarfBuzz natives are there.
3. Stages `publish/msix/layout/<arch>`: the publish output, `Assets/`, `resources.pri` (makepri index of the qualified
   images), `THIRD-PARTY-NOTICES.md`, and `AppxManifest.xml` filled from `AppxManifest.template.xml`.
4. `makeappx pack` per architecture (this also validates the manifest), `makeappx bundle`, then zips the bundle as
   the `.msixupload`.

Output in `publish/msix` (ignored by git):

| File | Use |
|---|---|
| `InkvoltPdf_<ver>.msixupload` | Upload this to Partner Center (a `.msixbundle` upload works too) |
| `InkvoltPdf_<ver>.msixbundle` | Both architectures; sideload test |
| `InkvoltPdf_<ver>_x64.msix`, `InkvoltPdf_<ver>_arm64.msix` | Single-architecture packages |

Images: `Assets/*.png` are generated, with the icons, by `python -I assets/make-icon.py`. Commit them after a change.

## Values from Partner Center

Reserve the name **Inkvolt PDF** (or another) in Partner Center, then open the app's **Product management > Product
identity** page and copy:

| Partner Center field | Script parameter | Manifest |
|---|---|---|
| Package/Identity/Name | `-IdentityName` | `Identity/@Name` |
| Package/Identity/Publisher (`CN=...`) | `-Publisher` | `Identity/@Publisher` |
| Package/Properties/PublisherDisplayName | `-PublisherDisplayName` | `Properties/PublisherDisplayName` |
| Reserved app name | `-DisplayName` | `Properties/DisplayName`, tile names |

Inkvolt PDF's values (the script's defaults):

| Field | Value |
|---|---|
| Store ID | `9MXDTSFJ9W28` (Store page: `ms-windows-store://pdp/?ProductId=9MXDTSFJ9W28`) |
| Package/Identity/Name | `BermudezSystems.InkvoltPDF` |
| Package/Identity/Publisher | `CN=1CC7D6EF-8A48-4BDE-AF19-4FEC30D5613B` |
| Package/Properties/PublisherDisplayName | `Bermudez Systems` |
| Reserved app name | `Inkvolt PDF` |

Inkvolt Print, the suite's other app, is Store ID `9PNR76HJ62SK` (`BermudezSystems.InkvoltPrint`, same publisher).

Version: four numbers, the last one 0 (the Store reserves it), higher than every earlier submission.

## Upload

1. Partner Center > the app > **Start your submission**.
2. **Packages**: drop `InkvoltPdf_<ver>.msixupload`. Device families: Windows 10/11 Desktop. Partner Center validates the
   identity values against the reservation; a mismatch is reported here.
3. **Properties**: category Productivity (or Business); privacy policy URL (see below); support contact.
4. **Age ratings**: the questionnaire (no user-generated content shared, no purchases, opens links in the browser).
5. **Store listings** (en-us): description, at least one screenshot, optional logos and trailers.
6. **Submission options > Restricted capabilities**: explain `runFullTrust` (text below).
7. Submit. Certification normally takes 1-3 business days.

### Visual C++ runtime

MuPDF's native engine (`MuPDFWrapper.dll`) links MSVCP140, VCRUNTIME140 and (x64) VCRUNTIME140_1. Windows doesn't
ship them, so the manifest declares the `Microsoft.VCLibs.140.00.UWPDesktop` framework (MinVersion 14.0.30704.0), which
the Store installs with the app. Without it, every file open fails with "Unable to load DLL 'MuPDFWrapper'" on a PC
without the VC++ redistributable: certification failed 1.0.0.0 for this (10.1.2.10, Oct 2026). A sideloaded test
needs the framework installed (`Get-AppxPackage Microsoft.VCLibs.140.00.UWPDesktop`).

### runFullTrust justification

> Inkvolt PDF is a classic Win32 desktop application (.NET / WPF) packaged with the Desktop Bridge. `runFullTrust` is
> required for every packaged desktop app: Inkvolt PDF runs as a regular full-trust process to render documents with its
> bundled native PDF engine (MuPDF), read and save files the user opens anywhere on disk, print through the Windows
> print system, use Windows OCR, make PDFs from Office files through the user's own installed Microsoft Office
> (automation of a separate, hidden Office instance) and from web pages through the system WebView2 runtime, and sign documents with certificates from the user's Windows certificate store and
> smart cards, and (only when the user turns it on) send text the user picks to an AI endpoint the user configures. It installs no services or drivers, needs no administrator rights, and changes no system settings.

### Draft Store description

Short description:

> A fast, private PDF reader and editor: fill and sign forms, comment, draw, organize pages, redact and OCR. No account,
> no ads, no telemetry.

Description:

> Inkvolt PDF opens big documents instantly and keeps your files on your PC. Read, fill, sign, mark up and rearrange
> PDFs with a clean Windows 11 interface, in tabs, in light or dark.
>
> - Read comfortably: continuous or two-page layouts, fast search, bookmarks, dark pages for night reading, Read Aloud.
> - Fill & Sign: fill any form, type anywhere on a page, and add a handwritten signature or initials.
> - Digital signatures: sign with a certificate or smart card, add a trusted timestamp, and check every signature's
>   status in detail.
> - Comment and draw: highlight, underline, sticky notes, pen, shapes, arrows, text boxes and callouts.
> - Edit text and images on the page, add links, stamps, headers and footers, watermarks.
> - Create forms: add text fields, check boxes, lists and signature fields, or detect them on a page.
> - Organize: reorder, rotate, insert, extract, split and merge pages. Make PDFs from images, the clipboard, Office files
>   (with your installed Microsoft Office) and web pages.
> - Redact for real: removes the text and images underneath, not just a black box on top. Sanitize hidden data.
> - Make scans searchable with Windows' own text recognition, export to Word, Excel or text, protect files with a
>   password, reduce their size and save as PDF/A for archiving.
> - Compare two versions of a document, measure distances and areas on drawings, and process many files at once.
> - Scan straight into a PDF with Inkvolt Print.
>
> Optional AI assistant (off by default): connect an AI you choose, such as Ollama or LM Studio on your PC or a service
> with your own API key, to summarize, ask questions about a document or explain a passage. Answers are generated live
> by that AI model and may be wrong. Inkvolt PDF includes no AI of its own and shows exactly what text will be sent, and
> where, before anything goes.
>
> No account, no ads, no telemetry. Your documents stay on your PC unless you send text to an AI service you set up.
>
> Free and open source (AGPL-3.0). Source code: https://github.com/gabandres/inkvolt

Keywords (up to 7): PDF, PDF editor, fill and sign, digital signature, annotate, merge PDF, OCR.

The AI paragraph is the metadata disclosure Store policy 11.16 (Live Generative AI Content, policies 7.20) asks for. Also
tick the generative AI question in Partner Center when submitting (below).

### Privacy policy

Partner Center asks for a privacy policy URL; publish a short page (e.g. on the product site or a public gist) saying:

- Inkvolt PDF collects no personal data and has no telemetry, analytics, ads or accounts.
- Documents are processed on the PC (rendering, search, OCR with Windows' own recognizer).
- Network use happens only on the user's action: an RFC 3161 timestamp when signing with "Add a timestamp" (only a
  hash of the signature goes to the chosen timestamp server, default DigiCert); certificate revocation checks when
  verifying a signature on request (Windows fetches CRL/OCSP from the certificate's issuer); and links in documents,
  which open in the default browser after the user clicks (and confirms for anything but http/https/mailto).
- PDF from Web Page loads the address the user types (or a local file) in a private WebView2 session, as a browser
  would; nothing else is sent. PDF from Office File uses the Office installed on the PC; the file stays on the PC.
- The AI assistant is off until the user turns it on and sends only to the endpoint the user configures (on the PC, the
  local network or a service of the user's choice with the user's own key), only the text the user asked about, after
  showing it and asking. Bermudez Systems receives nothing. API keys stay on the PC, encrypted for the Windows user.
- Settings, recent files and logs stay in the user's local app data folder.

### Store listing checklist

- [ ] Source link in the description: "Source code (AGPL-3.0): https://github.com/gabandres/inkvolt".
- [ ] Description, short description, feature list (from the README's "Using it").
- [ ] Screenshots: PNG, at least 1366x768 (1920x1080 recommended), 1-10. Take them off-screen with the dev script, e.g.
      a `steps.txt` of `size 1920 1080`, `wait 1500`, `shot C:\shots\reading.png`, `exit`, then
      `$env:INKVOLTPDF_DEVSCRIPT=1; $env:INKVOLTPDF_DATA="$env:TEMP\inkvoltpdf-shots"; InkvoltPdf.exe sample.pdf --script steps.txt`
      (see `src/InkvoltPdf.App/DevScript.cs` for panes, themes and tools).
- [ ] Store logo (optional 300x300 / 1:1 box art): `assets/InkvoltPdf-512.png` scaled.
- [ ] Privacy policy URL; support URL or email.
- [ ] Age rating questionnaire; pricing and availability (markets, free/paid).
- [ ] `runFullTrust` justification.
- [ ] Live generative AI (policy 11.16): the AI paragraph in the description, and the generative AI declaration in
      Partner Center during the submission.
- [ ] Notes for certification: "No sign-in needed. Open any PDF from File > Open."

## Local test install (optional)

The Store signs uploads itself; local installs need a trusted signature or Developer Mode. Both are manual steps on
purpose: the script never installs certificates or packages.

**Signed bundle.** `pack-msix.ps1 -App Pdf -SignWithTestCert` creates `publish/msix/InkvoltPdf-TestSigning.pfx` (no password) and
`.cer` with subject = `-Publisher`, in memory and files only, then signs the bundle and both `.msix`. To install it,
trust the certificate, then add the package (elevated PowerShell for the first command):

```powershell
Import-Certificate publish\msix\InkvoltPdf-TestSigning.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
Add-AppxPackage publish\msix\InkvoltPdf_1.0.0.0.msixbundle
# Remove afterwards:
Get-AppxPackage BermudezSystems.InkvoltPDF | Remove-AppxPackage
Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq 'CN=1CC7D6EF-8A48-4BDE-AF19-4FEC30D5613B' | Remove-Item
```

Anyone holding the `.pfx` can sign packages this PC then trusts: remove the certificate when done, and keep the
`.pfx` out of git (it lives under the ignored `publish/`).

**Unsigned, Developer Mode.** With Settings > System > For developers > Developer Mode on, register the staged folder
directly: `Add-AppxPackage -Register publish\msix\layout\arm64\AppxManifest.xml` (x64 on x64 PCs).

If `install.ps1`'s copy is installed too, both appear under "Open with"; uninstall one (`install.ps1 -Uninstall`).

## How the packaged app differs

`AppEnvironment.IsPackaged` (src/InkvoltPdf.App/AppEnvironment.cs) tells the two apart at run time:

- File associations, the Start menu entry and the `inkvoltpdf` command (app execution alias) come from the manifest;
  nothing writes registry associations. Settings' "Open Default apps" opens the package's own Default apps page.
- Settings and logs stay at `%LOCALAPPDATA%\InkvoltPdf`; Windows redirects that into the package's private folder, so a
  packaged and an unpackaged copy keep separate settings. Uninstalling the package removes them.
- Single instance, file forwarding (named pipe) and everything else behave the same. Updates come from the Store.
- `AppEnvironment.FindSuiteApp("InkvoltPrint")` finds a sibling app through its execution alias
  (`%LOCALAPPDATA%\Microsoft\WindowsApps\inkvoltprint.exe`), App Paths, or its install folders.
