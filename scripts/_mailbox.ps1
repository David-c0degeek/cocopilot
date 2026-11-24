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
        The fixed file names cocopilot creates inside a mailbox directory
        (the pair directory, or a legacy in-repo .mailbox/).
        With the baseline files and writer temps (see
        Test-CocopilotMailboxEntryName) they are the only entries
        cleanup-mailbox.ps1 ever deletes there.
    #>
    return @(
        "implementer.json", "agent-a.md", "agent-b.md", "session.log.md",
        "agent-a.cursor", "agent-b.cursor", "verify-request.md", "implementer.lock",
        "sessions.json", "sessions.lock", "target.json"
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
    # True for every name cocopilot itself creates inside a mailbox directory.
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
            if (-not (Test-CocopilotOwnershipRecordShape -Record $record)) {
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

function Test-CocopilotOwnershipRecordShape {
    <#
    .SYNOPSIS
        True when a parsed implementer.json is an ownership record: integer
        epoch >= 1, state active|offered, owner agent-a|agent-b.
    #>
    param([AllowNull()]$Record)

    if ($Record -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    # Property checks first, via the indexer (which returns $null): a caller
    # running Set-StrictMode -Version Latest would otherwise turn a missing
    # property into a throw.
    $properties = $Record.PSObject.Properties
    if ($null -eq $properties["epoch"] -or $null -eq $properties["state"] -or $null -eq $properties["owner"]) { return $false }
    $epoch = $Record.epoch
    return ($epoch -is [int] -or $epoch -is [long]) -and $epoch -ge 1 -and
        ($Record.state -cin @("active", "offered")) -and
        ($Record.owner -cin @("agent-a", "agent-b"))
}

function ConvertFrom-CocopilotOwnershipRecord {
    <#
    .SYNOPSIS
        Parses implementer.json text that was already read, and returns the
        record. Throws when it is not valid JSON or not an ownership record
        (see Test-CocopilotOwnershipRecordShape); never fills in defaults.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Path
    )

    $pairDir = Split-Path -Parent $Path
    $restore = ("No file was changed. Inspect implementer.json in the pair directory '$pairDir'. Restore it from a " +
        "backup if you have one. Otherwise use the last HANDOFF_OFFER and HANDOFF_ACCEPT entries in its session.log.md " +
        "only as evidence for a manual recovery decision by the user; do not reconstruct a record from them " +
        "automatically, because they are not a full saved record. A reset (init-mailbox.ps1 -Force) or a cleanup " +
        "(cleanup-mailbox.ps1) applies only once the record is valid again.")
    try {
        $record = ConvertFrom-Json -InputObject $Text -NoEnumerate -ErrorAction Stop
    } catch {
        throw "The ownership record '$Path' is not valid JSON ($($_.Exception.Message)). $restore"
    }
    if (-not (Test-CocopilotOwnershipRecordShape -Record $record)) {
        throw ("The ownership record '$Path' is not a cocopilot ownership record: it needs an integer epoch >= 1, " +
            "state active or offered, and owner agent-a or agent-b. $restore")
    }
    return $record
}

function Format-CocopilotOwnershipLine {
    <#
    .SYNOPSIS
        One compact line that summarizes a validated ownership record:
        "OWNERSHIP (<label>): epoch=.. state=.. owner=.. from=.. to=..
        model=.. manifest=<count> head=<12 chars> baseline=<8 chars|none>".

    .DESCRIPTION
        Every value goes through ConvertTo-CocopilotLineValue, so no value can
        break the line or forge another output line. head and baseline are
        shortened for display only; the full values stay in implementer.json.
    #>
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][ValidateSet("changed", "unchanged", "current")][string]$Label
    )

    $properties = $Record.PSObject.Properties
    $from = if ($null -ne $properties["from"] -and $null -ne $Record.from) { [string]$Record.from } else { "none" }
    $to = if ($null -ne $properties["to"] -and $null -ne $Record.to) { [string]$Record.to } else { "none" }
    $model = if ($null -ne $properties["owner_model"] -and $null -ne $Record.owner_model) { [string]$Record.owner_model } else { "none" }
    $manifest = if ($null -ne $properties["dirty_manifest"]) { @($Record.dirty_manifest | Where-Object { $null -ne $_ }).Count } else { 0 }
    $head = "none"
    if ($null -ne $properties["head"] -and $null -ne $Record.head) {
        $fullHead = [string]$Record.head
        $head = $fullHead.Substring(0, [Math]::Min(12, $fullHead.Length))
    }
    $baseline = "none"
    if ($null -ne $properties["baseline"] -and $Record.baseline -is [System.Management.Automation.PSCustomObject] -and
        $null -ne $Record.baseline.PSObject.Properties["id"] -and $null -ne $Record.baseline.id) {
        $id = [string]$Record.baseline.id
        $baseline = $id.Substring(0, [Math]::Min(8, $id.Length))
    }

    $fields = [ordered]@{
        epoch = [string]$Record.epoch; state = [string]$Record.state; owner = [string]$Record.owner
        from = $from; to = $to; model = $model; manifest = [string]$manifest; head = $head; baseline = $baseline
    }
    $pairs = foreach ($key in $fields.Keys) { "$key=$(ConvertTo-CocopilotLineValue -Value $fields[$key])" }
    return "OWNERSHIP (${Label}): $($pairs -join ' ')"
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
