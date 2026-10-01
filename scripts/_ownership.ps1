#Requires -Version 7.4

<#
.SYNOPSIS
    Handoff state: git HEAD, content hashes, workspace fingerprints,
    manifests and baselines. _common.ps1 dot-sources this file; don't run
    it directly.
#>

function Get-CocopilotGitHead {
    # The full HEAD commit, or the all-zero SHA while the branch has no commit.
    param([Parameter(Mandatory)][string]$WorkTree)

    $result = Invoke-CocopilotGit -WorkTree $WorkTree -Arguments @("rev-parse", "--verify", "--quiet", "HEAD") -AllowedExitCodes @(0, 1)
    if ($result.ExitCode -ne 0) { return "0" * 40 }
    return $result.Output.Trim()
}

function Get-CocopilotContentHash {
    <#
    .SYNOPSIS
        SHA-256 (lowercase hex) of one file, counted against the fingerprint
        budget. Past the budget it hashes nothing, marks the fingerprint
        incomplete and returns "unhashed".
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Budget
    )

    $size = [System.IO.FileInfo]::new($Path).Length
    if ($Budget.Files + 1 -gt $Budget.MaxFiles -or $Budget.Bytes + $size -gt $Budget.MaxBytes) {
        if ($Budget.Complete) {
            $Budget.Complete = $false
            $Budget.Reason = "the workspace holds more than $($Budget.MaxFiles) changed or unversioned files or $($Budget.MaxBytes) bytes to hash"
        }
        return "unhashed"
    }
    $Budget.Files++
    $Budget.Bytes += $size
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
    } finally {
        $stream.Dispose()
    }
}

