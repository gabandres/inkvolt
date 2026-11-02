# Smoke-tests a Store layout from pack-msix.ps1 the way a Store install runs it: registers <app>\publish\msix\layout\<arch>
# (Developer Mode), drives the installed app through its execution alias, then removes the package. 1.0.0.0 of Inkvolt PDF
# failed certification on a package that had only ever been tested from bin\; this is the test that would have run it.
#
#   pwsh -File packaging/smoke-msix.ps1 -App Pdf     opens a PDF, searches it in find workers (the installed app starting
#                                                    itself), Batch-exports it to Word, converts that .docx back (when
#                                                    Word is installed), and makes a PDF from a local web page
#   pwsh -File packaging/smoke-msix.ps1 -App Print   renders the demo printers' Overview to a PNG
#   pwsh -File packaging/smoke-msix.ps1 -App Pdf -SmokeSideBySide
#                                                    runs a renamed copy of the layout (identity <name>.Smoke, alias
#                                                    inkvoltpdfsmoke.exe / inkvoltprintsmoke.exe) beside a Store install
#
# Needs Settings > System > For developers > Developer Mode, and no Store install of the same app (registering would
# replace it) unless -SmokeSideBySide. Work files: <app>\publish\smoke (and smoke-side\<arch> for the renamed copy).
# pack-msix.ps1 runs this unless given -NoSmoke.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Pdf', 'Print')]
    [string]$App,
    # Default: this PC's architecture (only that one can run here)
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,
    # Default: <app>\publish\msix\layout\<arch>
    [string]$Layout,
    [int]$TimeoutSeconds = 240,
    # Register a copy of the layout under another identity and alias, so a Store install of the app and its data stay
    # untouched. The copy differs from the package only in the manifest's Identity Name and ExecutionAlias.
    [switch]$SmokeSideBySide
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$apps = @{
    Pdf   = @{ Folder = 'pdf'; Process = 'InkvoltPdf'; Alias = 'inkvoltpdf.exe' }
    Print = @{ Folder = 'print'; Process = 'InkvoltPrint'; Alias = 'inkvoltprint.exe' }
}
$cfg = $apps[$App]
$appRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\$($cfg.Folder)")).Path
if (-not $Architecture) { $Architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' } }
if (-not $Layout) { $Layout = Join-Path $appRoot "publish\msix\layout\$Architecture" }
$manifestPath = Join-Path $Layout 'AppxManifest.xml'
if (-not (Test-Path $manifestPath)) { throw "Not found: $manifestPath (run packaging/pack-msix.ps1 -App $App first)" }

$unlock = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
if (-not $unlock -or $unlock.PSObject.Properties['AllowDevelopmentWithoutDevLicense']?.Value -ne 1) {
    throw 'Developer Mode is off (Settings > System > For developers): the layout cannot be registered.'
}
$aliasName = $cfg.Alias
if ($SmokeSideBySide) {
    $side = Join-Path $appRoot "publish\smoke-side\$Architecture"
    Remove-Item $side -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $side | Out-Null
    Copy-Item (Join-Path $Layout '*') $side -Recurse
    $realName = ([xml](Get-Content $manifestPath -Raw)).Package.Identity.Name
    $aliasName = $cfg.Alias.Replace('.exe', 'smoke.exe')
    $xml = Get-Content $manifestPath -Raw
    $renamed = $xml.Replace("Name=`"$realName`"", "Name=`"$realName.Smoke`"").Replace("Alias=`"$($cfg.Alias)`"", "Alias=`"$aliasName`"")
    if ($renamed -notmatch [regex]::Escape("Name=`"$realName.Smoke`"") -or $renamed -notmatch [regex]::Escape("Alias=`"$aliasName`"")) {
        throw "Could not rename the identity and alias in $manifestPath."
    }
    $Layout = $side
    $manifestPath = Join-Path $side 'AppxManifest.xml'
    Set-Content $manifestPath $renamed -Encoding utf8 -NoNewline
}
$Layout = (Resolve-Path $Layout).Path
$identity = ([xml](Get-Content $manifestPath -Raw)).Package.Identity
$installed = Get-AppxPackage -Name $identity.Name
if ($installed -and -not $installed.IsDevelopmentMode) {
    throw "$($identity.Name) $($installed.Version) is installed from the Store; registering the layout would replace it. Use -SmokeSideBySide, uninstall it first, or pack with -NoSmoke."
}

$work = Join-Path $appRoot 'publish\smoke'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $work 'out') | Out-Null
$alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$aliasName"
# The registered layout's process only: a registered layout runs in place, and a Store install or a copy installed by
# install-suite.ps1 may be running too.
function Get-Packaged {
    Get-Process -Name $cfg.Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Layout\*" }
}

# A one-page PDF with a line of Helvetica text; offsets computed so the xref is exact.
function New-SamplePdf([string]$path) {
    $text = 'BT /F1 24 Tf 72 720 Td (Inkvolt smoke test) Tj ET'
    $objects = @(
        '<< /Type /Catalog /Pages 2 0 R >>'
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>'
        "<< /Length $($text.Length) >>`nstream`n$text`nendstream"
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    )
    $sb = [Text.StringBuilder]::new("%PDF-1.4`n")
    $offsets = foreach ($i in 0..($objects.Count - 1)) {
        $sb.Length
        $null = $sb.Append("$($i + 1) 0 obj`n$($objects[$i])`nendobj`n")
    }
    $xref = $sb.Length
    $null = $sb.Append("xref`n0 $($objects.Count + 1)`n0000000000 65535 f `n")
    foreach ($o in $offsets) { $null = $sb.Append(('{0:D10} 00000 n `n' -f $o)) }
    $null = $sb.Append("trailer`n<< /Size $($objects.Count + 1) /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n")
    [IO.File]::WriteAllText($path, $sb.ToString(), [Text.Encoding]::ASCII)
}

