#Requires -Version 7.4

<#
.SYNOPSIS
    Writes one mailbox lane entry: appends it to the write-once session
    log FIRST, then overwrites the calling agent's own lane LAST — the
    exact two-step sequence COLLABORATION.md requires (see "Mailbox lanes
    and the session log"), deriving both destination paths from -Role
    instead of a hand-typed file path.

.DESCRIPTION
    What this does and does not protect against: -Role is a normal
    parameter that accepts either valid value ("agent-a" or "agent-b") —
    it cannot authenticate which agent is actually calling, and does not
    turn a wrong-but-valid -Role into an error. What it removes is
    hand-typed destination PATHS: the caller never spells out
    "agent-a.md"/"agent-b.md" itself, only a role, and every agent's own
    session banner already gives a ready-to-run command with -Role baked
    in correctly for that agent — run verbatim, the destination is
    correct by construction. Preventing a caller from deliberately or
    mistakenly supplying the *other* valid role would need a separate,
    not-yet-built identity mechanism (e.g. a per-session marker checked
    against -Role); this script does not attempt that. Lane identity vs.
    driver/navigator responsibility is a discipline problem first — see
    COLLABORATION.md "Mailbox lanes and the session log".

    Never accepts an arbitrary destination path or a pre-built log entry
    — only the raw turn body via -Turn. The log entry is framed here:
    the UTC "## <timestamp> <role>" heading (invariant culture), the body,
    exactly one line break, and a "<!-- cocopilot:end <timestamp> <role> -->"
    marker. A reader treats an entry without its marker as incomplete, so
    an interrupted append can never pass for a whole entry. A -Turn line
    that a reader could take for a heading or an end marker is refused
    before anything is written: it would forge an entry or a boundary.
    -Turn is otherwise written to the lane exactly as given.

    Write order is fixed and cannot be reordered by the caller:
      1. Append the framed entry to session.log.md under an exclusive
         handle, so no reader sees it half-written and two writers never
         interleave. Only opening the log is retried, and only on a
         sharing violation (the peer or a reader holds it for a moment).
      2. With -VerifyRequest, pin the turn to .mailbox/verify-request.md,
         where the fresh-eyes verifier reads it (see COLLABORATION.md
         "Fresh-eyes verification").
      3. Only then overwrite <Role>.md with the turn body, replaced whole
         (temp file + rename), so a reader never sees it missing or
         partly written.
    A failure surfaces as a thrown error — never as silent success — and
    step 1 is never repeated once it has succeeded, so an entry is never
    duplicated. Every write is UTF-8 without a BOM via .NET, independent
    of cmdlet encoding defaults.

.PARAMETER RepoPath
    The repository being paired on (its .mailbox/ holds the log + lanes).
    Required, as in handoff.ps1: there is no current-directory
    default, since this is normally invoked with the exact path already
    resolved in the session banner.

.PARAMETER Role
    Which agent's lane to write — "agent-a" or "agent-b". Determines both
    the lane file and the log heading. Accepts either valid value; see
    "What this does and does not protect against" above — it is on the
    caller to supply its own actual role, matching its own session
    banner.

.PARAMETER Turn
    The raw entry body (e.g. "SYNC #3`nWORK_UNIT: ...`n...") — no
    timestamp or "## ..." heading; this script generates that itself.
    Written to the lane file exactly as given (a trailing newline is
    neither required nor added).

.PARAMETER VerifyRequest
    Also pins this turn as the current VERIFY_REQUEST in the mailbox's
    verify-request.md, stamped with the author and the ownership epoch.
    Only the active implementer may pin one, and the turn must start with
    "VERIFY_REQUEST".

.EXAMPLE
    & .\scripts\write-lane.ps1 -RepoPath C:\Repos\your-project -Role agent-a -Turn $turn
#>
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$Role,
    [Parameter(Mandatory)][string]$Turn,
    [switch]$VerifyRequest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$mailboxDir = Join-Path $RepoPath ".mailbox"
$sessionLogPath = Join-Path $mailboxDir "session.log.md"
$lanePath = Join-Path $mailboxDir "$Role.md"
$implementerPath = Join-Path $mailboxDir "implementer.json"
$verifyRequestPath = Join-Path $mailboxDir "verify-request.md"

$requiredPaths = @($sessionLogPath, $lanePath) + $(if ($VerifyRequest) { @($implementerPath) } else { @() })
foreach ($p in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $p)) {
        # Lazy: only shells out to git (via Get-CocopilotInitCommand) on
        # this exceptional path, not on every ordinary write-lane.ps1 call.
        $initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initMailboxScript
        throw "Missing mailbox file: $p. Run $initCommand first."
    }
}

# Every refusal runs before the first write.
$forbiddenLine = Get-CocopilotForbiddenBodyLine -Body $Turn
if ($null -ne $forbiddenLine) {
    throw "-Turn contains a line a log reader would take for an entry heading or an end marker: '$forbiddenLine'. Quote that line with '> ' or rephrase it; nothing was written."
}
if ($VerifyRequest -and $Turn -notmatch '^\s*VERIFY_REQUEST\b') {
    throw "-VerifyRequest pins a VERIFY_REQUEST, but -Turn does not start with 'VERIFY_REQUEST'; nothing was written."
}

$stamp = Get-CocopilotUtcStamp
$entryText = New-CocopilotLogEntryText -Stamp $stamp -Role $Role -Body $Turn
if ($VerifyRequest) {
    # Under the ownership lock, no handoff can change the owner or the epoch
    # between the owner check, the log entry and the pinned request.
    $lock = Enter-CocopilotOwnershipLock -MailboxDir $mailboxDir
    try {
        $record = Read-CocopilotSharedText -Path $implementerPath | ConvertFrom-Json
        if ($record.state -ne "active" -or $record.owner -ne $Role) {
            throw "Only the active implementer pins a VERIFY_REQUEST; implementer.json names owner '$($record.owner)' in state '$($record.state)', not an active '$Role'. Nothing was written."
        }
        Add-CocopilotLogText -Path $sessionLogPath -Text $entryText
        $pinned = "# VERIFY_REQUEST (pinned by write-lane.ps1 -VerifyRequest; the fresh-eyes verifier reads it)`n" +
            "- author: $Role`n- epoch: $($record.epoch)`n- posted: $stamp`n`n$Turn"
        Write-CocopilotFileAtomic -Path $verifyRequestPath -Text $pinned
    } finally {
        $lock.Dispose()
    }
} else {
    Add-CocopilotLogText -Path $sessionLogPath -Text $entryText
}

# The log entry is written - nothing below may repeat it.
Write-CocopilotFileAtomic -Path $lanePath -Text $Turn