function Add-CocopilotGitWorktreeFacts {
    <#
    .SYNOPSIS
        Adds one git worktree's state to a fingerprint: HEAD, the staged
        changes, and every changed or untracked path with its status and
        current content hash - so re-editing an already modified file
        changes the fingerprint too - and, recursively, the same for every
        git worktree nested inside it.

    .DESCRIPTION
        Ignored files are not part of it, and neither is anything under
        -SkipPrefix (the target's own mailbox). A nested worktree is never
        hidden behind its parent's constant "directory" entry: git reports
        each one as a path ending in "/" - untracked ones in its status,
        ones inside ignored directories in its ignored-file listing - and
        submodules as gitlinks. Each is captured under its own label. A link
        is recorded and never followed; a reported nested path without a
        .git entry cannot be inspected and marks the fingerprint incomplete.
    #>
    param(
        [Parameter(Mandatory)]$Facts,
        [Parameter(Mandatory)][string]$WorkTree,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)]$Budget,
        [string]$SkipPrefix
    )

    $Facts["head|$Label"] = Get-CocopilotGitHead -WorkTree $WorkTree
    $staged = (Invoke-CocopilotGit -WorkTree $WorkTree -Arguments @("diff", "--cached", "--raw", "-z", "--no-renames", "--no-abbrev")).Output
    $Facts["index|$Label"] = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($staged))).ToLowerInvariant()
    $nested = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $status = (Invoke-CocopilotGit -WorkTree $WorkTree -Arguments @("status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")).Output
    foreach ($record in $status.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $state = $record.Substring(0, 2)
        $relativePath = $record.Substring(3)
        if ($SkipPrefix -and $relativePath.StartsWith($SkipPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($relativePath.EndsWith("/")) { $null = $nested.Add($relativePath.TrimEnd("/")) }
        $fullPath = Join-Path $WorkTree $relativePath
        $content = "missing"
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $content = Get-CocopilotContentHash -Path $fullPath -Budget $Budget
        } elseif (Test-Path -LiteralPath $fullPath -PathType Container) {
            $content = "directory"
        }
        $Facts["status|$Label|$relativePath"] = "$state $content"
    }

    $ignored = (Invoke-CocopilotGit -WorkTree $WorkTree -Arguments @("ls-files", "-z", "--others", "--ignored", "--exclude-standard")).Output
    foreach ($path in $ignored.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($path.EndsWith("/") -and -not ($SkipPrefix -and $path.StartsWith($SkipPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
            $null = $nested.Add($path.TrimEnd("/"))
        }
    }
    $index = (Invoke-CocopilotGit -WorkTree $WorkTree -Arguments @("ls-files", "-z", "--stage")).Output
    foreach ($entry in $index.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        # "<mode> <object> <stage>`t<path>"; mode 160000 is a gitlink (submodule).
        if ($entry.StartsWith("160000 ")) {
            $gitlinkPath = $entry.Substring($entry.IndexOf("`t") + 1)
            # An uninitialized submodule has no worktree yet; its recorded
            # commit is already part of HEAD and the index.
            if (Test-Path -LiteralPath (Join-Path (Join-Path $WorkTree $gitlinkPath) ".git")) { $null = $nested.Add($gitlinkPath) }
        }
    }

    foreach ($relativePath in $nested) {
        $childLabel = if ($Label -eq ".") { $relativePath } else { "$Label/$relativePath" }
        $childPath = Join-Path $WorkTree $relativePath
        $childItem = Get-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $childItem -and $childItem.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            $Facts["link|$childLabel"] = "link to $($childItem.LinkTarget)"
        } elseif ($null -ne $childItem -and (Test-Path -LiteralPath (Join-Path $childPath ".git"))) {
            $Facts["worktree|$childLabel"] = "git"
            Add-CocopilotGitWorktreeFacts -Facts $Facts -WorkTree $childPath -Label $childLabel -Budget $Budget
        } elseif ($Budget.Complete) {
            $Budget.Complete = $false
            $Budget.Reason = "git reports '$childLabel' as a nested repository that cannot be inspected"
        }
    }
}

function Get-CocopilotWorkspaceFingerprint {
    <#
    .SYNOPSIS
        Captures the state an ownership handoff compares: a sorted set of
        facts, each "<kind>|<location>" mapped to a value.

    .DESCRIPTION
        A git target is its repository (see Add-CocopilotGitWorktreeFacts).
        A non-git workspace root is walked: every git worktree below it
        (found by its .git entry, never descended into), and every other file
        with its size and SHA-256. The root's .mailbox/ is skipped; a link
        is recorded, never followed. Complete is false - and a handoff then
        refuses - when a directory cannot be listed or more than -MaxFiles
        files or -MaxBytes bytes would have to be hashed.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [ValidateRange(1, [int]::MaxValue)][int]$MaxFiles = 20000,
        [ValidateRange(1, [long]::MaxValue)][long]$MaxBytes = 512MB
    )

    $facts = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $budget = [pscustomobject]@{ Files = 0; Bytes = 0L; MaxFiles = $MaxFiles; MaxBytes = $MaxBytes; Complete = $true; Reason = $null }

    # One rev-parse answers all three questions: inside a worktree, its top
    # level, and the target's path inside it (kept untrimmed but for the
    # line break - a directory name may end in a space).
    $location = Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("rev-parse", "--is-inside-work-tree", "--show-toplevel", "--show-prefix") -AllowedExitCodes @(0, 128)
    $answers = $location.Output.Split("`n")
    if ($location.ExitCode -eq 0 -and $answers[0].TrimEnd("`r") -eq "true") {
        $topLevel = $answers[1].TrimEnd("`r")
        $prefix = $answers[2].TrimEnd("`r")
        Add-CocopilotGitWorktreeFacts -Facts $facts -WorkTree $topLevel -Label "." -Budget $budget -SkipPrefix "$prefix.mailbox/"
    } else {
        $root = [System.IO.DirectoryInfo]::new($RepoPath)
        $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
        $pending.Push($root)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            try {
                $children = @($directory.EnumerateFileSystemInfos())
            } catch {
                $budget.Complete = $false
                $budget.Reason = "cannot list '$($directory.FullName)': $((Get-CocopilotInnerException -Exception $_.Exception).Message)"
                continue
            }
            foreach ($child in $children) {
                $relativePath = [System.IO.Path]::GetRelativePath($root.FullName, $child.FullName).Replace('\', '/')
                if ($directory.FullName -eq $root.FullName -and $child.Name -eq ".mailbox") { continue }
                if ($child.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                    $facts["link|$relativePath"] = "link to $($child.LinkTarget)"
                } elseif ($child -is [System.IO.DirectoryInfo]) {
                    if (Test-Path -LiteralPath (Join-Path $child.FullName ".git")) {
                        $facts["worktree|$relativePath"] = "git"
                        Add-CocopilotGitWorktreeFacts -Facts $facts -WorkTree $child.FullName -Label $relativePath -Budget $budget
                    } else {
                        $pending.Push($child)
                    }
                } else {
                    $facts["file|$relativePath"] = "$($child.Length) $(Get-CocopilotContentHash -Path $child.FullName -Budget $budget)"
                }
            }
        }
    }
    return [pscustomobject]@{ Complete = $budget.Complete; Reason = $budget.Reason; Facts = $facts }
}

