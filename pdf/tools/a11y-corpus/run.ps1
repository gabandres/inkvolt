# Runs Inkvolt PDF's accessibility checker (AccessibilityCheck) over the corpus (corpus.json) and compares each file's
# result with veraPDF's PDF/UA-1 validation, file by file and condition by condition. veraPDF is a test-only tool: it is
# never shipped (install it with -Install, or see README.md).
#
#   pwsh -File pdf/tools/a11y-corpus/run.ps1                    download what's missing, run veraPDF, compare
#   pwsh -File pdf/tools/a11y-corpus/run.ps1 -Synthetic         also veraPDF's own PDF/UA-1 test files (297, small)
#   pwsh -File pdf/tools/a11y-corpus/run.ps1 -Install           install veraPDF unattended into C:\Tools\verapdf first
#   pwsh -File pdf/tools/a11y-corpus/run.ps1 -Tag               also Make Accessible (AutoTag) on the untagged files and, with
#                                                               their tags replaced, the Word and office files; both checked
#                                                               by veraPDF and compared
#
# The PDFs go to -Corpus (outside the repo; none are committed). A file whose SHA-256 differs from corpus.json's (the
# publisher replaced it) is reported; the comparison still runs on what was downloaded.
[CmdletBinding()]
param(
    [string]$Corpus = 'C:\Temp\a11y-corpus',
    [string]$VeraPdf = 'C:\Tools\verapdf\verapdf.bat',
    [switch]$Synthetic,
    [string]$SyntheticFolder = 'C:\Temp\a11y-vc',
    [switch]$Install,
    [switch]$Tag,
    [string]$TaggedFolder = 'C:\Temp\a11y-tagged'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

if ($Install) {
    # veraPDF's installer (izpack) runs unattended from an answer file; it needs Java 8 or later (winget install Microsoft.OpenJDK.21).
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) { throw 'veraPDF needs Java: winget install Microsoft.OpenJDK.21' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "verapdf-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory $tmp | Out-Null
    Invoke-WebRequest 'https://software.verapdf.org/releases/verapdf-installer.zip' -OutFile "$tmp\installer.zip" -UserAgent $ua
    Expand-Archive "$tmp\installer.zip" "$tmp\x"
    $jar = Get-ChildItem "$tmp\x" -Recurse -Filter 'verapdf-izpack-installer-*.jar' | Select-Object -First 1
    $target = Split-Path $VeraPdf
    @"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<AutomatedInstallation langpack="eng">
  <com.izforge.izpack.panels.htmlhello.HTMLHelloPanel id="welcome"/>
  <com.izforge.izpack.panels.target.TargetPanel id="install_dir"><installpath>$target</installpath></com.izforge.izpack.panels.target.TargetPanel>
  <com.izforge.izpack.panels.packs.PacksPanel id="sdk_pack_select">
    <pack index="0" name="veraPDF GUI" selected="true"/>
    <pack index="1" name="veraPDF Mac and *nix Scripts" selected="false"/>
    <pack index="2" name="veraPDF Validation model" selected="true"/>
    <pack index="3" name="veraPDF Documentation" selected="false"/>
    <pack index="4" name="veraPDF Sample Plugins" selected="false"/>
  </com.izforge.izpack.panels.packs.PacksPanel>
  <com.izforge.izpack.panels.install.InstallPanel id="install"/>
  <com.izforge.izpack.panels.finish.FinishPanel id="finish"/>
</AutomatedInstallation>
"@ | Set-Content "$tmp\auto-install.xml" -Encoding utf8
    java -jar $jar.FullName "$tmp\auto-install.xml" | Out-Host
    Remove-Item $tmp -Recurse -Force
}
if (-not (Test-Path $VeraPdf)) { throw "veraPDF isn't at $VeraPdf (run with -Install, or pass -VeraPdf)." }

Write-Host 'Building A11yCorpus...'
dotnet build $here -c Release -nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'A11yCorpus did not build (run: dotnet build pdf/tools/a11y-corpus).' }
$dll = Get-ChildItem (Join-Path $here 'bin\Release') -Recurse -Filter A11yCorpus.dll | Sort-Object LastWriteTime | Select-Object -Last 1

