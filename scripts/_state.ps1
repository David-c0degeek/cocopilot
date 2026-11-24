#Requires -Version 7.4

<#
.SYNOPSIS
    Where a target's mailbox lives: canonical paths, the state root, pair
    ids and the validated mailbox directory outside the target.
    _common.ps1 dot-sources this file; don't run it directly.
#>

function Get-CocopilotCanonicalPath {
    <#
    .SYNOPSIS
        The physical path of $Path, read-only: junctions, symbolic links,
        subst drives and letter case resolve to the real location.

    .DESCRIPTION
        The nearest existing ancestor (or the path itself) is opened without
        any access right and asked for its final path; the missing
        components below it are appended unchanged. Nothing is created.
        "\\?\" and "\\?\UNC\" prefixes are removed, and trailing separators
        are trimmed, except for a drive root ("C:\"). A UNC share root reads
        "\\server\share".
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not ("Cocopilot.NativePath" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Cocopilot {
    public static class NativePath {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint size, uint flags);

        public static string GetFinalPath(string path) {
            // Access 0, share read|write|delete, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS (directories too).
            using (SafeFileHandle handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                StringBuilder buffer = new StringBuilder(1024);
                uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length >= buffer.Capacity) {
                    buffer = new StringBuilder((int)length + 1);
                    length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                }
                if (length == 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return buffer.ToString(0, (int)length);
            }
        }
    }
}
"@
    }

    # Relative to PowerShell's location, not the process directory.
    $fullPath = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $existing = $fullPath
    $missing = [System.Collections.Generic.List[string]]::new()
    while (-not ([System.IO.Directory]::Exists($existing) -or [System.IO.File]::Exists($existing))) {
        $parent = [System.IO.Path]::GetDirectoryName($existing)
        if ([string]::IsNullOrEmpty($parent)) {
            throw "Cannot resolve '$Path': not even its root '$existing' exists."
        }
        $missing.Insert(0, [System.IO.Path]::GetFileName($existing))
        $existing = $parent
    }

    try {
        $final = [Cocopilot.NativePath]::GetFinalPath($existing)
    } catch {
        throw "Cannot resolve the physical path of '$existing': $((Get-CocopilotInnerException -Exception $_.Exception).Message)"
    }
    if ($final.StartsWith("\\?\UNC\", [System.StringComparison]::OrdinalIgnoreCase)) {
        $final = "\\" + $final.Substring(8)
    } elseif ($final.StartsWith("\\?\", [System.StringComparison]::Ordinal)) {
        $final = $final.Substring(4)
    }
    foreach ($component in $missing) { $final = [System.IO.Path]::Join($final, $component) }

    $trimmed = [System.IO.Path]::GetFullPath($final).TrimEnd('\', '/')
    if ($trimmed -match '^[A-Za-z]:$') { return "$trimmed\" }
    return $trimmed
}

function Get-CocopilotStateRoot {
    <#
    .SYNOPSIS
        The canonical folder that holds every pair's mailbox:
        $env:COCOPILOT_STATE_HOME when set, else %LOCALAPPDATA%\cocopilot.
        A state root reached through a junction or symbolic link resolves to
        its real location, so every alias shares one store.
        A relative COCOPILOT_STATE_HOME is refused: the current directory
        would then pick a different store per caller.
    #>
    $configured = $env:COCOPILOT_STATE_HOME
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (-not [System.IO.Path]::IsPathFullyQualified($configured)) {
            throw "COCOPILOT_STATE_HOME must be an absolute path such as 'D:\cocopilot-state', but it is '$configured'."
        }
        return Get-CocopilotCanonicalPath -Path $configured
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw "Neither COCOPILOT_STATE_HOME nor LOCALAPPDATA is set, so cocopilot cannot locate its state folder."
    }
    return Get-CocopilotCanonicalPath -Path ([System.IO.Path]::Join($env:LOCALAPPDATA, "cocopilot"))
}

function Get-CocopilotPairId {
    <#
    .SYNOPSIS
        The pair directory name for a canonical target:
        "<leaf>-<16 lowercase hex>". The hex is the start of the SHA-256 of
        the upper-cased target (UTF-8), so letter case never splits a pair.
        The leaf keeps only [A-Za-z0-9._-] (others become "_"), at most 40
        characters, and reads "root" for a drive or share root.
    #>
    param([Parameter(Mandatory)][string]$CanonicalTarget)

    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($CanonicalTarget.ToUpperInvariant()))
    $hex = [Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant()

    $root = [System.IO.Path]::GetPathRoot($CanonicalTarget)
    if ($CanonicalTarget.TrimEnd('\', '/') -ieq ([string]$root).TrimEnd('\', '/')) {
        $leaf = "root"
    } else {
        # [regex]::Replace is case-sensitive, so [A-Za-z] stays ASCII-only.
        $leaf = [regex]::Replace([System.IO.Path]::GetFileName($CanonicalTarget), '[^A-Za-z0-9._-]', '_')
        if ($leaf.Length -gt 40) { $leaf = $leaf.Substring(0, 40) }
    }
    return "$leaf-$hex"
}

function Get-CocopilotMailboxDir {
    <#
    .SYNOPSIS
        The mailbox directory for $RepoPath: <StateRoot>\pairs\<pair-id>.
        Resolves only; it checks and creates nothing. Runtime scripts use
        Open-CocopilotMailbox instead.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    $target = Get-CocopilotCanonicalPath -Path $RepoPath
    $stateRoot = Get-CocopilotStateRoot
    return [System.IO.Path]::Join($stateRoot, "pairs", (Get-CocopilotPairId -CanonicalTarget $target))
}

function Test-CocopilotPathWithin {
    <#
    .SYNOPSIS
        True when $Path is $Root or lies below it, compared canonically,
        case-insensitively and on whole path segments: C:\a\b is within
        C:\a, C:\ab is not.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $canonicalPath = Get-CocopilotCanonicalPath -Path $Path
    $canonicalRoot = Get-CocopilotCanonicalPath -Path $Root
    if ($canonicalPath -ieq $canonicalRoot) { return $true }
    $prefix = if ($canonicalRoot.EndsWith("\")) { $canonicalRoot } else { "$canonicalRoot\" }
    return $canonicalPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-CocopilotReparsePoint {
    # True when $Path exists and is a symbolic link, junction or mount point.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ([System.IO.File]::GetAttributes($Path)).HasFlag([System.IO.FileAttributes]::ReparsePoint)
}

function Read-CocopilotPairTarget {
    <#
    .SYNOPSIS
        The target recorded in a pair directory's target.json, or $null when
        the file is missing. A file that is unreadable or lacks a target
        throws.
    #>
    param([Parameter(Mandatory)][string]$MailboxDir)

    $path = Join-Path $MailboxDir "target.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $record = Read-CocopilotSharedText -Path $path | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Cannot read '$path': $($_.Exception.Message)"
    }
    if ($record -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $record.PSObject.Properties["target"] -or
        [string]::IsNullOrWhiteSpace([string]$record.target)) {
        throw "'$path' does not name a target."
    }
    return [string]$record.target
}

function Test-CocopilotSameTarget {
    <#
    .SYNOPSIS
        True when a target recorded in a mailbox file is $CanonicalTarget.
        Recorded targets are canonical; one that cannot be resolved any more
        (its drive is gone) is compared as written.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RecordedTarget,
        [Parameter(Mandatory)][string]$CanonicalTarget
    )

    if ([string]::IsNullOrWhiteSpace($RecordedTarget)) { return $false }
    if ($RecordedTarget -ieq $CanonicalTarget) { return $true }
    try {
        return (Get-CocopilotCanonicalPath -Path $RecordedTarget) -ieq $CanonicalTarget
    } catch {
        return $false
    }
}

function Get-CocopilotStateRootSkipPath {
    <#
    .SYNOPSIS
        The state root's path relative to the target, with "/" separators,
        when the state root lies strictly inside the target; otherwise
        $null. The workspace fingerprint skips exactly that subtree.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    $target = Get-CocopilotCanonicalPath -Path $RepoPath
    $stateRoot = Get-CocopilotStateRoot
    if ($stateRoot -ieq $target -or -not (Test-CocopilotPathWithin -Path $stateRoot -Root $target)) { return $null }
    return [System.IO.Path]::GetRelativePath($target, $stateRoot).Replace('\', '/')
}

function Open-CocopilotMailbox {
    <#
    .SYNOPSIS
        Validates and returns the mailbox directory for $RepoPath. Runtime
        scripts get the mailbox directory only through this function.

    .DESCRIPTION
        Every check runs before anything reads or writes the mailbox:
        - the state root must not be, or contain, the target;
        - the state root's "pairs" folder and the pair directory must not
          be reparse points (symbolic links, junctions, mount points). The
          state root itself is canonical: one the user reaches through a
          link was already followed once to its single real location;
        - the target must not hold a cocopilot mailbox in <RepoPath>\.mailbox
          from an older cocopilot;
        - unless -ForInit, the pair directory must exist and its target.json
          must name this target. A pair directory of another target is never
          adopted.
        With -ForInit the directory may still be missing; init-mailbox.ps1
        checks its content itself.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$ForInit
    )

    $target = Get-CocopilotCanonicalPath -Path $RepoPath
    $stateRoot = Get-CocopilotStateRoot
    if (Test-CocopilotPathWithin -Path $target -Root $stateRoot) {
        throw ("The cocopilot state folder '$stateRoot' is or contains the target '$target', so the mailbox would be part " +
            "of the work it coordinates. Set COCOPILOT_STATE_HOME to an absolute folder outside the target.")
    }

    $pairsDir = [System.IO.Path]::Join($stateRoot, "pairs")
    $mailboxDir = [System.IO.Path]::Join($pairsDir, (Get-CocopilotPairId -CanonicalTarget $target))
    foreach ($component in @($pairsDir, $mailboxDir)) {
        if (Test-CocopilotReparsePoint -Path $component) {
            throw "'$component' is a reparse point (symbolic link, junction or mount point); cocopilot never creates its state that way and refuses to use it."
        }
    }

    $legacyDir = Join-Path $target ".mailbox"
    if ((Test-Path -LiteralPath $legacyDir -PathType Container) -and (Get-CocopilotMailboxState -Path $legacyDir).State -eq "Cocopilot") {
        throw ("'$target' has a legacy in-repo mailbox at '$legacyDir'; stop both agents and run init-mailbox.ps1 " +
            "-MigrateLegacy -AgentsStopped, or discard it with cleanup-mailbox.ps1.")
    }

    if ($ForInit) { return $mailboxDir }

    if (-not (Test-Path -LiteralPath $mailboxDir -PathType Container)) {
        $initCommand = Get-CocopilotInitCommand -RepoPath $target -InitScript (Join-Path $PSScriptRoot "init-mailbox.ps1")
        throw "There is no cocopilot mailbox for '$target' (expected '$mailboxDir'); run init-mailbox.ps1 first: $initCommand"
    }
    $recorded = Read-CocopilotPairTarget -MailboxDir $mailboxDir
    if ($null -eq $recorded) {
        $initCommand = Get-CocopilotInitCommand -RepoPath $target -InitScript (Join-Path $PSScriptRoot "init-mailbox.ps1")
        throw "There is no cocopilot mailbox for '$target': '$mailboxDir' has no target.json; run init-mailbox.ps1 first: $initCommand"
    }
    if ($recorded -ine $target) {
        throw ("The mailbox '$mailboxDir' belongs to '$recorded', not to '$target'; refusing to use it. Remove or " +
            "rename that directory only if you are sure it is stale.")
    }
    return $mailboxDir
}

function Get-CocopilotStagingPattern {
    # The name of a migration staging directory of $PairId in <state root>\pairs.
    param([Parameter(Mandatory)][string]$PairId)
    return '^\.' + [regex]::Escape($PairId) + '\.migrating-[0-9a-f]{32}$'
}

function Get-CocopilotFileSnapshot {
    <#
    .SYNOPSIS
        Name -> "<length> <SHA-256>" for every file directly in $Directory,
        in ordinal name order.
    #>
    param([Parameter(Mandatory)][string]$Directory)

    $snapshot = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Force -File)) {
        $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($file.FullName))).ToLowerInvariant()
        $snapshot[$file.Name] = "$($file.Length) $hash"
    }
    return $snapshot
}

function Compare-CocopilotFileSnapshot {
    # The names whose entry differs between two snapshots, or that only one has.
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)

    $names = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Before.Keys) { $null = $names.Add($key) }
    foreach ($key in $After.Keys) { $null = $names.Add($key) }
    return @($names | Where-Object { -not ($Before.ContainsKey($_) -and $After.ContainsKey($_) -and $Before[$_] -ceq $After[$_]) })
}

