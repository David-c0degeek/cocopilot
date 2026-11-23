#Requires -Version 7.4

<#
.SYNOPSIS
    Mailbox file names, mailbox and install checks, tracked-path checks
    and the ownership lock. _common.ps1 dot-sources this file; don't run
    it directly.
#>

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
        "agent-a.cursor", "agent-b.cursor", "verify-request.md", "implementer.lock",
        "sessions.json", "sessions.lock"
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

function Enter-CocopilotOwnershipLock {
    <#
    .SYNOPSIS
        Takes the mailbox's ownership lock (implementer.lock) and returns its
        handle; dispose the handle to release the lock.

    .DESCRIPTION
        The lock file is opened exclusively (FileShare.None) and removed when
        its handle is released. A lock file that a crashed process left
        behind holds nothing: the next update opens and reuses it. While
        another update holds the lock, or its released lock file is still
        being deleted, opening is retried for at most -RetryMilliseconds:
        Windows reports the first as a sharing violation and the second as
        access denied (see Test-CocopilotHeldDestination). Any other error,
        and either one after the deadline, surfaces with the path named.
    #>
    param(
        [Parameter(Mandatory)][string]$MailboxDir,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 10000
    )

    return Enter-CocopilotMailboxLock -LockPath (Join-Path $MailboxDir "implementer.lock") -Purpose "ownership" -RetryMilliseconds $RetryMilliseconds
}

function Enter-CocopilotMailboxLock {
    <#
    .SYNOPSIS
        Opens one mailbox lock file exclusively and returns its handle; dispose
        the handle to release the lock. Enter-CocopilotOwnershipLock and
        Enter-CocopilotRegistrationLock share this, each with its own file, so
        a registration update never waits on an ownership update.
    #>
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][string]$Purpose,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 10000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($RetryMilliseconds)
    while ($true) {
        try {
            return [System.IO.FileStream]::new($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        } catch {
            if (-not (Test-CocopilotHeldDestination -Exception $_.Exception)) { throw }
            if ([DateTime]::UtcNow -ge $deadline) {
                if (Test-CocopilotSharingViolation -Exception $_.Exception) {
                    throw "Another $Purpose update still holds '$LockPath'; nothing was changed. Try again."
                }
                $cause = Get-CocopilotInnerException -Exception $_.Exception
                throw ("Opening the $Purpose lock '$LockPath' kept failing because access was denied (a released lock file " +
                    "still being deleted, or missing permissions): $($cause.Message) Nothing was changed.")
            }
            Start-Sleep -Milliseconds 50
        }
    }
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
            if (-not $text.StartsWith((Get-CocopilotLogMarker), [System.StringComparison]::Ordinal)) {
                return [pscustomobject]@{ State = "Foreign"; Reason = "session.log.md lacks the cocopilot log marker" }
            }
        }
        default { throw "Get-CocopilotMailboxFileCheck: no content check is defined for '$name'." }
    }
    return [pscustomobject]@{ State = "Cocopilot"; Reason = $null }
}

function Test-IsCocopilotInstall {
    <#
    .SYNOPSIS
        True when $Path is the running cocopilot install $CocopilotRoot,
        by path or through an alias (junction, symlink, subst or mapped
        drive). A separate clone or worktree of cocopilot is not the
        install, so it can be a pairing target.

    .DESCRIPTION
        A path compare misses aliases, so a uniquely named probe file is
        written to the install root and looked up under $Path. The probe is
        git-ignored and always removed. If the probe cannot be written (a
        read-only install), only the path compare applies.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CocopilotRoot
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [System.IO.Path]::GetFullPath($CocopilotRoot).TrimEnd('\', '/')
    if ($fullPath -ieq $fullRoot) { return $true }

    $probeName = ".cocopilot-identity-{0}.tmp" -f [Guid]::NewGuid().ToString("N")
    $probePath = Join-Path $fullRoot $probeName
    try {
        [System.IO.File]::WriteAllText($probePath, "")
    } catch {
        return $false
    }
    try {
        return (Test-Path -LiteralPath (Join-Path $fullPath $probeName) -PathType Leaf)
    } finally {
        # [IO.File]::Delete, not Remove-Item: a caller's -WhatIf must never
        # leave the probe behind.
        [System.IO.File]::Delete($probePath)
    }
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