function Compare-Folder([string]$folder, [string]$label) {
    $xml = Join-Path $folder 'verapdf.xml'
    Write-Host "veraPDF (PDF/UA-1) on $label..."
    # veraPDF takes the folder (a long list of files overflows the batch file's command line).
    & $VeraPdf -f ua1 --format xml --maxfailuresdisplayed 1 $folder 2>$null | Set-Content $xml -Encoding utf8
    & dotnet $dll.FullName compare $xml $folder (Join-Path $folder 'comparison.csv') | Out-Host
    return $LASTEXITCODE
}

New-Item -ItemType Directory -Force $Corpus | Out-Null
$changed = 0
foreach ($c in Get-Content (Join-Path $here 'corpus.json') -Raw | ConvertFrom-Json) {
    $pdf = Join-Path $Corpus "$($c.name).pdf"
    if (-not (Test-Path $pdf)) {
        Write-Host "Downloading $($c.name)..."
        Invoke-WebRequest $c.url -OutFile $pdf -UserAgent $ua
    }
    if ((Get-FileHash $pdf -Algorithm SHA256).Hash.ToLowerInvariant() -ne $c.sha256) { $changed++; Write-Warning "$($c.name): the source changed since corpus.json was written." }
}
$failed = Compare-Folder $Corpus 'the corpus'
if ($changed) { Write-Warning "$changed file(s) differ from the pinned versions." }

if ($Tag) {
    # Make Accessible: the untagged files as they are; the Word and office files (all tagged by their writer) with their
    # tags replaced, as an untagged export of theirs would be tagged. Figures get a stand-in alternate text.
    $untagged = Join-Path $TaggedFolder 'untagged'
    $retagged = Join-Path $TaggedFolder 'retagged'
    foreach ($f in $untagged, $retagged) { if (Test-Path $f) { Remove-Item $f -Recurse -Force } }
    & dotnet $dll.FullName tag $untagged (Get-ChildItem $Corpus -Filter *.pdf | ForEach-Object FullName) | Where-Object { $_ -notmatch 'skipped' } | Out-Host
    $office = 'word-example', 'word-ms2016', 'rw-letter-doc', 'rw-resume', 'wcag-table-word', 'libreoffice-126207', 'nist-sp800-63-3',
              'usgs-fs-2008-3062', 'rw-pdf-ada-standards', 'wcag-lijst-arial', 'wcag-test-document-11', 'rw-table-with-attributes'
    & dotnet $dll.FullName tag --all $retagged ($office | ForEach-Object { Join-Path $Corpus "$_.pdf" }) | Out-Host
    $failed += Compare-Folder $untagged 'the untagged files after Make Accessible'
    $failed += Compare-Folder $retagged 'the office files with their tags replaced'
}

if ($Synthetic) {
    # veraPDF's own PDF/UA-1 test files: one pass and one fail file per rule, from github.com/veraPDF/veraPDF-corpus.
    New-Item -ItemType Directory -Force $SyntheticFolder | Out-Null
    $tree = Invoke-RestMethod 'https://api.github.com/repos/veraPDF/veraPDF-corpus/git/trees/staging?recursive=1' -UserAgent $ua
    foreach ($t in $tree.tree | Where-Object { $_.path -like 'PDF_UA-1/*.pdf' }) {
        $pdf = Join-Path $SyntheticFolder (Split-Path $t.path -Leaf)
        if (-not (Test-Path $pdf)) {
            $url = 'https://raw.githubusercontent.com/veraPDF/veraPDF-corpus/staging/' + (($t.path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
            Invoke-WebRequest $url -OutFile $pdf -UserAgent $ua
        }
    }
    $failed += Compare-Folder $SyntheticFolder "veraPDF's PDF/UA-1 test files"
}
if ($failed) { throw 'Some files got a different pass/fail result from veraPDF: see the tables above (and README.md, "Known differences").' }
