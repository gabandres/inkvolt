# PrintDesk for the Microsoft Store (MSIX)

`pack-msix.ps1` builds PrintDesk as MSIX packages for x64 and ARM64, bundles them, and writes the Store upload file.
The unpackaged builds (`dotnet publish -p:PublishProfile=win-x64|win-arm64`, the Desk installer) keep working unchanged.

PrintDesk is licensed under the MIT License (`../LICENSE`); dependencies are listed in `../THIRD-PARTY-NOTICES.md`
(both ship in the package and show under "About PrintDesk"). Source: https://github.com/gabandres/PrintDesk.

## Build

```powershell
pwsh -File packaging/pack-msix.ps1                       # placeholder identity, unsigned: proves the build works
pwsh -File packaging/pack-msix.ps1 `
    -IdentityName '12345YourName.PrintDesk' -Publisher 'CN=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX' `
    -PublisherDisplayName 'Your Name' -Version 1.0.0.0     # Store build
```

Other parameters: `-DisplayName` (default `PrintDesk`), `-Architectures x64,arm64`, `-OutDir`, `-NoBuild` (reuse the
last publish), `-SignWithTestCert` (below), `-IncludeHpCleanup` (sideloading only, see "HP clean-up" below).

What it does:

1. Restores `Microsoft.Windows.SDK.BuildTools` (version in `tools/BuildTools.csproj`) into the NuGet cache and uses its
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
| `PrintDesk_<ver>.msixupload` | Upload this to Partner Center (a `.msixbundle` upload works too) |
| `PrintDesk_<ver>.msixbundle` | Both architectures; sideload test |
| `PrintDesk_<ver>_x64.msix`, `PrintDesk_<ver>_arm64.msix` | Single-architecture packages |

