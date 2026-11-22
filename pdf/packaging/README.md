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
pwsh -NoProfile -File packaging/pack-msix.ps1 -App Pdf -Version x.y.z.0   # Store build with the Partner Center identity, unsigned; higher than the last submission
```

Before packing a release, rename `## Next` in `pdf/WHATS-NEW.md` to the version (three numbers, `## 1.1.0`): the app's
What's New shows that entry once after the update, and its lines are the Store's "What's new in this version". The script
warns when the heading is missing.

The defaults are the app's Partner Center identity (below); pass `-IdentityName`, `-Publisher` and
`-PublisherDisplayName` only to build under another one.

After packing, it installs this PC's layout as a Store install would (Developer Mode), runs it, and removes it
(`packaging/smoke-msix.ps1 -App Pdf`). The run includes the command line through the alias: `--batch` and
`--watch --once` in a folder in Documents, in the temp folder and on a network share (this PC's own `\\127.0.0.1\C$`, when
it answers), each result and moved original looked for from outside the package, the exit codes (0, 1 for a file that
isn't a PDF, 2 for a missing preset), `--help` typed in a terminal (what its console shows), and `--watch` stopped by
Ctrl+C in a console of its own. It also refuses a layout whose native libraries link the Visual C++ runtime
without the VCLibs dependency. Upload only a package that passed both; `-NoSmoke` skips the run.

While the Store copy of the app is installed on this PC, the smoke run refuses to register the layout (it would replace
the Store install and its data). Pack with `-SmokeSideBySide` instead:

```powershell
pwsh -NoProfile -File packaging/pack-msix.ps1 -App Pdf -Version x.y.z.0 -SmokeSideBySide
```

The packages are built with the real identity as usual; the smoke run then copies this PC's layout to
`pdf/publish/smoke-side/<arch>`, renames its identity to `BermudezSystems.InkvoltPDF.Smoke` and its execution alias to
`inkvoltpdfsmoke.exe`, registers that copy beside the Store install, runs it, and removes it. Only those two manifest
values differ from the package that is uploaded. For a layout that is already packed:
`pwsh -NoProfile -File packaging/smoke-msix.ps1 -App Pdf -SmokeSideBySide`.

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

A release, in order (the owner says when; Inkvolt Print's the same with its own ID `9PNR76HJ62SK`):

1. `pdf/tools/bench` `run` and commit its `RESULTS.md` (an idle PC; root `CLAUDE.md`).
2. `pdf/WHATS-NEW.md`: `## Next` becomes `## x.y.z`, a new empty `## Next` above it; the same in `pdf/WHATS-NEW.es.md`,
   which the Store's es release notes come from (the app shows What's New in the interface language).
3. Pack with the smoke test (Build, above; `-SmokeSideBySide` while the Store copy is installed).
4. `msstore publish pdf/publish/msix/InkvoltPdf_<ver>.msixupload -id 9MXDTSFJ9W28 -nc -ut 3000`: the package goes up as
   a draft, not committed.
5. Write `notes.json`, `{"en-us": "...", "es": "..."}`: the Store's short notes from the WHATS-NEW entry, under 1,500
   characters each, the Spanish in the voice of the app's `docs/SPANISH-REVIEW.md` (*tú*, "tu PC", the app's command names). `packaging/store-release.ps1 -App Pdf -Notes
   notes.json` puts them in the draft, checks them (length, every listing, no U+FFFD) and reads them back. A description
   change goes in by hand (`msstore submission get`, `update -p`; below).
6. `store-release.ps1 -App Pdf -Publish`, then `-Wait` as a background command, until `Published` (CommitStarted,
   Certification, Release; under two hours so far).
7. Commit and push; `store-release.ps1 -App Pdf -GitHub -Version <ver>` creates the release `pdf-v<ver>` from the WHATS-NEW
   lines (again with `-Published <date>` once Published); the website's `softwareVersion` (`Z:\portfolio`,
   `firebase deploy --only hosting`) once Published; `docs/HANDOFF.md`.

A draft edited in Partner Center's pages can't be updated through the API afterwards (409 InvalidState, "in the state
'None'"): finish such a submission in Partner Center. There, a submission is: **Packages** (drop the `.msixupload`;
Windows 10/11 Desktop; Partner Center checks the identity values against the reservation), **Properties** (Productivity;
privacy policy URL; support contact), **Age ratings** (no user-generated content shared, no purchases, opens links in
the browser), **Store listings**, **Submission options > Restricted
capabilities** (`runFullTrust`, text below), the generative AI declaration (policy 11.16), then Submit.

