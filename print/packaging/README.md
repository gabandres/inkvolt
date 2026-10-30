# Inkvolt Print for the Microsoft Store (MSIX)

The repository's `packaging/pack-msix.ps1 -App Print` (shared with Inkvolt PDF) builds Inkvolt Print as MSIX packages for
x64 and ARM64, bundles them, and writes the Store upload file. This folder holds Inkvolt Print's manifest template and
images. Paths below are in `print/` unless they start with `packaging/` (the repository root's).
The unpackaged builds (`dotnet publish -p:PublishProfile=win-x64|win-arm64`, the Inkvolt installer) keep working unchanged.

Inkvolt Print is licensed under the MIT License (`../LICENSE`); dependencies are listed in `../THIRD-PARTY-NOTICES.md`
(both ship in the package and show under "About Inkvolt Print"). Source: https://github.com/gabandres/inkvolt (Inkvolt Print is `print/`; the libraries it shares with
Inkvolt PDF are `shared/`).

## Build

From the repository root:

```powershell
pwsh -File packaging/pack-msix.ps1 -App Print                    # Store build with the Partner Center identity, unsigned
pwsh -File packaging/pack-msix.ps1 -App Print -Version 1.1.0.0   # a later submission
```

Before packing a release, rename `## Next` in `print/WHATS-NEW.md` to the version (three numbers, `## 1.1.0`): the app's
What's New shows that entry once after the update, and its lines are the Store's "What's new in this version". The script
warns when the heading is missing.

The defaults are the app's Partner Center identity (below); pass `-IdentityName`, `-Publisher` and
`-PublisherDisplayName` only to build under another one.

After packing, it installs this PC's layout as a Store install would (Developer Mode), runs it, and removes it
(`packaging/smoke-msix.ps1 -App Print`). It also refuses a layout whose native libraries link the Visual C++ runtime
without the VCLibs dependency. Upload only a package that passed both; `-NoSmoke` skips the run (e.g. while a Store
copy is installed).

Other parameters: `-DisplayName` (default `Inkvolt Print`), `-Architectures x64,arm64`, `-OutDir` (default `print/publish/msix`), `-NoBuild` (reuse the
last publish), `-SignWithTestCert` (below), `-IncludeHpCleanup` (sideloading only, see "HP clean-up" below).

What it does:

1. Restores `Microsoft.Windows.SDK.BuildTools` (version in `packaging/tools/BuildTools.csproj`) into the NuGet cache and uses its
   `makeappx`, `makepri` and `signtool`. No Windows SDK install.
2. `dotnet publish` per architecture: Release, self-contained, folder layout (not single-file), version = `-Version`.
   Checks that the WinRT projection and CommunityToolkit.Mvvm are there.
3. Stages `publish/msix/layout/<arch>`: the publish output, `Assets/`, `resources.pri` (makepri index of the qualified
   images), `LICENSE`, `THIRD-PARTY-NOTICES.md`, and `AppxManifest.xml` filled from `AppxManifest.template.xml`.
4. `makeappx pack` per architecture (this also validates the manifest), `makeappx bundle`, then zips the bundle as
   the `.msixupload`.

Output in `publish/msix` (ignored by git):

| File | Use |
|---|---|
| `InkvoltPrint_<ver>.msixupload` | Upload this to Partner Center (a `.msixbundle` upload works too) |
| `InkvoltPrint_<ver>.msixbundle` | Both architectures; sideload test |
| `InkvoltPrint_<ver>_x64.msix`, `InkvoltPrint_<ver>_arm64.msix` | Single-architecture packages |

