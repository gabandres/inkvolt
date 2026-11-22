# Smoke-tests a Store layout from pack-msix.ps1 the way a Store install runs it: registers <app>\publish\msix\layout\<arch>
# (Developer Mode), drives the installed app through its execution alias, then removes the package. 1.0.0.0 of Inkvolt PDF
# failed certification on a package that had only ever been tested from bin\; this is the test that would have run it.
#
#   pwsh -File packaging/smoke-msix.ps1 -App Pdf     opens a PDF, searches it in find workers (the installed app starting
#                                                    itself), Batch-exports it to Word, converts that .docx back (when
#                                                    Word is installed), makes a PDF from a local web page, and runs
#                                                    --batch and --watch through the alias (Test-CommandLine)
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

# Runs the installed app through its alias with arguments (no window); returns its exit code (-1: didn't end in time).
function Invoke-Alias([string[]]$arguments, [string]$log, [int]$seconds = 120) {
    $quoted = $arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    $env:INKVOLTPDF_DATA = Join-Path $work 'data'
    try { $p = Start-Process $alias -ArgumentList $quoted -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden }
    finally { Remove-Item Env:INKVOLTPDF_DATA -ErrorAction SilentlyContinue }
    $null = $p.Handle # keeps the exit code readable
    if (-not $p.WaitForExit($seconds * 1000)) { $p.Kill($true); return -1 }
    $p.ExitCode
}

