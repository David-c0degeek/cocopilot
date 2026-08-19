#Requires -Version 5.1
<#
.SYNOPSIS
    Blocks until the watched mailbox files in <RepoPath>/.mailbox/ change,
    then prints the new implementer.json and exits.

.DESCRIPTION
    This is the "listening" half of the mailbox: instead of a human
    manually relaying "check the mailbox now" between two copilot windows,
    each agent runs this as a background shell command. The moment its peer
    writes, this script detects the change (by content hash, polled every
    -PollIntervalSeconds) and exits 0 — which surfaces as a
    background-command-completed notification to whichever copilot session
    is watching it, letting that agent react immediately without being
    re-prompted by the user.

    What is watched depends on -Role:
      - With -Role agent-a or agent-b: implementer.json plus the PEER's
        lane file only (agent-b.md for agent-a, and vice versa). The
        agent's own lane is deliberately excluded so its own writes can
        never wake it.
      - Without -Role: implementer.json plus both lane files (for a human
        or tool observing the whole mailbox).

    One-shot by design: it exits on the first detected change. Re-run it
    (the agent should do this itself, right after handling the change) to
    keep listening for the next one.

    The session log (.mailbox/session.log.md) is deliberately NOT watched:
    the protocol writes the log entry before the lane overwrite, so
    watching the lanes alone is sufficient and avoids double-wakes.

.PARAMETER RepoPath
    The repository being paired on. Defaults to the current directory.

.PARAMETER Role
    Which agent is listening ("agent-a" or "agent-b"). Watches only the
    peer's lane + implementer.json. Omit to watch both lanes.

.PARAMETER TimeoutSeconds
    Give up and exit 1 after this many seconds with no change. Default 0
    means watch indefinitely.

.PARAMETER PollIntervalSeconds
    How often to re-check for changes. Default 3.

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -Role agent-a
    # blocks until agent-b writes its lane or the ownership record changes

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -TimeoutSeconds 1800
    # watch everything; give up after 30 minutes of silence (exit 1)
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [ValidateSet("agent-a", "agent-b")][string]$Role,
    [int]$TimeoutSeconds = 0,
    [int]$PollIntervalSeconds = 3
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initMailboxScript
$implementerPath = Join-Path $RepoPath ".mailbox\implementer.json"
$laneA = Join-Path $RepoPath ".mailbox\agent-a.md"
$laneB = Join-Path $RepoPath ".mailbox\agent-b.md"

$watchPaths = switch ($Role) {
    "agent-a" { @($implementerPath, $laneB) }
    "agent-b" { @($implementerPath, $laneA) }
    default   { @($implementerPath, $laneA, $laneB) }
}

foreach ($p in @($implementerPath, $laneA, $laneB)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Missing mailbox file: $p. Run $initCommand first."
    }
}

function Get-MailboxHash {
    # Hash the watched files together (content, not mtime) so edits to any
    # of them are caught and clock/filesystem timestamp quirks can't hide a
    # change.
    $combined = ($watchPaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join [char]0
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha256.ComputeHash($bytes)) }
    finally { $sha256.Dispose() }
}

$initialHash = Get-MailboxHash
$elapsed = 0

Write-Host "Listening on $($watchPaths -join ' / ') (poll every ${PollIntervalSeconds}s)..." -ForegroundColor Cyan

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