### Visual C++ runtime

MuPDF's native engine (`MuPDFWrapper.dll`) links MSVCP140, VCRUNTIME140 and (x64) VCRUNTIME140_1. Windows doesn't
ship them, so the manifest declares the `Microsoft.VCLibs.140.00.UWPDesktop` framework (MinVersion 14.0.30704.0), which
the Store installs with the app. Without it, every file open fails with "Unable to load DLL 'MuPDFWrapper'" on a PC
without the VC++ redistributable (certification failed 1.0.0.0 for this, 10.1.2.10); `pack-msix.ps1` now refuses such a
layout. A sideloaded test needs the framework installed (`Get-AppxPackage Microsoft.VCLibs.140.00.UWPDesktop`).

### runFullTrust justification

> Inkvolt PDF is a classic Win32 desktop application (.NET / WPF) packaged with the Desktop Bridge. `runFullTrust` is
> required for every packaged desktop app: Inkvolt PDF runs as a regular full-trust process to render documents with its
> bundled native PDF engine (MuPDF), read and save files the user opens anywhere on disk, print through the Windows
> print system, use Windows OCR, make PDFs from Office files through the user's own installed Microsoft Office
> (automation of a separate, hidden Office instance) and from web pages through the system WebView2 runtime, and sign documents with certificates from the user's Windows certificate store and
> smart cards, and (only when the user turns it on) send text the user picks to an AI endpoint the user configures. It installs no services or drivers, needs no administrator rights, and changes no system settings.

### Changing the listing

The listing as it is live: `msstore submission get` (en-us and es; plain Spanish only, which covers every Spanish market).
The text below is what was last submitted ("Listing proposals 2026-10-30", Submission 13; the es description with
1.8.0.0); keep it in step with what goes in.

- **Through the API** (descriptions, release notes): `msstore submission get`, change the JSON (list items start "• ",
  as the listing has them), `msstore submission update <id> -p payload.json`, `msstore submission publish <id>`; check the
  result with `msstore submission get` (no U+FFFD).
- **Keywords and other fields in Partner Center**: Export listings, change the .csv's text and SearchTerm rows, Import
  listings. That takes all seven keywords at once; the keyword box itself keeps only one new keyword at a time and drops
  one that begins a suggestion of its own ("firmar PDF" against "firmar PDF digitalmente"). The import reshuffles the
  screenshots whatever the file's order: drag the tiles back on each language's listing page (a drop swaps two tiles),
  save, and check by exporting again. Edit a draft this way only when it is going to be submitted from Partner Center:
  the API refuses it afterwards.
- Partner Center refuses a listing language without its own screenshots (`NoScreenshotsOfAnyType`): es uses the en-us
  ones. When the en-us description changes, change the es one to match.
- **Why these keywords:** the Store searches the title, the short description and the seven keywords, and the title
  already holds "PDF", so a keyword of just "PDF" is wasted; the apps on the comparison page (Acrobat Reader, Foxit,
  PDF-XChange, PDFgear) lead with "PDF editor", "PDF reader", "edit", "convert to Word", "merge", "sign" and "OCR", which is
  what people type; the differentiators (redaction, no account, no telemetry, open source) go in the first lines of the
  descriptions, where a person reads them. The Store's own suggestions show only in a draft's keyword box. Each keyword is
  at most 30 characters.
- The AI paragraph is the metadata disclosure Store policy 11.16 (Live Generative AI Content, policies 7.20) asks for;
  also tick the generative AI question in Partner Center when submitting.
- What to measure: Partner Center › Insights › Acquisitions, "Page views" by source type (Store search vs. links), against
  the baseline in `docs/VISIBILITY.md`.

Keywords (en-us, 7): `pdf editor`, `pdf reader`, `edit pdf`, `pdf to word`, `merge pdf`, `fill and sign`, `ocr`.
Alternates if the box drops one: `sign pdf`, `redact pdf`, `scan to pdf`, `compress pdf`, `pdf converter`.

Short description (en-us):

> Free PDF editor and reader: edit text, fill and sign forms, merge and organize pages, PDF to Word and Excel, OCR,
> redaction that removes the content. No account, no ads, no telemetry, open source.

Description (en-us):