function Wait-CocopilotQuiescence {
    # The pause between the two snapshots of a legacy mailbox.
    param([Parameter(Mandatory)][int]$Seconds)
    if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds }
}

function Get-CocopilotStagingForeignEntries {
    <#
    .SYNOPSIS
        The entries of a migration staging directory that cocopilot would
        never put there: anything but a regular, non-reparse file named like
        a mailbox file (see Test-CocopilotMailboxEntryName), the marker
        migration.json, or a writer temp of that marker.
    #>
    param([Parameter(Mandatory)][string]$Path)

    return @(Get-ChildItem -LiteralPath $Path -Force | Where-Object {
            $isFile = $_ -is [System.IO.FileInfo] -and -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            $isOurs = (Test-CocopilotMailboxEntryName -Name $_.Name) -or $_.Name -ceq "migration.json" -or
                $_.Name -cmatch '^\.migration\.json\.[0-9a-f]{32}\.tmp$'
            -not ($isFile -and $isOurs)
        } | ForEach-Object Name)
}

function Remove-CocopilotStagingDirectory {
    <#
    .SYNOPSIS
        Deletes a migration staging directory file by file, then the empty
        directory - only when every entry is one cocopilot puts there (see
        Get-CocopilotStagingForeignEntries). Otherwise it throws and deletes
        nothing.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (Test-CocopilotReparsePoint -Path $Path) {
        throw "The migration staging '$Path' is a reparse point; refusing to delete through it. Nothing was changed."
    }
    $foreign = @(Get-CocopilotStagingForeignEntries -Path $Path)
    if ($foreign.Count -gt 0) {
        throw ("The migration staging '$Path' holds entries cocopilot does not create there ($($foreign -join ', ')); " +
            "refusing to delete it. Move them out by hand, then run the command again. Nothing was changed.")
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Force -File)) { Remove-Item -LiteralPath $file.FullName -Force }
    [System.IO.Directory]::Delete($Path, $false)
}

