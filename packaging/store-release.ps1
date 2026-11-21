# The Store and GitHub steps of a release (pdf/packaging/README.md "Upload", steps 5 to 7), after `msstore publish` has
# put the package up as a draft:
#   pwsh -NoProfile -File packaging/store-release.ps1 -App Pdf -Notes notes.json   release notes into the draft, read back
#   pwsh -NoProfile -File packaging/store-release.ps1 -App Pdf -Publish            send the draft to certification
#   pwsh -NoProfile -File packaging/store-release.ps1 -App Pdf -Wait               until Published (exit 0) or Failed (exit 2)
#   pwsh -NoProfile -File packaging/store-release.ps1 -App Pdf -GitHub -Version 1.16.0.0 [-Submitted 2026-11-21] [-Published 2026-11-21]
# -DryRun with -Notes or -GitHub writes the payload or the body and sends nothing.
#
# notes.json is {"en-us": "...", "es": "..."}: the Store's own short notes, written from the WHATS-NEW entry, under 1,500
# characters each, the Spanish in the voice the app's docs/SPANISH-REVIEW.md sets (pdf/ or print/). Every listing the draft has needs one. The draft
# is read back after the update, and each note must come back as written (no U+FFFD).
# -Wait checks every 10 minutes, up to 8 hours: run it as a background command.
# -GitHub writes the release body from WHATS-NEW.md's `## x.y.z` lines to a file (its line breaks kept) and creates the
# release `pdf-v<ver>` or `print-v<ver>` on the pushed master, or replaces the body when the release exists (once
# Published, run it again with -Published).
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Pdf', 'Print')][string]$App,
    [string]$Notes,
    [switch]$Publish,
    [switch]$Wait,
    [switch]$GitHub,
    [string]$Version,
    [string]$Submitted = (Get-Date -Format 'yyyy-MM-dd'),
    [string]$Published,
    # -Notes and -GitHub: write the payload or the body and say where, send nothing
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$id = @{ Pdf = '9MXDTSFJ9W28'; Print = '9PNR76HJ62SK' }[$App]
$name = @{ Pdf = 'Inkvolt PDF'; Print = 'Inkvolt Print' }[$App]
$utf8 = [Text.UTF8Encoding]::new($false)
$work = Join-Path ([IO.Path]::GetTempPath()) "inkvolt-store-$($App.ToLowerInvariant())"
New-Item -ItemType Directory -Force $work | Out-Null
if (@($Notes, $Publish, $Wait, $GitHub | Where-Object { $_ }).Count -ne 1) { throw 'Give one of -Notes, -Publish, -Wait or -GitHub.' }

function Get-Draft {
    $text = & msstore submission get $id 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "msstore submission get $id failed: $text" }
    $start = $text.IndexOf('{')
    if ($start -lt 0) { throw "msstore submission get $id gave no JSON: $text" }
    # Dates stay strings, so the draft goes back exactly as it came
    $text.Substring($start) | ConvertFrom-Json -AsHashtable -DateKind String
}

function Get-Status { (& msstore submission status $id 2>&1 | Select-String 'Submission Status' | Select-Object -Last 1).Line }

if ($Notes) {
    $want = Get-Content $Notes -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $draft = Get-Draft
    $listings = @($draft.Listings.Keys)
    $problems = @(
        foreach ($lang in $listings) { if (-not $want.ContainsKey($lang)) { "no note for the $lang listing" } }
        foreach ($lang in $want.Keys) {
            if ($lang -notin $listings) { "the draft has no $lang listing" }
            if ($want[$lang].Length -ge 1500) { "$lang is $($want[$lang].Length) characters (under 1,500)" }
            if ($want[$lang].Contains([char]0xFFFD)) { "$lang has U+FFFD (read as the wrong encoding)" }
        }
    )
    if ($problems) { throw "Notes not sent: $($problems -join '; ')." }
    foreach ($lang in $listings) { $draft.Listings[$lang].BaseListing.ReleaseNotes = $want[$lang] }
    $payload = Join-Path $work 'payload.json'
    [IO.File]::WriteAllText($payload, ($draft | ConvertTo-Json -Depth 64), $utf8)
    if ($DryRun) { Write-Host "Payload (not sent): $payload"; exit 0 }
    $out = & msstore submission update $id -p $payload 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "msstore submission update $id failed: $out" }
    $back = Get-Draft
    foreach ($lang in $listings) {
        $got = $back.Listings[$lang].BaseListing.ReleaseNotes
        if ($got -ne $want[$lang]) { throw "The $lang note came back changed: $got" }
        Write-Host "$lang release notes set ($($got.Length) characters)."
    }
}
elseif ($Publish) {
    $out = & msstore submission publish $id 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "msstore submission publish $id failed: $out" }
    Write-Host (Get-Status)
}
elseif ($Wait) {
    for ($i = 0; $i -lt 48; $i++) {
        $line = Get-Status
        Write-Host "$(Get-Date -Format HH:mm) $name $line"
        if ($line -match 'Failed') { exit 2 }
        if ($line -match 'Published') { exit 0 }
        Start-Sleep -Seconds 600
    }
    Write-Host 'Not Published after 8 hours.'
    exit 1
}
else {
    if ($Version -notmatch '^(\d+\.\d+\.\d+)\.0$') { throw '-Version is the package version, x.y.z.0.' }
    $heading = $Matches[1]
    $whatsNew = Join-Path $root "$($App.ToLowerInvariant())/WHATS-NEW.md"
    $lines = [Collections.Generic.List[string]]::new()
    $take = $false
    foreach ($line in Get-Content $whatsNew -Encoding utf8) {
        if ($line.StartsWith('## ')) { $take = $line.Substring(3).Trim() -eq $heading; continue }
        if ($take -and $line.StartsWith('- ')) { $lines.Add($line) }
    }
    if ($lines.Count -eq 0) { throw "$whatsNew has no lines under ## $heading." }
    $state = if ($Published) { "published $Published" } else { 'in certification' }
    $body = "What's new in $name $heading for Windows:`n`n$($lines -join "`n")`n`nMicrosoft Store: https://apps.microsoft.com/detail/$id ($Version submitted $Submitted, $state)."
    $file = Join-Path $work 'github-notes.md'
    [IO.File]::WriteAllText($file, $body, $utf8)
    if ($DryRun) { Write-Host "Body (not sent): $file"; exit 0 }
    $tag = "$($App.ToLowerInvariant())-v$Version"
    gh release view $tag --json tagName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { gh release edit $tag --notes-file $file }
    else { gh release create $tag --target master --title "$name $Version" --notes-file $file }
    if ($LASTEXITCODE -ne 0) { throw "gh release for $tag failed." }
    Write-Host "$tag`: $($lines.Count) lines."
}
