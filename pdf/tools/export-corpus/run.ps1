# Exports the real-world corpus (corpus.json) to Word with the current code and counts each result's pages in Word. A
# layout regression shows up as more Word pages than last time (baseline.json): text that falls out of its frames, rows
# that wrap, spacing that grows. Needs Word (the page count is Word's own layout).
#
# It then checks the same documents' PowerPoint and HTML exports. PowerPoint (.pptx): the Open XML SDK's validator, then
# PowerPoint itself when it is installed, and Excel opens each .xlsx when it is installed; a check that can't run here says so and doesn't count. HTML: no active content
# (links only to web or mail addresses and the file's own pages), reads in order, and the W3C's Nu validator when it is in
# .cache\vnu (the install line is printed). -LibreOffice also has LibreOffice open every .docx, .xlsx and .pptx (converted
# to PDF, headless, with a profile of its own). Everything runs on this PC: no document goes to an online service.
#
#   pwsh -File pdf/tools/export-corpus/run.ps1                     export, count, compare with baseline.json
#   pwsh -File pdf/tools/export-corpus/run.ps1 -Files a.pdf,b.pdf  also export these (counted, no baseline: a user's file)
#   pwsh -File pdf/tools/export-corpus/run.ps1 -UpdateBaseline     accept the current counts (after a change that's better)
#   pwsh -File pdf/tools/export-corpus/run.ps1 -LibreOffice        also open the Office files in LibreOffice
#
# Downloads go to .cache\, results to .cache\out\<name>.docx, .txt, .xlsx (when there are tables), .pptx and .html, to open
# beside the PDF. A downloaded file whose SHA-256 differs from the baseline's (the publisher replaced it) is reported and
# not compared.
[CmdletBinding()]
param(
    [string[]]$Files = @(),
    [switch]$UpdateBaseline,
    # Only the PowerPoint and HTML checks, without Word's page count
    [switch]$SkipWord,
    # Opt-in: LibreOffice converts every .docx, .xlsx and .pptx to PDF (soffice from Program Files, or -Soffice)
    [switch]$LibreOffice,
    # Where soffice.exe is, when LibreOffice isn't in Program Files (a portable copy)
    [string]$Soffice = '',
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

if (-not $SkipWord) {
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
}

# ---- PowerPoint and HTML ----

$failures = [Collections.Generic.List[string]]::new()
# Every check that didn't run here, named again at the end (a gap shows in the summary, not only in the log above)
$notRun = [Collections.Generic.List[string]]::new()
if ($SkipWord) { $notRun.Add("Word's page count (-SkipWord)") }
$checks = foreach ($i in $items) {
    $pptx = [IO.Path]::ChangeExtension($i.Docx, '.pptx')
    $html = [IO.Path]::ChangeExtension($i.Docx, '.html')
    $txt = [IO.Path]::ChangeExtension($i.Docx, '.txt')
    $sdk = @(dotnet $dll.FullName pptx $pptx)
    if ($LASTEXITCODE -ne 0) { $failures.Add("$($i.Name): the .pptx doesn't validate: $($sdk -join ' ')") }
    $slides, $shapes, $errors = ($sdk[0] -split ' ')
    if ([int]$slides -ne $i.PdfPages) { $failures.Add("$($i.Name): $slides slides for $($i.PdfPages) pages") }
    $page = dotnet $dll.FullName html $html $txt
    if ($LASTEXITCODE -ne 0) { $failures.Add("$($i.Name): active content in the .html: $page") }
    $m = [regex]::Match("$page", 'lines=(\d+) found=(\d+) inOrder=(\d+)')
    [pscustomobject]@{
        Document = $i.Name; Pptx = $pptx; Html = $html; Slides = [int]$slides; Shapes = [int]$shapes; 'SDK errors' = [int]$errors
        'HTML lines in order' = "$($m.Groups[3].Value)/$($m.Groups[1].Value)"; PowerPoint = 'not run'; Excel = 'not run'; LibreOffice = 'not run'
    }
}

# PowerPoint itself: opens each without a window. A file it would repair fails to open here or comes back with fewer
# shapes than were written, so both count as failures. If PowerPoint is already open (someone's work) it is left running.
$pptExe = @("$env:ProgramFiles\Microsoft Office\root\Office16\POWERPNT.EXE", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\POWERPNT.EXE") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($pptExe) {
    $wasOpen = @(Get-Process POWERPNT -ErrorAction SilentlyContinue).Count -gt 0
    $ppt = New-Object -ComObject PowerPoint.Application
    try {
        foreach ($c in $checks) {
            try {
                $p = $ppt.Presentations.Open($c.Pptx, -1, 0, 0) # read-only, no window
                $count = 0
                foreach ($slide in $p.Slides) { $count += $slide.Shapes.Count }
                $c.PowerPoint = if ($p.Slides.Count -eq $c.Slides -and $count -eq $c.Shapes) { "opens: $($p.Slides.Count) slides, $count shapes" } else { "CHANGED: $($p.Slides.Count) slides, $count shapes" }
                if ($c.PowerPoint -like 'CHANGED*') { $failures.Add("$($c.Document): PowerPoint repaired it? $($c.PowerPoint), written $($c.Slides) slides, $($c.Shapes) shapes") }
                $p.Close()
            }
            catch {
                $c.PowerPoint = 'FAILED'
                $failures.Add("$($c.Document): PowerPoint can't open it: $($_.Exception.Message)")
            }
        }
    }
    finally {
        if (-not $wasOpen) { $ppt.Quit() }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ppt)
    }
}
else { Write-Host 'PowerPoint: not installed, not checked.'; $notRun.Add('PowerPoint (not installed)') }

