#Requires -Version 5.1
<#
.SYNOPSIS
    Initializes the local (git-ignored) mailbox state for a target
    repository: <RepoPath>/.mailbox/implementer.json, the per-agent lane
    scratchpads agent-a.md / agent-b.md, and session.log.md.

.DESCRIPTION
    cocopilot itself stays centrally installed (this script's own location);
    the mailbox it manages lives inside whatever repository (or, with
    -AllowNonGit, workspace root) you're pairing on. Templates are read
    from this cocopilot install's own .mailbox/*.example.* files, but the
    real, git-ignored files are written into <RepoPath>/.mailbox/, stamped
    with that repository's current git HEAD (or the fixed "non-git-root"
    sentinel, with -AllowNonGit). Safe to re-run: it will not overwrite
    existing implementer.json or lane files unless -Force is passed. The
    write-once session history (session.log.md) is created if missing and
    is PRESERVED even with -Force — a session-reset entry is appended
    instead; only cleanup-mailbox.ps1 removes it (with the whole
    .mailbox/ directory).

    Before anything is written, does a small safety check: if <RepoPath> is
    a git repository and its .gitignore doesn't already exclude .mailbox,
    this appends a rule first — so the per-machine mailbox state can't be
    accidentally committed to that project's real history even if init is
    interrupted mid-write.

    Refuses outright, before any of the above, if -RepoPath resolves to
    cocopilot's own installed repo: that repo is a tool you pair *from*,
    never a project you pair *on*, and its .mailbox/ intentionally tracks
    the two *.example.* templates this script reads from above.

.PARAMETER RepoPath
    The repository to pair on. Defaults to the current directory.

.PARAMETER Owner
    Which role starts as the active implementer. Defaults to "agent-a".

.PARAMETER OwnerModel
    Informational label for which model agent-a happens to be running.

.PARAMETER Force
    Overwrite existing .mailbox/implementer.json and the two lane files.

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
    [string]$Owner = "agent-a",
    [string]$OwnerModel = "unknown",
    [switch]$Force,
    [switch]$AllowNonGit
)

$ErrorActionPreference = "Stop"

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

$mailboxDir = Join-Path $RepoPath ".mailbox"
$implementerPath = Join-Path $mailboxDir "implementer.json"
$lanePaths = @("agent-a.md", "agent-b.md") | ForEach-Object { Join-Path $mailboxDir $_ }
$sessionLogPath = Join-Path $mailboxDir "session.log.md"
$implementerTemplate = Join-Path $cocopilotRoot ".mailbox\implementer.example.json"
$laneTemplate = Join-Path $cocopilotRoot ".mailbox\lane.example.md"

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
} elseif (-not $AllowNonGit) {
    throw ("'$RepoPath' is not a git repository. Pass -AllowNonGit to pair directly on this " +
        "workspace root (its ownership anchors then rely on dirty_manifest instead of git " +
        "HEAD/status - see COLLABORATION.md 'Ownership handoff'). If you only need read-only " +
        "cross-repo context while writing to just ONE child repo, start-agents.ps1 -ContextRoot " +
        "is the lighter-weight alternative.")
} else {
    Write-Warning "$RepoPath is not a git repository (-AllowNonGit): head will read the fixed sentinel 'non-git-root', the .gitignore safety check is skipped, and dirty_manifest becomes the authoritative handoff anchor - see COLLABORATION.md 'Ownership handoff' for what a HANDOFF_OFFER must record in this mode. Make sure .mailbox/ never gets committed here."
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

if ((Test-Path -LiteralPath $implementerPath) -and -not $Force) {
    Write-Host "implementer.json already exists, leaving it as-is (use -Force to reset)." -ForegroundColor Yellow
} else {
    $record = Get-Content -LiteralPath $implementerTemplate -Raw | ConvertFrom-Json
    $record.owner = $Owner
    $record.owner_model = $OwnerModel
    $record.head = $head
    Write-MailboxJson -Path $implementerPath -Object $record
    # Only a real git repo's head looks like a SHA worth truncating for
    # display; the non-git-root sentinel is short and self-explanatory, so
    # showing it in full avoids an odd mid-word cut ("non-git" instead of
    # "non-git-root").
    $headDisplay = if ($isGitRepo) { $head.Substring(0, [Math]::Min(7, $head.Length)) } else { $head }
    Write-Host "Wrote $implementerPath (owner=$Owner, head=$headDisplay)" -ForegroundColor Green
}

foreach ($lanePath in $lanePaths) {
    if ((Test-Path -LiteralPath $lanePath) -and -not $Force) {
        Write-Host "$(Split-Path -Leaf $lanePath) already exists, leaving it as-is (use -Force to reset)." -ForegroundColor Yellow
    } else {
        [System.IO.File]::Copy($laneTemplate, $lanePath, $true)
        Write-Host "Wrote $lanePath" -ForegroundColor Green
    }
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
    $resetEntry = "`n## $nowUtc init`n- session reset (-Force): implementer.json and lane files reinitialized; log preserved`n"
    [System.IO.File]::AppendAllText($sessionLogPath, $resetEntry, $utf8NoBom)
    Write-Host "Preserved $sessionLogPath (appended a session-reset entry)." -ForegroundColor Yellow
} else {
    Write-Host "session.log.md already exists, leaving it as-is (history survives -Force too)." -ForegroundColor Yellow
}

