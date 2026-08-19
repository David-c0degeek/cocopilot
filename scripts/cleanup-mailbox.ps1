#Requires -Version 5.1
<#
.SYNOPSIS
    Removes cocopilot's own coordination artifacts (.mailbox/ + its
    .gitignore rule) from one target repository, or from every repository
    found underneath a root when -Recurse is passed.

.DESCRIPTION
    cocopilot never wants its own coordination state to end up committed
    into a project you're pairing on. For a single target this script:

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

    -RepoPath resolving to cocopilot's own installed repo is refused
    outright (single-target: throws; -Recurse: excluded from discovery and
    reported as a discovery issue) — that repo is a tool you pair *from*,
    never a project you pair *on*, and its .mailbox/ intentionally tracks
    the two *.example.* templates init-mailbox.ps1 reads from. Treating
    those tracked files as the "should never happen" case in step 1 would
    otherwise untrack and delete them.

    This does NOT touch anything else in the target repository — not the
    agents' actual work, not unrelated .gitignore rules, not git history.
    Supports -WhatIf/-Confirm since it deletes files; nothing here commits
    anything on your behalf — un-tracking via git rm --cached only stages
    the removal, you still commit it yourself.

    With -Recurse, -RepoPath is instead treated as a search root: this
    walks -RepoPath and every directory underneath it (including
    -RepoPath itself) looking for a .mailbox/ directory, and runs the
    exact same single-repo cleanup above against every repository found —
    e.g. run against C:\Repos to clean every paired repo directly beneath
    it in one pass. The walk never descends into a directory named .git
    or node_modules, and never follows a reparse point (symbolic link,
    junction, or mount point) — so a junction can't create a traversal
    cycle back up the tree, or walk the search outside the requested
    root. A directory that can't be enumerated (e.g. access denied) is
    recorded as a discovery failure rather than silently skipped. A
    .mailbox/ that is itself a reparse point is never treated as a valid
    cleanup target either — cocopilot never creates it that way — and is
    rejected and reported the same way, in both -Recurse discovery and
    the single-target path.

    One target failing does not stop the others — every discoverable
    target is attempted, and a summary is printed at the end. If ANY
    target (cleanup or discovery) failed, the script throws a summary
    error after every attempt has completed, so a partial cleanup can
    never be mistaken for full success by a caller checking the outcome.

.PARAMETER RepoPath
    The repository to clean up, or — with -Recurse — the root to search.
    Defaults to the current directory.

.PARAMETER Recurse
    Treat -RepoPath as a search root instead of a single target: find and
    clean up every repository with a .mailbox/ directory at or below it.

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\some-other-project

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\some-other-project -WhatIf

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos -Recurse

    Cleans C:\Repos itself (if paired) plus every paired repo found
    anywhere underneath it.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoPath = (Get-Location).Path,
    [switch]$Recurse
)

$ErrorActionPreference = "Stop"