Images: `Assets/*.png` are generated, with the icon, by `python -I assets/make-icon.py` (tiles, Start/taskbar target
sizes, store logo, splash screen; the same set as PdfDesk's minus its PDF file-type logo). Commit them after a change.

## Manifest

- `runFullTrust` (every packaged desktop app); nothing else. No `allowElevation` (see "Elevation").
- App execution alias `printdesk.exe`: `printdesk` from a terminal or Run, and how PdfDesk finds and starts a packaged
  PrintDesk.
- File type: `.pdf` only, as an "Open with" entry, the same one the unpackaged app registers in HKCU
  (`src/PrintDesk.App/ShellIntegration.cs`). PrintDesk opens the PDF in its Print tab. It never becomes the default PDF
  app unless the user picks it. No protocol: PrintDesk handles none.

## Elevation (add printer by IP, HP clean-up)

Packaged builds never elevate and never start PowerShell. Microsoft's "Prepare to package a desktop application" page
says Store apps that require elevation for any part of their functionality won't be accepted, and advises against
starting PowerShell or cmd (Windows S mode can't start them). Two features needed administrator rights:

- **Printer added by IP address.** Unpackaged copies create the queue with one UAC prompt (`Add-Printer -IppURL` through
  `src/PrintDesk.Windows/Elevated.cs`). Packaged copies (`Features.ElevatedQueueSetup` in `src/PrintDesk.App/Features.cs`)
  copy the printer's IPP address to the clipboard and open Settings > Printers & scanners, with the steps on screen:
  Add device > "Add manually" > "Add a printer using an IP address or hostname" > IPP Device > paste. PrintDesk then
  watches for ten minutes and links the new queue by its port (`QueuePrinter.FindByHost`). Printers found on the network
  are set up with no prompt in both builds (Windows pairing).
- **HP clean-up.** Left out of packaged builds (below).

So the manifest needs no `allowElevation` and nothing about elevation goes in the certification notes.

**Test before submitting:** sideload (below), add a printer by IP address, press "Set up", add it in Settings as shown,
and check that PrintDesk shows "Ready to print from any app" within a few seconds.

## HP clean-up and the Store

The HP clean-up finds HP Smart and HP's Print Support App, removes them (Store packages of another publisher), deletes
the services and the virtual printer HP's app leaves behind, and turns off Windows' automatic download of manufacturers'
apps. A feature that uninstalls other publishers' software is likely to draw Store policy review, so:

- **Packaged builds hide it by default.** `Features.HpCleanup` is false when PrintDesk runs with package identity: no
  HP banner, no check for HP software. Unpackaged copies keep it.
- **`-IncludeHpCleanup`** builds a package that keeps it (MSBuild property `HpCleanupInPackage=true`, constant
  `HP_CLEANUP_IN_PACKAGE`), for sideloading or other direct distribution. Never upload such a package to the Store.
- The developer CLI (`printdesk hp`) is not packaged.

## Values from Partner Center

Reserve the name **PrintDesk** (or another) in Partner Center, then open the app's **Product management > Product
identity** page and copy:

| Partner Center field | Script parameter | Manifest |
|---|---|---|
| Package/Identity/Name | `-IdentityName` | `Identity/@Name` |
| Package/Identity/Publisher (`CN=...`) | `-Publisher` | `Identity/@Publisher` |
| Package/Properties/PublisherDisplayName | `-PublisherDisplayName` | `Properties/PublisherDisplayName` |
| Reserved app name | `-DisplayName` | `Properties/DisplayName`, tile names |

Version: four numbers, the last one 0 (the Store reserves it), higher than every earlier submission.

## Upload

1. Partner Center > the app > **Start your submission**.
2. **Packages**: drop `PrintDesk_<ver>.msixupload`. Device families: Windows 10/11 Desktop.
3. **Properties**: category Utilities & tools (or Productivity); privacy policy URL (below); support contact.
4. **Age ratings**: the questionnaire (no user-generated content shared, no purchases, talks only to printers on the
   local network).
5. **Store listings** (en-us): description (draft below), at least one screenshot.
6. **Submission options > Restricted capabilities**: explain `runFullTrust` (text below).
7. Submit. Certification normally takes 1-3 business days.

### runFullTrust justification

> PrintDesk is a classic Win32 desktop application (.NET / WPF) packaged with the Desktop Bridge. `runFullTrust` is
> required for every packaged desktop app: PrintDesk runs as a regular full-trust process to find network printers with
> Windows' device discovery, read their status and settings over the local network (HP LEDM, eSCL and IPP), scan,
> render PDFs with Windows' PDF engine and print them through the Windows print system, run Windows OCR on scans, keep
> an optional printer admin password in Windows Credential Manager, and save files where the user chooses. It installs
> no services or drivers and changes no system settings on its own.

### Trademarks and the listing

PrintDesk is not an HP product. In every Store text and image:

- Name: "PrintDesk" alone. No "HP" in the app name, the reserved name, the logo or the publisher name.
- Say what it works with: "for HP printers", "works with HP LaserJet printers". Not "HP PrintDesk", "official", or
  anything suggesting HP made or endorses it, and no HP logo.
- Keep the disclaimer in the description (draft below). Don't use "HP Smart" as a search term.
- Screenshots: the app shows the printer's own picture and details. Use a test printer or redact the serial number,
  product number and IP address ("About this printer" card) before uploading; never publish a real device's identifiers.

### Draft Store description

Short description:

> Printer status, toner, scanning and PDF printing for HP network printers. No account, no cloud, no telemetry.

Description:

> PrintDesk is a lean, private app for HP network printers. It finds your printer on the network and shows what
> matters: ready or sleeping, toner level and pages left, paper problems, and usage counts, updated live.
>
> - Find printers automatically, or add one by IP address.
> - Set the printer up in Windows with one click, using Windows' own driver: no driver download.
> - Scan from the glass or the document feeder, several pages at a time, and save as JPEG or as a searchable PDF (text
>   recognition runs on your PC).
> - Print PDFs with copies, page ranges and two-sided printing; drop a PDF on the window or use "Open with".
> - Change the printer's own settings, with the admin password kept in Windows Credential Manager if you choose.
>
> No HP account, no cloud service, no ads, no telemetry, no background services. PrintDesk talks only to your printer,
> on your network.
>
> Free and open source (MIT License). Source code: https://github.com/gabandres/PrintDesk
>
> PrintDesk is an independent project, not affiliated with or endorsed by HP Inc. HP and LaserJet are trademarks of
> HP Inc., used only to describe the printers PrintDesk works with.

### Privacy policy

Partner Center asks for a privacy policy URL; publish a short page saying:

- PrintDesk collects no personal data and has no telemetry, analytics, ads or accounts.
- It connects only to printers on the user's local network (discovery, status, scanning, settings, printing through
  the Windows print queue). Nothing is sent to HP or any other service.
- Scans are processed on the PC (OCR with Windows' own recognizer) and saved where the user chooses.
- A printer admin password is stored only if the user asks, in Windows Credential Manager, and is sent only to that
  printer over HTTPS.
- Settings and logs stay in the user's local app data folder.

### Store listing checklist

- [ ] Source link in the description: "Source code (MIT): https://github.com/gabandres/PrintDesk".
- [ ] Trademark disclaimer in the description; "for HP printers" wording only (above).
- [ ] Screenshots: PNG, at least 1366x768, 1-10. `PrintDesk.exe --snapshot out.png --tab Scan` renders the window after
      connecting; redact device identifiers.
- [ ] Privacy policy URL; support URL or email.
- [ ] Age rating questionnaire; pricing and availability.
- [ ] `runFullTrust` justification.
- [ ] Notes for certification: "Needs an HP network printer (LEDM/eSCL/IPP, e.g. LaserJet MFP M234dw) on the same
      network for status, scanning and printing; without one the app shows 'No printers found'. No sign-in."

## Local test install (optional)

The Store signs uploads itself; local installs need a trusted signature or Developer Mode. Both are manual steps on
purpose: the script never installs certificates or packages.

**Signed bundle.** `pack-msix.ps1 -SignWithTestCert` creates `publish/msix/PrintDesk-TestSigning.pfx` (no password) and
`.cer` with subject = `-Publisher`, in memory and files only, then signs the bundle and both `.msix`. To install it,
trust the certificate, then add the package (elevated PowerShell for the first command):

```powershell
Import-Certificate publish\msix\PrintDesk-TestSigning.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
Add-AppxPackage publish\msix\PrintDesk_1.0.0.0.msixbundle
# Remove afterwards:
Get-AppxPackage PrintDesk.Placeholder | Remove-AppxPackage
Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq 'CN=PrintDesk Placeholder Publisher' | Remove-Item
```

Anyone holding the `.pfx` can sign packages this PC then trusts: remove the certificate when done, and keep the `.pfx`
out of git (it lives under the ignored `publish/`; `*.pfx` is ignored too).

**Unsigned, Developer Mode.** With Settings > System > For developers > Developer Mode on, register the staged folder
directly: `Add-AppxPackage -Register publish\msix\layout\arm64\AppxManifest.xml` (x64 on x64 PCs).

If an unpackaged PrintDesk is installed too, both appear under "Open with"; remove one.

## How the packaged app differs

`AppPackage.IsPackaged` (`src/PrintDesk.Windows/AppPackage.cs`) tells the two apart at run time:

- "Open with", the Start menu entry and the `printdesk` command come from the manifest; `ShellIntegration` writes no
  registry entries.
- HP clean-up is hidden unless built with `-IncludeHpCleanup` (above).
- Settings, remembered printers and logs stay at `%LOCALAPPDATA%\PrintDesk`; Windows redirects a packaged app's writes
  there into `%LOCALAPPDATA%\Packages\<family>\LocalCache\Local\PrintDesk`, so a packaged and an unpackaged copy keep
  separate state. Uninstalling the package removes it. PdfDesk reads PrintDesk's remembered printers from whichever
  copy was written last (`DeskPaths.StateFiles` in `src/PrintDesk.Core/Suite/DeskPaths.cs`). Saved printer passwords
  live in Windows Credential Manager, which isn't redirected.
- `DeskApps.Find` (`src/PrintDesk.Windows/Suite/DeskApps.cs`) finds the other Desk app through its execution alias
  (`%LOCALAPPDATA%\Microsoft\WindowsApps\pdfdesk.exe` / `printdesk.exe`), then App Paths, then the install folders.
  PdfDesk uses the same code, so "Open in PdfDesk" and PdfDesk's "Printer Settings (PrintDesk)" work packaged too.
- Single instance, file forwarding and everything else behave the same. Updates come from the Store.
