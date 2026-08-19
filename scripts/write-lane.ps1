#Requires -Version 5.1
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
    (with its own timestamp/heading) — only the raw turn body via -Turn.
    The UTC "## <timestamp> <role>" log heading is generated here, once,
    so every entry's heading is byte-for-byte consistent regardless of
    which agent or host wrote it. -Turn's content is otherwise preserved
    exactly in the lane file (no forced trailing newline is added on top
    of what the caller supplied); the log entry gets exactly one
    separating newline before whatever follows, whether or not -Turn
    already ended in one — never two.

    Write order is fixed and cannot be reordered by the caller:
      1. Append the heading + turn body to session.log.md (retried on a
         sharing violation — the peer may be appending at the same
         moment).
      2. Only once that succeeds, overwrite <Role>.md with the turn body
         (retried separately — a sharing violation here must NOT re-run
         step 1, which would duplicate the log entry).
    Only a genuine sharing violation ([System.IO.IOException]) is
    retried; any other error propagates immediately. A failure surfaces
    as a thrown error — it is never silently reported as success, and
    step 1 is never repeated once it has already succeeded.

    Both writes use UTF-8 without a BOM via .NET, so Windows PowerShell
    5.1 and pwsh 7 produce byte-identical output.

.PARAMETER RepoPath
    The repository being paired on (its .mailbox/ holds the log + lanes).
    Required — unlike the other scripts, there is no current-directory
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

.EXAMPLE
    & .\scripts\write-lane.ps1 -RepoPath C:\Repos\your-project -Role agent-a -Turn $turn
#>
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$Role,
    [Parameter(Mandatory)][string]$Turn
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$sessionLogPath = Join-Path $RepoPath ".mailbox\session.log.md"
$lanePath = Join-Path $RepoPath ".mailbox\$Role.md"

foreach ($p in @($sessionLogPath, $lanePath)) {
    if (-not (Test-Path -LiteralPath $p)) {
        # Lazy: only shells out to git (via Get-CocopilotInitCommand) on
        # this exceptional path, not on every ordinary write-lane.ps1 call.
        $initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initMailboxScript
        throw "Missing mailbox file: $p. Run $initCommand first."
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$nowUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss'Z'")
# Exactly one separating newline after $Turn in the log, regardless of
# whether $Turn already ends in one - never a doubled blank line.
$logSeparator = if ($Turn.EndsWith("`n")) { "" } else { "`n" }
$logEntry = "`n## $nowUtc $Role`n$Turn$logSeparator"

$maxAttempts = 5
for ($i = 0; $i -lt $maxAttempts; $i++) {
    try {
        [System.IO.File]::AppendAllText($sessionLogPath, $logEntry, $utf8NoBom)
        break
    } catch [System.IO.IOException] {
        if ($i -eq $maxAttempts - 1) { throw }
        Start-Sleep -Seconds 1
    }
}

# The log entry is now durable - a sharing violation on the lane overwrite
# below retries ONLY this step, never step 1 above (re-running it would
# duplicate the log entry for one logical turn). $Turn is written exactly
# as given - no forced trailing newline on top of it.
for ($i = 0; $i -lt $maxAttempts; $i++) {
    try {
        [System.IO.File]::WriteAllText($lanePath, $Turn, $utf8NoBom)
        return
    } catch [System.IO.IOException] {
        if ($i -eq $maxAttempts - 1) { throw }
        Start-Sleep -Seconds 1
    }
}
