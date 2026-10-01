#Requires -Version 7.4

<#
.SYNOPSIS
    With -Role: delivers every new peer entry from the session log, or
    blocks until one arrives or the ownership record changes. Without
    -Role: blocks until the ownership record or a lane changes.

.DESCRIPTION
    This is the "listening" half of the mailbox: instead of a human
    relaying "check the mailbox now" between two copilot windows, each
    agent runs this as a background shell command. It exits 0 as soon as
    there is something to act on, which surfaces as a
    background-command-completed notification.

    With -Role (agent-a or agent-b), the session log is the inbox. A
    per-role cursor (.mailbox/<role>.cursor) records how far this agent
    has handled the log. On start the script delivers every entry after
    the cursor at once, except the agent's own; entries written while the
    agent was busy are never lost. With nothing to deliver it polls the
    log and implementer.json and exits on the first new peer entry or
    record change. Any change to implementer.json wakes it, including the
    agent's own handoff update.

    Delivery is not processing: the cursor never moves on its own. The
    output ends with "ACK_TOKEN: <generation>:<offset>" and a ready-made
    "RE_ARM:" command. Handle the entries, then re-arm with that token
    (-Ack): the cursor moves to the end of what was delivered. Without
    -Ack the same entries are delivered again (at least once). A token is
    accepted only for the current log generation, at the exact end of an
    entry after the cursor; anything else throws and leaves the cursor
    unchanged. Offsets are character positions in the decoded log, and
    every accepted boundary is a line break between two entries.

    A missing or unreadable cursor, or one for another log generation,
    delivers the whole log from its start.

    Each delivered entry shows its heading and its body indented by four
    spaces (the turn without its final line break). Labels mark entries
    whose completeness is not proven: LEGACY (written before cocopilot
    added end markers), INCOMPLETE (no end marker: the writer stopped
    mid-append or runs an older cocopilot) and FRAGMENT (text that
    reached an entry after it was acknowledged). An unmarked last entry is
    held back until the log has not changed for a few seconds, because a
    writer may still be appending to it.

    Without -Role the script watches implementer.json plus both lane files
    by content hash and prints the record on the first change - for a
    human or tool observing the whole mailbox.

.PARAMETER RepoPath
    The repository being paired on. Defaults to the current directory.

.PARAMETER Role
    Which agent is listening ("agent-a" or "agent-b"): delivers the other
    agent's entries and moves this role's cursor. Omit to observe the
    whole mailbox instead.

.PARAMETER Ack
    The ACK_TOKEN from this role's previous delivery, once its entries are
    handled. Moves the cursor before watching again. Requires -Role.

.PARAMETER TimeoutSeconds
    Give up and exit 1 after this many seconds with nothing to deliver.
    Default 0 means watch indefinitely.

.PARAMETER PollIntervalSeconds
    How often to re-check for changes, from 1 to 3600. Default 3.

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -Role agent-a
    # delivers agent-b's unhandled entries, or waits for the next one

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -Role agent-a -Ack 0123456789abcdef0123456789abcdef:52817
    # marks the previous delivery as handled, then watches again

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -TimeoutSeconds 1800
    # observe the whole mailbox; give up after 30 minutes of silence (exit 1)
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [ValidateSet("agent-a", "agent-b")][string]$Role,
    [ValidatePattern('^[0-9a-f]{32}:\d{1,18}$')][string]$Ack,
    [ValidateRange(0, [int]::MaxValue)][int]$TimeoutSeconds = 0,
    [ValidateRange(1, 3600)][int]$PollIntervalSeconds = 3
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$mailboxDir = Join-Path $RepoPath ".mailbox"
$implementerPath = Join-Path $mailboxDir "implementer.json"
$laneA = Join-Path $mailboxDir "agent-a.md"
$laneB = Join-Path $mailboxDir "agent-b.md"
$sessionLogPath = Join-Path $mailboxDir "session.log.md"

if ($Ack -and -not $Role) {
    throw "-Ack needs -Role: an ACK token moves that role's cursor."
}

foreach ($p in @($implementerPath, $laneA, $laneB, $sessionLogPath)) {
    if (-not (Test-Path -LiteralPath $p)) {
        # Computed lazily, here in the error path: Get-CocopilotInitCommand
        # shells out to git, and the common case needs no suggestion.
        $initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initMailboxScript
        throw "Missing mailbox file: $p. Run $initCommand first."
    }
}

