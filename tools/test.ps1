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
foreach ($trx in Get-ChildItem $results -Filter *.trx -Recurse) {
    [xml]$x = Get-Content -LiteralPath $trx.FullName -Raw
    $methods = @{}
    foreach ($t in $x.TestRun.TestDefinitions.UnitTest) { $methods[$t.id] = "$($t.TestMethod.className).$($t.TestMethod.name)" }
    foreach ($r in $x.TestRun.Results.UnitTestResult) {
        if ($r.outcome -eq 'Failed' -and $methods[$r.testId]) { $failed.Add($methods[$r.testId]) }
    }
}
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
if ($still) { Write-Host 'Failed again on the retry: a real failure.'; exit 1 }

foreach ($name in $failed) {
    if ($env:GITHUB_ACTIONS) { Write-Host "::warning title=Flaky test::$name failed under load and passed alone" }
    else { Write-Host "Flaky (failed under load, passed alone): $name" }
}
exit 0