function Move-CocopilotLegacyMailbox {
    <#
    .SYNOPSIS
        Moves a legacy in-repo cocopilot mailbox (<RepoPath>\.mailbox) into
        the target's pair directory without changing a byte. See
        init-mailbox.ps1 -MigrateLegacy.

    .DESCRIPTION
        Holds ".<pair-id>.migrate.lock" in <state root>\pairs for the whole
        run. Every refusal before the publish changes nothing in the
        target. The copy is staged in ".<pair-id>.migrating-<guid>",
        verified, and published with one directory rename; a pair directory
        that already exists is only accepted as an earlier publish of these
        very files (a resumed run). Each original is deleted only after all
        remaining originals matched their published copies.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [ValidateRange(0, 600)][int]$QuiescenceSeconds = 5
    )

    $target = Get-CocopilotCanonicalPath -Path $RepoPath
    $stateRoot = Get-CocopilotStateRoot
    if (Test-CocopilotPathWithin -Path $target -Root $stateRoot) {
        throw ("The cocopilot state folder '$stateRoot' is or contains the target '$target'. Set COCOPILOT_STATE_HOME " +
            "to an absolute folder outside the target. Nothing was changed.")
    }
    $pairId = Get-CocopilotPairId -CanonicalTarget $target
    $pairsDir = [System.IO.Path]::Join($stateRoot, "pairs")
    $pairDir = [System.IO.Path]::Join($pairsDir, $pairId)
    $legacyDir = Join-Path $target ".mailbox"

    # Preconditions: nothing below changes anything.
    if (-not (Test-Path -LiteralPath $legacyDir -PathType Container)) {
        throw "'$target' has no legacy in-repo mailbox at '$legacyDir' to migrate. Nothing was changed."
    }
    if (Test-CocopilotReparsePoint -Path $legacyDir) {
        throw "'$legacyDir' is a reparse point (symbolic link, junction or mount point); refusing to migrate through it. Nothing was changed."
    }
    # A resumed run may already have deleted the anchor files; there the
    # comparison with the published copies below is the proof instead.
    $state = Get-CocopilotMailboxState -Path $legacyDir
    if ($state.State -ne "Cocopilot" -and -not (Test-Path -LiteralPath $pairDir)) {
        throw "'$legacyDir' is not a cocopilot mailbox ($($state.State): $($state.Reason)); refusing to migrate it. Nothing was changed."
    }
    if (Test-CocopilotGitRepository -Path $target) {
        $tracked = @(Get-CocopilotTrackedMailboxPaths -RepoPath $target)
        if ($tracked.Count -gt 0) {
            throw ("git tracks files under .mailbox/ in '$target' ($($tracked -join ', ')); refusing to migrate them. " +
                "Untrack them first (git rm -r --cached -- .mailbox) and commit. Nothing was changed.")
        }
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $legacyDir -Force)) {
        $isOurs = (Test-CocopilotMailboxEntryName -Name $entry.Name) -and $entry.Name -ne "target.json"
        if (-not $isOurs -or $entry -isnot [System.IO.FileInfo] -or $entry.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            throw "'$($entry.FullName)' is not a regular file cocopilot creates; refusing to migrate '$legacyDir'. Nothing was changed."
        }
    }
    foreach ($lockName in @("implementer.lock", "sessions.lock")) {
        if (Test-Path -LiteralPath (Join-Path $legacyDir $lockName)) {
            throw "'$legacyDir' holds $lockName, so an agent or a handoff is still active. Stop both agents first. Nothing was changed."
        }
    }
    foreach ($component in @($pairsDir, $pairDir)) {
        if (Test-CocopilotReparsePoint -Path $component) {
            throw "'$component' is a reparse point (symbolic link, junction or mount point); refusing to migrate into it. Nothing was changed."
        }
    }

    [System.IO.Directory]::CreateDirectory($pairsDir) | Out-Null
    if (Test-CocopilotReparsePoint -Path $pairsDir) {
        throw "'$pairsDir' is a reparse point (symbolic link, junction or mount point); refusing to migrate into it. Nothing was changed."
    }
    $lock = Enter-CocopilotMailboxLock -LockPath ([System.IO.Path]::Join($pairsDir, ".$pairId.migrate.lock")) -Purpose "migration" -RetryMilliseconds 0
    # The staging this run created, until its publish rename; a failure
    # before that removes it (and never another run's).
    $ownStaging = $null
    try {
        $snapshot = Get-CocopilotFileSnapshot -Directory $legacyDir
        Wait-CocopilotQuiescence -Seconds $QuiescenceSeconds
        $changed = @(Compare-CocopilotFileSnapshot -Before $snapshot -After (Get-CocopilotFileSnapshot -Directory $legacyDir))
        if ($changed.Count -gt 0) {
            throw "Agents still writing: $($changed -join ', ') in '$legacyDir' changed while it was checked. Stop both agents first. Nothing was changed."
        }

        $resumed = Test-Path -LiteralPath $pairDir
        if ($resumed) {
            try {
                $recorded = Read-CocopilotPairTarget -MailboxDir $pairDir
            } catch {
                throw "'$pairDir' already exists with an unreadable target.json ($($_.Exception.Message)); refusing to merge into it. Nothing was changed."
            }
            if ($recorded -ine $target) {
                throw "'$pairDir' already exists and does not record '$target' as its target; refusing to merge into it. Nothing was changed."
            }
            $published = Get-CocopilotFileSnapshot -Directory $pairDir
            $different = @($snapshot.Keys | Where-Object { -not $published.ContainsKey($_) -or $published[$_] -cne $snapshot[$_] })
            if ($different.Count -gt 0) {
                throw ("'$pairDir' already exists and differs from the legacy mailbox ($($different -join ', ')); cocopilot never " +
                    "merges two mailboxes. Keep one: discard the legacy one with cleanup-mailbox.ps1, or remove the pair " +
                    "directory with cleanup-mailbox.ps1 -PairId $pairId. Nothing was changed.")
            }
        } else {
            $stagingPattern = Get-CocopilotStagingPattern -PairId $pairId
            foreach ($stale in @(Get-ChildItem -LiteralPath $pairsDir -Force -Directory | Where-Object { $_.Name -cmatch $stagingPattern })) {
                if ($stale.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                    throw ("The stale migration staging '$($stale.FullName)' is a reparse point (symbolic link, junction or " +
                        "mount point); cocopilot never creates one and does not touch it. Remove it by hand. Nothing was changed.")
                }
                $markerPath = Join-Path $stale.FullName "migration.json"
                try {
                    $marker = Read-CocopilotSharedText -Path $markerPath | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    continue
                }
                if ([string]$marker.target -ieq $target) {
                    Remove-CocopilotStagingDirectory -Path $stale.FullName
                    Write-Host "Removed the stale migration staging '$($stale.FullName)'." -ForegroundColor Yellow
                }
            }

            $staging = [System.IO.Path]::Join($pairsDir, ".$pairId.migrating-$([Guid]::NewGuid().ToString('N'))")
            [System.IO.Directory]::CreateDirectory($staging) | Out-Null
            $ownStaging = $staging
            $markerPath = Join-Path $staging "migration.json"
            Write-MailboxJson -Path $markerPath -Object ([ordered]@{ target = $target; source = $legacyDir })
            foreach ($name in $snapshot.Keys) {
                [System.IO.File]::Copy((Join-Path $legacyDir $name), (Join-Path $staging $name), $false)
            }
            $markerSnapshot = Get-CocopilotFileSnapshot -Directory $staging
            $null = $markerSnapshot.Remove("migration.json")
            $copyErrors = @(Compare-CocopilotFileSnapshot -Before $snapshot -After $markerSnapshot)
            if ($copyErrors.Count -gt 0) {
                throw "The staged copy in '$staging' does not match the legacy mailbox ($($copyErrors -join ', ')). The target was not changed."
            }
            Write-MailboxJson -Path (Join-Path $staging "target.json") -Object ([ordered]@{
                    target     = $target
                    createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
                })
            $changed = @(Compare-CocopilotFileSnapshot -Before $snapshot -After (Get-CocopilotFileSnapshot -Directory $legacyDir))
            if ($changed.Count -gt 0) {
                throw "Agents still writing: $($changed -join ', ') in '$legacyDir' changed during the copy. Stop both agents first. The target was not changed."
            }
            # The marker only identifies the staging; the published mailbox
            # holds cocopilot's own file names only.
            Remove-Item -LiteralPath $markerPath -Force
            [System.IO.Directory]::Move($staging, $pairDir)
            $ownStaging = $null
            Write-Host "Published the migrated mailbox at $pairDir" -ForegroundColor Green
        }

        # Commit point passed: from here the published copy is the mailbox.
        $remaining = Get-CocopilotFileSnapshot -Directory $legacyDir
        $published = Get-CocopilotFileSnapshot -Directory $pairDir
        $mismatched = @($remaining.Keys | Where-Object { -not $published.ContainsKey($_) -or $published[$_] -cne $remaining[$_] })
        if ($mismatched.Count -gt 0) {
            throw ("These legacy files differ from their published copies in '$pairDir': $($mismatched -join ', '). " +
                "Nothing was deleted; compare them by hand, then remove the legacy mailbox with cleanup-mailbox.ps1.")
        }
        # The anchors go last, so an interrupted run still finds a cocopilot
        # mailbox for as long as possible.
        $anchors = @("implementer.json", "session.log.md")
        $deleteOrder = @($remaining.Keys | Where-Object { $_ -notin $anchors }) + @($remaining.Keys | Where-Object { $_ -in $anchors })
        foreach ($name in $deleteOrder) { Remove-Item -LiteralPath (Join-Path $legacyDir $name) -Force }
    } finally {
        if ($null -ne $ownStaging -and (Test-Path -LiteralPath $ownStaging)) {
            try {
                Remove-CocopilotStagingDirectory -Path $ownStaging
            } catch {
                Write-Warning "Could not remove this run's migration staging '$ownStaging': $($_.Exception.Message)"
            }
        }
        $lock.Dispose()
    }

    if ((Test-CocopilotGitRepository -Path $target) -and (Remove-CocopilotMailboxExcludeRule -RepoPath $target)) {
        Write-Host "Removed cocopilot's .mailbox/ rule from the repository's git exclude file." -ForegroundColor Green
    }
    $leftovers = @(Get-ChildItem -LiteralPath $legacyDir -Force)
    if ($leftovers.Count -eq 0) {
        Remove-Item -LiteralPath $legacyDir -Force
    } else {
        Write-Warning "Kept '$legacyDir': it still holds $($leftovers.Name -join ', ')."
    }

    $resumeNote = if ($resumed) { " (completed an earlier, interrupted migration)" } else { "" }
    Write-Host "Migrated the mailbox of $target to $pairDir$resumeNote. Every file was moved unchanged." -ForegroundColor Green
    Write-Host ("A direct-transport pair must resume its registered sessions (copilot --resume <id>, ids in " +
        "$pairDir\sessions.json) or be relaunched with start-agents.ps1; never paste a prompt into a fresh window.") -ForegroundColor Yellow
}
