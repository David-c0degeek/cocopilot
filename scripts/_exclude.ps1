#Requires -Version 7.4

<#
.SYNOPSIS
    The git-local exclude rule that keeps a target's .mailbox/ out of git.
    _common.ps1 dot-sources this file; don't run it directly.
#>

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
