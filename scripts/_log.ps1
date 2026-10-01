#Requires -Version 7.4

<#
.SYNOPSIS
    Session log framing, appends, entry parsing, generations and delivery
    cursors. _common.ps1 dot-sources this file; don't run it directly.
#>

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
