#Requires -Version 7.4
<#
.SYNOPSIS
    Shared helpers for cocopilot's launcher scripts. Dot-source this, don't
    run it directly.
#>

function ConvertTo-SingleQuoted {
    # CodeGeneration escapes every character PowerShell accepts as a single
    # quote (U+0027 and U+2018-U+201B), not only the ASCII apostrophe - so a
    # typographic apostrophe can neither break nor inject into the result.
    param([string]$Value)
    return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

function Get-CocopilotUtcStamp {
    # InvariantCulture: under th-TH or da-DK the current culture would write a
    # Buddhist year or "." as the time separator into log headings.
    return [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-CocopilotSharingViolation {
    <#
    .SYNOPSIS
        True only when the exception chain holds ERROR_SHARING_VIOLATION
        (0x80070020) or ERROR_LOCK_VIOLATION (0x80070021): another process
        holds the file for a moment. A missing file or directory, a full disk
        or a denied access is a real failure and never matches.
    #>
    param([Parameter(Mandatory)][System.Exception]$Exception)

    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.IO.IOException] -and $current.HResult -in @(0x80070020, 0x80070021)) { return $true }
    }
    return $false
}

function Test-CocopilotHeldDestination {
    <#
    .SYNOPSIS
        True for the errors a rename over a destination that another process
        holds open raises on Windows: a sharing violation, or ACCESS_DENIED
        (0x80070005), which File.Move with overwrite reports even when the
        holder allows delete sharing. Only Write-CocopilotFileAtomic's rename
        uses this; every other operation retries sharing violations only.
    #>
    param([Parameter(Mandatory)][System.Exception]$Exception)

    if (Test-CocopilotSharingViolation -Exception $Exception) { return $true }
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.UnauthorizedAccessException] -and $current.HResult -eq 0x80070005) { return $true }
    }
    return $false
}

function Get-CocopilotInnerException {
    # PowerShell wraps .NET method failures in MethodInvocationException; the
    # inner exception carries the real message and HResult.
    param([Parameter(Mandatory)][System.Exception]$Exception)

    if ($Exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $Exception.InnerException) {
        return $Exception.InnerException
    }
    return $Exception
}

