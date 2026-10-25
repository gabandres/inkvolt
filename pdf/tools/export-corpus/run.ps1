# Exports the real-world corpus (corpus.json) to Word with the current code and counts each result's pages in Word. A
# layout regression shows up as more Word pages than last time (baseline.json): text that falls out of its frames, rows
# that wrap, spacing that grows. Needs Word (the page count is Word's own layout).
#
#   pwsh -File pdf/tools/export-corpus/run.ps1                     export, count, compare with baseline.json
#   pwsh -File pdf/tools/export-corpus/run.ps1 -Files a.pdf,b.pdf  also export these (counted, no baseline: a user's file)
#   pwsh -File pdf/tools/export-corpus/run.ps1 -UpdateBaseline     accept the current counts (after a change that's better)
#
# Downloads go to .cache\, results to .cache\out\<name>.docx and .txt, to open in Word beside the PDF. A downloaded file
# whose SHA-256 differs from the baseline's (the publisher replaced it) is reported and not compared.
[CmdletBinding()]
param(
    [string[]]$Files = @(),
    [switch]$UpdateBaseline,
    # Word pages a document may gain before it counts as a regression
    [int]$Slack = 0
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = $PSScriptRoot
$cache = Join-Path $here '.cache'
$out = Join-Path $cache 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$corpus = Get-Content (Join-Path $here 'corpus.json') -Raw | ConvertFrom-Json
$baselinePath = Join-Path $here 'baseline.json'
$baseline = @{}
if (Test-Path $baselinePath) {
    (Get-Content $baselinePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $baseline[$_.Name] = $_.Value }
}

Write-Host 'Building ExportCorpus...'
dotnet build $here -c Release -nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'ExportCorpus did not build (run: dotnet build pdf/tools/export-corpus).' }
$dll = Get-ChildItem (Join-Path $here 'bin\Release') -Recurse -Filter ExportCorpus.dll | Sort-Object LastWriteTime | Select-Object -Last 1

$items = [Collections.Generic.List[object]]::new()
foreach ($c in $corpus) {
    $pdf = Join-Path $cache "$($c.name).pdf"
    if (-not (Test-Path $pdf)) {
        Write-Host "Downloading $($c.name)..."
        Invoke-WebRequest $c.url -OutFile $pdf -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    }
    $items.Add([pscustomobject]@{
        Name = $c.name; Pdf = $pdf; Sha = (Get-FileHash $pdf -Algorithm SHA256).Hash.ToLowerInvariant(); Base = $baseline[$c.name]
        PdfPages = 0; WordPages = 0; Docx = $null
    })
}
foreach ($f in $Files) {
    $full = (Resolve-Path $f).Path
    $items.Add([pscustomobject]@{
        Name = [IO.Path]::GetFileNameWithoutExtension($full); Pdf = $full; Sha = $null; Base = $null; PdfPages = 0; WordPages = 0; Docx = $null
    })
}

foreach ($i in $items) {
    $i.Docx = Join-Path $out "$($i.Name).docx"
    $line = dotnet $dll.FullName export $i.Pdf $i.Docx
    if ($LASTEXITCODE -ne 0) { throw "Export failed: $($i.Name)" }
    $i.PdfPages = [int]([regex]::Match("$line", ': (\d+) page').Groups[1].Value)
}

$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
try {
    foreach ($i in $items) {
        $d = $word.Documents.Open($i.Docx, $false, $true)
        $i.WordPages = $d.ComputeStatistics(2) # wdStatisticPages
        $d.Close(0)
    }
}
finally {
    $word.Quit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($word)
}

$regressions = 0
$rows = foreach ($i in $items) {
    $verdict = if (-not $i.Sha) { 'no baseline (local file)' }
    elseif (-not $i.Base) { 'new' }
    elseif ($i.Base.sha256 -ne $i.Sha) { 'source changed: not compared' }
    elseif ($i.WordPages -gt $i.Base.wordPages + $Slack) { $regressions++; "REGRESSION (was $($i.Base.wordPages))" }
    elseif ($i.WordPages -lt $i.Base.wordPages) { "better (was $($i.Base.wordPages))" }
    else { 'same' }
    [pscustomobject]@{ Document = $i.Name; 'PDF pages' = $i.PdfPages; 'Word pages' = $i.WordPages; Result = $verdict }
}
$rows | Format-Table -AutoSize | Out-Host
Write-Host "Exports: $out"

if ($UpdateBaseline) {
    $new = [ordered]@{}
    foreach ($i in $items | Where-Object Sha) { $new[$i.Name] = [ordered]@{ sha256 = $i.Sha; pdfPages = $i.PdfPages; wordPages = $i.WordPages } }
    $new | ConvertTo-Json | Set-Content $baselinePath -Encoding utf8
    Write-Host "Baseline updated: $baselinePath"
}
elseif ($regressions) {
    throw "$regressions document(s) export to more Word pages than the baseline: open them in .cache\out beside the PDF."
}
