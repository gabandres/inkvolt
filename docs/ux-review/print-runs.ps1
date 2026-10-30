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
