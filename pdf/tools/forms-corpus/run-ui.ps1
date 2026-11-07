# The UI half of the forms corpus: Inkvolt PDF itself opens each sample form with a generated --script that fits the
# page, clicks each of the first fields with real mouse messages, types with real key messages, presses Tab, then
# saves; the harness then reads what the app saved back (FormsCorpus uicheck). This is the page view's own path:
# PageViewer's click and editor, DocumentTab's queued fill, the edit transaction, Save As.
#
#   pwsh -File pdf/tools/forms-corpus/run-ui.ps1                       the 20 sample forms below, 8 fields each
#   pwsh -File pdf/tools/forms-corpus/run-ui.ps1 -Forms irs-fw9 -Fields 20
#   pwsh -File pdf/tools/forms-corpus/run-ui.ps1 -App C:\path\InkvoltPdf.exe   an already built app
#
# Results: .cache\ui\<name>.steps.txt.log (the app's log of each step), <name>.ui.pdf (what it saved) and summary.txt.
[CmdletBinding()]
param(
    [string[]]$Forms = @(
        'irs-fw9', 'irs-f1040', 'irs-f941', 'irs-fw4', 'irs-f8822', 'uscis-i-9', 'va-vba-21-4138-are', 'ca-ftb-540',
        'ny-it2104', 'nj-st3', 'pdfjs-textfields', 'pdfjs-annotation-choice-widget', 'pdfjs-js-colors', 'pdfbox-acroformsbasicfields',
        'pdflib-fancy_fields', 'oo-pdfformexample', 'qpdf-field-types', 'synth-js-es', 'synth-inherited', 'synth-radio-kids'),
    [int]$Fields = 8,
    [string]$App,
    [int]$TimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = $PSScriptRoot
$root = Resolve-Path (Join-Path $here '..\..\..')
$cache = Join-Path $here '.cache\pdfs'
$ui = Join-Path $here '.cache\ui'
New-Item -ItemType Directory -Force $ui | Out-Null

Write-Host 'Building FormsCorpus...'
dotnet build $here -c Release -nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'FormsCorpus did not build.' }
$dll = Get-ChildItem (Join-Path $here 'bin\Release') -Recurse -Filter FormsCorpus.dll | Sort-Object LastWriteTime | Select-Object -Last 1
# The synthetic forms are written by the harness; make sure they exist for the sample.
& dotnet $dll.FullName synth $cache | Out-Null

if (-not $App) {
    Write-Host 'Building Inkvolt PDF...'
    $proj = Join-Path $root 'pdf\src\InkvoltPdf.App\InkvoltPdf.App.csproj'
    dotnet build $proj -c Release -nologo -v q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Inkvolt PDF did not build.' }
    $App = (Get-ChildItem (Join-Path $root 'pdf\src\InkvoltPdf.App\bin\Release') -Recurse -Filter InkvoltPdf.exe | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
}

$rows = foreach ($name in $Forms) {
    $pdf = Join-Path $cache "$name.pdf"
    if (-not (Test-Path $pdf)) { [pscustomobject]@{ Form = $name; Result = 'not downloaded (fetch.ps1)' }; continue }
    $steps = & dotnet $dll.FullName script $pdf $ui $Fields
    $saved = Join-Path $ui "$name.ui.pdf"
    Remove-Item -Force -ErrorAction SilentlyContinue $saved, "$steps.log"
    # A copy to open, so the app never writes next to the corpus file; settings go to a throwaway data folder.
    $open = Join-Path $ui "$name.pdf"
    Copy-Item -Force $pdf $open
    $start = New-Object Diagnostics.ProcessStartInfo $App
    $start.UseShellExecute = $false
    $start.ArgumentList.Add($open); $start.ArgumentList.Add('--script'); $start.ArgumentList.Add($steps)
    $start.Environment['INKVOLTPDF_DEVSCRIPT'] = '1'
    $start.Environment['INKVOLTPDF_DATA'] = (Join-Path $ui 'data')
    $p = [Diagnostics.Process]::Start($start)
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { $p.Kill($true); $result = "HANG (over $TimeoutSeconds s)" }
    else {
        $log = if (Test-Path "$steps.log") { Get-Content "$steps.log" -Raw } else { '' }
        $check = & dotnet $dll.FullName uicheck $saved (Join-Path $ui "$name.expected.json")
        $failedStep = ($log -split "`n" | Where-Object { $_ -like 'FAILED*' } | Select-Object -First 1)
        $result = if ($failedStep) { "SCRIPT FAILED: $($failedStep.Substring(0, [Math]::Min(160, $failedStep.Length)))" } else { ($check -join ' | ') }
    }
    Write-Host "$name : $result"
    [pscustomobject]@{ Form = $name; Result = $result }
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Tee-Object (Join-Path $ui 'summary.txt') | Out-Host
