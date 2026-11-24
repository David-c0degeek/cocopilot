#Requires -Version 7.4

<#
.SYNOPSIS
    Direct-transport helpers: the pair registration in the mailbox's sessions.json,
    the Copilot CLI settings preflight, and the peer notification that
    write-lane.ps1 prints. _common.ps1 dot-sources this file; don't run it
    directly.

.DESCRIPTION
    Direct transport only replaces how an agent is woken. The durable mailbox
    (session log, cursors, ACK tokens, ownership record, verifier pin) stays
    the single source of truth in both transports. A native peer message is a
    wake hint that names no content: the receiver always drains the log with
    its own trusted read command.

    The registration never stores or reads the CLI's own session registry or
    its tokens, and nothing here calls the CLI's private RPC. The agent sends
    the hint itself with the send_session_message tool.
#>

function Get-CocopilotSessionRegistrationPath {
    param([Parameter(Mandatory)][string]$MailboxDir)
    return Join-Path $MailboxDir "sessions.json"
}

function Enter-CocopilotRegistrationLock {
    <#
    .SYNOPSIS
        Takes the registration lock (sessions.lock) that serialises every
        read-modify-write of sessions.json; dispose the handle to release it.
    #>
    param(
        [Parameter(Mandatory)][string]$MailboxDir,
        [ValidateRange(0, 60000)][int]$RetryMilliseconds = 10000
    )

    return Enter-CocopilotMailboxLock -LockPath (Join-Path $MailboxDir "sessions.lock") -Purpose "session registration" -RetryMilliseconds $RetryMilliseconds
}

function Get-CocopilotConfigDir {
    <#
    .SYNOPSIS
        The Copilot CLI configuration directory this process would use:
        $env:COPILOT_HOME when set, else ~/.copilot. Native peer messaging
        only reaches sessions that share it.
    #>
    $configured = $env:COPILOT_HOME
    $path = if ([string]::IsNullOrWhiteSpace($configured)) {
        Join-Path ([Environment]::GetFolderPath("UserProfile")) ".copilot"
    } else {
        $configured
    }
    return [System.IO.Path]::GetFullPath($path).TrimEnd('\', '/')
}

function Read-CocopilotSessionRegistration {
    <#
    .SYNOPSIS
        Reads sessions.json. Returns State "None" when it is absent (mailbox
        transport), "Valid" with the parsed record, or "Invalid" with a
        reason. Never throws on bad content: a damaged registration must
        not block a lane write that has already been committed.
    #>
    param([Parameter(Mandatory)][string]$MailboxDir)

    $path = Get-CocopilotSessionRegistrationPath -MailboxDir $MailboxDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ State = "None"; Reason = $null; Record = $null }
    }
    try {
        $record = Read-CocopilotSharedText -Path $path | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ State = "Invalid"; Reason = "it could not be read as JSON: $($_.Exception.Message)"; Record = $null }
    }
    if ($null -eq $record -or $record.transport -ne "direct") {
        return [pscustomobject]@{ State = "Invalid"; Reason = "its transport is not 'direct'"; Record = $null }
    }
    if ([string]::IsNullOrWhiteSpace($record.target) -or [string]::IsNullOrWhiteSpace($record.configDir) -or $null -eq $record.agents) {
        return [pscustomobject]@{ State = "Invalid"; Reason = "it lacks target, configDir or agents"; Record = $null }
    }
    return [pscustomobject]@{ State = "Valid"; Reason = $null; Record = $record }
}

