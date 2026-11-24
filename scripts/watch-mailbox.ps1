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
    per-role cursor (<role>.cursor in the mailbox) records how far this agent
    has handled the log. On start the script delivers every entry after
    the cursor at once, except the agent's own; entries written while the
    agent was busy are never lost. With nothing to deliver it polls the
    log and implementer.json and exits on the first new peer entry or
    record change. Any change to implementer.json wakes it, including the
    agent's own handoff update.

    Delivery is not processing: the cursor never moves on its own. The
    output ends with "ACK_TOKEN: <generation>:<offset>", a ready-made
    "RE_ARM:" command and one compact ownership line:
    "OWNERSHIP (<changed|unchanged|current>): epoch=<n> state=<s>
    owner=<role> from=<role|none> to=<role|none> model=<owner_model>
    manifest=<dirty_manifest count> head=<12 chars> baseline=<8 chars|none>".
    head and baseline are shortened for display only; -Full prints the
    whole implementer.json instead. Every value is escaped (\\, \r, \n,
    \uXXXX) and quoted when it holds spaces, so it cannot forge a line.
    The record is checked first: one that is not a valid ownership record
    fails the run before any ACK token is printed and before -Ack moves
    the cursor. Handle the entries, then re-arm with that token
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

.PARAMETER NoWait
    Never block: deliver the peer entries that are waiting, or print
    NO_NEW_ENTRIES and the ownership line, then exit 0. Requires -Role.
    Used by the direct transport, where a native peer message wakes the
    agent instead of a background watch. With -Ack it first moves the
    cursor, then delivers anything that arrived meanwhile, so an agent
    drains by repeating the printed RE_ARM command until NO_NEW_ENTRIES.
    The only wait is for an unmarked last entry, which may still be
    growing: it waits once, at most until the log has been quiet for the
    settle period, and reports INCOMPLETE_TAIL_PENDING if the entry is
    still unsettled. It never enters the polling loop.

.PARAMETER Full
    Print the whole implementer.json ("OWNERSHIP_RECORD (<...>):" and the
    JSON) instead of the compact OWNERSHIP line. Requires -Role. The
    printed RE_ARM command keeps it. Before you accept a handoff, read
    the full record with -NoWait -Full: without -NoWait the watch blocks
    once everything is acknowledged.

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -Role agent-a
    # delivers agent-b's unhandled entries, or waits for the next one

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -Role agent-a -Ack 0123456789abcdef0123456789abcdef:52817
    # marks the previous delivery as handled, then watches again

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -TimeoutSeconds 1800
    # observe the whole mailbox; give up after 30 minutes of silence (exit 1)

.EXAMPLE
    .\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\some-other-project -Role agent-b -NoWait
    # direct transport: deliver what is waiting now, or print NO_NEW_ENTRIES
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [ValidateSet("agent-a", "agent-b")][string]$Role,
    [ValidatePattern('^[0-9a-f]{32}:\d{1,18}$')][string]$Ack,
    [ValidateRange(0, [int]::MaxValue)][int]$TimeoutSeconds = 0,
    [ValidateRange(1, 3600)][int]$PollIntervalSeconds = 3,
    [switch]$NoWait,
    [switch]$Full
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
if ($Ack -and -not $Role) {
    throw "-Ack needs -Role: an ACK token moves that role's cursor."
}
if ($NoWait -and -not $Role) {
    throw "-NoWait needs -Role: it delivers that role's waiting entries."
}
if ($Full -and -not $Role) {
    throw "-Full needs -Role: without -Role the watcher already prints the whole record."
}

$mailboxDir = Open-CocopilotMailbox -RepoPath $RepoPath
$implementerPath = Join-Path $mailboxDir "implementer.json"
$laneA = Join-Path $mailboxDir "agent-a.md"
$laneB = Join-Path $mailboxDir "agent-b.md"
$sessionLogPath = Join-Path $mailboxDir "session.log.md"

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