> Inkvolt PDF is a free PDF editor and reader for Windows 10 and 11 (x64 and ARM64). Open big documents instantly,
> in tabs, in light or dark; edit, fill, sign, convert, organize and redact without a subscription, a watermark, an
> account or any usage data sent anywhere. Open source (AGPL-3.0).
>
> - Edit PDF: click text to rewrite it in its own font; move, resize or replace pictures; add links, headers and
>   footers, page numbers, watermarks.
> - Fill and sign: fill any form, type or tick anywhere on a page, add a handwritten signature or initials. Create
>   forms with text fields, check boxes, lists and signature fields, or detect them on the page.
> - Digital signatures: sign with a certificate, smart card or Windows Hello, add a trusted timestamp, verify every
>   signature.
> - Comment and draw: highlight, underline, sticky notes, stamps, pen, shapes, arrows, text boxes, callouts,
>   measurements.
> - Merge and organize: combine files, reorder, rotate, insert, extract, split and crop pages. Make PDFs from images,
>   the clipboard, Office files (with your installed Microsoft Office) and web pages.
> - PDF to Word, Excel or text, rebuilt as editable paragraphs, headings, lists and tables, on your PC.
> - OCR: make scans searchable with Windows' own text recognition, on your PC.
> - Redact for real: the text and pictures underneath are removed, not covered, then the whole file is checked for
>   anything left. Redact by pattern (Social Security, phone and card numbers, emails, dates). Check a PDF redacted
>   elsewhere.
> - What's in This PDF: every script, link, attachment, earlier version and hidden element a file carries, before you
>   share it. Sanitize removes them.
> - Protect with a password, reduce file size, save as PDF/A, compare two versions, check accessibility (PDF/UA), and
>   run batches over many files.
> - Scan straight into a PDF from network, USB and TWAIN scanners.
>
> Optional AI assistant (off by default): connect an AI you choose, such as Ollama or LM Studio on your PC or a service
> with your own API key, to summarize, ask questions about a document or explain a passage. Answers are generated live
> by that AI model and may be wrong. Inkvolt PDF includes no AI of its own and shows exactly what text will be sent, and
> where, before anything goes.
>
> No account, no ads, no telemetry. Your documents stay on your PC unless you send text to an AI service you set up.
>
> Free and open source (AGPL-3.0). Source code: https://github.com/gabandres/inkvolt. Also for Mac:
> https://bermudezsystems.com/products/inkvolt/

### Spanish listing (es)

In the voice and with the command names of the app (`pdf/docs/SPANISH-REVIEW.md`): **Qué hay en este PDF**, **Limpiar
documento**, **Eliminar por patrón**, **En lote**, **Configuración › Idioma**.

Keywords (es, 7): `editor de pdf`, `lector de pdf`, `editar pdf`, `pdf a word`, `unir pdf`, `llenar y firmar`, `ocr`.
Alternates: `firmar pdf` (the box drops it for its own "firmar PDF digitalmente"; try last), `comprimir pdf`,
`convertir pdf`, `escanear a pdf`.

Short description (es):

> Editor y lector de PDF gratis: edita texto, llena y firma formularios, une y organiza páginas, convierte PDF a Word y
> Excel, OCR, y elimina información confidencial de verdad. Sin cuenta, sin anuncios, sin telemetría, código abierto.

Description (es):

