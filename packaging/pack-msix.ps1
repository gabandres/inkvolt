# Builds Inkvolt PDF or Inkvolt Print as MSIX packages (x64 + ARM64) and a bundle for the Microsoft Store. No Windows SDK
# install needed: makeappx/makepri/signtool come from the Microsoft.Windows.SDK.BuildTools NuGet package (packaging/tools).
# Each app's manifest template and images stay in its own folder (pdf/packaging, print/packaging).
#
#   pwsh -File packaging/pack-msix.ps1 -App Pdf                     Partner Center identity (Store ID 9MXDTSFJ9W28), unsigned
#                                                                   (Store signs uploads)
#   pwsh -File packaging/pack-msix.ps1 -App Print                   Partner Center identity (Store ID 9PNR76HJ62SK), unsigned
#   pwsh -File packaging/pack-msix.ps1 -App Pdf -Version 1.2.0.0
#   pwsh -File packaging/pack-msix.ps1 -App Pdf -SignWithTestCert   also signs with a self-signed test certificate (.pfx in
#                                                                   the output folder; installed nowhere) for sideloading
#   pwsh -File packaging/pack-msix.ps1 -App Print -IncludeHpCleanup keeps the HP clean-up in the package (sideloading only;
#                                                                   Store builds leave it out, see print/packaging/README.md)
#   pwsh -File packaging/pack-msix.ps1 -App Pdf -NoSmoke            skips installing and running this PC's layout
#                                                                   (packaging/smoke-msix.ps1; needs Developer Mode)
#   pwsh -File packaging/pack-msix.ps1 -App Pdf -SmokeSideBySide    builds the real package, then smoke-tests a renamed copy
#                                                                   of the layout (identity <name>.Smoke, its own alias), so
#                                                                   a Store install of the app on this PC stays untouched
#
# Output (<app>\publish\msix): <Name>_<ver>_x64.msix, <Name>_<ver>_arm64.msix, <Name>_<ver>.msixbundle, <Name>_<ver>.msixupload,
# <Name> being InkvoltPdf or InkvoltPrint. See pdf/packaging/README.md and print/packaging/README.md.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Pdf', 'Print')]
    [string]$App,
    # Partner Center > Product identity > Package/Identity/Name (default: the app's)
    [string]$IdentityName,
    # Partner Center > Product identity > Package/Identity/Publisher (the full "CN=..." string)
    [string]$Publisher = 'CN=1CC7D6EF-8A48-4BDE-AF19-4FEC30D5613B',
    # Partner Center > Product identity > Package/Properties/PublisherDisplayName
    [string]$PublisherDisplayName = 'Bermudez Systems',
    # Package/Properties/DisplayName: must be a name reserved in Partner Center (default: the app's)
    [string]$DisplayName,
    # Four parts; the Store needs the last one to be 0
    [string]$Version = '1.0.0.0',
    [ValidateSet('x64', 'arm64')]
    [string[]]$Architectures = @('x64', 'arm64'),
    # Default: <app>\publish\msix
    [string]$OutDir,
    # Reuse the publish folders from the last run
    [switch]$NoBuild,
    [switch]$SignWithTestCert,
    # Inkvolt Print only: keep the HP clean-up (removes HP's apps and services) in the package. Off by default: Store builds
    # leave it out.
    [switch]$IncludeHpCleanup,
    # Skip the smoke test (packaging/smoke-msix.ps1), which installs this PC's layout in Developer Mode and runs it
    [switch]$NoSmoke,
    # Smoke-test a renamed copy of the layout (smoke-msix.ps1 -SmokeSideBySide) instead of the layout itself: needed while
    # the Store copy of the app is installed here. The packages are built with the real identity either way.
    [switch]$SmokeSideBySide
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# What differs between the two apps. Folder: the app's folder in the repo (src, packaging, notices). Required: files the
# publish output must hold (a publish that lacks them would package an app that can't start). Extras: files from the app's
# folder copied into the package root.
$apps = @{
    Pdf   = @{
        Folder = 'pdf'; Name = 'InkvoltPdf'; IdentityName = 'BermudezSystems.InkvoltPDF'; DisplayName = 'Inkvolt PDF'
        # MuPDF's and HarfBuzz's native libraries
        Required = @('MuPDFWrapper.dll', 'libHarfBuzzSharp.dll')
        Extras = @('THIRD-PARTY-NOTICES.md')
    }
    Print = @{
        Folder = 'print'; Name = 'InkvoltPrint'; IdentityName = 'BermudezSystems.InkvoltPrint'; DisplayName = 'Inkvolt Print'
        Required = @('Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll', 'CommunityToolkit.Mvvm.dll')
        Extras = @('THIRD-PARTY-NOTICES.md', 'LICENSE')
    }
}
$cfg = $apps[$App]
$name = $cfg.Name
$appRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\$($cfg.Folder)")).Path
$appPackaging = Join-Path $appRoot 'packaging'
if (-not $IdentityName) { $IdentityName = $cfg.IdentityName }
if (-not $DisplayName) { $DisplayName = $cfg.DisplayName }
if (-not $OutDir) { $OutDir = Join-Path $appRoot 'publish\msix' }
$OutDir = [IO.Path]::GetFullPath($OutDir)