function Write-OwnershipRecord {
    # The compact OWNERSHIP line, or with -Full the raw record as before.
    param(
        [Parameter(Mandatory)][ValidateSet("changed", "unchanged", "current")][string]$Label,
        [Parameter(Mandatory)][string]$RecordText,
        [Parameter(Mandatory)]$Record
    )

    if ($Full) {
        Write-Output "OWNERSHIP_RECORD (${Label}):"
        Write-Output $RecordText.TrimEnd()
    } else {
        Write-Output (Format-CocopilotOwnershipLine -Record $Record -Label $Label)
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

    # Before any output: an invalid record fails the run. It is never
    # summarized with invented values or followed by an ACK token.
    $record = ConvertFrom-CocopilotOwnershipRecord -Text $RecordText -Path $implementerPath
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
    $suffix = $(if ($NoWait) { " -NoWait" } else { "" }) + $(if ($Full) { " -Full" } else { "" })
    Write-Output "ACK_TOKEN: $token"
    Write-Output "RE_ARM: & $(ConvertTo-SingleQuoted $PSCommandPath) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $Role -Ack $token$suffix"
    Write-OwnershipRecord -Label $(if ($RecordChanged) { "changed" } else { "unchanged" }) -RecordText $RecordText -Record $record
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

# Validated before -Ack can move the cursor: with an invalid record the run
# fails and every mailbox file stays as it was.
$recordText = Read-CocopilotSharedText -Path $implementerPath
$null = ConvertFrom-CocopilotOwnershipRecord -Text $recordText -Path $implementerPath
$recordHash = Get-TextHash -Text $recordText

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
        $ackScan = Get-CocopilotDeliveryScan -Text $logText -From $from -TailSettled (Test-LogTailSettled) -Role $Role
        if ($tokenOffset -notin $ackScan.AckBoundaries) {
            throw "ACK token $Ack does not end an entry after the cursor (offset $from); the cursor was not moved."
        }
        Write-CocopilotCursor -Path $cursorPath -Generation $generation -Offset $tokenOffset
        $from = $tokenOffset
        $note = $null
    }
}

$scan = Get-CocopilotDeliveryScan -Text $logText -From $from -TailSettled (Test-LogTailSettled) -Role $Role
if (@($scan.Deliver).Count -gt 0) {
    Write-Delivery -Scan $scan -Generation $generation -Note $note -RecordChanged $false -RecordText $recordText
    exit 0
}

if ($NoWait) {
    if ($scan.HeldBack) {
        # An unmarked last entry may still be growing, and in this mode no
        # later watch wakes the agent for it: wait once, only until the log
        # has been quiet for the settle period, then decide.
        $quietFor = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($sessionLogPath)).TotalSeconds
        Start-Sleep -Milliseconds ([int][Math]::Ceiling(([Math]::Max(0, $settleSeconds - $quietFor) + 0.2) * 1000))
        $logText = Read-CocopilotSharedText -Path $sessionLogPath
        if ((Get-CocopilotLogGeneration -Text $logText) -cne $generation) {
            throw "The session log was replaced while reading (its generation changed); run the read again without -Ack."
        }
        $recordText = Read-CocopilotSharedText -Path $implementerPath
        $scan = Get-CocopilotDeliveryScan -Text $logText -From $from -TailSettled (Test-LogTailSettled) -Role $Role
        if (@($scan.Deliver).Count -gt 0) {
            Write-Delivery -Scan $scan -Generation $generation -Note $note -RecordChanged $false -RecordText $recordText
            exit 0
        }
    }
    if ($scan.HeldBack) {
        Write-Output "INCOMPLETE_TAIL_PENDING: the last log entry has no end marker and the log is still being written. Nothing wakes you for it later: run this read again in a few seconds."
    } else {
        Write-Output "NO_NEW_ENTRIES"
        if ($note) { Write-Output "NOTE: $note" }
    }
    $record = ConvertFrom-CocopilotOwnershipRecord -Text $recordText -Path $implementerPath
    Write-OwnershipRecord -Label "current" -RecordText $recordText -Record $record
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
        $scan = Get-CocopilotDeliveryScan -Text $logText -From $from -TailSettled (Test-LogTailSettled) -Role $Role
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