function Get-TextHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text)))
}

if (-not $Role) {
    # Observer mode: content hashes, not timestamps, so clock or filesystem
    # quirks cannot hide a change.
    $watchPaths = @($implementerPath, $laneA, $laneB)
    $observedHash = Get-TextHash -Text (($watchPaths | ForEach-Object { Read-CocopilotSharedText -Path $_ }) -join [char]0)
    Write-Host "Listening on $($watchPaths -join ' / ') (poll every ${PollIntervalSeconds}s)..." -ForegroundColor Cyan
    $elapsed = 0
    while ($true) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
        if ((Get-TextHash -Text (($watchPaths | ForEach-Object { Read-CocopilotSharedText -Path $_ }) -join [char]0)) -ne $observedHash) {
            Write-Output "MAILBOX_CHANGED"
            Write-Output (Read-CocopilotSharedText -Path $implementerPath).TrimEnd()
            exit 0
        }
        if ($TimeoutSeconds -gt 0 -and $elapsed -ge $TimeoutSeconds) {
            Write-Output "MAILBOX_WATCH_TIMEOUT"
            exit 1
        }
    }
}

$cursorPath = Join-Path $mailboxDir "$Role.cursor"
# An unmarked last entry may still be growing; it counts as settled once
# the log has not been written for this long.
$settleSeconds = [Math]::Max(5, 2 * $PollIntervalSeconds)

function Test-LogTailSettled {
    return ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($sessionLogPath)).TotalSeconds -ge $settleSeconds
}

function Get-DeliveryScan {
    <#
    .SYNOPSIS
        Splits the log after $From into what to deliver (peer and init
        entries), which offsets an ACK may name, and how far the delivered
        and own entries reach.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][long]$From,
        [Parameter(Mandatory)][bool]$TailSettled
    )

    $segments = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-CocopilotLogEntries -Text $Text)) {
        if ($entry.End -le $From) { continue }
        if ($entry.Start -lt $From) {
            # The cursor points into this entry: text reached it after an
            # unmarked tail had settled and was acknowledged.
            $segments.Add([pscustomobject]@{
                    Stamp = $entry.Stamp; Role = $entry.Role; Start = $From; End = $entry.End; Kind = "Fragment"
                    Body  = $Text.Substring([int]$From, [int]($entry.End - $From)).Trim("`r", "`n")
                })
            continue
        }
        $segments.Add($entry)
    }

    $heldBack = $null
    if ($segments.Count -gt 0) {
        $last = $segments[$segments.Count - 1]
        if ($last.Kind -ne "Complete" -and $last.End -eq $Text.Length -and -not $TailSettled) {
            $heldBack = $last
            $segments.RemoveAt($segments.Count - 1)
        }
    }

    return [pscustomobject]@{
        Deliver       = @($segments | Where-Object { $_.Role -ne $Role })
        AckBoundaries = @($segments | ForEach-Object { [long]$_.End })
        AckOffset     = if ($segments.Count -gt 0) { [long]$segments[$segments.Count - 1].End } else { $From }
        HeldBack      = $null -ne $heldBack
    }
}

function Write-Delivery {
    param(
        [Parameter(Mandatory)]$Scan,
        [Parameter(Mandatory)][string]$Generation,
        [string]$Note,
        [Parameter(Mandatory)][bool]$RecordChanged,
        [Parameter(Mandatory)][string]$RecordText
    )

    $count = @($Scan.Deliver).Count
    $noun = if ($count -eq 1) { "entry" } else { "entries" }
    $recordNote = if ($RecordChanged) { "; the ownership record changed" } else { "" }
    Write-Output "MAILBOX_CHANGED: $count new $noun$recordNote"
    if ($Note) { Write-Output "NOTE: $Note" }
    foreach ($segment in $Scan.Deliver) {
        $label = switch ($segment.Kind) {
            "Legacy" { " [LEGACY - completeness unverified]" }
            "Incomplete" { " [INCOMPLETE - no end marker: its writer stopped mid-append or runs an older cocopilot]" }
            "Fragment" { " [FRAGMENT - text that reached this entry after it was acknowledged]" }
            default { "" }
        }
        Write-Output "----- $($segment.Stamp) $($segment.Role)$label"
        foreach ($line in ($segment.Body -split "\r?\n")) { Write-Output "    $line" }
    }
    $token = "${Generation}:$($Scan.AckOffset)"
    Write-Output "ACK_TOKEN: $token"
    Write-Output "RE_ARM: & $(ConvertTo-SingleQuoted $PSCommandPath) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $Role -Ack $token"
    Write-Output ("OWNERSHIP_RECORD ({0}):" -f $(if ($RecordChanged) { "changed" } else { "unchanged" }))
    Write-Output $RecordText.TrimEnd()
}