# This very file's own parent directory - i.e. wherever THIS cocopilot
# install lives on disk, regardless of where it was cloned to. cocopilot's
# own repo is never a valid cleanup target: its .mailbox/ intentionally
# tracks the *.example.* templates init-mailbox.ps1 reads from, so "found
# tracked files under .mailbox/" there is expected, not a bug to fix.
# Checked below both for a direct single-target call and during -Recurse
# discovery, the same way a reparse-point .mailbox is guarded in both places.
$script:CocopilotOwnRoot = (Split-Path -Parent $PSScriptRoot).TrimEnd('\', '/')

function Test-IsCocopilotOwnRoot {
    param([Parameter(Mandatory)][string]$Path)
    return ([System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')) -ieq $script:CocopilotOwnRoot
}

function Invoke-SingleMailboxCleanup {
    <#
    .SYNOPSIS
        Removes .mailbox/ and its .gitignore rule from exactly one
        already-resolved repository path — the single-target body of
        cleanup-mailbox.ps1, factored out so -Recurse can call it once
        per discovered repository.

    .OUTPUTS
        [bool] $true if a mutating action actually ran (i.e. not skipped
        by -WhatIf or a declined -Confirm prompt), $false otherwise - so a
        caller can tell an actual cleanup apart from a no-op preview. The
        target repo's git status is written via Write-Host, not the
        success stream, so it never pollutes this return value.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )

    if (Test-IsCocopilotOwnRoot -Path $RepoPath) {
        throw ("'$RepoPath' is cocopilot's own installed repo, not a project you were pairing on. " +
            "Its .mailbox/ intentionally tracks the *.example.* templates that init-mailbox.ps1 reads from " +
            "(see README.md/COLLABORATION.md) - cleaning up here would delete them. cd into the project " +
            "repo you actually paired on and re-run cocopilot-cleanup there instead.")
    }

    $mailboxDir = Join-Path $RepoPath ".mailbox"
    $gitignorePath = Join-Path $RepoPath ".gitignore"
    $anyChangeMade = $false

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
                $anyChangeMade = $true
            }
        }
    }

    # 2. Delete .mailbox/ from disk. Refuse outright if .mailbox itself is a
    # reparse point (symlink/junction/mount point): cocopilot never creates
    # it that way, so a linked .mailbox means this repo is suspect, and
    # -Recurse -Force must never be pointed at a link to an arbitrary,
    # externally-controlled target.
    if (Test-Path -LiteralPath $mailboxDir) {
        if (([System.IO.File]::GetAttributes($mailboxDir)).HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            throw "$mailboxDir is a reparse point (symlink/junction/mount point) - refusing to delete it. cocopilot never creates .mailbox/ this way; resolve this repository manually before retrying."
        }
        if ($PSCmdlet.ShouldProcess($mailboxDir, "Remove directory")) {
            Remove-Item -LiteralPath $mailboxDir -Recurse -Force
            Write-Host "Removed $mailboxDir" -ForegroundColor Green
            $anyChangeMade = $true
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
                $anyChangeMade = $true
            }
        } else {
            if ($PSCmdlet.ShouldProcess($gitignorePath, "Remove cocopilot's .mailbox/ rule, keep the rest")) {
                Set-Content -LiteralPath $gitignorePath -Value $newRaw -NoNewline -Encoding utf8
                Write-Host "Removed cocopilot's .mailbox/ rule from $gitignorePath (rest of the file preserved)." -ForegroundColor Green
                $anyChangeMade = $true
            }
        }
    } else {
        Write-Host "No .gitignore found at $RepoPath - nothing to change." -ForegroundColor Cyan
    }

    # 4. Final safety check: show the target repo's git status so you can see
    # at a glance that nothing cocopilot-related remains tracked or staged.
    # Piped through Write-Host (not left as pipeline/success-stream output)
    # so these lines are always just console text, never part of this
    # function's actual return value below.
    if ($isGitRepo) {
        Write-Host "`n--- git status for $RepoPath ---" -ForegroundColor Cyan
        git -C $RepoPath status --short | ForEach-Object { Write-Host $_ }
    }

    return $anyChangeMade
}

function Find-MailboxTarget {
    <#
    .SYNOPSIS
        Recursively discovers every directory with a .mailbox/ child under
        $RootPath (including $RootPath itself), for -Recurse.

    .DESCRIPTION
        Explicit-stack depth-first walk (not PowerShell call recursion), so
        depth is bounded by available memory, not call-stack size. Never
        descends into a directory named .git or node_modules, and never
        follows a reparse point (symbolic link, junction, or mount point) —
        so a junction can't create a traversal cycle back up the tree, or
        walk the search outside the requested root. A directory that can't
        be enumerated, or whose attributes can't be read, is recorded as a
        discovery failure rather than silently skipped. Children at each
        level are visited in descending-sorted push order, so they pop (and
        are processed) in ascending order — a deterministic left-to-right
        preorder walk.
    #>
    param(
        [Parameter(Mandatory)][string]$RootPath
    )

    $excludedNames = @(".git", "node_modules")
    $targets = [System.Collections.Generic.List[string]]::new()
    $failures = [System.Collections.Generic.List[pscustomobject]]::new()

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($RootPath)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        $mailboxCandidate = Join-Path $current ".mailbox"
        if (Test-Path -LiteralPath $mailboxCandidate -PathType Container) {
            # cocopilot's own installed repo is never a valid cleanup target
            # (see Test-IsCocopilotOwnRoot) - reject and report it as a
            # discovery issue instead of a target, the same as a reparse-point
            # .mailbox below, rather than letting it fail loudly mid-Recurse.
            if (Test-IsCocopilotOwnRoot -Path $current) {
                $failures.Add([pscustomobject]@{
                    Path  = $mailboxCandidate
                    Error = "This is cocopilot's own installed repo - its .mailbox/ intentionally tracks the *.example.* templates and must never be treated as a cleanup target."
                })
            } else {
                # A .mailbox that is itself a reparse point (symlink/junction/
                # mount point) is never a valid cleanup target - cocopilot
                # never creates it that way, and Invoke-SingleMailboxCleanup
                # would otherwise be asked to -Recurse -Force delete through a
                # link to an arbitrary, externally-controlled target. Reject
                # and report it as a discovery issue instead of a target.
                $mailboxAttrs = $null
                try {
                    $mailboxAttrs = [System.IO.File]::GetAttributes($mailboxCandidate)
                } catch {
                    $failures.Add([pscustomobject]@{ Path = $mailboxCandidate; Error = $_.Exception.Message })
                }

                if ($null -ne $mailboxAttrs -and $mailboxAttrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                    $failures.Add([pscustomobject]@{
                        Path  = $mailboxCandidate
                        Error = "'.mailbox' is a reparse point (symlink/junction/mount point) - refusing to treat it as a cleanup target."
                    })
                } elseif ($null -ne $mailboxAttrs) {
                    $targets.Add($current)
                }
            }
        }

        try {
            $children = [System.IO.Directory]::GetDirectories($current)
        } catch {
            $failures.Add([pscustomobject]@{ Path = $current; Error = $_.Exception.Message })
            continue
        }

        foreach ($child in ($children | Sort-Object -Descending)) {
            if ($excludedNames -contains (Split-Path -Leaf $child)) { continue }

            try {
                $attrs = [System.IO.File]::GetAttributes($child)
            } catch {
                $failures.Add([pscustomobject]@{ Path = $child; Error = $_.Exception.Message })
                continue
            }

            # Never follow a reparse point (symlink/junction/mount point):
            # its target is arbitrary and could cycle back up the tree or
            # point outside $RootPath entirely.
            if ($attrs.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                continue
            }

            $stack.Push($child)
        }
    }

    return [pscustomobject]@{ Targets = $targets; Failures = $failures }
}

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

