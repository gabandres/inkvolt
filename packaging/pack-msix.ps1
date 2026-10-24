# Builds Inkvolt Print as MSIX packages (x64 + ARM64) and a bundle for the Microsoft Store. No Windows SDK install needed:
# makeappx/makepri/signtool come from the Microsoft.Windows.SDK.BuildTools NuGet package (packaging/tools).
#
#   pwsh -File packaging/pack-msix.ps1                              Partner Center identity (Store ID 9PNR76HJ62SK), unsigned
#                                                                   (Store signs uploads)
#   pwsh -File packaging/pack-msix.ps1 -Version 1.2.0.0
#   pwsh -File packaging/pack-msix.ps1 -SignWithTestCert            also signs with a self-signed test certificate (.pfx in
#                                                                   the output folder; installed nowhere) for sideloading
#   pwsh -File packaging/pack-msix.ps1 -IncludeHpCleanup            keeps the HP clean-up in the package (sideloading only;
#                                                                   Store builds leave it out, see packaging/README.md)
#
# Output (publish\msix): InkvoltPrint_<ver>_x64.msix, InkvoltPrint_<ver>_arm64.msix, InkvoltPrint_<ver>.msixbundle, InkvoltPrint_<ver>.msixupload.
# See packaging/README.md.
[CmdletBinding()]
param(
    # Partner Center > Product identity > Package/Identity/Name
    [string]$IdentityName = 'BermudezSystems.InkvoltPrint',
    # Partner Center > Product identity > Package/Identity/Publisher (the full "CN=..." string)
    [string]$Publisher = 'CN=1CC7D6EF-8A48-4BDE-AF19-4FEC30D5613B',
    # Partner Center > Product identity > Package/Properties/PublisherDisplayName
    [string]$PublisherDisplayName = 'Bermudez Systems',
    # Package/Properties/DisplayName: must be a name reserved in Partner Center
    [string]$DisplayName = 'Inkvolt Print',
    # Four parts; the Store needs the last one to be 0
    [string]$Version = '1.0.0.0',
    [ValidateSet('x64', 'arm64')]
    [string[]]$Architectures = @('x64', 'arm64'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\publish\msix'),
    # Reuse the publish folders from the last run
    [switch]$NoBuild,
    [switch]$SignWithTestCert,
    # Keep the HP clean-up (removes HP's apps and services) in the package. Off by default: Store builds leave it out.
    [switch]$IncludeHpCleanup
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$OutDir = [IO.Path]::GetFullPath($OutDir)

# ───── Checks ─────
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or ($Version.Split('.') | Where-Object { [int]$_ -gt 65535 })) {
    throw "Version must be four numbers 0-65535 (e.g. 1.0.0.0): $Version"
}
if (-not $Version.EndsWith('.0')) { Write-Warning "The Store rejects packages whose last version number isn't 0 ($Version)." }
if ($IdentityName -notmatch '^[A-Za-z0-9.\-]{3,50}$') { throw "IdentityName: 3-50 letters, digits, '.' or '-': $IdentityName" }
if ($Publisher -notmatch '^CN=') { throw "Publisher must be a distinguished name starting with CN= (copy it from Partner Center): $Publisher" }
if ($IncludeHpCleanup) { Write-Warning 'HP clean-up included: for sideloading only, not for Store upload (see packaging/README.md).' }
if ($IncludeHpCleanup -and $NoBuild) { throw '-IncludeHpCleanup changes the build: run without -NoBuild.' }

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

# ───── Publish (self-contained folder layout: no single-file extraction, starts faster) ─────
New-Item -ItemType Directory -Force $OutDir | Out-Null
$template = Get-Content (Join-Path $PSScriptRoot 'AppxManifest.template.xml') -Raw
$assets = Join-Path $PSScriptRoot 'Assets'
if (-not (Get-ChildItem $assets -Filter *.png -ErrorAction SilentlyContinue)) { throw "No images in $assets (run: python -I assets/make-icon.py)" }

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

$msix = @{}
foreach ($arch in $Architectures) {
    $rid = "win-$arch"
    $pub = Join-Path $OutDir "publish\$rid"
    if (-not $NoBuild) {
        Remove-Item $pub -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Publishing $rid..."
        dotnet publish (Join-Path $root 'src\InkvoltPrint.App') -c Release -r $rid --self-contained true -nologo -v q `
            -p:PublishSingleFile=false -p:Version=$Version -p:CopyOutputSymbolsToPublishDirectory=false `
            -p:HpCleanupInPackage=$(if ($IncludeHpCleanup) { 'true' } else { 'false' }) -o $pub | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Publish failed for $rid." }
    }
    if (-not (Test-Path (Join-Path $pub 'InkvoltPrint.exe'))) { throw "Not found: $pub\InkvoltPrint.exe (run without -NoBuild)" }
    foreach ($dll in 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll', 'CommunityToolkit.Mvvm.dll') {
        if (-not (Test-Path (Join-Path $pub $dll))) { throw "$rid publish lacks $dll" }
    }

    $layout = Join-Path $OutDir "layout\$arch"
    Remove-Item $layout -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $layout | Out-Null
    Get-ChildItem $pub -Exclude *.pdb | Copy-Item -Destination $layout -Recurse
    Copy-Item $assets (Join-Path $layout 'Assets') -Recurse
    Copy-Item $pri $layout
    Copy-Item (Join-Path $root 'THIRD-PARTY-NOTICES.md'), (Join-Path $root 'LICENSE') $layout
    Set-Content (Join-Path $layout 'AppxManifest.xml') (New-Manifest $arch) -Encoding utf8

    $file = Join-Path $packagesDir "InkvoltPrint_${Version}_$arch.msix"
    Write-Host "Packing $([IO.Path]::GetFileName($file))..."
    Invoke-Tool $makeappx @('pack', '/d', $layout, '/p', $file, '/o')
    $msix[$arch] = $file
}

# ───── Bundle + Store upload file ─────
$bundle = Join-Path $OutDir "InkvoltPrint_$Version.msixbundle"
Write-Host "Bundling $([IO.Path]::GetFileName($bundle))..."
Invoke-Tool $makeappx @('bundle', '/d', $packagesDir, '/p', $bundle, '/bv', $Version, '/o')

# .msixupload = a zip holding the bundle (symbol .appxsym files would go beside it; Release builds have no PDBs).
$upload = Join-Path $OutDir "InkvoltPrint_$Version.msixupload"
$zip = "$upload.zip"
Remove-Item $upload, $zip -ErrorAction SilentlyContinue
Compress-Archive -Path $bundle -DestinationPath $zip -CompressionLevel NoCompression
Move-Item $zip $upload -Force

# Per-architecture packages next to the bundle (handy for testing one architecture).
foreach ($f in $msix.Values) { Copy-Item $f $OutDir -Force }

# ───── Optional: test signature for sideloading ─────
if ($SignWithTestCert) {
    $pfx = Join-Path $OutDir 'InkvoltPrint-TestSigning.pfx'
    $cer = Join-Path $OutDir 'InkvoltPrint-TestSigning.cer'
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
    $signed = @($bundle) + @($msix.Keys | ForEach-Object { Join-Path $OutDir "InkvoltPrint_${Version}_$_.msix" })
    foreach ($f in $signed) { Invoke-Tool $signtool @('sign', '/q', '/fd', 'SHA256', '/f', $pfx, $f) }
    Write-Host 'Signed with the test certificate. To sideload, trust it yourself first (see packaging/README.md, "Local test install").'
}

Write-Host ''
Get-ChildItem $OutDir -File | Where-Object Extension -in '.msix', '.msixbundle', '.msixupload', '.pfx', '.cer' |
    Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } | Format-Table -AutoSize | Out-Host
