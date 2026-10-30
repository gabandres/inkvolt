# The Inkvolt Print snapshots and UI audits of the UX review (docs/UX-REVIEW.md). Each run renders one state to a PNG
# and writes its audit findings (no accessible name, a target under 24 x 24) beside it.
# Usage: pwsh -File docs/ux-review/print-runs.ps1 -Exe path\to\InkvoltPrint.exe -Out C:\ux
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Out)

New-Item -ItemType Directory -Force $Out | Out-Null
$runs = [ordered]@{
    'overview'          = @()
    'overview-dark'     = @('--theme', 'Dark')
    'narrow'            = @('--size', '1008', '660')
    'no-printers'       = @('--no-printers')
    'inkjet'            = @('--printer', '2')
    'usb'               = @('--printer', '6')
    'scan'              = @('--tab', 'Scan')
    'scan-review'       = @('--tab', 'Scan', '--scan', '3')
    'scan-crop'         = @('--tab', 'Scan', '--scan', '1', '--crop', '1')
    'review-undo'       = @('--tab', 'Scan', '--scan', '3', '--delete', '2')
    'copy'              = @('--tab', 'Copy')
    'photos'            = @('--tab', 'Photos', '--photos')
    'settings-tab'      = @('--tab', 'Printer settings')
    'fixer'             = @('--printer', '3', '--fix')
    'presets'           = @('--presets', '1')
    'dlg-settings'      = @('--dialog', 'settings')
    'dlg-help'          = @('--dialog', 'help')
    'dlg-whatsnew'      = @('--dialog', 'whatsnew')
    'dlg-report'        = @('--dialog', 'report')
    'dlg-addprinter'    = @('--dialog', 'addprinter')
    'dlg-confirm'       = @('--dialog', 'confirm')
}
foreach ($name in $runs.Keys) {
    & $Exe --demo --snapshot (Join-Path $Out "print-$name.png") --a11y-audit (Join-Path $Out "print-$name.txt") @($runs[$name]) | Out-Null
}
# Windows' Text size at 150 % (INKVOLT_TEXTSCALE stands in for the setting)
$env:INKVOLT_TEXTSCALE = '1.5'
foreach ($name in 'overview', 'scan-review', 'dlg-confirm') {
    & $Exe --demo --snapshot (Join-Path $Out "print-$name-textsize150.png") @($runs[$name]) | Out-Null
}
Remove-Item Env:INKVOLT_TEXTSCALE
# Round 2: the command palette (Ctrl+K), and the sidebar folded at 150 % and 200 %, closed and opened
& $Exe --demo --palette --snapshot (Join-Path $Out 'print-palette.png') --a11y-audit (Join-Path $Out 'print-palette.txt') | Out-Null
& $Exe --demo --theme Dark --palette scan --snapshot (Join-Path $Out 'print-palette-scan-dark.png') | Out-Null
& $Exe --demo --palette zzz --snapshot (Join-Path $Out 'print-palette-nomatch.png') | Out-Null
& $Exe --demo --palette 'go to scan' --run-palette --snapshot (Join-Path $Out 'print-palette-ran.png') | Out-Null
foreach ($scale in '1.5', '2') {
    $env:INKVOLT_TEXTSCALE = $scale
    $pct = [int]([double]$scale * 100)
    & $Exe --demo --size 1180 800 --snapshot (Join-Path $Out "print-overview-textsize$pct.png") --a11y-audit (Join-Path $Out "print-overview-textsize$pct.txt") | Out-Null
    & $Exe --demo --size 1180 800 --nav open --snapshot (Join-Path $Out "print-nav-open-textsize$pct.png") | Out-Null
}
Remove-Item Env:INKVOLT_TEXTSCALE