if (-not $Recurse) {
    Invoke-SingleMailboxCleanup -RepoPath $RepoPath | Out-Null
    return
}

Write-Host "Searching $RepoPath for cocopilot mailboxes..." -ForegroundColor Cyan
$discovery = Find-MailboxTarget -RootPath $RepoPath

$attempts = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($target in $discovery.Targets) {
    Write-Host "`n=== $target ===" -ForegroundColor Magenta
    try {
        $changed = Invoke-SingleMailboxCleanup -RepoPath $target
        $attempts.Add([pscustomobject]@{ Path = $target; Error = $null; Changed = [bool]$changed })
    } catch {
        Write-Warning "Failed to clean up $target : $($_.Exception.Message)"
        $attempts.Add([pscustomobject]@{ Path = $target; Error = $_.Exception.Message; Changed = $false })
    }
}

$cleanupFailures = @($attempts | Where-Object { $null -ne $_.Error })
$discoveryFailures = @($discovery.Failures)
$succeeded = @($attempts | Where-Object { $null -eq $_.Error })
$actuallyChanged = @($succeeded | Where-Object { $_.Changed })
$noOpSucceeded = @($succeeded | Where-Object { -not $_.Changed })

Write-Host "`n=== cocopilot-cleanup -Recurse summary ===" -ForegroundColor Cyan
Write-Host "Mailboxes found:            $($discovery.Targets.Count)"
Write-Host "Cleaned successfully:       $($actuallyChanged.Count)"
Write-Host "No changes made (preview or declined confirmation): $($noOpSucceeded.Count)"
Write-Host "Cleanup failures:           $($cleanupFailures.Count)"
Write-Host "Discovery issues (unscannable directories + rejected reparse-point .mailbox candidates): $($discoveryFailures.Count)"

if ($cleanupFailures.Count -gt 0) {
    Write-Host "`nCleanup failures:" -ForegroundColor Red
    $cleanupFailures | ForEach-Object { Write-Host "  - $($_.Path): $($_.Error)" -ForegroundColor Red }
}
if ($discoveryFailures.Count -gt 0) {
    Write-Host "`nDiscovery issues:" -ForegroundColor Red
    $discoveryFailures | ForEach-Object { Write-Host "  - $($_.Path): $($_.Error)" -ForegroundColor Red }
}
if ($discovery.Targets.Count -eq 0 -and $discoveryFailures.Count -eq 0) {
    Write-Host "No cocopilot mailboxes found under $RepoPath." -ForegroundColor Cyan
}

$totalFailures = $cleanupFailures.Count + $discoveryFailures.Count
if ($totalFailures -gt 0) {
    throw ("cocopilot-cleanup -Recurse: $($cleanupFailures.Count) cleanup failure(s) and " +
        "$($discoveryFailures.Count) discovery issue$(if ($discoveryFailures.Count -eq 1) { '' } else { 's' })" +
        " - see summary above.")
}
