#Requires -Version 5.1
<#
.SYNOPSIS
    Removes cocopilot's own coordination artifacts from a target
    repository: the local .mailbox/ directory and the .gitignore rule
    init-mailbox.ps1 added for it.

.DESCRIPTION
    cocopilot never wants its own coordination state to end up committed
    into a project you're pairing on. This script:

      1. Un-tracks any .mailbox/ paths that somehow ended up in the target
         repo's git index (git rm --cached) — this should never happen
         given init-mailbox.ps1's own .gitignore rule, but is checked and
         fixed defensively.
      2. Deletes <RepoPath>/.mailbox/ from disk.
      3. Removes exactly the "# Per-machine cocopilot mailbox state..."
         comment + .mailbox/ line that init-mailbox.ps1 appended to the
         target repo's .gitignore, leaving the rest of that file (and any
         unrelated .mailbox/ rule the user added themselves, without
         cocopilot's comment above it) untouched. If the .gitignore file
         was created solely by init-mailbox.ps1 (i.e. it's empty after
         removing our block), the file itself is deleted too.

    This does NOT touch anything else in the target repository — not the
    agents' actual work, not unrelated .gitignore rules, not git history.
    Supports -WhatIf/-Confirm since it deletes files; nothing here commits
    anything on your behalf — un-tracking via git rm --cached only stages
    the removal, you still commit it yourself.

.PARAMETER RepoPath
    The repository to clean up. Defaults to the current directory.

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\some-other-project

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\some-other-project -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoPath = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$mailboxDir = Join-Path $RepoPath ".mailbox"
$gitignorePath = Join-Path $RepoPath ".gitignore"

$isGitRepo = $false
try {
    $null = git -C $RepoPath rev-parse --is-inside-work-tree 2>$null
    $isGitRepo = ($LASTEXITCODE -eq 0)
} catch { $isGitRepo = $false }

# 1. Un-track any .mailbox/ paths that ended up committed/staged. Should
# never happen given init-mailbox.ps1's own .gitignore rule, but checked
# defensively since the user must never get cocopilot state committed.
if ($isGitRepo) {
    $tracked = git -C $RepoPath ls-files -- .mailbox 2>$null
    if ($tracked) {
        Write-Warning "Found tracked files under .mailbox/ in $RepoPath - this should never happen, un-tracking now:"
        $tracked | ForEach-Object { Write-Warning "  $_" }
        if ($PSCmdlet.ShouldProcess("$RepoPath (.mailbox/ in git index)", "git rm -r --cached")) {
            git -C $RepoPath rm -r --cached --ignore-unmatch -- .mailbox | Out-Null
            Write-Host "Untracked .mailbox/ from the git index. This is staged for removal - commit it yourself to finalize." -ForegroundColor Yellow
        }
    }
}

# 2. Delete .mailbox/ from disk.
if (Test-Path -LiteralPath $mailboxDir) {
    if ($PSCmdlet.ShouldProcess($mailboxDir, "Remove directory")) {
        Remove-Item -LiteralPath $mailboxDir -Recurse -Force
        Write-Host "Removed $mailboxDir" -ForegroundColor Green
    }
} else {
    Write-Host "No .mailbox/ directory found at $RepoPath - nothing to remove." -ForegroundColor Cyan
}

# 3. Strip exactly the cocopilot-added block from .gitignore, leaving
# everything else (including an unrelated bare .mailbox/ rule without our
# comment above it) untouched.
if (Test-Path -LiteralPath $gitignorePath) {
    $raw = Get-Content -LiteralPath $gitignorePath -Raw
    # [ \t\r]* (not \s*) around the .mailbox/ line: \s also matches \n, so a
    # greedy \s* there would silently swallow blank lines *beyond* the block
    # (e.g. a user-added blank line separating their own rules that follow).
    # \r is kept (unlike \n) since Add-Content terminates its own appended
    # text with the OS default newline (\r\n on Windows) even when the rest
    # of the file uses bare \n, so a lone trailing \r before the line's own
    # \n is still part of *this* line, not a signal to keep scanning.
    $pattern = '(?m)(\r?\n)?^#[ \t]*Per-machine cocopilot mailbox state.*$\r?\n^[ \t]*/?\.mailbox/?[ \t\r]*$\r?\n?'
    $newRaw = [regex]::Replace($raw, $pattern, '')

    if ($newRaw -eq $raw) {
        Write-Host "No cocopilot .mailbox/ rule found in $gitignorePath - nothing to change." -ForegroundColor Cyan
    } elseif ($newRaw.Trim().Length -eq 0) {
        if ($PSCmdlet.ShouldProcess($gitignorePath, "Remove file (only contained cocopilot's rule)")) {
            Remove-Item -LiteralPath $gitignorePath -Force
            Write-Host "Removed $gitignorePath (it only contained the rule cocopilot added)." -ForegroundColor Green
        }
    } else {
        if ($PSCmdlet.ShouldProcess($gitignorePath, "Remove cocopilot's .mailbox/ rule, keep the rest")) {
            Set-Content -LiteralPath $gitignorePath -Value $newRaw -NoNewline -Encoding utf8
            Write-Host "Removed cocopilot's .mailbox/ rule from $gitignorePath (rest of the file preserved)." -ForegroundColor Green
        }
    }
} else {
    Write-Host "No .gitignore found at $RepoPath - nothing to change." -ForegroundColor Cyan
}

# 4. Final safety check: show the target repo's git status so you can see
# at a glance that nothing cocopilot-related remains tracked or staged.
if ($isGitRepo) {
    Write-Host "`n--- git status for $RepoPath ---" -ForegroundColor Cyan
    git -C $RepoPath status --short
}
