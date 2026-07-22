#Requires -Version 5.1
<#
.SYNOPSIS
    Initializes the local (git-ignored) mailbox state for a target
    repository: <RepoPath>/.mailbox/implementer.json, mailbox.md, and
    session.log.md.

.DESCRIPTION
    cocopilot itself stays centrally installed (this script's own location);
    the mailbox it manages lives inside whatever repository you're pairing
    on. Templates are read from this cocopilot install's own
    .mailbox/*.example.* files, but the real, git-ignored files are written
    into <RepoPath>/.mailbox/, stamped with that repository's current git
    HEAD. Safe to re-run: it will not overwrite existing implementer.json or
    mailbox.md unless -Force is passed. The write-once session history
    (session.log.md) is created if missing and is PRESERVED even with
    -Force — a session-reset entry is appended instead; only
    cleanup-mailbox.ps1 removes it (with the whole .mailbox/ directory).

    Before anything is written, does a small safety check: if <RepoPath> is
    a git repository and its .gitignore doesn't already exclude .mailbox,
    this appends a rule first — so the per-machine mailbox state can't be
    accidentally committed to that project's real history even if init is
    interrupted mid-write.

.PARAMETER RepoPath
    The repository to pair on. Defaults to the current directory.

.PARAMETER Owner
    Which role starts as the active implementer. Defaults to "agent-a".

.PARAMETER OwnerModel
    Informational label for which model agent-a happens to be running.

.PARAMETER Force
    Overwrite existing .mailbox/implementer.json and .mailbox/mailbox.md.

.EXAMPLE
    .\scripts\init-mailbox.ps1 -RepoPath C:\Repos\some-other-project
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$Owner = "agent-a",
    [string]$OwnerModel = "unknown",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$cocopilotRoot = Split-Path -Parent $PSScriptRoot

$mailboxDir = Join-Path $RepoPath ".mailbox"
$implementerPath = Join-Path $mailboxDir "implementer.json"
$mailboxPath = Join-Path $mailboxDir "mailbox.md"
$sessionLogPath = Join-Path $mailboxDir "session.log.md"
$implementerTemplate = Join-Path $cocopilotRoot ".mailbox\implementer.example.json"
$mailboxTemplate = Join-Path $cocopilotRoot ".mailbox\mailbox.example.md"

# Safety net FIRST — before anything under .mailbox/ exists: keep the
# per-machine mailbox out of the target repo's real history, the same way
# cocopilot's own .gitignore keeps it out of this repo.
$isGitRepo = $false
try {
    $null = git -C $RepoPath rev-parse --is-inside-work-tree 2>$null
    $isGitRepo = ($LASTEXITCODE -eq 0)
} catch { $isGitRepo = $false }

if ($isGitRepo) {
    $gitignorePath = Join-Path $RepoPath ".gitignore"
    $alreadyIgnored = (Test-Path -LiteralPath $gitignorePath) -and ((Get-Content -LiteralPath $gitignorePath -Raw) -match '(?m)^\s*/?\.mailbox/?\s*$')
    if (-not $alreadyIgnored) {
        Add-Content -LiteralPath $gitignorePath -Value "`n# Per-machine cocopilot mailbox state (see cocopilot's own README/COLLABORATION.md)`n.mailbox/"
        Write-Host "Appended a .mailbox/ ignore rule to $gitignorePath" -ForegroundColor Green
    }
} else {
    Write-Warning "$RepoPath doesn't look like a git repository; skipped the .gitignore safety check. Make sure .mailbox/ never gets committed there."
}

[System.IO.Directory]::CreateDirectory($mailboxDir) | Out-Null

$head = "0000000000000000000000000000000000000000"
try {
    $gitHead = git -C $RepoPath rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitHead) { $head = $gitHead.Trim() }
} catch {
    Write-Warning "Could not resolve git HEAD for $RepoPath (no commits yet?); using zero SHA."
}

if ((Test-Path -LiteralPath $implementerPath) -and -not $Force) {
    Write-Host "implementer.json already exists, leaving it as-is (use -Force to reset)." -ForegroundColor Yellow
} else {
    $record = Get-Content -LiteralPath $implementerTemplate -Raw | ConvertFrom-Json
    $record.owner = $Owner
    $record.owner_model = $OwnerModel
    $record.head = $head
    Write-MailboxJson -Path $implementerPath -Object $record
    Write-Host "Wrote $implementerPath (owner=$Owner, head=$($head.Substring(0, [Math]::Min(7,$head.Length))))" -ForegroundColor Green
}

if ((Test-Path -LiteralPath $mailboxPath) -and -not $Force) {
    Write-Host "mailbox.md already exists, leaving it as-is (use -Force to reset)." -ForegroundColor Yellow
} else {
    [System.IO.File]::Copy($mailboxTemplate, $mailboxPath, $true)
    Write-Host "Wrote $mailboxPath" -ForegroundColor Green
}

# Write-once session history: created once, preserved forever after — even
# -Force only appends a reset marker. UTF-8 without BOM via .NET so Windows
# PowerShell 5.1 and pwsh 7 produce identical bytes.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$nowUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss'Z'")
if (-not (Test-Path -LiteralPath $sessionLogPath)) {
    $logHeader = "# session log - write-once history (see cocopilot's COLLABORATION.md; never edit or delete entries)`n`n## $nowUtc init`n- repo: $RepoPath`n- initial owner: $Owner`n"
    [System.IO.File]::WriteAllText($sessionLogPath, $logHeader, $utf8NoBom)
    Write-Host "Wrote $sessionLogPath" -ForegroundColor Green
} elseif ($Force) {
    $resetEntry = "`n## $nowUtc init`n- session reset (-Force): implementer.json and mailbox.md reinitialized; log preserved`n"
    [System.IO.File]::AppendAllText($sessionLogPath, $resetEntry, $utf8NoBom)
    Write-Host "Preserved $sessionLogPath (appended a session-reset entry)." -ForegroundColor Yellow
} else {
    Write-Host "session.log.md already exists, leaving it as-is (history survives -Force too)." -ForegroundColor Yellow
}