Images: `Assets/*.png` are generated, with the icon, by `python -I assets/make-icon.py` (tiles, Start/taskbar target
sizes, store logo, splash screen; the same set as Inkvolt PDF's minus its PDF file-type logo). Commit them after a change.

## Manifest

- `runFullTrust` (every packaged desktop app); nothing else. No `allowElevation` (see "Elevation").
- App execution alias `inkvoltprint.exe`: `inkvoltprint` from a terminal or Run, and how Inkvolt PDF finds and starts a packaged
  Inkvolt Print.
- File types: `.pdf`, and pictures (`.jpg`, `.jpeg`, `.png`, `.bmp`, `.gif`, `.tif`, `.tiff`, `.heic`, `.webp`), as "Open with"
  entries, the same ones the unpackaged app registers in HKCU (`src/InkvoltPrint.App/ShellIntegration.cs`). Inkvolt Print opens
  a PDF in its Print tab and pictures in its Photos tab. It never becomes the default app for either unless the user picks it.
  No protocol: Inkvolt Print handles none.
- Startup task `InkvoltPrintTray` (`uap5:StartupTask`, `Enabled="false"`): Start with Windows for the packaged copy, turned on
  only from Settings › Notification area and alerts (`StartupTask.RequestEnableAsync`); Task Manager › Startup apps lists it.
  Started by it, the app reads the StartupTask activation and goes straight to the notification area. Check after packing:
  the smoke run, then the checkbox, then Task Manager (README, "Not done").
- Toast notifications need no manifest entry: the packaged copy sends them under its package identity, and a toast clicked
  after it exited starts it with the toast's arguments (`AppInstance.GetActivatedEventArgs`), opening that printer.

## Elevation (add printer by IP, offline fixer, HP clean-up)

Packaged builds never elevate and never start PowerShell. Microsoft's "Prepare to package a desktop application" page
says Store apps that require elevation for any part of their functionality won't be accepted, and advises against
starting PowerShell or cmd (Windows S mode can't start them). Three features need administrator rights:

- **Printer added by IP address.** Unpackaged copies create the queue with one UAC prompt (`Add-Printer -IppURL` through
  `src/InkvoltPrint.Windows/Elevated.cs`). Packaged copies (`Features.ElevatedQueueSetup` in `src/InkvoltPrint.App/Features.cs`)
  copy the printer's IPP address to the clipboard and open Settings > Printers & scanners, with the steps on screen:
  Add device > "Add manually" > "Add a printer using an IP address or hostname" > IPP Device > paste. Inkvolt Print then
  watches for ten minutes and links the new queue by its port (`QueuePrinter.FindByHost`). Printers found on the network
  are set up with no prompt in both builds (Windows pairing).
- **Printer offline fixer.** Diagnosis is read-only and needs no rights. Repairs first run as the signed-in user through the
  spooler API (winspool: resume a queue and turn off "Use Printer Offline" on queues the user set up, cancel or restart their
  own jobs). What Windows reserves for administrators (pointing a queue at a new Standard TCP/IP port, re-adding an
  IPP-URL queue, starting or restarting the Print Spooler, other people's jobs) gets one UAC prompt per repair in
  unpackaged copies (`Features.ElevatedRepairs`, constant scripts through `Elevated.cs`); packaged copies show the steps
  in Windows instead and a button to Settings > Printers & scanners.
- **HP clean-up.** Left out of packaged builds (below).

So the manifest needs no `allowElevation` and nothing about elevation goes in the certification notes.

**Test before submitting:** sideload (below), add a printer by IP address, press "Set up", add it in Settings as shown,
and check that Inkvolt Print shows "Ready to print from any app" within a few seconds.

## HP clean-up and the Store

The HP clean-up finds HP Smart and HP's Print Support App, removes them (Store packages of another publisher), deletes
the services and the virtual printer HP's app leaves behind, and turns off Windows' automatic download of manufacturers'
apps. A feature that uninstalls other publishers' software is likely to draw Store policy review, so:

- **Packaged builds hide it by default.** `Features.HpCleanup` is false when Inkvolt Print runs with package identity: no
  HP banner, no check for HP software. Unpackaged copies keep it.
- **`-IncludeHpCleanup`** builds a package that keeps it (MSBuild property `HpCleanupInPackage=true`, constant
  `HP_CLEANUP_IN_PACKAGE`), for sideloading or other direct distribution. Never upload such a package to the Store.
- The developer CLI (`inkvoltprint hp`) is not packaged.

## Values from Partner Center

Reserve the name **Inkvolt Print** (or another) in Partner Center, then open the app's **Product management > Product
identity** page and copy:

| Partner Center field | Script parameter | Manifest |
|---|---|---|
| Package/Identity/Name | `-IdentityName` | `Identity/@Name` |
| Package/Identity/Publisher (`CN=...`) | `-Publisher` | `Identity/@Publisher` |
| Package/Properties/PublisherDisplayName | `-PublisherDisplayName` | `Properties/PublisherDisplayName` |
| Reserved app name | `-DisplayName` | `Properties/DisplayName`, tile names |

Inkvolt Print's values (the script's defaults):

| Field | Value |
|---|---|
| Store ID | `9PNR76HJ62SK` (Store page: `ms-windows-store://pdp/?ProductId=9PNR76HJ62SK`) |
| Package/Identity/Name | `BermudezSystems.InkvoltPrint` |
| Package/Identity/Publisher | `CN=1CC7D6EF-8A48-4BDE-AF19-4FEC30D5613B` |
| Package/Properties/PublisherDisplayName | `Bermudez Systems` |
| Reserved app name | `Inkvolt Print` |

Inkvolt PDF, the suite's other app, is Store ID `9MXDTSFJ9W28` (`BermudezSystems.InkvoltPDF`, same publisher).

Version: four numbers, the last one 0 (the Store reserves it), higher than every earlier submission.

## Upload

1. Partner Center > the app > **Start your submission**.
2. **Packages**: drop `InkvoltPrint_<ver>.msixupload`. Device families: Windows 10/11 Desktop.
3. **Properties**: category Utilities & tools (or Productivity); privacy policy URL (below); support contact.
4. **Age ratings**: the questionnaire (no user-generated content shared, no purchases, talks only to printers on the
   local network).
5. **Store listings** (en-us): description (draft below), at least one screenshot.
6. **Submission options > Restricted capabilities**: explain `runFullTrust` (text below).
7. Submit. Certification normally takes 1-3 business days.

### runFullTrust justification

> Inkvolt Print is a classic Win32 desktop application (.NET / WPF) packaged with the Desktop Bridge. `runFullTrust` is
> required for every packaged desktop app: Inkvolt Print runs as a regular full-trust process to find network printers with
> Windows' device discovery, read their status and settings over the local network (HP LEDM and CDM, eSCL and IPP), scan,
> render PDFs with Windows' PDF engine and print them through the Windows print system, run Windows OCR on scans, keep
> an optional printer admin password in Windows Credential Manager, and save files where the user chooses. It installs
> no services or drivers and changes no system settings on its own.

### Trademarks and the listing

Inkvolt Print is not an HP product. In every Store text and image:

- Name: "Inkvolt Print" alone. No "HP" in the app name, the reserved name, the logo or the publisher name.
- Say what it works with: "for HP printers", "works with HP LaserJet printers". Not "HP Inkvolt Print", "official", or
  anything suggesting HP made or endorses it, and no HP logo.
- Keep the disclaimer in the description (draft below). Don't use "HP Smart" as a search term.
- Screenshots: the app shows the printer's own picture and details. Use a test printer or redact the serial number,
  product number and IP address ("About this printer" card) before uploading; never publish a real device's identifiers.

### Draft Store description

Short description:

> Printer status, ink and toner, scanning, copying and printing for HP, Canon, Epson, Brother and other network
> printers. No account, no cloud, no telemetry.

Description:

> Inkvolt Print is a lean, private app for your printers. Made for HP printers, it also works with Canon, Epson,
> Brother and other AirPrint, Mopria or IPP Everywhere printers. It finds your printer on the network and shows what
> matters: ready or sleeping, ink or toner levels, paper problems, and usage counts, updated live.
>
> - Find printers automatically, or add one by IP address. Printers already set up in Windows show up too, USB ones
>   included, with the status their driver reports. Older network printers get status and toner over SNMP.
> - Set the printer up in Windows with one click, using Windows' own driver: no driver download.
> - Scan from the glass or the document feeder (AirScan, or the scanner's own Windows driver), several pages at a time,
>   review and crop the pages, skip blank ones, and save as JPEG or as a searchable PDF (text recognition runs on your PC). One-click scan presets.
> - Copy, including ID card copies on one sheet, and print photos in standard sizes.
> - Print PDFs with copies, page ranges and two-sided printing. Drag a PDF onto the window, or right-click a PDF in
>   File Explorer and open it with Inkvolt Print.
> - See and cancel jobs in the print queue, and fix common problems such as a paused or offline printer.
> - Change the printer's own settings, with the admin password kept in Windows Credential Manager if you choose.
>
> No HP account, no cloud service, no ads, no telemetry, no background services. Inkvolt Print talks only to your printer,
> on your network.
>
> Free and open source (MIT License). Source code: https://github.com/gabandres/inkvolt
>
> Inkvolt Print is an independent project, not affiliated with or endorsed by HP Inc., Canon, Seiko Epson or Brother.
> HP and LaserJet are trademarks of HP Inc. Canon, Epson and Brother are trademarks of their owners. They are used only
> to describe the printers Inkvolt Print works with.

Partner Center sits behind a web firewall that rejects a listing save (403 "Access Denied", shown as "We are unable to
save listing") when the text looks like SQL: "; drop a PDF" did. Keep semicolons away from words like drop, delete,
select or insert.

### Spanish listing (es)

Live since 2026-10-30 (Submission 11, Published; `msstore submission get` lists `en-us` and `es`), submitted with the en-us screenshots and the text below; plain Spanish only, which covers every Spanish market (Spanish (Americas), `es-019`, was removed). Partner Center refuses a listing language without its own screenshots (`NoScreenshotsOfAnyType`), and once a draft has been edited in Partner Center the submission API refuses it (409 InvalidState, "in the state 'None'"), so a listing change goes through the Partner Center pages. Their keyword box keeps only one new keyword at a time and drops one that begins a suggestion of its own ("firmar PDF" against "firmar PDF digitalmente"): add one, save, reload, reselect any it dropped from the list, save again, and check the result with `msstore submission get`. When the en-us description changes, change this one to match. The app itself is in English, and the description says so.

Short description:

> Estado de la impresora, tinta y tóner, escaneo, copias e impresión para impresoras de red HP, Canon, Epson, Brother y otras. Sin cuenta, sin nube, sin telemetría.

Description:

> Inkvolt Print es una aplicación ligera y privada para tus impresoras. Hecha para impresoras HP, también funciona con Canon, Epson, Brother y otras impresoras AirPrint, Mopria o IPP Everywhere. Encuentra tu impresora en la red y muestra lo importante: si está lista o en reposo, los niveles de tinta o tóner, los problemas de papel y los contadores de uso, actualizados al momento.
>
> • Encuentra impresoras automáticamente o agrega una por su dirección IP. También aparecen las impresoras ya configuradas en Windows, incluidas las USB, con el estado que informa su controlador. Las impresoras de red más antiguas muestran estado y tóner por SNMP.
> • Configura la impresora en Windows con un clic, con el controlador del propio Windows: no hay que descargar controladores.
> • Escanea desde el cristal o el alimentador de documentos (AirScan, o el controlador de Windows del escáner), varias páginas a la vez; revisa y recorta las páginas, omite las que estén en blanco y guarda como JPEG o como PDF con texto que se puede buscar (el reconocimiento de texto se hace en tu PC). Ajustes de escaneo de un clic.
> • Copia, incluidas copias de identificaciones en una sola hoja, e imprime fotos en tamaños estándar.
> • Imprime PDF con copias, rangos de páginas e impresión a doble cara. Arrastra un PDF a la ventana, o haz clic derecho en un PDF en el Explorador de archivos y ábrelo con Inkvolt Print.
> • Mira y cancela trabajos en la cola de impresión, y resuelve problemas comunes como una impresora en pausa o sin conexión.
> • Cambia la configuración de la propia impresora, guardando la contraseña de administrador en el Administrador de credenciales de Windows si así lo eliges.
>
> Sin cuenta de HP, sin servicio en la nube, sin anuncios, sin telemetría, sin servicios en segundo plano. Inkvolt Print solo se comunica con tu impresora, en tu red.
>
> La aplicación está en inglés.
>
> Gratis y de código abierto (licencia MIT). Código fuente: https://github.com/gabandres/inkvolt
>
> Inkvolt Print es un proyecto independiente, sin relación con HP Inc., Canon, Seiko Epson ni Brother, y sin su respaldo. HP y LaserJet son marcas comerciales de HP Inc. Canon, Epson y Brother son marcas comerciales de sus dueños. Se mencionan solo para describir las impresoras con las que funciona Inkvolt Print.

Features:

> - Encuentra impresoras automáticamente o agrega una por su dirección IP; también las ya configuradas en Windows, incluidas las USB.
> - Configura la impresora en Windows con un clic, con el controlador del propio Windows: no hay que descargar controladores.
> - Escanea desde el cristal o el alimentador, revisa y recorta las páginas, omite las que estén en blanco y guarda como JPEG o PDF con texto buscable.
> - Copia, incluidas copias de identificaciones en una sola hoja, e imprime fotos en tamaños estándar.
> - Imprime PDF con copias, rangos de páginas e impresión a doble cara; arrastra un PDF a la ventana o ábrelo desde el Explorador de archivos.
> - Mira y cancela trabajos en la cola de impresión, y resuelve problemas comunes como una impresora en pausa o sin conexión.
> - Cambia la configuración de la propia impresora, con la contraseña de administrador guardada en el Administrador de credenciales de Windows.

Keywords: impresora, escáner, escanear a PDF, tinta y tóner, imprimir PDF, copiar, impresora de red.

License terms: Inkvolt Print es de código abierto bajo la licencia MIT. Código fuente y licencia: https://github.com/gabandres/inkvolt

### Privacy policy

Partner Center asks for a privacy policy URL; publish a short page saying:

- Inkvolt Print collects no personal data and has no telemetry, analytics, ads or accounts.
- It connects only to printers on the user's local network (discovery, status, scanning, settings, printing through
  the Windows print queue). Nothing is sent to HP or any other service.
- Scans are processed on the PC (OCR with Windows' own recognizer) and saved where the user chooses.
- A printer admin password is stored only if the user asks, in Windows Credential Manager, and is sent only to that
  printer over HTTPS.
- Settings and logs stay in the user's local app data folder.

### Store listing checklist

- [ ] Source link in the description: "Source code (MIT): https://github.com/gabandres/inkvolt".
- [ ] Trademark disclaimer in the description; "for HP printers" / "works with Canon, Epson, Brother" wording only
      (above).
- [ ] Screenshots: PNG, at least 1366x768, 1-10. `InkvoltPrint.exe --snapshot out.png --tab Scan` renders the window after
      connecting; redact device identifiers.
- [ ] Privacy policy URL; support URL or email.
- [ ] Age rating questionnaire; pricing and availability.
- [ ] `runFullTrust` justification.
- [ ] Notes for certification: "Needs a network printer (HP LEDM/CDM, or any IPP Everywhere / AirPrint / Mopria
      printer, with eSCL for scanning, e.g. HP LaserJet MFP M234dw) on the same network for status, scanning and
      printing. Without one, the 'No printers found' screen has "No printer here? Try a demo printer", which opens a second
      window with a made-up printer (no network). No sign-in."

## Local test install (optional)

The Store signs uploads itself; local installs need a trusted signature or Developer Mode. Both are manual steps on
purpose: the script never installs certificates or packages.

**Signed bundle.** `pack-msix.ps1 -App Print -SignWithTestCert` creates `publish/msix/InkvoltPrint-TestSigning.pfx` (no password) and
`.cer` with subject = `-Publisher`, in memory and files only, then signs the bundle and both `.msix`. To install it,
trust the certificate, then add the package (elevated PowerShell for the first command):

```powershell
Import-Certificate publish\msix\InkvoltPrint-TestSigning.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
Add-AppxPackage publish\msix\InkvoltPrint_1.0.0.0.msixbundle
# Remove afterwards:
Get-AppxPackage BermudezSystems.InkvoltPrint | Remove-AppxPackage
Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq 'CN=1CC7D6EF-8A48-4BDE-AF19-4FEC30D5613B' | Remove-Item
```

Anyone holding the `.pfx` can sign packages this PC then trusts: remove the certificate when done, and keep the `.pfx`
out of git (it lives under the ignored `publish/`; `*.pfx` is ignored too).

**Unsigned, Developer Mode.** With Settings > System > For developers > Developer Mode on, register the staged folder
directly: `Add-AppxPackage -Register publish\msix\layout\arm64\AppxManifest.xml` (x64 on x64 PCs).

If an unpackaged Inkvolt Print is installed too, both appear under "Open with"; remove one.

## How the packaged app differs

`AppPackage.IsPackaged` (`src/InkvoltPrint.Windows/AppPackage.cs`) tells the two apart at run time:

- "Open with", the Start menu entry and the `inkvoltprint` command come from the manifest; `ShellIntegration` writes no
  registry entries.
- HP clean-up is hidden unless built with `-IncludeHpCleanup` (above).
- Settings, remembered printers and logs stay at `%LOCALAPPDATA%\InkvoltPrint`; Windows redirects a packaged app's writes
  there into `%LOCALAPPDATA%\Packages\<family>\LocalCache\Local\InkvoltPrint`, so a packaged and an unpackaged copy keep
  separate state. Uninstalling the package removes it. Inkvolt PDF reads Inkvolt Print's remembered printers from whichever
  copy was written last (`InkvoltPaths.StateFiles` in `src/InkvoltPrint.Core/Suite/InkvoltPaths.cs`). Saved printer passwords
  live in Windows Credential Manager, which isn't redirected.
- `InkvoltApps.Find` (`src/InkvoltPrint.Windows/Suite/InkvoltApps.cs`) finds the other Inkvolt app through its execution alias
  (`%LOCALAPPDATA%\Microsoft\WindowsApps\inkvoltpdf.exe` / `inkvoltprint.exe`), then App Paths, then the install folders.
  Inkvolt PDF uses the same code, so "Open in Inkvolt PDF" and Inkvolt PDF's "Printer Settings (Inkvolt Print)" work packaged too.
- Start with Windows is the manifest's startup task, not the HKCU `Run` value; alerts are toasts under the package identity
  (an unpackaged copy registers an AppUserModelId in HKCU for them).
- Single instance, file forwarding and everything else behave the same. Updates come from the Store.
