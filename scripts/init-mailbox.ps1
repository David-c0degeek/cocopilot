#Requires -Version 7.4

<#
.SYNOPSIS
    Initializes the local (git-ignored) mailbox state for a target
    repository: <RepoPath>/.mailbox/implementer.json, the per-agent lane
    scratchpads agent-a.md / agent-b.md, session.log.md, and one delivery
    cursor per agent (agent-a.cursor / agent-b.cursor).

.DESCRIPTION
    cocopilot itself stays centrally installed (this script's own location);
    the mailbox it manages lives inside whatever repository (or, with
    -AllowNonGit, workspace root) you're pairing on. Templates are read
    from this cocopilot install's own .mailbox/*.example.* files, but the
    real, git-ignored files are written into <RepoPath>/.mailbox/, stamped
    with that repository's current git HEAD (or the fixed "non-git-root"
    sentinel, with -AllowNonGit). Safe to re-run: it will not overwrite
    existing implementer.json or lane files unless -Force is passed. The
    write-once session history (session.log.md) is created whole if
    missing, with its init entry naming the log's generation, and is
    PRESERVED even with -Force — a session-reset entry is appended
    instead; only cleanup-mailbox.ps1 removes it (together with
    cocopilot's other mailbox files).

    Delivery cursors record how far each agent has handled the log (see
    watch-mailbox.ps1). A new log resets both to its end, since it holds
    only its init entry. For an existing log, init never counts history as
    handled on its own: a missing cursor stays missing, so the first watch
    of that agent replays the whole log, and an existing cursor is never
    moved. Likewise, an ownership record without a handoff baseline (from
    an older cocopilot) keeps none, and handoffs stay refused. Only
    -AcknowledgeHistory changes either.

    Before anything is written, does a small safety check: if <RepoPath> is
    a git repository and .mailbox/ is not ignored yet, this adds cocopilot's
    managed rule to the repository's git-local exclude file
    (.git/info/exclude, never committed, untouched by checkout/stash/clean
    of tracked files) first - so the per-machine mailbox state can't be
    committed even if init is interrupted mid-write. The tracked .gitignore
    of the target is never edited.

    Refuses outright, before any of the above, when -RepoPath is a
    cocopilot install - its own path, or any other path (junction, symlink,
    subst, copy) to a directory whose .mailbox/ holds cocopilot's
    *.example.* templates - when git tracks anything under .mailbox/, or
    when an existing .mailbox/ holds anything cocopilot does not create
    itself. A partially initialized cocopilot mailbox is completed on re-run.

.PARAMETER RepoPath
    The repository to pair on. Defaults to the current directory.

.PARAMETER Owner
    Which role starts as the active implementer: "agent-a" (default) or
    "agent-b".

.PARAMETER OwnerModel
    Informational label for which model agent-a happens to be running.

.PARAMETER Force
    Overwrite the existing ownership record and the two lane files. The
    record's epoch rises by one, so an offer from before the reset can
    never be accepted.

.PARAMETER AcknowledgeHistory
    Counts everything so far as handled: moves both delivery cursors to
    the log's current end, also a cursor that exists, and gives an
    ownership record without a baseline the current state as its first
    one (owner and epoch unchanged). This is the upgrade step for a
    mailbox from an older cocopilot. Use it only when every entry so far
    is handled, with no STOP or QUESTION still pending, and stop both
    agents first. Nothing in cocopilot passes it for you.

.PARAMETER AllowNonGit
    Pair directly on a workspace root that is itself not a git repository
    — e.g. a folder like C:\Repos containing several independent repos as
    children. Without this switch, such a target is refused, since the
    protocol's ownership anchors (head / dirty_manifest) normally pin to
    git HEAD/status, which the root itself doesn't have. With
    -AllowNonGit, head is recorded as the fixed sentinel "non-git-root"
    and dirty_manifest becomes the authoritative handoff anchor instead —
    see COLLABORATION.md "Ownership handoff" for exactly what a
    HANDOFF_OFFER must record in that mode. If you only need read-only
    cross-repo context while writing to just ONE child repo,
    start-agents.ps1 -ContextRoot (pairing on that one repo, with the
    workspace granted as a read-only search scope) is the lighter-weight
    alternative.

.EXAMPLE
    .\scripts\init-mailbox.ps1 -RepoPath C:\Repos\some-other-project
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [ValidateSet("agent-a", "agent-b")][string]$Owner = "agent-a",
    [string]$OwnerModel = "unknown",
    [switch]$Force,
    [switch]$AcknowledgeHistory,
    [switch]$AllowNonGit
)

