#Requires -Version 7.4

<#
.SYNOPSIS
    Removes cocopilot's own coordination artifacts (its .mailbox/ files and
    ignore rule) from one target repository, or from every repository found
    underneath a root when -Recurse is passed.

.DESCRIPTION
    cocopilot never wants its own coordination state to end up committed
    into a project you're pairing on, and it never deletes anything it did
    not create. For a single target this script:

      1. Refuses, before changing anything, when the target is a cocopilot
         install (its own path, or any path to a directory whose .mailbox/
         holds cocopilot's *.example.* templates), when git tracks anything
         under .mailbox/, when .mailbox/ is a reparse point, or when the
         mailbox is not cocopilot's (its implementer.json is not an
         ownership record, or session.log.md lacks cocopilot's marker).
      2. Deletes only the files cocopilot creates there (implementer.json,
         agent-a.md, agent-b.md, session.log.md, the two delivery cursors,
         verify-request.md, implementer.lock, the baseline-<id>.json
         handoff baselines, and the writer's own ".<name>.<guid>.tmp"
         files). The directory is removed only when it is then empty;
         anything else in it is kept and reported.
      3. Removes cocopilot's managed block for this target from the
         repository's .git/info/exclude, leaving every other rule there
         (including a user's own .mailbox rule) untouched.
      4. Removes the legacy "# Per-machine cocopilot mailbox state..."
         comment + .mailbox/ line that older init-mailbox.ps1 versions
         appended to .gitignore, keeping the file's UTF-8 BOM state. If
         that file held nothing else, it is deleted.

    This does NOT touch anything else in the target repository - not the
    agents' actual work, not other ignore rules, not the git index, not git
    history. Supports -WhatIf/-Confirm since it deletes files.

    With -Recurse, -RepoPath is instead treated as a search root: this
    walks -RepoPath and every directory underneath it (including
    -RepoPath itself) looking for a .mailbox/ directory, and runs the
    exact same single-repo cleanup above against every cocopilot mailbox
    found - e.g. run against C:\Repos to clean every paired repo beneath
    it in one pass. A .mailbox/ that is not a cocopilot mailbox is skipped
    and listed in the summary, not treated as a failure. The walk never
    descends into a directory named .git or node_modules, and never
    follows a reparse point (symbolic link, junction, or mount point) - so
    a junction can't create a traversal cycle back up the tree, or walk
    the search outside the requested root. A directory that can't be
    enumerated (e.g. access denied), a .mailbox/ that can't be read, a
    linked .mailbox/ (itself a reparse point), and a cocopilot install
    are recorded as discovery issues rather than silently skipped.

    One target failing does not stop the others - every discoverable
    target is attempted, and a summary is printed at the end. If ANY
    target (cleanup or discovery) failed, the script throws a summary
    error after every attempt has completed, so a partial cleanup can
    never be mistaken for full success by a caller checking the outcome.

.PARAMETER RepoPath
    The repository to clean up, or — with -Recurse — the root to search.
    Defaults to the current directory.

.PARAMETER Recurse
    Treat -RepoPath as a search root instead of a single target: find and
    clean up every cocopilot mailbox at or below it.

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
# Expected non-zero git exits are read from $LASTEXITCODE, whatever the
# caller's profile sets here.
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot "_common.ps1")

# This very file's own parent directory - i.e. wherever THIS cocopilot
# install lives on disk, regardless of where it was cloned to. cocopilot's
# own repo is never a valid cleanup target: its .mailbox/ intentionally
# tracks the *.example.* templates init-mailbox.ps1 reads from. The
# template check (Test-CocopilotTemplatesPresent) also catches the same
# install reached through an alias path, where this string compare cannot.
$script:CocopilotOwnRoot = (Split-Path -Parent $PSScriptRoot).TrimEnd('\', '/')

function Test-IsCocopilotOwnRoot {
    param([Parameter(Mandatory)][string]$Path)
    return ([System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')) -ieq $script:CocopilotOwnRoot
}

function Invoke-SingleMailboxCleanup {
    <#
    .SYNOPSIS
        Removes cocopilot's mailbox files and ignore rules from exactly one
        already-resolved repository path - the single-target body of
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

    # Every refusal runs before the first change.
    if (Test-IsCocopilotOwnRoot -Path $RepoPath) {
        throw ("'$RepoPath' is cocopilot's own installed repo, not a project you were pairing on. " +
            "Its .mailbox/ intentionally tracks the *.example.* templates that init-mailbox.ps1 reads from " +
            "(see README.md/COLLABORATION.md) - cleaning up here would delete them. cd into the project " +
            "repo you actually paired on and re-run cocopilot-cleanup there instead.")
    }
    if (Test-CocopilotTemplatesPresent -RepoPath $RepoPath) {
        throw ("'$RepoPath' holds cocopilot's *.example.* templates under .mailbox/ - it is a cocopilot install " +
            "(possibly reached through an alias path), never a cleanup target.")
    }

    $mailboxDir = Join-Path $RepoPath ".mailbox"
    $gitignorePath = Join-Path $RepoPath ".gitignore"
    $anyChangeMade = $false

    $isGitRepo = $false
    try {
        $null = git -C $RepoPath rev-parse --is-inside-work-tree 2>$null
        $isGitRepo = ($LASTEXITCODE -eq 0)
    } catch { $isGitRepo = $false }

    if ($isGitRepo) {
        $tracked = @(Get-CocopilotTrackedMailboxPaths -RepoPath $RepoPath)
        if ($tracked.Count -gt 0) {
            throw ("git tracks files under .mailbox/ in '$RepoPath' ($($tracked -join ', ')) - refusing to touch " +
                "them. If they are cocopilot state committed by mistake, untrack them yourself " +
                "(git rm -r --cached -- .mailbox), commit, then re-run cleanup.")
        }
    }

    $mailboxExists = Test-Path -LiteralPath $mailboxDir
    if ($mailboxExists) {
        # cocopilot never creates .mailbox/ as a link, so a linked .mailbox
        # means this repo is suspect.
        if (([System.IO.File]::GetAttributes($mailboxDir)).HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            throw "$mailboxDir is a reparse point (symlink/junction/mount point) - refusing to delete it. cocopilot never creates .mailbox/ this way; resolve this repository manually before retrying."
        }
        $state = Get-CocopilotMailboxState -Path $mailboxDir
        if ($state.State -ne "Cocopilot") {
            throw "$mailboxDir is not a cocopilot mailbox ($($state.State): $($state.Reason)) - nothing was changed."
        }
    }

    # 1. Delete only the files cocopilot creates; keep the directory unless
    # it is then empty.
    if ($mailboxExists) {
        $ours = @(Get-ChildItem -LiteralPath $mailboxDir -Force -File | Where-Object {
                Test-CocopilotMailboxEntryName -Name $_.Name
            })
        if ($PSCmdlet.ShouldProcess($mailboxDir, "Remove cocopilot mailbox files ($($ours.Name -join ', '))")) {
            foreach ($file in $ours) { Remove-Item -LiteralPath $file.FullName -Force }
            $anyChangeMade = $true
            $leftovers = @(Get-ChildItem -LiteralPath $mailboxDir -Force)
            if ($leftovers.Count -eq 0) {
                Remove-Item -LiteralPath $mailboxDir -Force
                Write-Host "Removed $mailboxDir" -ForegroundColor Green
            } else {
                Write-Warning "Removed cocopilot's files but kept $mailboxDir - it still holds entries cocopilot did not create: $($leftovers.Name -join ', ')"
            }
        }
    } else {
        Write-Host "No .mailbox/ directory found at $RepoPath - nothing to remove." -ForegroundColor Cyan
    }

    # 2. cocopilot's managed block in the git-local exclude file.
    if ($isGitRepo -and (Remove-CocopilotMailboxExcludeRule -RepoPath $RepoPath)) {
        Write-Host "Removed cocopilot's .mailbox/ rule from the repository's git exclude file." -ForegroundColor Green
        $anyChangeMade = $true
    }

    # 3. The legacy block older init-mailbox.ps1 versions appended to the
    # tracked .gitignore - removed exactly, everything else (including a
    # bare .mailbox/ rule without cocopilot's comment) and the file's BOM
    # state preserved.
    if (Test-Path -LiteralPath $gitignorePath) {
        $gitignore = Read-CocopilotTextFile -Path $gitignorePath
        # [ \t\r]* (not \s*) around the .mailbox/ line: \s also matches \n, so a
        # greedy \s* there would silently swallow blank lines *beyond* the block
        # (e.g. a user-added blank line separating their own rules that follow).
        # \r is kept (unlike \n) since Add-Content terminated its own appended
        # text with the OS default newline (\r\n on Windows) even when the rest
        # of the file uses bare \n, so a lone trailing \r before the line's own
        # \n is still part of *this* line, not a signal to keep scanning.
        $pattern = '(?m)(\r?\n)?^#[ \t]*Per-machine cocopilot mailbox state.*$\r?\n^[ \t]*/?\.mailbox/?[ \t\r]*$\r?\n?'
        $newRaw = [regex]::Replace($gitignore.Text, $pattern, '')

        if ($newRaw -eq $gitignore.Text) {
            Write-Host "No legacy cocopilot .mailbox/ rule found in $gitignorePath - nothing to change." -ForegroundColor Cyan
        } elseif ($newRaw.Trim().Length -eq 0) {
            if ($PSCmdlet.ShouldProcess($gitignorePath, "Remove file (only contained cocopilot's legacy rule)")) {
                Remove-Item -LiteralPath $gitignorePath -Force
                Write-Host "Removed $gitignorePath (it only contained the rule an older cocopilot added)." -ForegroundColor Green
                $anyChangeMade = $true
            }
        } else {
            if ($PSCmdlet.ShouldProcess($gitignorePath, "Remove cocopilot's legacy .mailbox/ rule, keep the rest")) {
                Write-CocopilotTextFile -Path $gitignorePath -Text $newRaw -HasBom $gitignore.HasBom
                Write-Host "Removed cocopilot's legacy .mailbox/ rule from $gitignorePath (rest of the file preserved)." -ForegroundColor Green
                $anyChangeMade = $true
            }
        }
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
        Recursively discovers every cocopilot mailbox under $RootPath
        (including $RootPath itself), for -Recurse.

    .DESCRIPTION
        Explicit-stack depth-first walk (not PowerShell call recursion), so
        depth is bounded by available memory, not call-stack size. Never
        descends into a directory named .git or node_modules, and never
        follows a reparse point (symbolic link, junction, or mount point) -
        so a junction can't create a traversal cycle back up the tree, or
        walk the search outside the requested root. Each .mailbox/ found is
        classified: a cocopilot mailbox becomes a target; a readable one
        that is not cocopilot's is skipped (reported, never touched); an
        unreadable one, a linked one, and a cocopilot install are discovery
        failures. A directory that can't be enumerated, or whose attributes
        can't be read, is a discovery failure as well.
        Children at each level are visited in descending-sorted push order,
        so they pop (and are processed) in ascending order - a
        deterministic left-to-right preorder walk.
    #>
    param(
        [Parameter(Mandatory)][string]$RootPath
    )

    $excludedNames = @(".git", "node_modules")
    $targets = [System.Collections.Generic.List[string]]::new()
    $failures = [System.Collections.Generic.List[pscustomobject]]::new()
    $skipped = [System.Collections.Generic.List[pscustomobject]]::new()

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($RootPath)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        $mailboxCandidate = Join-Path $current ".mailbox"
        if (Test-Path -LiteralPath $mailboxCandidate -PathType Container) {
            # A cocopilot install (by path, or by its templates when reached
            # through an alias) is never a valid cleanup target - reported
            # as a discovery issue rather than failing loudly mid-Recurse.
            if (Test-IsCocopilotOwnRoot -Path $current) {
                $failures.Add([pscustomobject]@{
                    Path  = $mailboxCandidate
                    Error = "This is cocopilot's own installed repo - its .mailbox/ intentionally tracks the *.example.* templates and must never be treated as a cleanup target."
                })
            } elseif (Test-CocopilotTemplatesPresent -RepoPath $current) {
                $failures.Add([pscustomobject]@{
                    Path  = $mailboxCandidate
                    Error = "This .mailbox/ holds cocopilot's *.example.* templates - a cocopilot install (possibly reached through an alias path), never a cleanup target."
                })
            } else {
                # A .mailbox that is itself a reparse point (symlink/junction/
                # mount point) is never a valid cleanup target - cocopilot
                # never creates it that way. Reject and report it as a
                # discovery issue instead of a target.
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
                    $state = Get-CocopilotMailboxState -Path $mailboxCandidate
                    switch ($state.State) {
                        "Cocopilot" { $targets.Add($current) }
                        "Foreign" { $skipped.Add([pscustomobject]@{ Path = $mailboxCandidate; Reason = $state.Reason }) }
                        default {
                            $failures.Add([pscustomobject]@{ Path = $mailboxCandidate; Error = "unreadable mailbox: $($state.Reason)" })
                        }
                    }
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

    return [pscustomobject]@{ Targets = $targets; Failures = $failures; Skipped = $skipped }
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
$skippedMailboxes = @($discovery.Skipped)
$succeeded = @($attempts | Where-Object { $null -eq $_.Error })
$actuallyChanged = @($succeeded | Where-Object { $_.Changed })
$noOpSucceeded = @($succeeded | Where-Object { -not $_.Changed })

Write-Host "`n=== cocopilot-cleanup -Recurse summary ===" -ForegroundColor Cyan
Write-Host "Mailboxes found:            $($discovery.Targets.Count)"
Write-Host "Cleaned successfully:       $($actuallyChanged.Count)"
Write-Host "No changes made (preview or declined confirmation): $($noOpSucceeded.Count)"
Write-Host "Skipped (not a cocopilot mailbox): $($skippedMailboxes.Count)"
Write-Host "Cleanup failures:           $($cleanupFailures.Count)"
Write-Host "Discovery issues (unscannable directories, unreadable or linked .mailbox candidates, cocopilot installs): $($discoveryFailures.Count)"

if ($skippedMailboxes.Count -gt 0) {
    Write-Host "`nSkipped, left untouched:" -ForegroundColor Yellow
    $skippedMailboxes | ForEach-Object { Write-Host "  - $($_.Path): $($_.Reason)" -ForegroundColor Yellow }
}
if ($cleanupFailures.Count -gt 0) {
    Write-Host "`nCleanup failures:" -ForegroundColor Red
    $cleanupFailures | ForEach-Object { Write-Host "  - $($_.Path): $($_.Error)" -ForegroundColor Red }
}
if ($discoveryFailures.Count -gt 0) {
    Write-Host "`nDiscovery issues:" -ForegroundColor Red
    $discoveryFailures | ForEach-Object { Write-Host "  - $($_.Path): $($_.Error)" -ForegroundColor Red }
}
if ($discovery.Targets.Count -eq 0 -and $discoveryFailures.Count -eq 0 -and $skippedMailboxes.Count -eq 0) {
    Write-Host "No cocopilot mailboxes found under $RepoPath." -ForegroundColor Cyan
}

$totalFailures = $cleanupFailures.Count + $discoveryFailures.Count
if ($totalFailures -gt 0) {
    throw ("cocopilot-cleanup -Recurse: $($cleanupFailures.Count) cleanup failure(s) and " +
        "$($discoveryFailures.Count) discovery issue$(if ($discoveryFailures.Count -eq 1) { '' } else { 's' })" +
        " - see summary above.")
}
