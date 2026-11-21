# Merges an agent's reviewed branch into master and clears its worktree, in one step:
#   pwsh -NoProfile -File tools/merge-agent.ps1 <branch> -Summary "what it brings" [-NoPush]
# Run from the main checkout on master. Stops before merging when master or the agent's worktree has uncommitted work,
# and on a conflict (the merge is undone; resolve it by hand). After the merge: push, then the worktree is unlocked (an
# agent's lock outlives it), removed, and the branch deleted with -d. A worktree Windows won't remove (a process still
# has a file open) is named; the merge stands.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Branch,
    [Parameter(Mandatory)][string]$Summary,
    [switch]$NoPush
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location (Split-Path $PSScriptRoot -Parent)

function Invoke-Git { git @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed." } }

if ((git branch --show-current) -ne 'master') { throw 'Run it on master, in the main checkout.' }
if (git status --porcelain --untracked-files=no) { throw 'master has uncommitted changes: commit or stash them first.' }
git rev-parse --verify --quiet "refs/heads/$Branch" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "No branch $Branch." }

# The agent's worktree, from the porcelain list (a "worktree <path>" line, then its "branch refs/heads/<name>")
$tree = $null
$path = $null
foreach ($line in git worktree list --porcelain) {
    if ($line.StartsWith('worktree ')) { $path = $line.Substring(9) }
    elseif ($line -eq "branch refs/heads/$Branch") { $tree = $path }
}
if ($tree -and (git -C $tree status --porcelain --untracked-files=no)) { throw "$tree has uncommitted changes: the agent's work isn't all committed." }

$tip = git rev-parse --short=8 $Branch
$ahead = [int](git rev-list --count "master..$Branch")
if ($ahead -eq 0) { throw "$Branch has nothing master doesn't." }
git merge --no-ff -q $Branch -m "Merge branch '$Branch': $Summary ($tip)"
if ($LASTEXITCODE -ne 0) {
    git merge --abort
    throw "Merging $Branch conflicts; master is as it was. Resolve it by hand."
}
Write-Host "Merged $Branch ($ahead commits, $tip)."
if (-not $NoPush) { Invoke-Git push -q; Write-Host 'Pushed.' }

if ($tree) {
    git worktree unlock $tree 2>$null
    git worktree remove $tree
    if ($LASTEXITCODE -ne 0) { Write-Host "The worktree $tree is still there (a process has a file open?): end it, then git worktree remove and git branch -d $Branch."; exit 1 }
    Write-Host "Removed $tree."
}
Invoke-Git branch -d $Branch