$ErrorActionPreference = "Stop"
# Expected non-zero git exits (e.g. check-ignore's 1 = "not ignored") are
# read from $LASTEXITCODE, whatever the caller's profile sets here.
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$cocopilotRoot = Split-Path -Parent $PSScriptRoot

# Refuse FIRST, before any side effect: cocopilot's own installed repo is
# never a pairing target. Its .mailbox/ only ever holds the two tracked
# *.example.* templates this script reads from below - initializing a real
# mailbox there would collide with them, and cleanup-mailbox.ps1 would later
# see tracked files under .mailbox/ and (correctly) refuse to touch them too.
if ($RepoPath.TrimEnd('\', '/') -ieq $cocopilotRoot.TrimEnd('\', '/')) {
    throw ("'$RepoPath' is cocopilot's own installed repo, not a project you're pairing on. " +
        "cd into the project repo you want to pair on (or pass it as -RepoPath) and run this there instead.")
}
# The path check above misses aliases (junction, symlink, subst) and copies;
# the templates themselves identify a cocopilot install whatever the path.
if (Test-CocopilotTemplatesPresent -RepoPath $RepoPath) {
    throw ("'$RepoPath' holds cocopilot's *.example.* templates under .mailbox/ - it is a cocopilot install " +
        "(possibly reached through an alias path), not a project you're pairing on.")
}

$mailboxDir = Join-Path $RepoPath ".mailbox"
$implementerPath = Join-Path $mailboxDir "implementer.json"
$lanePaths = @("agent-a.md", "agent-b.md") | ForEach-Object { Join-Path $mailboxDir $_ }
$sessionLogPath = Join-Path $mailboxDir "session.log.md"
$implementerTemplate = Join-Path $cocopilotRoot ".mailbox\implementer.example.json"
$laneTemplate = Join-Path $cocopilotRoot ".mailbox\lane.example.md"

$isGitRepo = $false
try {
    $null = git -C $RepoPath rev-parse --is-inside-work-tree 2>$null
    $isGitRepo = ($LASTEXITCODE -eq 0)
} catch { $isGitRepo = $false }

if ($isGitRepo) {
    $tracked = @(Get-CocopilotTrackedMailboxPaths -RepoPath $RepoPath)
    if ($tracked.Count -gt 0) {
        throw ("git tracks files under .mailbox/ in '$RepoPath' ($($tracked -join ', ')). That content is not " +
            "cocopilot's per-machine state; refusing to write into it.")
    }
} elseif (-not $AllowNonGit) {
    throw ("'$RepoPath' is not a git repository. Pass -AllowNonGit to pair directly on this " +
        "workspace root (its ownership anchors then rely on dirty_manifest instead of git " +
        "HEAD/status - see COLLABORATION.md 'Ownership handoff'). If you only need read-only " +
        "cross-repo context while writing to just ONE child repo, start-agents.ps1 -ContextRoot " +
        "is the lighter-weight alternative.")
} else {
    Write-Warning "$RepoPath is not a git repository (-AllowNonGit): head will read the fixed sentinel 'non-git-root', no git ignore rule is added, and dirty_manifest becomes the authoritative handoff anchor - see COLLABORATION.md 'Ownership handoff' for what a HANDOFF_OFFER must record in this mode. Make sure .mailbox/ never gets committed here."
}

if (Test-Path -LiteralPath $mailboxDir) {
    if (([System.IO.File]::GetAttributes($mailboxDir)).HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
        throw "$mailboxDir is a reparse point (symlink/junction/mount point) - cocopilot never creates .mailbox/ that way; refusing to write through it."
    }
    $foreign = @(Get-ChildItem -LiteralPath $mailboxDir -Force | Where-Object {
            -not (Test-CocopilotMailboxEntryName -Name $_.Name)
        })
    if ($foreign.Count -gt 0) {
        throw ("'$mailboxDir' already holds entries cocopilot does not create ($($foreign.Name -join ', ')) - " +
            "refusing to mix cocopilot state into it.")
    }
    # Known names prove nothing: each existing file must be a file, and an
    # existing record or log must hold cocopilot content, before anything is
    # adopted or overwritten - even with -Force. Missing files stay
    # recoverable (an interrupted init is completed on re-run).
    foreach ($name in Get-CocopilotMailboxFileNames) {
        $known = Join-Path $mailboxDir $name
        if (-not (Test-Path -LiteralPath $known)) { continue }
        if (-not (Test-Path -LiteralPath $known -PathType Leaf)) {
            throw "'$known' exists but is not a file - refusing to initialize over it."
        }
        if ($name -in @("implementer.json", "session.log.md")) {
            $check = Get-CocopilotMailboxFileCheck -Path $known
            if ($check.State -ne "Cocopilot") {
                throw "'$known' exists but is not cocopilot's ($($check.State): $($check.Reason)) - refusing to adopt or overwrite it, even with -Force."
            }
        }
    }
}

# Safety net FIRST - before anything under .mailbox/ exists: keep the
# per-machine mailbox out of the target repo's history through the
# git-local exclude file, never through the tracked .gitignore.
if ($isGitRepo) {
    $null = git -C $RepoPath check-ignore -q -- .mailbox/ 2>$null
    if ($LASTEXITCODE -gt 1) { throw "git check-ignore failed in '$RepoPath' (exit $LASTEXITCODE)." }
    if ($LASTEXITCODE -eq 1) {
        $excludeTarget = Add-CocopilotMailboxExcludeRule -RepoPath $RepoPath
        if ($excludeTarget) {
            Write-Host "Added the ignore rule $($excludeTarget.Rule) to $($excludeTarget.Path)" -ForegroundColor Green
        }
        # Proof, not assumption: git itself must now ignore this exact
        # .mailbox/ before any mailbox state is created.
        $null = git -C $RepoPath check-ignore -q -- .mailbox/ 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "git still does not ignore '$mailboxDir' after adding cocopilot's exclude rule - refusing to create mailbox state that could be committed."
        }
    }
}

