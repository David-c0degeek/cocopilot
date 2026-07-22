#Requires -Version 5.1
<#
.SYNOPSIS
    Blocks until <RepoPath>/.mailbox/implementer.json or mailbox.md
    changes, then prints the new implementer.json and exits.

.DESCRIPTION
    This is the "listening" half of the mailbox: instead of a human
    manually relaying "check the mailbox now" between two copilot windows,
    each agent runs this as a background shell command. The moment its peer
    edits either mailbox file in the target repository, this script
    detects the change (by content hash, polled every -PollIntervalSeconds)
    and exits 0 — which surfaces as a background-command-completed
    notification to whichever copilot session is watching it, letting that
    agent react immediately without being re-prompted by the user.

    One-shot by design: it exits on the first detected change. Re-run it
    (the agent should do this itself, right after handling the change) to
    keep listening for the next one.

    The session log (.mailbox/session.log.md) is deliberately NOT watched:
    the protocol writes the log entry before the mailbox.md overwrite, so
    watching mailbox.md alone is sufficient and avoids double-wakes.

.PARAMETER RepoPath
    The repository being paired on. Defaults to the current directory.

.PARAMETER TimeoutSeconds
    Give up and exit 1 after this many seconds with no change. Default 0
    means watch indefinitely.

.PARAMETER PollIntervalSeconds
    How often to re-check for changes. Default 3.

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project
    # blocks until the peer touches that repo's mailbox, then exits 0

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -TimeoutSeconds 1800
    # give up after 30 minutes of silence (exit 1) instead of waiting forever
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [int]$TimeoutSeconds = 0,
    [int]$PollIntervalSeconds = 3
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$initCommand = "& $(ConvertTo-SingleQuoted $initMailboxScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath)"
$implementerPath = Join-Path $RepoPath ".mailbox\implementer.json"
$mailboxPath = Join-Path $RepoPath ".mailbox\mailbox.md"

foreach ($p in @($implementerPath, $mailboxPath)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Missing mailbox file: $p. Run $initCommand first."
    }
}

function Get-MailboxHash {
    # Hash both files together (content, not mtime) so edits to either one
    # are caught and clock/filesystem timestamp quirks can't hide a change.
    $combined = (Get-Content -LiteralPath $implementerPath -Raw) + [char]0 + (Get-Content -LiteralPath $mailboxPath -Raw)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha256.ComputeHash($bytes)) }
    finally { $sha256.Dispose() }
}

$initialHash = Get-MailboxHash
$elapsed = 0

Write-Host "Listening on $mailboxPath / $implementerPath (poll every ${PollIntervalSeconds}s)..." -ForegroundColor Cyan

while ($true) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $elapsed += $PollIntervalSeconds

    if ((Get-MailboxHash) -ne $initialHash) {
        Write-Host "MAILBOX_CHANGED" -ForegroundColor Green
        Get-Content -LiteralPath $implementerPath -Raw
        exit 0
    }

    if ($TimeoutSeconds -gt 0 -and $elapsed -ge $TimeoutSeconds) {
        Write-Host "MAILBOX_WATCH_TIMEOUT" -ForegroundColor Yellow
        exit 1
    }
}