$failures = [Collections.Generic.List[string]]::new()
Write-Host "Registering $($identity.Name) $($identity.Version) ($Architecture) from $Layout..."
Add-AppxPackage -Register $manifestPath
try {
    if (-not (Test-Path $alias)) { throw "The package registered but its execution alias is missing: $alias" }

    if ($App -eq 'Pdf') {
        $pdf = Join-Path $work 'sample.pdf'
        New-SamplePdf $pdf
        $page = Join-Path $work 'page.html'
        Set-Content $page '<html><body><h1>Smoke page</h1><p>Hello from a local page.</p></body></html>' -Encoding utf8
        $out = Join-Path $work 'out'
        $docx = Join-Path $out 'sample.docx'
        $indexed = Join-Path $work 'indexed'
        New-Item -ItemType Directory -Force $indexed | Out-Null
        Copy-Item $pdf $indexed
        $steps = @(
            'wait 2500'
            'converters'
            "shot $work\open.png"
            'findworkers smoke'
            'batch'
            "batchadd $pdf"
            'batchstep export word'
            "batchout $out"
            'batchrun'
            'batchclose'
            "webpage $page"
            "indexadd $indexed"
            'indexwait 60'
            'indexsearch smoke'
            'indexremove'
            'exit'
        )
        $script = Join-Path $work 'steps.txt'
        Set-Content $script $steps -Encoding utf8
        $log = "$script.log"

        $env:INKVOLTPDF_DEVSCRIPT = '1'
        $env:INKVOLTPDF_DATA = Join-Path $work 'data'
        try { Start-Process $alias -ArgumentList $pdf, '--script', $script | Out-Null }
        finally { Remove-Item Env:INKVOLTPDF_DEVSCRIPT, Env:INKVOLTPDF_DATA -ErrorAction SilentlyContinue }

        # The script's log is rewritten after every step; it is complete once it holds "ok: exit" or a FAILED line.
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep 1
            $lines = if (Test-Path $log) { @(Get-Content $log) } else { @() }
        } until (($lines -match '^(ok: exit|FAILED)') -or (Get-Date) -gt $deadline)
        $lines | Out-Host

        if (-not ($lines -match '^ok: exit')) { $failures.Add("the dev script did not finish within $TimeoutSeconds s") }
        if ($lines -match '^FAILED') { $failures.Add('a dev-script step failed (log above)') }
        if (-not (Test-Path "$work\open.png")) { $failures.Add('no window snapshot (open.png)') }
        if (-not ($lines -match '^findworkers: started=2 failed=0 pages=[1-9].* left running=0$')) { $failures.Add('the package could not search in find workers (log above)') }
        if (-not ($lines -match '^indexsearch smoke: 1 results')) { $failures.Add('the package could not index a folder in index workers (log above)') }
        if (-not (Test-Path $docx) -or (Get-Item $docx).Length -lt 1000) { $failures.Add('Batch export to Word wrote no sample.docx') }
        if (-not ($lines -match '^webpage: [1-9]\d* bytes')) { $failures.Add('Create PDF from Web Page made no PDF') }

        # Office conversion: only where Word is installed (the Store's test PCs may lack it; the app hides the menu then).
        if (($lines -match '^converters: office=\[[^\]]*Word') -and (Test-Path $docx)) {
            $script2 = Join-Path $work 'steps2.txt'
            Set-Content $script2 @('wait 1500', "convert $docx", 'exit') -Encoding utf8
            $env:INKVOLTPDF_DEVSCRIPT = '1'
            $env:INKVOLTPDF_DATA = Join-Path $work 'data'
            try { Start-Process $alias -ArgumentList '--script', $script2 | Out-Null }
            finally { Remove-Item Env:INKVOLTPDF_DEVSCRIPT, Env:INKVOLTPDF_DATA -ErrorAction SilentlyContinue }
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            do {
                Start-Sleep 1
                $lines2 = if (Test-Path "$script2.log") { @(Get-Content "$script2.log") } else { @() }
            } until (($lines2 -match '^(ok: exit|FAILED)') -or (Get-Date) -gt $deadline)
            $lines2 | Out-Host
            if (-not ($lines2 -match '^convert: .* pages=[1-9]')) { $failures.Add('converting the .docx back to PDF through Word failed') }
        }
    }
    else {
        $png = Join-Path $work 'overview.png'
        Start-Process $alias -ArgumentList '--demo', '--snapshot', $png, '--tab', 'Overview', '--size', '1366', '860' | Out-Null
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do { Start-Sleep 1 } until ((Test-Path $png) -and -not (Get-Packaged) -or (Get-Date) -gt $deadline)
        if (-not (Test-Path $png) -or (Get-Item $png).Length -lt 10000) { $failures.Add('no Overview snapshot of the demo printers (overview.png)') }
        else { Write-Host "Overview snapshot: $png ($([math]::Round((Get-Item $png).Length / 1KB)) KB)" }
    }
}
finally {
    Get-Packaged | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Get-AppxPackage -Name $identity.Name | Remove-AppxPackage
    Remove-Item (Join-Path $work 'data') -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Host "SMOKE FAILED: $_" -ForegroundColor Red }
    throw "Smoke test of the $App layout failed ($($failures.Count)); the package is not fit to upload."
}
Write-Host "Smoke test passed: $($identity.Name) $($identity.Version) ($Architecture) installed, ran and was removed. Snapshots in $work."