> Inkvolt PDF es un editor y lector de PDF gratis para Windows 10 y 11 (x64 y ARM64). Abre documentos grandes al
> instante, en pestañas, en modo claro u oscuro; edita, llena, firma, convierte, organiza y elimina información
> confidencial sin suscripción, sin marca de agua, sin cuenta y sin enviar datos de uso a ningún sitio. Código abierto
> (AGPL-3.0).
>
> - Editar PDF: haz clic en un texto para reescribirlo con su propia fuente; mueve, cambia de tamaño o reemplaza
>   imágenes; agrega vínculos, encabezados y pies de página, números de página y marcas de agua.
> - Llenar y firmar: llena cualquier formulario, escribe o marca en cualquier parte de la página y agrega tu firma a
>   mano o tus iniciales. Crea formularios con campos de texto, casillas, listas y campos de firma, o detéctalos en la
>   página.
> - Firmas digitales: firma con un certificado, una tarjeta inteligente o Windows Hello, agrega una marca de tiempo
>   confiable y comprueba cada firma.
> - Comentarios y dibujo: resaltado, subrayado, notas, sellos, pluma, formas, flechas, cuadros de texto, llamadas y
>   medidas.
> - Unir y organizar: combina archivos; reordena, gira, inserta, extrae, divide y recorta páginas. Crea PDF a partir de
>   imágenes, del portapapeles, de archivos de Office (con tu Microsoft Office instalado) y de páginas web.
> - PDF a Word, Excel o texto, reconstruido como párrafos, títulos, listas y tablas que se pueden editar, en tu PC.
> - OCR: haz que los escaneos se puedan buscar con el reconocimiento de texto de Windows, en tu PC.
> - Eliminar información confidencial de verdad: se borran el texto y las imágenes que hay debajo, no solo se tapan, y
>   luego se revisa todo el archivo por si queda algo. Eliminar por patrón (números de Seguro Social, de teléfono y de
>   tarjeta, correos electrónicos, fechas). Comprueba también un PDF en el que se eliminó información con otro programa.
> - Qué hay en este PDF: cada script, vínculo, archivo adjunto, versión anterior y elemento oculto que lleva un archivo,
>   antes de compartirlo. Limpiar documento los quita.
> - Protege con contraseña, reduce el tamaño del archivo, guarda como PDF/A, compara dos versiones, comprueba la
>   accesibilidad (PDF/UA) y aplica acciones a muchos archivos a la vez (En lote).
> - Escanea directamente a un PDF desde escáneres de red, USB y TWAIN.
>
> Asistente de IA opcional (desactivado de forma predeterminada): conecta la IA que elijas, como Ollama o LM Studio en
> tu PC o un servicio con tu propia clave de API, para resumir, hacer preguntas sobre un documento o explicar un pasaje.
> Las respuestas las genera en el momento ese modelo de IA y pueden ser incorrectas. Inkvolt PDF no incluye ninguna IA
> propia y muestra exactamente qué texto se enviará, y adónde, antes de enviar nada.
>
> Sin cuenta, sin anuncios, sin telemetría. Tus documentos se quedan en tu PC, salvo el texto que envíes a un servicio
> de IA que configures.
>
> La aplicación está en español y en inglés: sigue el idioma de Windows, o elígelo en Configuración › Idioma.
>
> Gratis y de código abierto (AGPL-3.0). Código fuente: https://github.com/gabandres/inkvolt. También para Mac:
> https://bermudezsystems.com/products/inkvolt/

License terms (es): Inkvolt PDF es software libre bajo la Licencia Pública General Affero de GNU v3.0. Código fuente y
licencia: https://github.com/gabandres/inkvolt

### Privacy policy

Partner Center asks for a privacy policy URL; publish a short page (e.g. on the product site or a public gist) saying:

- Inkvolt PDF collects no personal data and has no telemetry, analytics, ads or accounts.
- Documents are processed on the PC (rendering, search, OCR with Windows' own recognizer, or Tesseract once the user
  downloads it).
- Store installs ask Windows' own Store service whether an update is ready, about 30 s after startup (Settings turns it
  off); only this app's package is named. Other network use happens only on the user's action: an RFC 3161 timestamp when signing with "Add a timestamp" or adding a
  document timestamp (only a hash goes to the timestamp server in the field, Sectigo's free one unless the user enters another); Add Verification
  Information, signing for the long term and Check Signatures Online, which ask the OCSP and CRL addresses a certificate names
  (they learn which certificate is asked about, never the document), each after a window listing them; Tesseract and its
  language files, downloaded from GitHub only when the user chooses a language and confirms; and links in documents,
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
  the alias is also the command line (`inkvoltpdf --batch`, `--watch`, `--fill`, `--help`: README's "Command line"), so after a
  package change check `inkvoltpdf --help | Out-Default` prints the usage and `$LASTEXITCODE` is 0;
  nothing writes registry associations. Settings' "Open Default apps" opens the package's own Default apps page.
- Settings and logs stay at `%LOCALAPPDATA%\InkvoltPdf`; Windows redirects that into the package's private folder (`%LOCALAPPDATA%\Packages\<family>\LocalCache\Local\InkvoltPdf`, the log in its `logs`; not when that folder already exists), so a
  packaged and an unpackaged copy keep separate settings. Uninstalling the package removes them.
- Single instance, file forwarding (named pipe) and everything else behave the same. Updates come from the Store, and
  only the packaged app checks for them in the app: ~30 s after startup (Settings › "Check for updates when Inkvolt PDF
  starts") and Help › Check for Updates…, through `Windows.Services.Store` (`StoreContext`, initialized with the main
  window). That is the one thing the app asks over the network by itself, and it talks only to Windows' own Store service
  about this package; nothing about the user or their documents is sent. Sideloaded and dev packages get an error from
  the Store, which the startup check only logs. A real update can only be seen from a Store-installed copy with an older
  version than the one published.
- `AppEnvironment.FindSuiteApp("InkvoltPrint")` finds a sibling app through its execution alias
  (`%LOCALAPPDATA%\Microsoft\WindowsApps\inkvoltprint.exe`), App Paths, or its install folders.