# ───── Checks ─────
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or ($Version.Split('.') | Where-Object { [int]$_ -gt 65535 })) {
    throw "Version must be four numbers 0-65535 (e.g. 1.0.0.0): $Version"
}
if (-not $Version.EndsWith('.0')) { Write-Warning "The Store rejects packages whose last version number isn't 0 ($Version)." }
if ($IdentityName -notmatch '^[A-Za-z0-9.\-]{3,50}$') { throw "IdentityName: 3-50 letters, digits, '.' or '-': $IdentityName" }
if ($Publisher -notmatch '^CN=') { throw "Publisher must be a distinguished name starting with CN= (copy it from Partner Center): $Publisher" }
$notesVersion = ($Version.Split('.')[0..2] -join '.')
$notesFile = Join-Path $appRoot 'WHATS-NEW.md'
if (-not (Select-String -Path $notesFile -Pattern "^## $([regex]::Escape($notesVersion))\s*$" -Quiet)) {
    Write-Warning "$notesFile has no '## $notesVersion' heading: the app's What's New will show nothing for this update (rename '## Next')."
}
if ($IncludeHpCleanup -and $App -ne 'Print') { throw '-IncludeHpCleanup is for Inkvolt Print (-App Print).' }
if ($IncludeHpCleanup) { Write-Warning 'HP clean-up included: for sideloading only, not for Store upload (see print/packaging/README.md).' }
if ($IncludeHpCleanup -and $NoBuild) { throw '-IncludeHpCleanup changes the build: run without -NoBuild.' }
if ($SmokeSideBySide -and $NoSmoke) { throw '-SmokeSideBySide and -NoSmoke: pick one.' }

# ───── Tools ─────
$toolsProj = Join-Path $PSScriptRoot 'tools\BuildTools.csproj'
dotnet restore $toolsProj -nologo -v q | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Could not restore Microsoft.Windows.SDK.BuildTools.' }
$toolsPkg = (dotnet msbuild $toolsProj -t:PrintBuildToolsPath -nologo -v:m | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
$hostArch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'AMD64' { 'x64' } default { 'x86' } }
$toolsBin = Get-ChildItem (Join-Path $toolsPkg 'bin') -Directory | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Join-Path $_.FullName $hostArch }
$makeappx = Join-Path $toolsBin 'makeappx.exe'
$makepri = Join-Path $toolsBin 'makepri.exe'
$signtool = Join-Path $toolsBin 'signtool.exe'
foreach ($t in $makeappx, $makepri, $signtool) { if (-not (Test-Path $t)) { throw "Not found: $t" } }

function Invoke-Tool([string]$exe, [string[]]$arguments) {
    $out = & $exe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | Out-Host
        throw "$([IO.Path]::GetFileName($exe)) failed ($LASTEXITCODE)."
    }
    $out | Where-Object { $_ -match 'warning' } | Out-Host
}

function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

# The DLL names a PE file imports (its import directory), or nothing for a file that isn't one.
function Get-PeImports([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 64 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -lt 0 -or $pe + 24 -gt $b.Length -or [BitConverter]::ToUInt32($b, $pe) -ne 0x4550) { return }
    $sections = [BitConverter]::ToUInt16($b, $pe + 6)
    $opt = $pe + 24
    $dirs = if ([BitConverter]::ToUInt16($b, $opt) -eq 0x20B) { $opt + 112 } else { $opt + 96 }
    $importRva = [BitConverter]::ToUInt32($b, $dirs + 8)
    if ($importRva -eq 0) { return }
    $sectionTable = $opt + [BitConverter]::ToUInt16($b, $pe + 20)
    $toOffset = {
        param([uint32]$rva)
        for ($i = 0; $i -lt $sections; $i++) {
            $s = $sectionTable + 40 * $i
            $va = [BitConverter]::ToUInt32($b, $s + 12)
            $size = [math]::Max([BitConverter]::ToUInt32($b, $s + 8), [BitConverter]::ToUInt32($b, $s + 16))
            if ($rva -ge $va -and $rva -lt $va + $size) { return [long]($rva - $va + [BitConverter]::ToUInt32($b, $s + 20)) }
        }
        -1
    }
    $d = & $toOffset $importRva
    while ($d -ge 0 -and $d + 20 -le $b.Length) {
        $nameRva = [BitConverter]::ToUInt32($b, $d + 12)
        if ($nameRva -eq 0) { break }
        $n = & $toOffset $nameRva
        if ($n -lt 0) { break }
        [Text.Encoding]::ASCII.GetString($b, $n, [Array]::IndexOf($b, [byte]0, [int]$n) - $n)
        $d += 20
    }
}