# Excel itself: opens each .xlsx (written only when the document has tables) read-only, without a window or a prompt. A
# file it would repair fails to open here or comes back with fewer sheets or filled cells than the file holds, so both
# count as failures. If Excel is already open (someone's work) it is left running.
$excelExe = @("$env:ProgramFiles\Microsoft Office\root\Office16\EXCEL.EXE", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\EXCEL.EXE") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($excelExe) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $wasOpen = @(Get-Process EXCEL -ErrorAction SilentlyContinue).Count -gt 0
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false
    $xl.DisplayAlerts = $false
    try {
        foreach ($c in $checks) {
            $file = [IO.Path]::ChangeExtension($c.Pptx, '.xlsx')
            if (-not (Test-Path $file)) { $c.Excel = 'no tables'; continue }
            # What the file holds: its sheets, and the cells with a value (a number, a shared string or inline text)
            $zip = [IO.Compression.ZipFile]::OpenRead($file)
            try {
                $written = @(foreach ($e in $zip.Entries | Where-Object FullName -like 'xl/worksheets/sheet*.xml') {
                    $r = [IO.StreamReader]::new($e.Open()); $xml = $r.ReadToEnd(); $r.Dispose()
                    [regex]::Matches($xml, '<c\b[^>]*?(?<!/)>.*?</c>', 'Singleline') | Where-Object { $_.Value -match '<v>|<is>' } | Measure-Object | Select-Object -ExpandProperty Count
                })
            }
            finally { $zip.Dispose() }
            $writtenCells = ($written | Measure-Object -Sum).Sum
            try {
                $wb = $xl.Workbooks.Open($file, 0, $true) # no link updates, read-only
                $cells = 0
                foreach ($ws in $wb.Worksheets) { $cells += [int]$xl.WorksheetFunction.CountA($ws.UsedRange) }
                $sheets = $wb.Worksheets.Count
                $wb.Close($false)
                $c.Excel = if ($sheets -eq $written.Count -and $cells -eq $writtenCells) { "opens: $sheets sheets, $cells cells" } else { "CHANGED: $sheets sheets, $cells cells" }
                if ($c.Excel -like 'CHANGED*') { $failures.Add("$($c.Document): Excel repaired it? $($c.Excel), written $($written.Count) sheets, $writtenCells cells") }
            }
            catch {
                $c.Excel = 'FAILED'
                $failures.Add("$($c.Document): Excel can't open it: $($_.Exception.Message)")
            }
        }
    }
    finally {
        if (-not $wasOpen) { $xl.Quit() }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xl)
    }
}
else { Write-Host 'Excel: not installed, not checked.'; $notRun.Add('Excel (not installed)') }