[System.IO.Directory]::CreateDirectory($mailboxDir) | Out-Null

$head = if ($isGitRepo) { "0000000000000000000000000000000000000000" } else { "non-git-root" }
if ($isGitRepo) {
    try {
        $gitHead = git -C $RepoPath rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitHead) { $head = $gitHead.Trim() }
    } catch {
        Write-Warning "Could not resolve git HEAD for $RepoPath (no commits yet?); using zero SHA."
    }
}

$lock = Enter-CocopilotOwnershipLock -MailboxDir $mailboxDir
try {
    if ((Test-Path -LiteralPath $implementerPath) -and -not $Force) {
        $existing = Read-CocopilotSharedText -Path $implementerPath | ConvertFrom-Json
        if ($null -eq $existing.PSObject.Properties["baseline"] -or $null -eq $existing.baseline) {
            if ($AcknowledgeHistory) {
                # A record from an older cocopilot has no baseline, so no
                # handoff could prove its manifest. Recording the current
                # state counts every change so far as known, which only the
                # explicit switch may do.
                $fingerprint = Get-CocopilotWorkspaceFingerprint -RepoPath $RepoPath
                $upgraded = [ordered]@{}
                foreach ($property in $existing.PSObject.Properties) { $upgraded[$property.Name] = $property.Value }
                $upgraded["baseline"] = Save-CocopilotBaseline -MailboxDir $mailboxDir -Fingerprint $fingerprint
                Write-MailboxJson -Path $implementerPath -Object ([pscustomobject]$upgraded)
                Write-Host "Recorded the current state as the handoff baseline in $implementerPath (owner and epoch unchanged)." -ForegroundColor Green
                if (-not $fingerprint.Complete) { Write-Warning "The baseline is partial ($($fingerprint.Reason)); handoffs will be refused here." }
            } else {
                Write-Warning ("$implementerPath has no handoff baseline (it predates baselines), so handoffs are refused. " +
                    "Only when every change and every log entry so far is handled, re-run this command with " +
                    "-AcknowledgeHistory to record the current state as the baseline.")
            }
        } else {
            Write-Host "implementer.json already exists, leaving it as-is (use -Force to reset)." -ForegroundColor Yellow
        }
    } else {
        # -Force keeps the epoch monotonic (the old record passed the ownership
        # check above), so an offer from before the reset can never be accepted.
        $epoch = 1
        $supersededBaseline = $null
        if (Test-Path -LiteralPath $implementerPath) {
            $previous = Read-CocopilotSharedText -Path $implementerPath | ConvertFrom-Json
            $epoch = [long]$previous.epoch + 1
            if ($null -ne $previous.PSObject.Properties["baseline"]) { $supersededBaseline = $previous.baseline }
        }
        $fingerprint = Get-CocopilotWorkspaceFingerprint -RepoPath $RepoPath
        $record = Get-Content -LiteralPath $implementerTemplate -Raw | ConvertFrom-Json
        $record.epoch = $epoch
        $record.owner = $Owner
        $record.owner_model = $OwnerModel
        $record.head = $head
        $record.baseline = Save-CocopilotBaseline -MailboxDir $mailboxDir -Fingerprint $fingerprint
        Write-MailboxJson -Path $implementerPath -Object $record
        if ($null -ne $supersededBaseline -and [string]$supersededBaseline.id -cmatch '^[0-9a-f]{32}$') {
            $supersededPath = Join-Path $mailboxDir "baseline-$($supersededBaseline.id).json"
            try {
                if (Test-Path -LiteralPath $supersededPath) { Remove-Item -LiteralPath $supersededPath -Force }
            } catch {
                Write-Warning "Could not remove the superseded baseline '$supersededPath': $($_.Exception.Message)"
            }
        }
        # Only a real git repo's head looks like a SHA worth truncating for
        # display; the non-git-root sentinel is short and self-explanatory, so
        # showing it in full avoids an odd mid-word cut ("non-git" instead of
        # "non-git-root").
        $headDisplay = if ($isGitRepo) { $head.Substring(0, [Math]::Min(7, $head.Length)) } else { $head }
        Write-Host "Wrote $implementerPath (epoch=$epoch, owner=$Owner, head=$headDisplay)" -ForegroundColor Green
        if (-not $fingerprint.Complete) { Write-Warning "The handoff baseline is partial ($($fingerprint.Reason)); handoffs will be refused here." }
    }
} finally {
    $lock.Dispose()
}

