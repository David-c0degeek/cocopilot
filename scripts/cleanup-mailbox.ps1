#Requires -Version 7.4

<#
.SYNOPSIS
    Removes cocopilot's own coordination artifacts (the target's mailbox
    outside it, and a legacy in-repo .mailbox/ with its ignore rule) for one
    target repository, or for every repository with a legacy .mailbox/ found
    underneath a root when -Recurse is passed.

.DESCRIPTION
    cocopilot never wants its own coordination state to end up committed
    into a project you're pairing on, and it never deletes anything it did
    not create. For a single target this script:

      1. Refuses, before changing anything, when the target is the cocopilot
         install running this script (its own path, or an alias such as a
         junction, symlink or subst drive to it); when the pairs folder or
         the target's pair directory is a reparse point, the pair directory
         is not a direct child of <state root>\pairs, or a non-empty pair
         directory lacks a readable target.json naming this target or holds
         an implementer.json or session.log.md that is not cocopilot's;
         when .mailbox/ is a reparse
         point or cannot be classified; or when git tracks anything under a
         legacy cocopilot .mailbox/. A .mailbox/ that is not cocopilot's
         (its implementer.json is not an ownership record, or
         session.log.md lacks cocopilot's marker) is the project's own: it
         is left untouched, and so is the exclude rule that hides it.
      2. Deletes only the files cocopilot creates in the pair directory and
         in a legacy cocopilot .mailbox/ (target.json, implementer.json,
         agent-a.md, agent-b.md, session.log.md, the two delivery cursors,
         verify-request.md, implementer.lock, the direct-transport
         registration sessions.json and its sessions.lock, the baseline-<id>.json
         handoff baselines, and the writer's own ".<name>.<guid>.tmp"
         files). Each directory is removed only when it is then empty;
         anything else in it is kept and reported.
      3. Removes cocopilot's managed block for this target from the
         repository's .git/info/exclude, leaving every other rule there
         (including a user's own .mailbox rule) untouched.
      4. Removes the legacy "# Per-machine cocopilot mailbox state..."
         comment + .mailbox/ line that older init-mailbox.ps1 versions
         appended to .gitignore, keeping the file's UTF-8 BOM state. If
         that file held nothing else, it is deleted.

    It never deletes the state root, its pairs folder or a target folder.
    This does NOT touch anything else in the target repository - not the
    agents' actual work, not other ignore rules, not the git index, not git
    history. Supports -WhatIf/-Confirm since it deletes files.

    With -Recurse, -RepoPath is instead treated as a search root, which
    need not exist any more. Every pair directory whose target.json
    records a target at or below the root (compared on whole path
    segments, so C:\ab is not below C:\a) is cleaned with the rules of
    step 1 and 2. A pair directory whose target cannot be read (a link, or
    a missing or broken target.json) cannot be placed in or out of the root:
    it is reported as a discovery issue and never deleted. An unfinished
    -MigrateLegacy staging is listed as retained. When the root exists, this also walks it and every
    directory underneath it (including -RepoPath itself) looking for a
    legacy .mailbox/ directory, and runs the exact same single-repo
    cleanup above against every cocopilot mailbox found - e.g. run
    against C:\Repos to clean every paired repo beneath it in one pass. A .mailbox/ that is not a cocopilot mailbox is skipped
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

.PARAMETER List
    Read-only: one row per child of <state root>\pairs with PairId,
    Target (from target.json), TargetExists, LastLogWriteUtc, SizeBytes,
    Status (OK, MALFORMED, INACCESSIBLE, or STAGING for an unfinished
    -MigrateLegacy copy) and Reason (why a row is not OK). Changes nothing.

.PARAMETER PairId
    Cleans one pair directory by its id, as -List shows it, without
    resolving its target - for a target that was moved or deleted. The
    rules of step 1 and 2 apply; the recorded target is displayed, never
    used as a path.

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\some-other-project

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\some-other-project -WhatIf

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -List

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -PairId old-project-0123456789abcdef

.EXAMPLE
    .\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos -Recurse

    Cleans C:\Repos itself (if paired) plus every paired repo found
    anywhere underneath it, including pairs whose folder is gone.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoPath = (Get-Location).Path,
    [switch]$Recurse,
    [switch]$List,
    [string]$PairId
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

# This very file's own parent directory - i.e. wherever THIS cocopilot
# install lives on disk. It is never a cleanup target (init-mailbox.ps1
# never pairs on it); Test-IsCocopilotInstall also catches the install
# reached through an alias path.
$script:CocopilotOwnRoot = Split-Path -Parent $PSScriptRoot

function Test-IsCocopilotOwnRoot {
    param([Parameter(Mandatory)][string]$Path)
    return Test-IsCocopilotInstall -Path $Path -CocopilotRoot $script:CocopilotOwnRoot
}

function Assert-PairDirectoryDeletable {
    <#
    .SYNOPSIS
        Throws, before anything changes, unless $PairDir is a direct,
        non-reparse child of the non-reparse <state root>\pairs whose files
        are provably a cocopilot mailbox: a readable target.json (naming
        $ExpectedTarget, when given) and cocopilot content in
        implementer.json and session.log.md when present. An empty directory
        holds nothing to protect and passes. Returns the recorded target, or
        $null for an empty directory. The state root itself is canonical: a
        state root reached through a link was already followed to its one
        real location.
    #>
    param(
        [Parameter(Mandatory)][string]$PairDir,
        [string]$ExpectedTarget
    )

    $pairsDir = [System.IO.Path]::Join((Get-CocopilotStateRoot), "pairs")
    foreach ($component in @($pairsDir, $PairDir)) {
        if (Test-CocopilotReparsePoint -Path $component) {
            throw "'$component' is a reparse point (symbolic link, junction or mount point) - refusing to delete through it. Nothing was changed."
        }
    }
    if ([System.IO.Path]::GetDirectoryName($PairDir) -ine $pairsDir) {
        throw "'$PairDir' is not a direct child of '$pairsDir' - refusing to delete it. Nothing was changed."
    }
    if (@(Get-ChildItem -LiteralPath $PairDir -Force).Count -eq 0) { return $null }
    try {
        $recorded = Read-CocopilotPairTarget -MailboxDir $PairDir
    } catch {
        throw "'$PairDir' has an unreadable target.json ($($_.Exception.Message)) - refusing to delete it. Nothing was changed."
    }
    if ($null -eq $recorded) {
        throw "'$PairDir' has no target.json, so it cannot be proven to be a cocopilot mailbox - refusing to delete it. Nothing was changed."
    }
    if ($ExpectedTarget -and $recorded -ine $ExpectedTarget) {
        throw "'$PairDir' belongs to '$recorded', not to '$ExpectedTarget' - refusing to delete it. Nothing was changed."
    }
    foreach ($anchor in @("implementer.json", "session.log.md")) {
        $anchorPath = Join-Path $PairDir $anchor
        if (-not (Test-Path -LiteralPath $anchorPath)) { continue }
        if (-not (Test-Path -LiteralPath $anchorPath -PathType Leaf)) {
            throw "'$anchorPath' is not a file - refusing to delete '$PairDir'. Nothing was changed."
        }
        $check = Get-CocopilotMailboxFileCheck -Path $anchorPath
        if ($check.State -ne "Cocopilot") {
            throw "'$anchorPath' is not cocopilot's ($($check.State): $($check.Reason)) - refusing to delete '$PairDir'. Nothing was changed."
        }
    }
    return $recorded
}

function Get-ExternalMailboxCleanupTarget {
    <#
    .SYNOPSIS
        The pair directory of $RepoPath when it exists and is safe to clean
        (see Assert-PairDirectoryDeletable), $null when there is none.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    $pairDir = Get-CocopilotMailboxDir -RepoPath $RepoPath
    $pairsDir = Split-Path -Parent $pairDir
    foreach ($component in @($pairsDir, $pairDir)) {
        if (Test-CocopilotReparsePoint -Path $component) {
            throw "'$component' is a reparse point (symbolic link, junction or mount point) - refusing to delete through it. Nothing was changed."
        }
    }
    if (-not (Test-Path -LiteralPath $pairDir -PathType Container)) { return $null }
    $null = Assert-PairDirectoryDeletable -PairDir $pairDir -ExpectedTarget (Get-CocopilotCanonicalPath -Path $RepoPath)
    return $pairDir
}

function Get-PairDirectoryRow {
    <#
    .SYNOPSIS
        One -List row for a child of <state root>\pairs. Never throws: a
        child that cannot be read is reported, not fatal.
    #>
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)

    $row = [ordered]@{ PairId = $Item.Name; Target = $null; TargetExists = $null; LastLogWriteUtc = $null; SizeBytes = $null; Status = "OK"; Reason = $null }
    try {
        # A link is never followed, also when it is named like a staging.
        if ($Item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or $Item -isnot [System.IO.DirectoryInfo]) {
            $row.Status = "MALFORMED"
            $row.Reason = "it is a link (symbolic link, junction or mount point), never followed"
        } elseif ($Item.Name.StartsWith(".") -and $Item.Name -cmatch '\.migrating-[0-9a-f]{32}$') {
            $row.Status = "STAGING"
        }
        if ($row.Status -ne "MALFORMED") {
            $files = @(Get-ChildItem -LiteralPath $Item.FullName -Force -File)
            $row.SizeBytes = [long]($files | Measure-Object -Property Length -Sum).Sum
            $log = $files | Where-Object Name -eq "session.log.md"
            if ($log) { $row.LastLogWriteUtc = $log.LastWriteTimeUtc }
        }
        if ($row.Status -eq "OK") {
            try {
                $row.Target = Read-CocopilotPairTarget -MailboxDir $Item.FullName
                if ($null -eq $row.Target) { $row.Reason = "it has no target.json" }
            } catch {
                $row.Target = $null
                $row.Reason = $_.Exception.Message
            }
            if ($null -eq $row.Target) {
                $row.Status = "MALFORMED"
            } else {
                $row.TargetExists = Test-Path -LiteralPath $row.Target -PathType Container
            }
        }
    } catch {
        $row.Status = "INACCESSIBLE"
        $row.Reason = $_.Exception.Message
    }
    return [pscustomobject]$row
}

function Get-PairDirectoryRows {
    # Every child of <state root>\pairs as a -List row; none when there is no pairs folder yet.
    $pairsDir = [System.IO.Path]::Join((Get-CocopilotStateRoot), "pairs")
    if (Test-CocopilotReparsePoint -Path $pairsDir) {
        throw "'$pairsDir' is a reparse point (symbolic link, junction or mount point); cocopilot never follows its pairs folder through a link. Nothing was read or changed."
    }
    if (-not (Test-Path -LiteralPath $pairsDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $pairsDir -Force -Directory | Sort-Object Name | ForEach-Object { Get-PairDirectoryRow -Item $_ })
}

function Test-RecordedTargetWithin {
    # Whether a recorded target lies at or below $Root; a recorded target
    # whose drive no longer exists is compared by its full path instead.
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$Root)

    try {
        return Test-CocopilotPathWithin -Path $Target -Root $Root
    } catch {
        $fullTarget = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
        $fullRoot = $Root.TrimEnd('\')
        return ($fullTarget -ieq $fullRoot) -or $fullTarget.StartsWith("$fullRoot\", [System.StringComparison]::OrdinalIgnoreCase)
    }
}
function Remove-CocopilotMailboxFiles {
    <#
    .SYNOPSIS
        Deletes only the files cocopilot creates in one mailbox directory,
        and the directory itself when it is then empty; anything else is
        kept and reported. Returns $true when the removal ran (not skipped
        by -WhatIf or a declined -Confirm).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$MailboxDir)

    $ours = @(Get-ChildItem -LiteralPath $MailboxDir -Force -File | Where-Object {
            Test-CocopilotMailboxEntryName -Name $_.Name
        })
    if (-not $PSCmdlet.ShouldProcess($MailboxDir, "Remove cocopilot mailbox files ($($ours.Name -join ', '))")) { return $false }

    foreach ($file in $ours) { Remove-Item -LiteralPath $file.FullName -Force }
    $leftovers = @(Get-ChildItem -LiteralPath $MailboxDir -Force)
    if ($leftovers.Count -eq 0) {
        Remove-Item -LiteralPath $MailboxDir -Force
        Write-Host "Removed $MailboxDir" -ForegroundColor Green
    } else {
        Write-Warning "Removed cocopilot's files but kept $MailboxDir - it still holds entries cocopilot did not create: $($leftovers.Name -join ', ')"
    }
    return $true
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
        throw ("'$RepoPath' is cocopilot's own installed repo (by path or alias), not a project you were pairing on. " +
            "cd into the project repo (or cocopilot worktree/clone) you actually paired on and re-run " +
            "cocopilot-cleanup there instead.")
    }

    $mailboxDir = Join-Path $RepoPath ".mailbox"
    $gitignorePath = Join-Path $RepoPath ".gitignore"
    $anyChangeMade = $false

    $isGitRepo = Test-CocopilotGitRepository -Path $RepoPath
    $pair = Get-ExternalMailboxCleanupTarget -RepoPath $RepoPath

    # A legacy in-repo mailbox. A .mailbox/ that is not cocopilot's is the
    # project's own folder now that mailboxes live outside the target: it is
    # left alone, with its ignore rules.
    $mailboxExists = Test-Path -LiteralPath $mailboxDir
    $legacyIsOurs = $false
    if ($mailboxExists) {
        # cocopilot never creates .mailbox/ as a link, so a linked .mailbox
        # means this repo is suspect.
        if (([System.IO.File]::GetAttributes($mailboxDir)).HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            throw "$mailboxDir is a reparse point (symlink/junction/mount point) - refusing to delete it. cocopilot never creates .mailbox/ this way; resolve this repository manually before retrying."
        }
        $state = Get-CocopilotMailboxState -Path $mailboxDir
        switch ($state.State) {
            "Cocopilot" { $legacyIsOurs = $true }
            "Foreign" { Write-Host "$mailboxDir is not a cocopilot mailbox ($($state.Reason)) - left untouched." -ForegroundColor Cyan }
            default { throw "$mailboxDir cannot be classified ($($state.State): $($state.Reason)) - nothing was changed." }
        }
    }
    if ($legacyIsOurs -and $isGitRepo) {
        $tracked = @(Get-CocopilotTrackedMailboxPaths -RepoPath $RepoPath)
        if ($tracked.Count -gt 0) {
            throw ("git tracks files under .mailbox/ in '$RepoPath' ($($tracked -join ', ')) - refusing to touch " +
                "them. If they are cocopilot state committed by mistake, untrack them yourself " +
                "(git rm -r --cached -- .mailbox), commit, then re-run cleanup.")
        }
    }

    # 1. The pair directory outside the target, then a legacy in-repo
    # mailbox: delete only the files cocopilot creates, and each directory
    # only when it is then empty.
    if ($null -ne $pair) {
        if (Remove-CocopilotMailboxFiles -MailboxDir $pair) { $anyChangeMade = $true }
    } else {
        Write-Host "No cocopilot mailbox directory found for $RepoPath outside the target - nothing to remove there." -ForegroundColor Cyan
    }
    if ($legacyIsOurs) {
        if (Remove-CocopilotMailboxFiles -MailboxDir $mailboxDir) { $anyChangeMade = $true }
    } elseif (-not $mailboxExists) {
        Write-Host "No legacy .mailbox/ directory found at $RepoPath - nothing to remove there." -ForegroundColor Cyan
    }

    # 2. cocopilot's managed block in the git-local exclude file - kept while
    # it still hides the project's own .mailbox/.
    if ($isGitRepo -and ($legacyIsOurs -or -not $mailboxExists) -and (Remove-CocopilotMailboxExcludeRule -RepoPath $RepoPath)) {
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
    # Written through Write-Host (not the success stream), so these lines are
    # always just console text, never part of this function's return value.
    # Read through Invoke-CocopilotGit, so non-ASCII paths are decoded as
    # UTF-8. Every change above has already succeeded or thrown, so a failure
    # of this display only warns.
    if ($isGitRepo) {
        Write-Host "`n--- git status for $RepoPath ---" -ForegroundColor Cyan
        try {
            $status = Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("status", "--short")
            foreach ($line in ($status.Output -split "\r?\n")) { if ($line) { Write-Host $line } }
        } catch {
            Write-Warning "Could not show the git status: $($_.Exception.Message)"
        }
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
            # The running cocopilot install (by path or alias) is never a
            # valid cleanup target - reported as a discovery issue rather
            # than failing loudly mid-Recurse.
            if (Test-IsCocopilotOwnRoot -Path $current) {
                $failures.Add([pscustomobject]@{
                    Path  = $mailboxCandidate
                    Error = "This is cocopilot's own installed repo (by path or alias) - never a cleanup target."
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

$modes = @(@($List, ($PSBoundParameters.ContainsKey("PairId")), $Recurse) | Where-Object { $_ })
if ($modes.Count -gt 1) {
    throw "-List, -PairId and -Recurse cannot be combined. Nothing was changed."
}

if ($List) {
    # Read-only: rows only, never a ShouldProcess call or a change.
    Get-PairDirectoryRows
    return
}

if ($PSBoundParameters.ContainsKey("PairId")) {
    if ($PairId -cnotmatch '^[A-Za-z0-9._-]{1,40}-[0-9a-f]{16}$') {
        throw "'$PairId' is not a cocopilot pair id (<name>-<16 lowercase hex>, as -List shows). Nothing was changed."
    }
    $pairDir = [System.IO.Path]::Join((Get-CocopilotStateRoot), "pairs", $PairId)
    if (-not (Test-Path -LiteralPath $pairDir)) {
        throw "There is no pair directory '$pairDir'. Nothing was changed."
    }
    if (-not (Test-Path -LiteralPath $pairDir -PathType Container) -and -not (Test-CocopilotReparsePoint -Path $pairDir)) {
        throw "'$pairDir' is not a directory. Nothing was changed."
    }
    # The recorded target is only shown: it never decides what is deleted.
    $recorded = Assert-PairDirectoryDeletable -PairDir $pairDir
    Write-Host "Pair $PairId was the mailbox of $(if ($recorded) { $recorded } else { '(empty directory)' })." -ForegroundColor Cyan
    $null = Remove-CocopilotMailboxFiles -MailboxDir $pairDir
    return
}

if (-not $Recurse) {
    $RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
    Invoke-SingleMailboxCleanup -RepoPath $RepoPath | Out-Null
    return
}

# -Recurse: the root may be gone already, so it is resolved canonically
# without requiring it to exist; only the legacy walk needs it on disk.
$searchRoot = Get-CocopilotCanonicalPath -Path $RepoPath
$discovery = [pscustomobject]@{
    Targets  = [System.Collections.Generic.List[string]]::new()
    Failures = [System.Collections.Generic.List[pscustomobject]]::new()
    Skipped  = [System.Collections.Generic.List[pscustomobject]]::new()
}
if (Test-Path -LiteralPath $searchRoot -PathType Container) {
    Write-Host "Searching $searchRoot for legacy in-repo cocopilot mailboxes..." -ForegroundColor Cyan
    $discovery = Find-MailboxTarget -RootPath $searchRoot
}

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

# Pair directories whose recorded target lies at or below the root. A
# target handled by the legacy walk above already had its pair directory
# cleaned there.
$legacyTargets = @($discovery.Targets | ForEach-Object { Get-CocopilotCanonicalPath -Path $_ })
$pairRows = @()
try {
    $pairRows = @(Get-PairDirectoryRows)
} catch {
    $discovery.Failures.Add([pscustomobject]@{ Path = [System.IO.Path]::Join((Get-CocopilotStateRoot), "pairs"); Error = $_.Exception.Message })
}
$pairsFound = 0
$retainedStaging = [System.Collections.Generic.List[string]]::new()
foreach ($row in $pairRows) {
    $rowPath = [System.IO.Path]::Join((Get-CocopilotStateRoot), "pairs", $row.PairId)
    # A pair whose target cannot be read cannot be scoped to the root, so it
    # is reported - never deleted, never guessed in or out.
    if ($row.Status -in @("MALFORMED", "INACCESSIBLE")) {
        $discovery.Failures.Add([pscustomobject]@{ Path = $rowPath; Error = "$($row.Status) pair directory: $($row.Reason); left untouched." })
        continue
    }
    if ($row.Status -eq "STAGING") {
        $retainedStaging.Add($rowPath)
        continue
    }
    if (-not (Test-RecordedTargetWithin -Target $row.Target -Root $searchRoot)) { continue }
    $pairsFound++
    if ($row.Target -in $legacyTargets) { continue }
    Write-Host "`n=== pair $($row.PairId) ($($row.Target)) ===" -ForegroundColor Magenta
    $pairDir = [System.IO.Path]::Join((Get-CocopilotStateRoot), "pairs", $row.PairId)
    try {
        $null = Assert-PairDirectoryDeletable -PairDir $pairDir -ExpectedTarget $row.Target
        $changed = Remove-CocopilotMailboxFiles -MailboxDir $pairDir
        $attempts.Add([pscustomobject]@{ Path = $pairDir; Error = $null; Changed = [bool]$changed })
    } catch {
        Write-Warning "Failed to clean up $pairDir : $($_.Exception.Message)"
        $attempts.Add([pscustomobject]@{ Path = $pairDir; Error = $_.Exception.Message; Changed = $false })
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
Write-Host "Pair directories found:     $pairsFound"
Write-Host "Cleaned successfully:       $($actuallyChanged.Count)"
Write-Host "No changes made (preview or declined confirmation): $($noOpSucceeded.Count)"
Write-Host "Skipped (not a cocopilot mailbox): $($skippedMailboxes.Count)"
Write-Host "Cleanup failures:           $($cleanupFailures.Count)"
Write-Host "Retained migration stagings: $($retainedStaging.Count)"
Write-Host "Discovery issues (unscannable directories, unreadable or linked .mailbox candidates or pair directories, cocopilot installs): $($discoveryFailures.Count)"

if ($retainedStaging.Count -gt 0) {
    Write-Host "`nRetained on purpose (unfinished -MigrateLegacy staging; rerun the migration to finish it):" -ForegroundColor Cyan
    $retainedStaging | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }
}
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
if ($discovery.Targets.Count -eq 0 -and $pairsFound -eq 0 -and $discoveryFailures.Count -eq 0 -and $skippedMailboxes.Count -eq 0) {
    Write-Host "No cocopilot mailboxes found under $searchRoot." -ForegroundColor Cyan
}

$totalFailures = $cleanupFailures.Count + $discoveryFailures.Count
if ($totalFailures -gt 0) {
    throw ("cocopilot-cleanup -Recurse: $($cleanupFailures.Count) cleanup failure(s) and " +
        "$($discoveryFailures.Count) discovery issue$(if ($discoveryFailures.Count -eq 1) { '' } else { 's' })" +
        " - see summary above.")
}