function Set-CocopilotSessionRegistration {
    <#
    .SYNOPSIS
        Registers the native session of one or both agents for direct
        transport, under the registration lock.

    .DESCRIPTION
        A role not passed in -Agents keeps its existing registration, but only
        when the existing record belongs to the same target and configuration
        directory; otherwise it is dropped. The record is replaced whole, so a
        reader sees the old or the new registration, never a partial one.
    #>
    param(
        [Parameter(Mandatory)][string]$MailboxDir,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ConfigDir,
        # role ("agent-a"/"agent-b") -> @{ SessionId = <guid>; Name = <session name> }
        [Parameter(Mandatory)][hashtable]$Agents
    )

    foreach ($role in $Agents.Keys) {
        if ($role -notin @("agent-a", "agent-b")) { throw "Unknown role '$role' in a session registration." }
        $sessionId = [string]$Agents[$role].SessionId
        $parsed = [Guid]::Empty
        if (-not [Guid]::TryParse($sessionId, [ref]$parsed)) { throw "Session id '$sessionId' for $role is not a GUID." }
    }

    # The target's identity is its canonical path, so every alias of it
    # (junction, subst drive, letter case) reads the same registration.
    $target = Get-CocopilotCanonicalPath -Path $RepoPath
    $lock = Enter-CocopilotRegistrationLock -MailboxDir $MailboxDir
    try {
        $existing = Read-CocopilotSessionRegistration -MailboxDir $MailboxDir
        $registered = [ordered]@{}
        foreach ($role in @("agent-a", "agent-b")) {
            if ($Agents.ContainsKey($role)) {
                $registered[$role] = [ordered]@{
                    sessionId     = ([Guid]$Agents[$role].SessionId).ToString()
                    name          = [string]$Agents[$role].Name
                    registeredUtc = Get-CocopilotUtcStamp
                }
                continue
            }
            $keep = $existing.State -eq "Valid" -and
                (Test-CocopilotSameTarget -RecordedTarget $existing.Record.target -CanonicalTarget $target) -and
                $existing.Record.configDir -ieq $ConfigDir -and
                $null -ne $existing.Record.agents.$role
            if ($keep) { $registered[$role] = $existing.Record.agents.$role }
        }
        $record = [ordered]@{ transport = "direct"; target = $target; configDir = $ConfigDir; agents = $registered }
        Write-MailboxJson -Path (Get-CocopilotSessionRegistrationPath -MailboxDir $MailboxDir) -Object $record
    } finally {
        $lock.Dispose()
    }
}

function Remove-CocopilotSessionRegistration {
    <#
    .SYNOPSIS
        Removes sessions.json under the registration lock, so a mailbox-
        transport launch never keeps producing direct notifications from a
        stale registration. Returns $true when a file was removed.
    #>
    param([Parameter(Mandatory)][string]$MailboxDir)

    $path = Get-CocopilotSessionRegistrationPath -MailboxDir $MailboxDir
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $lock = Enter-CocopilotRegistrationLock -MailboxDir $MailboxDir
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        Remove-Item -LiteralPath $path -Force
        return $true
    } finally {
        $lock.Dispose()
    }
}