foreach ($lanePath in $lanePaths) {
    if ((Test-Path -LiteralPath $lanePath) -and -not $Force) {
        Write-Host "$(Split-Path -Leaf $lanePath) already exists, leaving it as-is (use -Force to reset)." -ForegroundColor Yellow
    } else {
        [System.IO.File]::Copy($laneTemplate, $lanePath, $true)
        Write-Host "Wrote $lanePath" -ForegroundColor Green
    }
}

# Write-once session history: created once, whole, and preserved forever
# after - even -Force only appends a framed reset entry. A new log names its
# generation, which binds the delivery cursors to this log.
$stamp = Get-CocopilotUtcStamp
$logCreated = $false
if (-not (Test-Path -LiteralPath $sessionLogPath)) {
    $initBody = "- repo: $RepoPath`n- initial owner: $Owner`n- generation: $([Guid]::NewGuid().ToString('N'))"
    $logText = "# session log - write-once history (see cocopilot's COLLABORATION.md; never edit or delete entries)`n" +
        (New-CocopilotLogEntryText -Stamp $stamp -Role init -Body $initBody)
    New-CocopilotFileAtomic -Path $sessionLogPath -Text $logText
    $logCreated = $true
    Write-Host "Wrote $sessionLogPath" -ForegroundColor Green
} elseif ($Force) {
    $resetBody = "- session reset (-Force): implementer.json and lane files reinitialized; log preserved"
    Add-CocopilotLogText -Path $sessionLogPath -Text (New-CocopilotLogEntryText -Stamp $stamp -Role init -Body $resetBody)
    Write-Host "Preserved $sessionLogPath (appended a session-reset entry)." -ForegroundColor Yellow
} else {
    Write-Host "session.log.md already exists, leaving it as-is (history survives -Force too)." -ForegroundColor Yellow
}

# Delivery cursors. A new log resets both: it holds only its init entry.
# For an existing log, an unknown position stays unknown - a missing cursor
# makes that agent's first watch replay the whole log - and an existing
# cursor is never moved, unless -AcknowledgeHistory declares the log so far
# handled: then both move to its current end.
$logText = Read-CocopilotSharedText -Path $sessionLogPath
$generation = Get-CocopilotLogGeneration -Text $logText
$rolesWithoutCursor = [System.Collections.Generic.List[string]]::new()
foreach ($cursorRole in @("agent-a", "agent-b")) {
    $cursorPath = Join-Path $mailboxDir "$cursorRole.cursor"
    if ($logCreated -or $AcknowledgeHistory) {
        Write-CocopilotCursor -Path $cursorPath -Generation $generation -Offset $logText.Length
        Write-Host "Wrote $cursorPath (the log so far counts as handled by $cursorRole)" -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $cursorPath) {
        Write-Host "$cursorRole.cursor already exists, leaving it as-is." -ForegroundColor Yellow
    } else {
        $rolesWithoutCursor.Add($cursorRole)
    }
}
if ($rolesWithoutCursor.Count -gt 0) {
    Write-Warning ("No delivery cursor for $($rolesWithoutCursor -join ' and '): the first watch of each agent without " +
        "one replays the whole session log from its start. That is the safe default. Only when every entry so far " +
        "is handled, with no STOP or QUESTION still pending, stop both agents and re-run this command with " +
        "-AcknowledgeHistory to count the log so far as handled instead.")
}

