# Downloads the forms corpus (corpus.json) into .cache\pdfs\, which git ignores: the PDFs stay out of the repo, only
# their URLs, SHA-256s and licenses are committed. Each download is checked against its pinned SHA-256; a publisher's
# new version is reported as "changed", and the run skips it ("source changed") until it is pinned again.
# Downloads are untrusted data: nothing here opens them, and the harness reads them only as PDFs.
#
#   pwsh -File pdf/tools/forms-corpus/fetch.ps1          download what's missing, check every SHA-256
#   pwsh -File pdf/tools/forms-corpus/fetch.ps1 -Pin     also write the SHA-256 of entries that have none yet
[CmdletBinding()]
param([switch]$Pin)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = $PSScriptRoot
$cache = Join-Path $here '.cache\pdfs'
New-Item -ItemType Directory -Force $cache | Out-Null
$corpusPath = Join-Path $here 'corpus.json'
$corpus = Get-Content $corpusPath -Raw | ConvertFrom-Json
# curl.exe (in Windows since 10 1803): some publishers (USCIS) refuse PowerShell's own client.
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source

$missing = 0; $changed = 0; $pinned = 0
foreach ($c in $corpus) {
    if ($c.url -like 'synthetic:*') { continue } # written by the harness each run
    $pdf = Join-Path $cache "$($c.name).pdf"
    if (-not (Test-Path $pdf)) {
        $tmp = "$pdf.part"
        if ($curl) {
            & $curl -s -f -L --max-time 120 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -o $tmp $c.url
            if ($LASTEXITCODE -ne 0) { Remove-Item -Force -ErrorAction SilentlyContinue $tmp } # cut off or refused: never kept as the form
        }
        else { try { Invoke-WebRequest $c.url -OutFile $tmp -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } catch { Remove-Item -Force -ErrorAction SilentlyContinue $tmp } }
        if (-not (Test-Path $tmp)) { Write-Warning "$($c.name): download failed ($($c.url))"; $missing++; continue }
        Move-Item -Force $tmp $pdf
    }
    $sha = (Get-FileHash $pdf -Algorithm SHA256).Hash.ToLowerInvariant()
    $known = if ($c.PSObject.Properties['sha256']) { $c.sha256 } else { $null }
    if (-not $known) {
        if ($Pin) { $c | Add-Member -Force sha256 $sha; $pinned++ }
    }
    elseif ($known -ne $sha) {
        Write-Warning "$($c.name): the publisher's file changed (sha256 $sha, pinned $known); the run skips it until it is pinned again"
        $changed++
    }
}
if ($pinned) {
    $corpus | ConvertTo-Json -Depth 4 | Set-Content $corpusPath -Encoding utf8
    Write-Host "Pinned $pinned SHA-256(s) in corpus.json"
}
Write-Host "Corpus: $($corpus.Count) forms in $cache; missing $missing, changed $changed."