# A native library that links the Visual C++ runtime starts on a Store PC only if the package ships the runtime or
# declares the VCLibs framework: Inkvolt PDF 1.0.0.0 failed certification for this (pdf/packaging/README.md, "Visual C++
# runtime"). A PC with the redistributable installed, like the one packing, never shows it.
function Assert-VcRuntime([string]$layout, [string]$manifest) {
    if ($manifest -match 'Microsoft\.VCLibs\.140\.00\.UWPDesktop') { return }
    $users = Get-ChildItem $layout -Recurse -Include *.dll, *.exe | ForEach-Object {
        $file = $_
        Get-PeImports $file.FullName | Where-Object { $_ -match '^(msvcp140|vcruntime140)(_\d+)?\.dll$' } |
            Where-Object { -not (Test-Path (Join-Path $file.DirectoryName $_)) } | ForEach-Object { "$($file.Name) -> $_" }
    }
    if ($users) {
        throw "The package links the Visual C++ runtime without shipping it or declaring Microsoft.VCLibs.140.00.UWPDesktop in the manifest: $($users -join '; ')"
    }
}

# ───── Publish (self-contained folder layout: no single-file extraction, starts faster) ─────
New-Item -ItemType Directory -Force $OutDir | Out-Null
$template = Get-Content (Join-Path $appPackaging 'AppxManifest.template.xml') -Raw
$assets = Join-Path $appPackaging 'Assets'
if (-not (Get-ChildItem $assets -Filter *.png -ErrorAction SilentlyContinue)) { throw "No images in $assets (run: python -I $($cfg.Folder)/assets/make-icon.py)" }

function New-Manifest([string]$arch) {
    $values = @{
        IdentityName = $IdentityName; Publisher = $Publisher; Version = $Version; Architecture = $arch
        DisplayName = $DisplayName; PublisherDisplayName = $PublisherDisplayName
    }
    $xml = $template
    foreach ($k in $values.Keys) { $xml = $xml.Replace("{{$k}}", (ConvertTo-XmlText $values[$k])) }
    if ($xml -match '\{\{\w+\}\}') { throw "Unfilled manifest token: $($Matches[0])" }
    $xml
}

$packagesDir = Join-Path $OutDir 'packages'
Remove-Item $packagesDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $packagesDir | Out-Null

# resources.pri: only the images are indexed (the layout's hundreds of runtime files have no qualifiers to resolve),
# from a folder holding just Assets\ and a manifest; the same file then serves every architecture.
$priRoot = Join-Path $OutDir 'pri'
Remove-Item $priRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $priRoot | Out-Null
Copy-Item $assets (Join-Path $priRoot 'Assets') -Recurse
Set-Content (Join-Path $priRoot 'AppxManifest.xml') (New-Manifest $Architectures[0]) -Encoding utf8
$priConfig = Join-Path $OutDir 'priconfig.xml'
Invoke-Tool $makepri @('createconfig', '/cf', $priConfig, '/dq', 'en-US', '/pv', '10.0.0', '/o')
$pri = Join-Path $OutDir 'resources.pri'
Invoke-Tool $makepri @('new', '/pr', $priRoot, '/cf', $priConfig, '/mn', (Join-Path $priRoot 'AppxManifest.xml'), '/of', $pri, '/o')

$publishProps = @('-p:PublishSingleFile=false', "-p:Version=$Version", '-p:CopyOutputSymbolsToPublishDirectory=false')
if ($App -eq 'Print') { $publishProps += "-p:HpCleanupInPackage=$(if ($IncludeHpCleanup) { 'true' } else { 'false' })" }

