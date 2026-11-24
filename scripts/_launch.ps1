#Requires -Version 7.4

<#
.SYNOPSIS
    Launch helpers: the init command, agent names, window titles, Windows
    and Windows Terminal quoting, role prompts and the session banner.
    _common.ps1 dot-sources this file; don't run it directly.
#>

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

    $isGitRepo = Test-CocopilotGitRepository -Path $RepoPath
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
        drift apart. The transport picks how the agent waits for its peer:
        prompts/listening-mailbox.md or prompts/listening-direct.md fills the
        "Listening for peer changes" section, and three short phrases follow
        it. A {{...}} token left after rendering throws instead of reaching
        an agent.
    #>
    param(
        [Parameter(Mandatory)][string]$CocopilotRoot,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b", "verifier")][string]$AgentRole,
        [ValidateSet("mailbox", "direct")][string]$Transport = "mailbox"
    )

    $promptFile = if ($AgentRole -eq "verifier") { "verifier.md" } else { "agent.md" }
    $promptPath = Join-Path $CocopilotRoot "prompts\$promptFile"
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) { throw "Missing prompt file: $promptPath" }
    $text = (Read-CocopilotTextFile -Path $promptPath).Text
    if ($AgentRole -eq "verifier") { return $text }

    $listeningPath = Join-Path $CocopilotRoot "prompts\listening-$Transport.md"
    if ($text.Contains("{{LISTENING_SECTION}}")) {
        if (-not (Test-Path -LiteralPath $listeningPath -PathType Leaf)) { throw "Missing prompt file: $listeningPath" }
        $listening = (Read-CocopilotTextFile -Path $listeningPath).Text.TrimEnd()
    } else {
        $listening = ""
    }
    if ($Transport -eq "direct") {
        $deliveryPath = "when you drain the mailbox with the banner's read command, which you do whenever a peer message wakes you"
        $afterHandling = "drain until ``NO_NEW_ENTRIES`` and end your turn"
        $idleWait = "drain the mailbox once with the read command, send the one startup resync message (see `"Listening for peer changes`")"
    } else {
        $deliveryPath = "through the watch command, which you run in the background"
        $afterHandling = "re-arm the watch with its ``RE_ARM:`` command"
        $idleWait = "launch the watch command in the background"
    }

    if ($AgentRole -eq "agent-a") {
        $roleName = "Agent A"; $peerRole = "agent-b"; $peerName = "Agent B"
    } else {
        $roleName = "Agent B"; $peerRole = "agent-a"; $peerName = "Agent A"
    }
    # The transport text goes in first: it uses the role placeholders too.
    $rendered = $text.
        Replace("{{LISTENING_SECTION}}", $listening).
        Replace("{{DELIVERY_PATH}}", $deliveryPath).
        Replace("{{AFTER_HANDLING}}", $afterHandling).
        Replace("{{IDLE_WAIT}}", $idleWait).
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
        [string]$ContextRoot,
        [ValidateSet("mailbox", "direct")][string]$Transport = "mailbox"
    )

    $collaborationPath = Join-Path $CocopilotRoot "COLLABORATION.md"
    $watchScript = Join-Path $CocopilotRoot "scripts\watch-mailbox.ps1"
    $initScript = Join-Path $CocopilotRoot "scripts\init-mailbox.ps1"
    $writeLaneScript = Join-Path $CocopilotRoot "scripts\write-lane.ps1"
    $handoffScript = Join-Path $CocopilotRoot "scripts\handoff.ps1"
    $statusScript = Join-Path $CocopilotRoot "scripts\mailbox-status.ps1"
    $watchCmd = "& $(ConvertTo-SingleQuoted $watchScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole"
    $statusCmd = "& $(ConvertTo-SingleQuoted $statusScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole"
    $initCmd = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initScript
    $writeLaneCmd = "& $(ConvertTo-SingleQuoted $writeLaneScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole -Turn `$turn"
    $handoffCmd = "& $(ConvertTo-SingleQuoted $handoffScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole -Action <Offer|Accept|Cancel|SetModel>"
    $mailboxDir = Open-CocopilotMailbox -RepoPath $RepoPath

    $core = @"
## Session context (auto-generated by cocopilot — do not hand-edit)

- Your role: $AgentRole
- Target repository: $RepoPath
- Mailbox: $mailboxDir\ (outside the target; implementer.json, agent-a.md, agent-b.md, session.log.md, verify-request.md, one cursor per agent)
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
    $myLane = Join-Path $mailboxDir "$AgentRole.md"
    $peerLane = Join-Path $mailboxDir "$peerRole.md"

    if ($Transport -eq "direct") {
        # The ids come from the registration start-agents.ps1 wrote before
        # this window opened. write-lane.ps1 re-reads it on every entry, so
        # a peer that is later re-registered still gets the right hint.
        $registration = Read-CocopilotSessionRegistration -MailboxDir $mailboxDir
        if ($registration.State -ne "Valid") {
            $why = if ($registration.State -eq "None") { "it is missing" } else { $registration.Reason }
            throw "Direct transport needs $mailboxDir\sessions.json, but $why. Launch the pair with start-agents.ps1 -Transport direct."
        }
        $record = $registration.Record
        $canonicalTarget = Get-CocopilotCanonicalPath -Path $RepoPath
        if (-not (Test-CocopilotSameTarget -RecordedTarget $record.target -CanonicalTarget $canonicalTarget)) {
            throw "Direct transport: $mailboxDir\sessions.json belongs to target '$($record.target)', not '$canonicalTarget'. Launch the pair with start-agents.ps1 -Transport direct."
        }
        $configDir = Get-CocopilotConfigDir
        if ($record.configDir -ine $configDir) {
            throw "Direct transport: $mailboxDir\sessions.json was registered for Copilot configuration directory '$($record.configDir)', but this shell uses '$configDir'. Launch the pair with start-agents.ps1 -Transport direct."
        }
        $ownId = [string]$record.agents.$AgentRole.sessionId
        $peerId = [string]$record.agents.$peerRole.sessionId
        if (-not $ownId -or -not $peerId) {
            throw "Direct transport: $mailboxDir\sessions.json does not register both agents. Launch the pair with start-agents.ps1 -Transport direct."
        }
        $readCmd = "$watchCmd -NoWait"
        return $core + @"

- Transport: direct — $peerRole wakes you with a native peer message
  (send_session_message); you never run a background watch.
- Your session id: $ownId
- Peer ($peerRole) session id: $peerId
  (registered in $mailboxDir\sessions.json for Copilot configuration
  directory $($record.configDir); restart a closed window with
  copilot --resume <its id> to keep it registered)

- Your lane (the ONLY mailbox file you may write): $myLane
- Peer lane (read-only to you): $peerLane

- Lane write command (the preferred way to post a lane entry — build
  `$turn as the raw turn body first, no timestamp or "## ..." heading
  of your own, then run verbatim; appends to the session log FIRST and
  overwrites your own lane LAST, exactly as the protocol requires, then
  prints the NOTIFY_PEER send_session_message call that wakes the peer.
  Run EXACTLY as given below — -Role is already correct for you here, but
  the command cannot itself verify who is calling it, so never edit the
  -Role value. Add -VerifyRequest when the turn is a VERIFY_REQUEST, to
  pin it for the fresh-eyes verifier):
  $writeLaneCmd
- Read command (drains the mailbox without waiting: delivers the peer's
  unacknowledged entries, or prints NO_NEW_ENTRIES and the OWNERSHIP
  line — run it on every peer message and at the start of every turn;
  after handling a delivery, run the RE_ARM command it printed, which
  acknowledges what you handled and reads again, until NO_NEW_ENTRIES;
  add -Full to print the whole ownership record instead of its
  OWNERSHIP line):
  $readCmd
- Status command (read-only index of the mailbox: ownership, unread
  peer entries, work unit, verdict, pin, what needs reading — run it
  first on every (re)start; it never delivers or acknowledges anything,
  so drain with the read command before acting):
  $statusCmd
- Init command (only if implementer.json, a lane file or session.log.md
  is missing — never because a cursor or verify-request.md is missing;
  without a cursor, your first read replays the whole log):
  $initCmd
- Handoff command (the ONLY allowed way to change implementer.json; it
  checks the record, takes the ownership lock and prints the entry to
  post in your lane. Accept and Cancel need -Epoch <n> from the offer;
  SetModel needs -OwnerModel <model>; Accept takes it too):
  $handoffCmd

---

"@
    }

    return $core + @"

- Transport: mailbox — you wait for the peer with the background watch
  command below.

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
  acknowledges what you handled; to read the whole ownership record
  once, without waiting, run it with -NoWait -Full added):
  $watchCmd
- Status command (read-only index of the mailbox: ownership, unread
  peer entries, work unit, verdict, pin, what needs reading — run it
  first on every (re)start; it never delivers or acknowledges anything,
  so drain with the watch command before acting):
  $statusCmd
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