function Get-CocopilotPeerHintText {
    <#
    .SYNOPSIS
        The fixed wake-hint text. It carries no paths, commands or content:
        the receiver must only drain the mailbox with its own banner command.
    #>
    param([Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$Role)
    return "cocopilot: new mailbox entry from $Role. Drain the mailbox with your banner's read command."
}

function Get-CocopilotPeerNotification {
    <#
    .SYNOPSIS
        Decides what write-lane.ps1 prints after a committed entry: nothing
        (State "None", mailbox transport), a send instruction for the peer's
        registered session (State "Ready"), or a warning that explains why no
        hint can be sent (State "Warning").
    #>
    param(
        [Parameter(Mandatory)][string]$MailboxDir,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$Role,
        [Parameter(Mandatory)][string]$ConfigDir
    )

    $registration = Read-CocopilotSessionRegistration -MailboxDir $MailboxDir
    if ($registration.State -eq "None") {
        return [pscustomobject]@{ State = "None"; PeerSessionId = $null; Reason = $null; Message = $null }
    }
    $warn = { param($reason) [pscustomobject]@{ State = "Warning"; PeerSessionId = $null; Reason = $reason; Message = "No direct wake hint can be sent: $reason The entry is committed; the peer reads it on its next drain." } }
    if ($registration.State -eq "Invalid") {
        return & $warn "sessions.json is invalid ($($registration.Reason))."
    }
    $record = $registration.Record
    $target = Get-CocopilotCanonicalPath -Path $RepoPath
    if (-not (Test-CocopilotSameTarget -RecordedTarget $record.target -CanonicalTarget $target)) {
        return & $warn "sessions.json belongs to target '$($record.target)', not '$target'."
    }
    if ($record.configDir -ine $ConfigDir) {
        return & $warn "sessions.json was registered for Copilot configuration directory '$($record.configDir)', but this shell uses '$ConfigDir'."
    }
    $peerRole = if ($Role -eq "agent-a") { "agent-b" } else { "agent-a" }
    $peer = $record.agents.$peerRole
    $parsed = [Guid]::Empty
    if ($null -eq $peer -or -not [Guid]::TryParse([string]$peer.sessionId, [ref]$parsed)) {
        return & $warn "$peerRole has no valid session registration."
    }
    return [pscustomobject]@{ State = "Ready"; PeerSessionId = $parsed.ToString(); Reason = $null; Message = Get-CocopilotPeerHintText -Role $Role }
}

function Get-CocopilotCliSetting {
    <#
    .SYNOPSIS
        Reads one Copilot CLI setting with `<copilot> config <key>`. Returns
        State "Set" with its value, or "Unset". Throws on any other failure.

    .DESCRIPTION
        The CLI exits 1 with no output at all for a known key that is not set;
        an unknown key or another failure also exits non-zero but writes an
        error. Standard output and standard error are captured separately, so
        an error is never mistaken for an unset key.
    #>
    param(
        [Parameter(Mandatory)][string]$CopilotCommand,
        [Parameter(Mandatory)][string]$Key
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = @(& $CopilotCommand config $Key 2>$stderrPath)
        $exitCode = $LASTEXITCODE
        $stderr = [System.IO.File]::ReadAllText($stderrPath).Trim()
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    $value = ($stdout -join "`n").Trim()
    if ($exitCode -eq 0 -and $stderr.Length -eq 0) {
        return [pscustomobject]@{ State = "Set"; Value = $value }
    }
    if ($exitCode -eq 1 -and $value.Length -eq 0 -and $stderr.Length -eq 0) {
        return [pscustomobject]@{ State = "Unset"; Value = $null }
    }
    $detail = (@($value, $stderr) | Where-Object { $_ }) -join " "
    throw "Could not read the Copilot CLI setting '$Key' with '$CopilotCommand config $Key' (exit $exitCode): $detail"
}

function Assert-CocopilotDirectTransportReady {
    <#
    .SYNOPSIS
        Throws unless the Copilot CLI settings let two independent sessions
        message each other: sessionManagementTools.enabled is true, .message
        is not false, and .scope is not in-process. Unset .message and .scope
        use the CLI's documented defaults (true and all).
    #>
    param([Parameter(Mandatory)][string]$CopilotCommand)

    $enabled = Get-CocopilotCliSetting -CopilotCommand $CopilotCommand -Key "sessionManagementTools.enabled"
    if ($enabled.State -ne "Set" -or $enabled.Value -ne "true") {
        throw ("Direct transport needs Copilot's session management tools, which are off. Turn them on with " +
            "'copilot config sessionManagementTools.enabled on' (a user-level setting: every opted-in session of this " +
            "user can then see the others), or launch with -Transport mailbox.")
    }
    $message = Get-CocopilotCliSetting -CopilotCommand $CopilotCommand -Key "sessionManagementTools.message"
    if ($message.State -eq "Set" -and $message.Value -ne "true") {
        throw "Direct transport needs send_session_message, but sessionManagementTools.message is '$($message.Value)'. Run 'copilot config sessionManagementTools.message on', or launch with -Transport mailbox."
    }
    $scope = Get-CocopilotCliSetting -CopilotCommand $CopilotCommand -Key "sessionManagementTools.scope"
    if ($scope.State -eq "Set" -and $scope.Value -ne "all") {
        throw "Direct transport needs two separate CLI processes to reach each other, but sessionManagementTools.scope is '$($scope.Value)'. Run 'copilot config sessionManagementTools.scope all', or launch with -Transport mailbox."
    }
}

function Get-CocopilotSessionSelectionArgument {
    <#
    .SYNOPSIS
        Returns the first argument in a raw argument array that selects or
        resumes a session (--session-id, --resume/-r, --continue, --connect,
        in "--x value" or "--x=value" form), or $null. Direct transport
        assigns the session id itself, so such an argument would break the
        registration.
    #>
    param([AllowEmptyCollection()][string[]]$Arguments = @())

    foreach ($argument in $Arguments) {
        if ($argument -cmatch '^(--session-id|--resume|--continue|--connect)(=.*)?$' -or $argument -ceq "-r") {
            return $argument
        }
    }
    return $null
}