$msix = @{}
foreach ($arch in $Architectures) {
    $rid = "win-$arch"
    $pub = Join-Path $OutDir "publish\$rid"
    if (-not $NoBuild) {
        Remove-Item $pub -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Publishing $rid..."
        dotnet publish (Join-Path $appRoot "src\$name.App") -c Release -r $rid --self-contained true -nologo -v q `
            @publishProps -o $pub | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Publish failed for $rid." }
    }
    if (-not (Test-Path (Join-Path $pub "$name.exe"))) { throw "Not found: $pub\$name.exe (run without -NoBuild)" }
    foreach ($dll in $cfg.Required) {
        if (-not (Test-Path (Join-Path $pub $dll))) { throw "$rid publish lacks $dll" }
    }

    $layout = Join-Path $OutDir "layout\$arch"
    Remove-Item $layout -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $layout | Out-Null
    Get-ChildItem $pub -Exclude *.pdb | Copy-Item -Destination $layout -Recurse
    Copy-Item $assets (Join-Path $layout 'Assets') -Recurse
    Copy-Item $pri $layout
    Copy-Item ($cfg.Extras | ForEach-Object { Join-Path $appRoot $_ }) $layout
    $manifest = New-Manifest $arch
    Set-Content (Join-Path $layout 'AppxManifest.xml') $manifest -Encoding utf8
    Assert-VcRuntime $layout $manifest

    $file = Join-Path $packagesDir "${name}_${Version}_$arch.msix"
    Write-Host "Packing $([IO.Path]::GetFileName($file))..."
    Invoke-Tool $makeappx @('pack', '/d', $layout, '/p', $file, '/o')
    $msix[$arch] = $file
}

# ───── Bundle + Store upload file ─────
$bundle = Join-Path $OutDir "${name}_$Version.msixbundle"
Write-Host "Bundling $([IO.Path]::GetFileName($bundle))..."
Invoke-Tool $makeappx @('bundle', '/d', $packagesDir, '/p', $bundle, '/bv', $Version, '/o')

# .msixupload = a zip holding the bundle (symbol .appxsym files would go beside it; Inkvolt PDF embeds its PDBs and
# Inkvolt Print's Release builds have none).
$upload = Join-Path $OutDir "${name}_$Version.msixupload"
$zip = "$upload.zip"
Remove-Item $upload, $zip -ErrorAction SilentlyContinue
Compress-Archive -Path $bundle -DestinationPath $zip -CompressionLevel NoCompression
Move-Item $zip $upload -Force

# Per-architecture packages next to the bundle (handy for testing one architecture).
foreach ($f in $msix.Values) { Copy-Item $f $OutDir -Force }

# ───── Optional: test signature for sideloading ─────
if ($SignWithTestCert) {
    $pfx = Join-Path $OutDir "$name-TestSigning.pfx"
    $cer = Join-Path $OutDir "$name-TestSigning.cer"
    $cert = $null
    if (Test-Path $pfx) {
        $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$null, 'Exportable')
        if ($cert.Subject -ne $Publisher -or $cert.NotAfter -lt (Get-Date).AddDays(1)) { $cert = $null }
    }
    if (-not $cert) {
        # Made in memory and written only to files: no certificate store is touched.
        Add-Type -AssemblyName System.Security
        $X = 'System.Security.Cryptography.X509Certificates'
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new($Publisher, $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $req.CertificateExtensions.Add((New-Object "$X.X509BasicConstraintsExtension" $false, $false, 0, $true))
        $req.CertificateExtensions.Add((New-Object "$X.X509KeyUsageExtension" ([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature), $true))
        $eku = [Security.Cryptography.OidCollection]::new()
        $null = $eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3')) # code signing
        $req.CertificateExtensions.Add((New-Object "$X.X509EnhancedKeyUsageExtension" $eku, $false))
        $req.CertificateExtensions.Add((New-Object "$X.X509SubjectKeyIdentifierExtension" $req.PublicKey, $false))
        $cert = $req.CreateSelfSigned((Get-Date).AddDays(-1), (Get-Date).AddYears(1))
        [IO.File]::WriteAllBytes($pfx, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx))
        [IO.File]::WriteAllBytes($cer, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        Write-Host "Created test certificate $([IO.Path]::GetFileName($pfx)) ($Publisher, thumbprint $($cert.Thumbprint))"
    }
    $signed = @($bundle) + @($msix.Keys | ForEach-Object { Join-Path $OutDir "${name}_${Version}_$_.msix" })
    foreach ($f in $signed) { Invoke-Tool $signtool @('sign', '/q', '/fd', 'SHA256', '/f', $pfx, $f) }
    Write-Host "Signed with the test certificate. To sideload, trust it yourself first (see $($cfg.Folder)/packaging/README.md, `"Local test install`")."
}

# ───── Smoke test: install this PC's layout as the Store would and run it ─────
$smokeArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
if ($NoSmoke) { Write-Warning 'Smoke test skipped (-NoSmoke): this package has not been run installed.' }
elseif ($Architectures -notcontains $smokeArch) { Write-Warning "Smoke test skipped: no $smokeArch layout to run on this PC." }
else {
    & (Join-Path $PSScriptRoot 'smoke-msix.ps1') -App $App -Architecture $smokeArch -Layout (Join-Path $OutDir "layout\$smokeArch") `
        -SmokeSideBySide:$SmokeSideBySide
}

Write-Host ''
Get-ChildItem $OutDir -File | Where-Object Extension -in '.msix', '.msixbundle', '.msixupload', '.pfx', '.cer' |
    Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } | Format-Table -AutoSize | Out-Host