function Write-CocopilotFileAtomic {
    <#
    .SYNOPSIS
        Replaces a mailbox file whole: writes a same-directory temp file, then
        renames it over the destination with File.Move (overwrite).

    .DESCRIPTION
        The rename keeps the destination present throughout: in stress runs a
        concurrent reader never found it missing or partly written. That is
        visibility for readers, not durability; nothing is claimed about
        power loss.

        Only the rename is retried, for at most -RetryMilliseconds, and only
        while another process holds the destination open (see
        Test-CocopilotHeldDestination). After that, or on any other error, the
        error surfaces with the destination named. The destination is never
        deleted and its attributes and ACL are never changed; a failure
        removes only this call's temp file.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 5000
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "Cannot replace '$Path': a directory exists there."
    }
    $directory = Split-Path -Parent $Path
    $tempPath = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
    try {
        # UTF-8 without BOM via .NET, independent of cmdlet encoding defaults.
        [System.IO.File]::WriteAllText($tempPath, $Text, [System.Text.UTF8Encoding]::new($false))
        $deadline = [DateTime]::UtcNow.AddMilliseconds($RetryMilliseconds)
        while ($true) {
            try {
                [System.IO.File]::Move($tempPath, $Path, $true)
                return
            } catch {
                $cause = Get-CocopilotInnerException -Exception $_.Exception
                if (-not (Test-CocopilotHeldDestination -Exception $cause) -or [DateTime]::UtcNow -ge $deadline) {
                    throw [System.IO.IOException]::new("Could not replace '$Path': $($cause.Message)", $cause)
                }
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-MailboxJson {
    <#
    .SYNOPSIS
        Replaces a mailbox JSON file (implementer.json) whole through
        Write-CocopilotFileAtomic: readers see the old or the new record,
        never a missing or partial one. It does not serialize writers:
        callers that read and then replace the record hold the ownership
        lock (Enter-CocopilotOwnershipLock).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 5000
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "Write-MailboxJson: -Path must be a file, but a directory exists there: $Path"
    }
    $json = ($Object | ConvertTo-Json -Depth 20 -Compress) + "`n"
    Write-CocopilotFileAtomic -Path $Path -Text $json -RetryMilliseconds $RetryMilliseconds
}

function Get-CocopilotMailboxFileNames {
    <#
    .SYNOPSIS
        The fixed file names cocopilot creates inside a target's .mailbox/.
        With the baseline files and writer temps (see
        Test-CocopilotMailboxEntryName) they are the only entries
        cleanup-mailbox.ps1 ever deletes there.
    #>
    return @(
        "implementer.json", "agent-a.md", "agent-b.md", "session.log.md",
        "agent-a.cursor", "agent-b.cursor", "verify-request.md", "implementer.lock"
    )
}

function Test-CocopilotBaselineFileName {
    # An immutable handoff baseline: "baseline-<32 lowercase hex>.json".
    param([Parameter(Mandatory)][string]$Name)

    return $Name -cmatch '^baseline-[0-9a-f]{32}\.json$'
}

function Test-CocopilotWriterTempName {
    <#
    .SYNOPSIS
        True only for the exact temp-file name Write-CocopilotFileAtomic
        generates next to a listed mailbox file or a baseline file:
        ".<name>.<32 lowercase hex>.tmp".
    #>
    param([Parameter(Mandatory)][string]$Name)

    $names = (Get-CocopilotMailboxFileNames | ForEach-Object { [regex]::Escape($_) }) -join "|"
    return $Name -cmatch "^\.(?:$names|baseline-[0-9a-f]{32}\.json)\.[0-9a-f]{32}\.tmp$"
}

function Test-CocopilotMailboxEntryName {
    # True for every name cocopilot itself creates inside .mailbox/.
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -in (Get-CocopilotMailboxFileNames)) -or
        (Test-CocopilotBaselineFileName -Name $Name) -or
        (Test-CocopilotWriterTempName -Name $Name)
}

function Read-CocopilotSharedText {
    <#
    .SYNOPSIS
        Reads a whole mailbox file as UTF-8 without blocking a concurrent
        writer or rename (FileShare ReadWrite|Delete). A sharing violation -
        a writer holding the session log exclusively for an append - is
        retried for at most -RetryMilliseconds.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 5000
    )

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $deadline = [DateTime]::UtcNow.AddMilliseconds($RetryMilliseconds)
    while ($true) {
        try {
            $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            break
        } catch {
            if (-not (Test-CocopilotSharingViolation -Exception $_.Exception) -or [DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $true)
        return $reader.ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

function Add-CocopilotLogText {
    <#
    .SYNOPSIS
        Appends text to the session log under an exclusive handle
        (FileShare.None), so no reader sees the append half-done and two
        writers never interleave.

    .DESCRIPTION
        Only opening the log is retried, for at most -RetryMilliseconds and
        only on a sharing violation: a reader or the peer holds the log for a
        moment. Once the exclusive handle exists, a failed write is never
        repeated, so an entry is never duplicated. A missing log is an error;
        it is never recreated without its marker.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 5000
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($RetryMilliseconds)
    while ($true) {
        try {
            $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            break
        } catch {
            if (-not (Test-CocopilotSharingViolation -Exception $_.Exception) -or [DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
    try {
        $null = $stream.Seek(0, [System.IO.SeekOrigin]::End)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally {
        $stream.Dispose()
    }
}

function New-CocopilotFileAtomic {
    <#
    .SYNOPSIS
        Creates a file whole: writes a same-directory temp file, then renames
        it into place without overwriting. An existing file is an error and
        stays untouched; a failure removes only this call's temp file.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $directory = Split-Path -Parent $Path
    $tempPath = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($tempPath, $Text, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tempPath, $Path, $false)
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-CocopilotCursor {
    # A delivery cursor: "<log generation> <character offset>" - everything
    # in that log generation before the offset counts as handled.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$Generation,
        [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$Offset
    )

    Write-CocopilotFileAtomic -Path $Path -Text "$Generation $Offset`n"
}

function Read-CocopilotCursor {
    <#
    .SYNOPSIS
        Reads a delivery cursor. Returns Valid, Generation, Offset and, when
        it is not valid, a Reason: the file is missing or does not hold
        "<32 hex> <offset>".
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; Generation = $null; Offset = 0L; Reason = "there is no cursor file" }
    }
    $match = [regex]::Match((Read-CocopilotSharedText -Path $Path), '^(?<generation>[0-9a-f]{32}) (?<offset>\d{1,18})\r?\n?$')
    if (-not $match.Success) {
        return [pscustomobject]@{ Valid = $false; Generation = $null; Offset = 0L; Reason = "the cursor file is unreadable" }
    }
    return [pscustomobject]@{
        Valid      = $true
        Generation = $match.Groups["generation"].Value
        Offset     = [long]$match.Groups["offset"].Value
        Reason     = $null
    }
}

function Enter-CocopilotOwnershipLock {
    <#
    .SYNOPSIS
        Takes the mailbox's ownership lock (implementer.lock) and returns its
        handle; dispose the handle to release the lock.

    .DESCRIPTION
        The lock file is opened exclusively (FileShare.None) and removed when
        its handle is released. A lock file that a crashed process left
        behind holds nothing: the next update opens and reuses it. While
        another update holds the lock, opening is retried for at most
        -RetryMilliseconds, on sharing violations only.
    #>
    param(
        [Parameter(Mandatory)][string]$MailboxDir,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 10000
    )

    $lockPath = Join-Path $MailboxDir "implementer.lock"
    $deadline = [DateTime]::UtcNow.AddMilliseconds($RetryMilliseconds)
    while ($true) {
        try {
            return [System.IO.FileStream]::new($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        } catch {
            if (-not (Test-CocopilotSharingViolation -Exception $_.Exception)) { throw }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Another ownership update still holds '$lockPath'; nothing was changed. Try again."
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Invoke-CocopilotGit {
    <#
    .SYNOPSIS
        Runs a read-only git command in $WorkTree and returns its exit code
        and standard output, decoded as UTF-8 whatever the console encoding.

    .DESCRIPTION
        --no-optional-locks keeps "git status" from rewriting the index while
        the tree is only being inspected. An exit code outside
        -AllowedExitCodes throws with git's own message.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkTree,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new("git")
    foreach ($argument in @("--no-optional-locks", "-C", $WorkTree) + $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    # git gets its own, already closed stdin: an inherited pipe - as in a
    # PowerShell job or an agent's tool shell - can leave it waiting forever.
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        # Read both streams at once, so a full stderr pipe cannot stall git.
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $outputText = $outputTask.GetAwaiter().GetResult()
        if ($process.ExitCode -notin $AllowedExitCodes) {
            throw "git $($Arguments -join ' ') failed in '$WorkTree' (exit $($process.ExitCode)): $($errorText.Trim())"
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outputText }
    } finally {
        $process.Dispose()
    }
}

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

function New-CocopilotLogEntryText {
    <#
    .SYNOPSIS
        Frames one session-log entry: the "## <stamp> <role>" heading, the
        body, exactly one line break, and the
        "<!-- cocopilot:end <stamp> <role> -->" marker that proves the
        append completed.
    #>
    param(
        [Parameter(Mandatory)][string]$Stamp,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b", "init")][string]$Role,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    $separator = if ($Body.EndsWith("`n")) { "" } else { "`n" }
    return "`n## $Stamp $Role`n$Body$separator<!-- cocopilot:end $Stamp $Role -->`n"
}

function Get-CocopilotForbiddenBodyLine {
    <#
    .SYNOPSIS
        Returns the first line of $Body that a reader could take for a log
        heading or an end marker - it would forge an entry or a commit
        boundary - or $null when there is none. Whitespace variants count.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)

    foreach ($line in ($Body -split "`n")) {
        $candidate = $line.TrimEnd("`r")
        if ($candidate -match '^\s*##\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}Z\s+(agent-a|agent-b|init)\s*$' -or
            $candidate -match '^\s*<!--\s*cocopilot:end\b') {
            return $candidate
        }
    }
    return $null
}

function Get-CocopilotLogEntries {
    <#
    .SYNOPSIS
        Splits session-log text into entries with character offsets.

    .DESCRIPTION
        An entry starts at the line break before its "## <stamp> <role>"
        heading line and ends where the next entry starts, or at the end of
        the text. Each entry has a Kind:
          Complete   - its last line is its own end marker.
          Legacy     - no marker, before the log's first marked entry. It was
                       written before cocopilot framed entries, so its
                       completeness cannot be verified.
          Incomplete - no marker, after the first marked entry. Its writer
                       stopped mid-append, or still runs an older cocopilot.
        Offsets are character positions in the decoded text; the log is
        append-only, so an offset never moves once written.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $headings = [regex]::Matches($Text, '(?m)^## (?<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z) (?<role>agent-a|agent-b|init)\r?$')
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $headings.Count; $index++) {
        $heading = $headings[$index]
        $stamp = $heading.Groups["stamp"].Value
        $role = $heading.Groups["role"].Value
        $start = [Math]::Max(0, $heading.Index - 1)
        $end = if ($index + 1 -lt $headings.Count) { $headings[$index + 1].Index - 1 } else { $Text.Length }
        $afterHeading = $heading.Index + $heading.Length
        $content = $Text.Substring($afterHeading, [Math]::Max(0, $end - $afterHeading)).TrimEnd("`r", "`n")
        $lastBreak = $content.LastIndexOf("`n")
        $isMarked = $lastBreak -ge 0 -and $content.Substring($lastBreak + 1).TrimEnd("`r") -ceq "<!-- cocopilot:end $stamp $role -->"
        $body = if ($isMarked) { $content.Substring(0, $lastBreak) } else { $content }
        $body = ($body -replace '^\r?\n', '').TrimEnd("`r")
        $entries.Add([pscustomobject]@{
                Stamp  = $stamp
                Role   = $role
                Start  = $start
                End    = $end
                Marked = $isMarked
                Kind   = $null
                Body   = $body
            })
    }

    $firstMarked = -1
    for ($index = 0; $index -lt $entries.Count; $index++) {
        if ($entries[$index].Marked) { $firstMarked = $index; break }
    }
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        if ($entry.Marked) { $entry.Kind = "Complete" }
        elseif ($firstMarked -lt 0 -or $index -lt $firstMarked) { $entry.Kind = "Legacy" }
        else { $entry.Kind = "Incomplete" }
    }
    return $entries.ToArray()
}

function Get-CocopilotLogGeneration {
    <#
    .SYNOPSIS
        The log's generation: the 32-hex id that cursors and ACK tokens are
        bound to, so a token for a deleted and re-created log is never
        accepted.

    .DESCRIPTION
        A log written by this cocopilot version names it in its init entry
        ("- generation: <32 hex>"). An older log has no such line; its
        generation is the first 32 hex digits of the SHA-256 of its immutable
        start - the text up to the end of its first entry, with line breaks
        normalized to LF and trailing line breaks dropped. Later appends never
        change that text, however far the log grows.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $headings = [regex]::Matches($Text, '(?m)^## \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z (?:agent-a|agent-b|init)\r?$')
    if ($headings.Count -eq 0) {
        throw "The session log has no entry heading, so its generation cannot be determined."
    }
    $firstEnd = if ($headings.Count -gt 1) { $headings[1].Index - 1 } else { $Text.Length }
    $firstEntry = $Text.Substring($headings[0].Index, $firstEnd - $headings[0].Index)
    $named = [regex]::Match($firstEntry, '(?m)^- generation: (?<id>[0-9a-f]{32})\r?$')
    if ($named.Success) { return $named.Groups["id"].Value }

    $immutableStart = $Text.Substring(0, $firstEnd).Replace("`r`n", "`n").TrimEnd("`n")
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($immutableStart))
    return [Convert]::ToHexString($hash).ToLowerInvariant().Substring(0, 32)
}

function Get-CocopilotMailboxState {
    <#
    .SYNOPSIS
        Classifies a .mailbox directory before anything adopts or deletes it.

    .DESCRIPTION
        Cocopilot: implementer.json is an ownership record and session.log.md
        starts with the marker init-mailbox.ps1 writes (see
        Get-CocopilotMailboxFileCheck). Foreign: readable, but either file is
        missing or not cocopilot's. Unreadable: an I/O or JSON parse failure -
        never treated as cocopilot's or as foreign.
    #>
    param([Parameter(Mandatory)][string]$Path)

    foreach ($name in @("implementer.json", "session.log.md")) {
        $file = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            return [pscustomobject]@{ State = "Foreign"; Reason = "it has no $name" }
        }
        $check = Get-CocopilotMailboxFileCheck -Path $file
        if ($check.State -ne "Cocopilot") { return $check }
    }
    return [pscustomobject]@{ State = "Cocopilot"; Reason = $null }
}

function Get-CocopilotMailboxFileCheck {
    <#
    .SYNOPSIS
        Checks the content of one existing mailbox anchor file:
        implementer.json must be an ownership record (integer epoch >= 1,
        state active|offered, owner agent-a|agent-b); session.log.md must start
        with the init marker. Returns State Cocopilot | Foreign | Unreadable
        (+ reason); Unreadable = I/O or JSON parse failure.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $name = Split-Path -Leaf $Path
    try {
        $text = Read-CocopilotSharedText -Path $Path
        $record = if ($name -eq "implementer.json") { $text | ConvertFrom-Json -ErrorAction Stop } else { $null }
    } catch {
        return [pscustomobject]@{ State = "Unreadable"; Reason = "$name - $($_.Exception.Message)" }
    }

    switch ($name) {
        "implementer.json" {
            $isRecord = $record -is [System.Management.Automation.PSCustomObject]
            if ($isRecord) {
                # Property checks first, via the indexer (which returns $null):
                # a caller running Set-StrictMode -Version Latest would
                # otherwise turn a missing property into a throw.
                $properties = $record.PSObject.Properties
                $isRecord = ($null -ne $properties["epoch"]) -and ($null -ne $properties["state"]) -and ($null -ne $properties["owner"])
            }
            if ($isRecord) {
                $epoch = $record.epoch
                $isRecord = ($epoch -is [int] -or $epoch -is [long]) -and $epoch -ge 1 -and
                    ($record.state -cin @("active", "offered")) -and
                    ($record.owner -cin @("agent-a", "agent-b"))
            }
            if (-not $isRecord) {
                return [pscustomobject]@{ State = "Foreign"; Reason = "implementer.json is not a cocopilot ownership record" }
            }
        }
        "session.log.md" {
            if (-not $text.StartsWith("# session log - write-once history", [System.StringComparison]::Ordinal)) {
                return [pscustomobject]@{ State = "Foreign"; Reason = "session.log.md lacks the cocopilot log marker" }
            }
        }
        default { throw "Get-CocopilotMailboxFileCheck: no content check is defined for '$name'." }
    }
    return [pscustomobject]@{ State = "Cocopilot"; Reason = $null }
}

function Test-CocopilotTemplatesPresent {
    <#
    .SYNOPSIS
        True when $RepoPath\.mailbox holds cocopilot's own tracked templates -
        i.e. $RepoPath is a cocopilot install, whatever path reached it
        (junction, symlink, subst, mapped drive or a plain copy).
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    foreach ($name in @("implementer.example.json", "lane.example.md")) {
        if (Test-Path -LiteralPath (Join-Path $RepoPath ".mailbox\$name")) { return $true }
    }
    return $false
}

function Get-CocopilotTrackedMailboxPaths {
    <#
    .SYNOPSIS
        Paths under .mailbox/ that git tracks in $RepoPath. Anything tracked
        there is never cocopilot's runtime state to delete.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    # -z and Invoke-CocopilotGit: exact UTF-8 paths, never quoted or
    # decoded through the console code page.
    $result = Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("ls-files", "-z", "--", ".mailbox") -AllowedExitCodes @(0..255)
    if ($result.ExitCode -ne 0) {
        throw "git ls-files failed in '$RepoPath' (exit $($result.ExitCode)); refusing to guess what it tracks under .mailbox/."
    }
    return @($result.Output.Split([char]0) | Where-Object { $_ })
}

function Read-CocopilotTextFile {
    <#
    .SYNOPSIS
        Reads a UTF-8 text file and reports whether it starts with a BOM, so a
        rewrite keeps the user's exact encoding. Invalid UTF-8 throws: a file
        that cannot be decoded exactly is never rewritten.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Text = ""; HasBom = $false }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    return [pscustomobject]@{ Text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset); HasBom = $hasBom }
}

function Write-CocopilotTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$HasBom
    )
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($HasBom))
}

function Get-CocopilotExcludeTarget {
    <#
    .SYNOPSIS
        The git-local exclude file for $RepoPath (never committed, and shared
        by linked worktrees) plus the rooted rule that ignores exactly this
        target's .mailbox/ - "/.mailbox/", or "/sub/dir/.mailbox/" when
        $RepoPath is a subdirectory of the repository.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    # Paths are read through Invoke-CocopilotGit: git writes them as UTF-8,
    # which the console code page would garble.
    $excludePath = ((Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("rev-parse", "--git-path", "info/exclude")).Output -split "\r?\n")[0]
    if (-not $excludePath) {
        throw "Could not resolve the git exclude file for '$RepoPath'."
    }
    $prefix = ((Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("rev-parse", "--show-prefix")).Output -split "\r?\n")[0]
    if (-not [System.IO.Path]::IsPathRooted($excludePath)) {
        $excludePath = Join-Path $RepoPath $excludePath
    }
    # Ignore rules are glob patterns: escape git's wildcard characters so a
    # directory named e.g. "[api]" is matched literally, not as a set. The
    # prefix is used untrimmed - leading spaces are valid in a name.
    $literalPrefix = [regex]::Replace($prefix, '[\\*?\[\]]', '\$0')
    return [pscustomobject]@{
        Path   = [System.IO.Path]::GetFullPath($excludePath)
        Rule   = "/" + $literalPrefix + ".mailbox/"
        Prefix = $prefix
    }
}

function Get-CocopilotExcludeSharers {
    <#
    .SYNOPSIS
        Other worktrees of $RepoPath's repository that still hold a cocopilot
        mailbox at the same relative location. They share the same
        info/exclude rule, so it must stay while any of them exists.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prefix
    )

    $top = ((Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("rev-parse", "--show-toplevel")).Output -split "\r?\n")[0]
    if (-not $top) { throw "Could not resolve the worktree root of '$RepoPath'." }
    $top = [System.IO.Path]::GetFullPath($top).TrimEnd('\', '/')
    $listing = (Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("worktree", "list", "--porcelain")).Output -split "\r?\n"

    $sharers = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $listing) {
        if (-not $line.StartsWith("worktree ", [System.StringComparison]::Ordinal)) { continue }
        $worktree = [System.IO.Path]::GetFullPath($line.Substring(9)).TrimEnd('\', '/')
        if ($worktree -ieq $top) { continue }
        $base = if ($Prefix) { Join-Path $worktree ($Prefix -replace '/', '\') } else { $worktree }
        $mailbox = Join-Path $base ".mailbox"
        if ((Test-Path -LiteralPath $mailbox -PathType Container) -and
            (Get-CocopilotMailboxState -Path $mailbox).State -eq "Cocopilot") {
            $sharers.Add($mailbox)
        }
    }
    return @($sharers)
}

function Get-CocopilotExcludeBlockPattern {
    param([Parameter(Mandatory)][string]$Rule)
    return "(?m)^# >>> cocopilot mailbox >>>\r?\n" + [regex]::Escape($Rule) + "\r?\n# <<< cocopilot mailbox <<<(?:\r?\n|$)"
}

function Add-CocopilotMailboxExcludeRule {
    <#
    .SYNOPSIS
        Appends cocopilot's managed ignore block for $RepoPath's .mailbox/ to
        the git-local exclude file, unless that exact block is already there.
        Returns the exclude target, or $null when nothing was written.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    $target = Get-CocopilotExcludeTarget -RepoPath $RepoPath
    $file = Read-CocopilotTextFile -Path $target.Path
    if ($file.Text -match (Get-CocopilotExcludeBlockPattern -Rule $target.Rule)) { return $null }

    $separator = if ($file.Text.Length -gt 0 -and -not $file.Text.EndsWith("`n")) { "`n" } else { "" }
    $block = "# >>> cocopilot mailbox >>>`n$($target.Rule)`n# <<< cocopilot mailbox <<<`n"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $target.Path)) | Out-Null
    Write-CocopilotTextFile -Path $target.Path -Text ($file.Text + $separator + $block) -HasBom $file.HasBom
    return $target
}

function Remove-CocopilotMailboxExcludeRule {
    <#
    .SYNOPSIS
        Removes only cocopilot's managed block for $RepoPath's rule from the
        git-local exclude file; every other line stays, including a user's
        own .mailbox rule. Returns $true when the file was changed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RepoPath)

    $target = Get-CocopilotExcludeTarget -RepoPath $RepoPath
    if (-not (Test-Path -LiteralPath $target.Path -PathType Leaf)) { return $false }

    $file = Read-CocopilotTextFile -Path $target.Path
    $newText = [regex]::Replace($file.Text, (Get-CocopilotExcludeBlockPattern -Rule $target.Rule), "")
    if ($newText -eq $file.Text) { return $false }

    # info/exclude is shared by every worktree of the repository.
    $sharers = @(Get-CocopilotExcludeSharers -RepoPath $RepoPath -Prefix $target.Prefix)
    if ($sharers.Count -gt 0) {
        Write-Warning "Kept cocopilot's exclude rule $($target.Rule): it still protects $($sharers -join ', ')."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($target.Path, "Remove cocopilot's .mailbox/ exclude rule $($target.Rule)")) { return $false }

    Write-CocopilotTextFile -Path $target.Path -Text $newText -HasBom $file.HasBom
    return $true
}

function Get-CocopilotInitCommand {
    <#
    .SYNOPSIS
        Builds the ready-to-run init-mailbox.ps1 command suggested to
        recover a missing/incomplete mailbox (embedded in the session
        banner, and in start-agents.ps1's / watch-mailbox.ps1's own
        "mailbox missing" throws).

    .DESCRIPTION
        Single source of truth for that suggestion so all three sites
        agree: probes whether $RepoPath is currently a git repository and,
        if not, appends -AllowNonGit — otherwise the suggested command
        would refuse to run on a non-git workspace root, bouncing the user
        into a dead-end recovery loop.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$InitScript
    )

    $isGitRepo = $false
    try {
        $null = git -C $RepoPath rev-parse --is-inside-work-tree 2>$null
        $isGitRepo = ($LASTEXITCODE -eq 0)
    } catch { $isGitRepo = $false }

    $allowNonGitFlag = if ($isGitRepo) { "" } else { " -AllowNonGit" }
    return "& $(ConvertTo-SingleQuoted $InitScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath)$allowNonGitFlag"
}

function Resolve-CocopilotAgentName {
    <#
    .SYNOPSIS
        Resolves the effective session/window name for one agent: an
        explicitly-bound -NameA/-NameB always wins; otherwise -SessionName
        (if given) derives "<SessionName> - agent a/b"; otherwise the caller's
        own inline default (already in $CurrentValue) stands.
    #>
    param(
        [Parameter(Mandatory)][string]$CurrentValue,
        [Parameter(Mandatory)][bool]$ExplicitlyBound,
        [string]$SessionName,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$AgentRole
    )

    if (-not $ExplicitlyBound -and -not [string]::IsNullOrWhiteSpace($SessionName)) {
        $displayRole = $AgentRole -replace "-", " "
        return "$($SessionName.Trim()) - $displayRole"
    }
    return $CurrentValue
}

function Get-CocopilotWindowTitleStatement {
    <#
    .SYNOPSIS
        A small PowerShell statement, meant to be prepended to an agent's
        encoded inner script, that sets the new console's window title —
        the only way the plain (non-Windows-Terminal) console-window path
        gets any title at all.
    #>
    param([Parameter(Mandatory)][string]$Title)
    return "`$host.UI.RawUI.WindowTitle = $(ConvertTo-SingleQuoted $Title); "
}

function ConvertTo-WindowsProcessArgument {
    <#
    .SYNOPSIS
        Quotes one argument for APIs such as Start-Process -ArgumentList that
        flatten an argument array into a single Windows command line.
    #>
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $quoted = New-Object System.Text.StringBuilder
    [void]$quoted.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$quoted.Append(('\' * (($backslashes * 2) + 1)))
            [void]$quoted.Append('"')
        } else {
            if ($backslashes -gt 0) { [void]$quoted.Append(('\' * $backslashes)) }
            [void]$quoted.Append($character)
        }
        $backslashes = 0
    }

    if ($backslashes -gt 0) { [void]$quoted.Append(('\' * ($backslashes * 2))) }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function ConvertTo-CocopilotWtArgument {
    <#
    .SYNOPSIS
        Escapes Windows Terminal's command separator, then applies normal
        Windows process argument quoting.
    #>
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)

    $escapedForWindowsTerminal = $Value.Replace(";", "\;")
    return ConvertTo-WindowsProcessArgument -Value $escapedForWindowsTerminal
}

function Get-CocopilotWtNewTabArgs {
    <#
    .SYNOPSIS
        Builds the wt.exe argument array for opening one agent as a new
        tab.

    .DESCRIPTION
        -w 0 is a GLOBAL wt.exe option (must precede the command verb) —
        Microsoft's documented "run in the most-recently-used window, or
        create one if none exists" sentinel. This is what actually fixes
        "always opens a new window": without it, every wt.exe invocation
        opens a fresh window regardless of one already being open.
        --startingDirectory matches the plain-console-window branch, which
        sets -WorkingDirectory; the wt.exe branch had no equivalent before
        this, so a tab could start in the wrong directory.
        --suppressApplicationTitle keeps the hosted process (PowerShell,
        then copilot) from silently overwriting --title later.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ShellExe,
        [Parameter(Mandatory)][string]$EncodedCommand
    )

    $arguments = @(
        "-w", "0",
        "new-tab",
        "--title", $Title,
        "--suppressApplicationTitle",
        "--startingDirectory", $RepoPath,
        "--",
        $ShellExe, "-NoExit", "-EncodedCommand", $EncodedCommand
    )
    return @($arguments | ForEach-Object { ConvertTo-CocopilotWtArgument -Value $_ })
}

function Get-CocopilotRolePrompt {
    <#
    .SYNOPSIS
        Returns the role prompt that follows the session banner: the shared
        prompts/agent.md template rendered for agent-a or agent-b, or
        prompts/verifier.md unchanged.

    .DESCRIPTION
        Both peer roles render from one template, so their guidance cannot
        drift apart. A {{...}} token left after rendering throws instead of
        reaching an agent.
    #>
    param(
        [Parameter(Mandatory)][string]$CocopilotRoot,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b", "verifier")][string]$AgentRole
    )

    $promptFile = if ($AgentRole -eq "verifier") { "verifier.md" } else { "agent.md" }
    $promptPath = Join-Path $CocopilotRoot "prompts\$promptFile"
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) { throw "Missing prompt file: $promptPath" }
    $text = (Read-CocopilotTextFile -Path $promptPath).Text
    if ($AgentRole -eq "verifier") { return $text }

    if ($AgentRole -eq "agent-a") {
        $roleName = "Agent A"; $peerRole = "agent-b"; $peerName = "Agent B"
    } else {
        $roleName = "Agent B"; $peerRole = "agent-a"; $peerName = "Agent A"
    }
    $rendered = $text.
        Replace("{{ROLE}}", $AgentRole).
        Replace("{{ROLE_NAME}}", $roleName).
        Replace("{{PEER_ROLE}}", $peerRole).
        Replace("{{PEER_NAME}}", $peerName)
    $unresolved = [regex]::Match($rendered, '\{\{[^{}\r\n]*\}\}')
    if ($unresolved.Success) { throw "Unresolved placeholder $($unresolved.Value) in $promptPath" }
    return $rendered
}

function Get-CocopilotSessionBanner {
    <#
    .SYNOPSIS
        Builds the "session context" banner prepended to each agent's
        prompt, so the same role prompts (see Get-CocopilotRolePrompt) can
        target any repository without hardcoding its name or path.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$CocopilotRoot,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b", "verifier")][string]$AgentRole,
        [string]$ContextRoot
    )

    $collaborationPath = Join-Path $CocopilotRoot "COLLABORATION.md"
    $watchScript = Join-Path $CocopilotRoot "scripts\watch-mailbox.ps1"
    $initScript = Join-Path $CocopilotRoot "scripts\init-mailbox.ps1"
    $writeLaneScript = Join-Path $CocopilotRoot "scripts\write-lane.ps1"
    $handoffScript = Join-Path $CocopilotRoot "scripts\handoff.ps1"
    $watchCmd = "& $(ConvertTo-SingleQuoted $watchScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole"
    $initCmd = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initScript
    $writeLaneCmd = "& $(ConvertTo-SingleQuoted $writeLaneScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole -Turn `$turn"
    $handoffCmd = "& $(ConvertTo-SingleQuoted $handoffScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole -Action <Offer|Accept|Cancel|SetModel>"

    $core = @"
## Session context (auto-generated by cocopilot — do not hand-edit)

- Your role: $AgentRole
- Target repository: $RepoPath
- Mailbox: $RepoPath\.mailbox\ (implementer.json, agent-a.md, agent-b.md, session.log.md, verify-request.md, one cursor per agent)
- Collaboration protocol: $collaborationPath
"@

    if ($ContextRoot) {
        $core += @"

- Workspace context root (READ-ONLY search scope): $ContextRoot
  You may read anything under it — sibling repositories, shared contracts,
  cross-repo callers — for context and evidence. Ownership, epochs, diffs,
  reviews, and EVERY write remain bound to the target repository above;
  sibling repositories are evidence, never workspace (see the protocol's
  "Workspace context" section).
"@
    }

    if ($AgentRole -eq "verifier") {
        # Read-only role: deliberately gets NO watch/init/ownership
        # commands — a verifier must never be handed a ready-to-run
        # mutating command.
        return $core + @"

- You are a read-only fresh-eyes verifier; no watch/init/ownership
  commands are provided to this role on purpose.

---

"@
    }

    $peerRole = if ($AgentRole -eq "agent-a") { "agent-b" } else { "agent-a" }
    $myLane = Join-Path $RepoPath ".mailbox\$AgentRole.md"
    $peerLane = Join-Path $RepoPath ".mailbox\$peerRole.md"

    return $core + @"

- Your lane (the ONLY mailbox file you may write): $myLane
- Peer lane (read-only to you): $peerLane

- Lane write command (the preferred way to post a lane entry — build
  `$turn as the raw turn body first, no timestamp or "## ..." heading
  of your own, then run verbatim; appends to the session log FIRST and
  overwrites your own lane LAST, exactly as the protocol requires. Run
  EXACTLY as given below — -Role is already correct for you here, but
  the command cannot itself verify who is calling it, so never edit the
  -Role value. Add -VerifyRequest when the turn is a VERIFY_REQUEST, to
  pin it for the fresh-eyes verifier):
  $writeLaneCmd
- Watch command (delivers the peer's new log entries at once, or waits
  for the next one or for any ownership-record change, including your
  own — run in the background whenever you're blocked on the peer; after
  handling a delivery, run the RE_ARM command it printed, which
  acknowledges what you handled):
  $watchCmd
- Init command (only if implementer.json, a lane file or session.log.md
  is missing — never because a cursor or verify-request.md is missing;
  without a cursor, your first watch replays the whole log):
  $initCmd
- Handoff command (the ONLY allowed way to change implementer.json; it
  checks the record, takes the ownership lock and prints the entry to
  post in your lane. Accept and Cancel need -Epoch <n> from the offer;
  SetModel needs -OwnerModel <model>; Accept takes it too):
  $handoffCmd

---

"@
}