# Inkvolt PDF's --batch and --watch through the alias, in Documents, the temp folder and a network share (this PC's own
# administrative share over SMB, when it answers): exit codes, results and moved originals looked for from outside the
# package (a packaged app's writes under AppData could land in its private copy instead), and --watch stopped by Ctrl+C.
# Returns what failed.
function Test-CommandLine([string]$sample) {
    $failed = [Collections.Generic.List[string]]::new()
    $preset = Join-Path $work 'smoke-preset.json'
    Set-Content $preset -Encoding utf8NoBOM -Value '{ "format": "Inkvolt PDF batch preset", "version": 1, "name": "Smoke", "output": { "names": "<<name>> smoke" }, "actions": [ { "action": "watermark", "text": "SMOKE" } ] }'
    $tag = "inkvolt-smoke-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $temp = Join-Path ([IO.Path]::GetTempPath()) $tag
    $places = [ordered]@{ Documents = Join-Path ([Environment]::GetFolderPath('MyDocuments')) $tag; Temp = $temp }
    $drive = $temp.Substring(0, 1)
    if (Test-Path "\\127.0.0.1\$drive`$\") { $places.Share = "\\127.0.0.1\$drive`$$($temp.Substring(2))-share" }
    else { Write-Host "Command line on a share skipped: \\127.0.0.1\$drive`$ doesn't answer here." }
    try {
        foreach ($place in $places.GetEnumerator()) {
            $root = $place.Value
            $in = Join-Path $root 'in'
            $out = Join-Path $root 'out'
            New-Item -ItemType Directory -Force $in | Out-Null
            Copy-Item $sample (Join-Path $in 'a.pdf')
            Set-Content (Join-Path $in 'b.pdf') 'not a PDF' -Encoding ascii
            $log = Join-Path $work "cli-$($place.Key)"

            $code = Invoke-Alias @('--batch', $preset, (Join-Path $in 'a.pdf'), '--out', $out) "$log-batch"
            if ($code -ne 0) { $failed.Add("--batch in $($place.Key) exited $code, not 0 ($log-batch.err)") }
            if (-not (Test-Path (Join-Path $out 'a smoke.pdf'))) { $failed.Add("--batch in $($place.Key) left no result to see from outside the package ($out)") }
            $code = Invoke-Alias @('--batch', $preset, $in, '--out', $out) "$log-batch2"
            if ($code -ne 1) { $failed.Add("--batch with a file that isn't a PDF in $($place.Key) exited $code, not 1") }
            if (-not (Select-String -Path "$log-batch2.err" -Pattern 'failed +b\.pdf' -Quiet)) { $failed.Add("--batch in $($place.Key) didn't report b.pdf as failed") }

            # --watch --once: a scheduled task's run.
            $watch = Join-Path $root 'watch'
            New-Item -ItemType Directory -Force $watch | Out-Null
            Move-Item (Join-Path $in '*.pdf') $watch
            $code = Invoke-Alias @('--watch', $watch, '--preset', $preset, '--once') "$log-watch"
            if ($code -ne 1) { $failed.Add("--watch --once in $($place.Key) exited $code, not 1 (b.pdf fails)") }
            foreach ($moved in 'done\a.pdf', 'failed\b.pdf', 'results\a smoke.pdf', 'inkvolt-watch.log') {
                if (-not (Test-Path (Join-Path $watch $moved))) { $failed.Add("--watch --once in $($place.Key): no $moved to see from outside the package") }
            }
            Write-Host "Command line in $($place.Key) ($root): --batch and --watch --once checked"
        }

        $code = Invoke-Alias @('--batch', (Join-Path $work 'no-such-preset.json'), $sample, '--out', $temp) (Join-Path $work 'cli-wrong')
        if ($code -ne 2) { $failed.Add("--batch with a missing preset exited $code, not 2") }

        # Typed in a terminal (nothing redirected; 1.15.0 ended at once there, printing nothing): a hidden PowerShell with a
        # console of its own runs --help and saves what its console shows.
        $shown = Join-Path $work 'cli-terminal.txt'
        $terminal = Join-Path $work 'terminal.ps1'
        Set-Content $terminal -Encoding utf8 -Value @'
param([string]$Alias, [string]$Out, [string]$Data)
$env:INKVOLTPDF_DATA = $Data
$p = Start-Process $Alias -ArgumentList '--help' -NoNewWindow -PassThru
$null = $p.Handle
if (-not $p.WaitForExit(60000)) { $p.Kill($true) }
$raw = $Host.UI.RawUI
$cells = $raw.GetBufferContents([Management.Automation.Host.Rectangle]::new(0, 0, $raw.BufferSize.Width - 1, $raw.CursorPosition.Y))
$lines = for ($y = 0; $y -le $cells.GetUpperBound(0); $y++) { -join (0..$cells.GetUpperBound(1) | ForEach-Object { $cells[$y, $_].Character }) }
@("exit $($p.ExitCode)") + ($lines | ForEach-Object TrimEnd) | Set-Content $Out
'@
        Start-Process pwsh -ArgumentList '-NoProfile', '-File', "`"$terminal`"", '-Alias', "`"$alias`"", '-Out', "`"$shown`"", '-Data', "`"$(Join-Path $work 'data')`"" -WindowStyle Hidden -Wait
        $text = if (Test-Path $shown) { Get-Content $shown -Raw } else { '' }
        if ($text -notmatch '^exit 0' -or $text -notmatch 'Inkvolt PDF command line') { $failed.Add("--help typed in a terminal showed no help or didn't exit 0 ($shown)") }
        else { Write-Host 'Command line: --help typed in a terminal showed its help (exit 0)' }

        # --watch until Ctrl+C, in a console of its own (a hidden PowerShell that starts it, drops a file in, waits for it to be
        # done, then presses Ctrl+C on that console, itself ignoring it): it must end by itself, exit 0 and leave no lock.
        $stopRoot = if ($places.Contains('Share')) { $places.Share } else { $temp }
        $stop = Join-Path $stopRoot 'watch-stop'
        New-Item -ItemType Directory -Force $stop | Out-Null
        $helper = Join-Path $work 'ctrl-c.ps1'
        Set-Content $helper -Encoding utf8 -Value @'
param([string]$Alias, [string]$Folder, [string]$Preset, [string]$Sample, [string]$Log, [string]$Data)
Add-Type -Namespace Smoke -Name Ctrl -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr handler, bool add);'
$env:INKVOLTPDF_DATA = $Data
$p = Start-Process $Alias -ArgumentList '--watch', "`"$Folder`"", '--preset', "`"$Preset`"" -NoNewWindow -PassThru -RedirectStandardOutput "$Log.out" -RedirectStandardError "$Log.err"
$null = $p.Handle
$deadline = (Get-Date).AddSeconds(90)
while (-not (Test-Path (Join-Path $Folder 'working')) -and -not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
if (Test-Path (Join-Path $Folder 'working')) {
    Copy-Item $Sample (Join-Path $Folder 'c.pdf')
    while (-not (Test-Path (Join-Path $Folder 'done\c.pdf')) -and -not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
}
if ($p.HasExited) { exit 97 }
if (-not (Test-Path (Join-Path $Folder 'done\c.pdf'))) { $p.Kill($true); exit 96 } # it never started watching, or c.pdf was never done
[Smoke.Ctrl]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null # this PowerShell ignores it; the watcher takes it (ConsoleOutput), even passed down "ignore" from Git Bash
[Smoke.Ctrl]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
if (-not $p.WaitForExit(30000)) { $p.Kill($true); exit 98 }
exit $p.ExitCode
'@
        $h = Start-Process pwsh -ArgumentList '-NoProfile', '-File', "`"$helper`"", '-Alias', "`"$alias`"", '-Folder', "`"$stop`"", '-Preset', "`"$preset`"",
            '-Sample', "`"$sample`"", '-Log', "`"$(Join-Path $work 'cli-stop')`"", '-Data', "`"$(Join-Path $work 'data')`"" -WindowStyle Hidden -PassThru
        $null = $h.Handle
        # A timeout ends the watcher too (the helper's child), so no --watch is left holding the folder's lock.
        if (-not $h.WaitForExit(180000)) { $h.Kill($true); $failed.Add('--watch until Ctrl+C: the test didn''t end in 3 minutes') }
        elseif ($h.ExitCode -ne 0) {
            $why = switch ($h.ExitCode) {
                96 { "it never started watching, or c.pdf dropped in wasn't done within 90 s" }
                97 { 'it ended before Ctrl+C' }
                98 { "it didn't end within 30 s of Ctrl+C" }
                default { "it exited $($h.ExitCode), not 0" }
            }
            $failed.Add("--watch until Ctrl+C: $why ($(Join-Path $work 'cli-stop').err)")
        }
        else {
            if (Test-Path (Join-Path $stop '.inkvolt-watch.lock')) { $failed.Add('--watch left its lock file after Ctrl+C') }
            if (@(Get-ChildItem (Join-Path $stop 'working') -File -ErrorAction SilentlyContinue).Count) { $failed.Add('--watch left files in working after Ctrl+C') }
            Write-Host "Command line: --watch in $stop stopped by Ctrl+C (exit 0)"
        }
    }
    finally {
        foreach ($root in $places.Values) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $failed
}

$failures = [Collections.Generic.List[string]]::new()
Write-Host "Registering $($identity.Name) $($identity.Version) ($Architecture) from $Layout..."
Add-AppxPackage -Register $manifestPath
try {
    if (-not (Test-Path $alias)) { throw "The package registered but its execution alias is missing: $alias" }

    if ($App -eq 'Pdf') {
        # Explorer's "Convert to Word with Inkvolt PDF": the package's ProgId for .pdf carries the verb (Explorer shows it
        # while Inkvolt PDF opens PDFs; the right-click itself is a person's check).
        $verb = Get-ChildItem 'HKCU:\Software\Classes' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'AppX*' -and (Test-Path "$($_.PSPath)\Shell\ConvertToWord") } |
            Where-Object { "$((Get-ItemProperty "$($_.PSPath)\Shell\ConvertToWord").'(default)')" -like "*$($identity.Name)_*ConvertToWordVerb*" }
        if (-not $verb) { $failures.Add('the package registered no Convert to Word verb on .pdf') }
        else { Write-Host "Convert to Word verb registered on $($verb[0].PSChildName)" }

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

        # The command line through the alias, as a terminal, a script or a scheduled task runs it.
        foreach ($f in Test-CommandLine $pdf) { $failures.Add("command line: $f") }
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