# LibreOffice (opt-in): converts each .docx, .xlsx and .pptx to PDF, headless. A file it can't open makes no PDF (or
# times out after 5 minutes); an empty PDF is a failure too. Its own profile in .cache, so a LibreOffice the user has
# open, and their settings, are left alone.
if ($LibreOffice) {
    $sofficeExe = @($Soffice, "$env:ProgramFiles\LibreOffice\program\soffice.exe", "${env:ProgramFiles(x86)}\LibreOffice\program\soffice.exe") |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($sofficeExe) {
        $lo = Join-Path $out 'libreoffice'
        $profileUrl = ([Uri](Join-Path $cache 'lo-profile')).AbsoluteUri
        foreach ($c in $checks) {
            $results = foreach ($ext in '.docx', '.xlsx', '.pptx') {
                $file = [IO.Path]::ChangeExtension($c.Pptx, $ext)
                if (-not (Test-Path $file)) { continue } # no tables: no workbook
                $dir = Join-Path $lo $ext.TrimStart('.')
                New-Item -ItemType Directory -Force $dir | Out-Null
                $made = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($file) + '.pdf')
                Remove-Item $made -ErrorAction SilentlyContinue
                $p = Start-Process $sofficeExe -ArgumentList @("-env:UserInstallation=$profileUrl", '--headless', '--norestore', '--convert-to', 'pdf', '--outdir', "`"$dir`"", "`"$file`"") -PassThru -WindowStyle Hidden
                if (-not $p.WaitForExit(300000)) { $p.Kill($true); "$ext timed out" }
                elseif (-not (Test-Path $made) -or (Get-Item $made).Length -lt 100) { "$ext FAILED" }
                else { "$ext ok" }
            }
            $c.LibreOffice = ($results -join ', ')
            foreach ($r in $results | Where-Object { $_ -notlike '* ok' }) { $failures.Add("$($c.Document): LibreOffice can't open the $r") }
        }
    }
    else { Write-Host 'LibreOffice: not installed (or -Soffice not found), not checked.'; $notRun.Add('LibreOffice (not installed)') }
}
else { $notRun.Add('LibreOffice (opt-in: -LibreOffice)') }

$checks | Select-Object Document, Slides, Shapes, 'SDK errors', PowerPoint, Excel, LibreOffice, 'HTML lines in order' | Format-Table -AutoSize | Out-Host

# The W3C's Nu validator, run here (it takes files, and sends nothing anywhere).
$vnu = Join-Path $cache 'vnu\node_modules\vnu-jar\build\dist\vnu.jar'
if ((Test-Path $vnu) -and (Get-Command java -ErrorAction SilentlyContinue)) {
    $result = & java -Xss4m -Xmx1g -jar $vnu --errors-only --format text @($checks.Html) 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { $failures.Add("HTML validator: $(($result | Select-Object -First 5) -join ' | ')") }
    else { Write-Host "HTML validator: $($result | Select-Object -Last 1)" }
}
else { Write-Host "HTML validator: not run. It needs Java and: npm install --prefix `"$cache\vnu`" vnu-jar --ignore-scripts"; $notRun.Add('the HTML validator (Java or .cache\vnu missing)') }

$regressions = 0
$rows = foreach ($i in $items) {
    $verdict = if ($SkipWord) { 'not counted' }
    elseif (-not $i.Sha) { 'no baseline (local file)' }
    elseif (-not $i.Base) { 'new' }
    elseif ($i.Base.sha256 -ne $i.Sha) { 'source changed: not compared' }
    elseif ($i.WordPages -gt $i.Base.wordPages + $Slack) { $regressions++; "REGRESSION (was $($i.Base.wordPages))" }
    elseif ($i.WordPages -lt $i.Base.wordPages) { "better (was $($i.Base.wordPages))" }
    else { 'same' }
    [pscustomobject]@{ Document = $i.Name; 'PDF pages' = $i.PdfPages; 'Word pages' = $i.WordPages; Result = $verdict }
}
$rows | Format-Table -AutoSize | Out-Host
Write-Host "Exports: $out"
Write-Host $(if ($notRun.Count) { "Not run here: $($notRun -join '; ')." } else { 'Every check ran.' })

if ($UpdateBaseline) {
    $new = [ordered]@{}
    foreach ($i in $items | Where-Object Sha) { $new[$i.Name] = [ordered]@{ sha256 = $i.Sha; pdfPages = $i.PdfPages; wordPages = $i.WordPages } }
    $new | ConvertTo-Json | Set-Content $baselinePath -Encoding utf8
    Write-Host "Baseline updated: $baselinePath"
}
elseif ($regressions) {
    throw "$regressions document(s) export to more Word pages than the baseline: open them in .cache\out beside the PDF."
}
if ($failures.Count) {
    throw "PowerPoint, Excel or HTML checks failed:`n$($failures -join "`n")"
}