$observedLength = [System.IO.FileInfo]::new($sessionLogPath).Length
$logText = Read-CocopilotSharedText -Path $sessionLogPath
$generation = Get-CocopilotLogGeneration -Text $logText
$cursor = Read-CocopilotCursor -Path $cursorPath
$from = 0L
$note = $null
if (-not $cursor.Valid) {
    $note = "$($cursor.Reason); delivering the whole log from its start."
} elseif ($cursor.Generation -ne $generation) {
    $note = "the cursor belongs to another log generation; delivering the whole log from its start."
} elseif ($cursor.Offset -gt $logText.Length) {
    $note = "the cursor points past the end of the log; delivering the whole log from its start."
} else {
    $from = $cursor.Offset
}

if ($Ack) {
    $tokenGeneration, $tokenOffsetText = $Ack.Split(":")
    $tokenOffset = [long]$tokenOffsetText
    if ($tokenGeneration -cne $generation) {
        throw "ACK token $Ack belongs to another log generation (this log is $generation); the cursor was not moved."
    }
    if ($tokenOffset -lt $from) {
        throw "ACK token $Ack is behind the cursor (offset $from); the cursor was not moved."
    }
    if ($tokenOffset -gt $from) {
        $ackScan = Get-DeliveryScan -Text $logText -From $from -TailSettled (Test-LogTailSettled)
        if ($tokenOffset -notin $ackScan.AckBoundaries) {
            throw "ACK token $Ack does not end an entry after the cursor (offset $from); the cursor was not moved."
        }
        Write-CocopilotCursor -Path $cursorPath -Generation $generation -Offset $tokenOffset
        $from = $tokenOffset
        $note = $null
    }
}

$recordText = Read-CocopilotSharedText -Path $implementerPath
$recordHash = Get-TextHash -Text $recordText
$scan = Get-DeliveryScan -Text $logText -From $from -TailSettled (Test-LogTailSettled)
if (@($scan.Deliver).Count -gt 0) {
    Write-Delivery -Scan $scan -Generation $generation -Note $note -RecordChanged $false -RecordText $recordText
    exit 0
}

$peer = if ($Role -eq "agent-a") { "agent-b" } else { "agent-a" }
Write-Host "Listening for ${peer}'s entries in $sessionLogPath and for changes to $implementerPath (poll every ${PollIntervalSeconds}s)..." -ForegroundColor Cyan
$elapsed = 0
while ($true) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $elapsed += $PollIntervalSeconds

    $currentRecord = Read-CocopilotSharedText -Path $implementerPath
    $recordChanged = (Get-TextHash -Text $currentRecord) -ne $recordHash
    # Byte length, measured before the read like the first one: growth
    # during a read only causes one more scan, never a missed entry.
    $logLength = [System.IO.FileInfo]::new($sessionLogPath).Length
    if ($logLength -ne $observedLength -or $scan.HeldBack -or $recordChanged) {
        $logText = Read-CocopilotSharedText -Path $sessionLogPath
        if ((Get-CocopilotLogGeneration -Text $logText) -cne $generation) {
            throw "The session log was replaced while watching (its generation changed); run the watch again without -Ack."
        }
        $observedLength = $logLength
        $scan = Get-DeliveryScan -Text $logText -From $from -TailSettled (Test-LogTailSettled)
    }
    if (@($scan.Deliver).Count -gt 0 -or $recordChanged) {
        Write-Delivery -Scan $scan -Generation $generation -Note $note -RecordChanged $recordChanged -RecordText $currentRecord
        exit 0
    }

    if ($TimeoutSeconds -gt 0 -and $elapsed -ge $TimeoutSeconds) {
        Write-Output "MAILBOX_WATCH_TIMEOUT"
        exit 1
    }
}