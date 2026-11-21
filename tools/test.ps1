# The tests CI runs, with one retry for tests that fail under load:
#   pwsh -NoProfile -File tools/test.ps1 [-Configuration Release] [-MaxRetry 15] [-Filter <dotnet test filter>]
# Runs `dotnet test Inkvolt.slnx`. When at most -MaxRetry tests fail, runs those again, one at a time per collection
# (no parallel collections), and passes if they all pass then; each one is named as flaky (a GitHub warning in CI), so a
# flaky test stays visible instead of being rerun by hand. More failures than that are a real break: no retry.
param(
    [string]$Configuration = 'Debug',
    [int]$MaxRetry = 15,
    [string]$Filter
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$results = Join-Path ([IO.Path]::GetTempPath()) "inkvolt-tests-$PID"
Remove-Item $results -Recurse -Force -ErrorAction SilentlyContinue

$only = if ($Filter) { @('--filter', $Filter) } else { @() }
dotnet test Inkvolt.slnx -c $Configuration --logger 'trx' --results-directory $results @only
if ($LASTEXITCODE -eq 0) { exit 0 }

# Failed tests from the TRX files: their class and method, per test project.
$projects = @{ 'InkvoltPdf.Tests' = 'pdf/tests/InkvoltPdf.Tests'; 'InkvoltPrint.Tests' = 'print/tests/InkvoltPrint.Tests' }
$failed = [Collections.Generic.List[string]]::new()
$aborted = [Collections.Generic.List[string]]::new()
foreach ($trx in Get-ChildItem $results -Filter *.trx -Recurse) {
    [xml]$x = Get-Content -LiteralPath $trx.FullName -Raw
    # A crashed or aborted test host leaves the tests after it unrun, and they aren't in the TRX as failed: retrying the
    # recorded failures alone would pass a run that never ran them.
    $summary = $x.TestRun.ResultSummary
    # (Every failed test's output is an Error RunInfo too, so only the abort's own words count.)
    $errors = @($summary.RunInfos.RunInfo | Where-Object { $_ -and $_.Text -match 'test run was aborted|test host process crashed' })
    if ($summary.outcome -in 'Aborted', 'Timeout' -or $errors.Count -gt 0) {
        $aborted.Add("$($trx.Name): $(@($errors | ForEach-Object { ($_.Text -split "`n")[0] }) -join ' ')")
    }
    $methods = @{}
    foreach ($t in $x.TestRun.TestDefinitions.UnitTest) { $methods[$t.id] = "$($t.TestMethod.className).$($t.TestMethod.name)" }
    foreach ($r in $x.TestRun.Results.UnitTestResult) {
        if ($r.outcome -eq 'Failed' -and $methods[$r.testId]) { $failed.Add($methods[$r.testId]) }
    }
}
if ($aborted.Count -gt 0) { Write-Host 'The test run was aborted (a test host crashed?), so some tests never ran: no retry.'; $aborted | ForEach-Object { Write-Host "  $_" }; exit 1 }
$failed = @($failed | Sort-Object -Unique)
if ($failed.Count -eq 0) { Write-Host 'The run failed without a failed test (a build error?): no retry.'; exit 1 }
if ($failed.Count -gt $MaxRetry) { Write-Host "$($failed.Count) tests failed (more than $MaxRetry): a real break, no retry."; exit 1 }

Write-Host "`nRetrying $($failed.Count) failed test(s) without parallel collections:"
$failed | ForEach-Object { Write-Host "  $_" }
$still = $false
foreach ($group in $failed | Group-Object { ($_ -split '\.')[0..1] -join '.' }) {
    $project = $projects[$group.Name]
    if (-not $project) { Write-Host "No project known for $($group.Name)."; $still = $true; continue }
    $filter = ($group.Group | ForEach-Object { "FullyQualifiedName=$_" }) -join '|'
    dotnet test $project -c $Configuration --no-build --filter $filter -- xUnit.ParallelizeTestCollections=false
    if ($LASTEXITCODE -ne 0) { $still = $true }
}
if ($still) {
    # A timing test that fails alone can be the PC's other work: name what used the CPU over the last 3 seconds.
    $before = @{}; Get-Process | ForEach-Object { $before[$_.Id] = $_.TotalProcessorTime }
    Start-Sleep -Seconds 3
    $busy = Get-Process | Where-Object { $before.ContainsKey($_.Id) -and $_.Id -ne $PID } |
        ForEach-Object { [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id; Cpu = ($_.TotalProcessorTime - $before[$_.Id]).TotalSeconds / 3 / [Environment]::ProcessorCount * 100 } } |
        Sort-Object Cpu -Descending | Select-Object -First 5
    Write-Host "CPU now: $(($busy | ForEach-Object { '{0} ({1}) {2:N0}%' -f $_.Name, $_.Id, $_.Cpu }) -join ', ')"
    Write-Host 'Failed again on the retry: a real failure, unless a process above (not this run) had the CPU; then end it and run again.'
    exit 1
}

foreach ($name in $failed) {
    if ($env:GITHUB_ACTIONS) { Write-Host "::warning title=Flaky test::$name failed under load and passed alone" }
    else { Write-Host "Flaky (failed under load, passed alone): $name" }
}
exit 0
