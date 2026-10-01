#Requires -Version 7.4

<#
.SYNOPSIS
    File, quoting and process helpers that the other helper files build on:
    quoting, UTC stamps, sharing checks, atomic and shared file I/O, text
    files and the UTF-8 git runner. _common.ps1 dot-sources this file;
    don't run it directly.
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