function Compare-CocopilotFingerprint {
    <#
    .SYNOPSIS
        The handoff manifest: one { fact, before, after } entry, in ordinal
        order, per fact that differs between two fingerprints. $null means
        the fact is absent on that side.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Before,
        [Parameter(Mandatory)][AllowEmptyCollection()]$After
    )

    $items = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Before.Keys) { $null = $items.Add($key) }
    foreach ($key in $After.Keys) { $null = $items.Add($key) }
    foreach ($item in $items) {
        $beforeValue = if ($Before.ContainsKey($item)) { $Before[$item] } else { $null }
        $afterValue = if ($After.ContainsKey($item)) { $After[$item] } else { $null }
        if ($beforeValue -cne $afterValue) {
            [pscustomobject][ordered]@{ fact = $item; before = $beforeValue; after = $afterValue }
        }
    }
}

function Test-CocopilotManifestEqual {
    # True when two manifests hold the same entries in the same order,
    # compared case-sensitively.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual
    )

    if ($Expected.Count -ne $Actual.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        foreach ($field in @("fact", "before", "after")) {
            if ($Expected[$index].$field -cne $Actual[$index].$field) { return $false }
        }
    }
    return $true
}

function Save-CocopilotBaseline {
    <#
    .SYNOPSIS
        Writes a fingerprint as an immutable .mailbox/baseline-<id>.json and
        returns the { id, sha256 } reference the ownership record stores.
    #>
    param(
        [Parameter(Mandatory)][string]$MailboxDir,
        [Parameter(Mandatory)]$Fingerprint
    )

    $id = [Guid]::NewGuid().ToString("N")
    $document = [ordered]@{
        id       = $id
        created  = Get-CocopilotUtcStamp
        complete = $Fingerprint.Complete
        reason   = $Fingerprint.Reason
        facts    = @($Fingerprint.Facts.GetEnumerator() | ForEach-Object { , @($_.Key, $_.Value) })
    }
    $text = ($document | ConvertTo-Json -Depth 5 -Compress) + "`n"
    $path = Join-Path $MailboxDir "baseline-$id.json"
    New-CocopilotFileAtomic -Path $path -Text $text
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($path))).ToLowerInvariant()
    return [pscustomobject][ordered]@{ id = $id; sha256 = $hash }
}

function Read-CocopilotBaseline {
    <#
    .SYNOPSIS
        Loads the baseline an ownership record references, after checking
        that its file still has the recorded SHA-256. Returns Complete,
        Reason and Facts, like Get-CocopilotWorkspaceFingerprint.
    #>
    param(
        [Parameter(Mandatory)][string]$MailboxDir,
        [AllowNull()]$Reference
    )

    $hasReference = $null -ne $Reference -and $null -ne $Reference.PSObject.Properties["id"] -and
        [string]$Reference.id -cmatch '^[0-9a-f]{32}$'
    if (-not $hasReference) {
        throw ("The ownership record references no baseline. Only when every change and every log entry so far is " +
            "handled, run init-mailbox.ps1 -AcknowledgeHistory to record the current state as one.")
    }
    $path = Join-Path $MailboxDir "baseline-$($Reference.id).json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The baseline '$path' that the ownership record references is missing."
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($hash -cne [string]$Reference.sha256) {
        throw "The baseline '$path' changed after it was recorded (SHA-256 $hash, recorded $($Reference.sha256))."
    }
    $document = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
    $facts = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($pair in @($document.facts)) { $facts[[string]$pair[0]] = [string]$pair[1] }
    return [pscustomobject]@{ Complete = [bool]$document.complete; Reason = $document.reason; Facts = $facts }
}
