#Requires -Version 7.4

<#
.SYNOPSIS
    Launches two GitHub Copilot CLI instances in separate terminal windows,
    each with its own model/flags, paired on a target repository through
    cocopilot's mailbox.

.DESCRIPTION
    cocopilot itself (this script, COLLABORATION.md, prompts/) stays
    centrally installed wherever you cloned it. -RepoPath is the repository
    you actually want to pair on — it can be anywhere, unrelated to
    cocopilot's own location. Only the mailbox (.mailbox/) is created inside
    that target repository.

    By default each agent is launched through the full path of the first
    `copilot` native executable or PowerShell script on PATH — never a
    same-name alias or function from a personal PowerShell profile, and
    never a cmd shim (.cmd/.bat), which cannot carry the multi-line prompt
    and is skipped with a warning — so this works the same for anyone with
    the `copilot` CLI on PATH, without requiring any particular $PROFILE
    setup. If no such CLI exists, the launcher stops before model
    discovery or any window opens. Assign each role with
    -AgentAModel/-AgentBModel and optional effort/context settings. When a
    role has neither a model nor an explicitly-bound raw
    -AgentAArgs/-AgentBArgs array, the launcher shows the available model
    catalog and prompts for that role's model and supported settings.

    If you keep your own shortcut functions (e.g. a `copilot-opus`
    function that already bakes in your preferred flags), pass its name via
    -AgentACommand/-AgentBCommand and explicitly pass the corresponding
    -AgentAArgs/-AgentBArgs @(). An explicitly passed command is launched
    as given, without resolution. An explicitly-bound raw argument array is
    the expert escape hatch: it suppresses the typed model picker for that
    role and is passed through unchanged.

    Opens two new console windows in the same shell you're currently
    running this from (see -ShellExe) and runs, in the target repository:

        <AgentACommand> <AgentAArgs> -C <RepoPath> -n <NameA> -i <banner + agent-a prompt>
        <AgentBCommand> <AgentBArgs> -C <RepoPath> -n <NameB> -i <banner + agent-b prompt>

    Each new window renders its own prompt with render-prompt.ps1 from the
    shared prompts/agent.md template, so the launch command itself carries
    only paths and arguments and stays far below the Windows command-line
    limit. PowerShell's execution policy in a new pwsh session must
    therefore allow cocopilot's scripts, as it already must for the
    installed profile functions. The rendered prompt itself still reaches
    copilot as one command-line argument, which Windows limits to 32,767
    characters; with 220-character paths it is about 13,900 characters.
    The banner (see _common.ps1) tells each agent the target repo path,
    the mailbox location, where to find COLLABORATION.md, and the exact
    watch/init commands to run — all resolved to this cocopilot install,
    so the prompts themselves never need to hardcode a repo name or path.

    Agent A starts as the active implementer/driver (per
    <RepoPath>/.mailbox, see init-mailbox.ps1). Agent B starts as the
    navigator: it reads COLLABORATION.md and the mailbox, thinks along in
    its own lane (huddle challenges, syncs acks, rubber-duck answers), and
    only writes repository files after accepting a HANDOFF_OFFER.

    Run the init-mailbox.ps1 script from this cocopilot install with
    -RepoPath <RepoPath> first if that repository's mailbox doesn't exist yet.
    A mailbox without delivery cursors (from an older cocopilot) only gets a
    warning: both agents still start, and the first watch of each agent
    without a cursor replays the whole session log.

.PARAMETER RepoPath
    The repository to pair on. Defaults to the current directory.

.PARAMETER ContextRoot
    Optional workspace root (e.g. a folder containing many sibling
    repositories) granted to both agents as a READ-ONLY search scope, via
    an extra --add-dir and a banner note. Ownership, diffs, and all writes
    remain bound to -RepoPath; use this when the pair needs cross-repo
    context, not cross-repo editing. See COLLABORATION.md "Workspace
    context".

.PARAMETER AgentACommand
    Command to run for agent-a. When omitted, the full path of the `copilot`
    CLI on PATH is used (see DESCRIPTION). Pass a personal shortcut function
    name instead (e.g. "copilot-opus") if you have one defined in your
    $PROFILE — in that case also pass -AgentAArgs @() since your function
    already bakes in its own flags. An explicit value is launched as given.

.PARAMETER AgentAArgs
    Complete expert argument array appended after AgentACommand, before
    -C/-n/-i. When explicitly bound, this suppresses -AgentAModel,
    -AgentAEffort, -AgentAContext, and the picker for agent-a. Pass @() if
    AgentACommand is a shortcut that already includes its own flags.

.PARAMETER AgentAModel
    Model assigned to agent-a. If omitted (and -AgentAArgs was not
    explicitly bound), opens the model/settings picker. The picker defaults
    to claude-opus-5.5 when it is available.

.PARAMETER AgentAEffort
    Optional reasoning effort for agent-a. Validated against account model
    metadata when the picker is active; otherwise passed to Copilot as-is.

.PARAMETER AgentAContext
    Optional context tier for agent-a: default or long_context. Validated
    against account model metadata when the picker is active.

.PARAMETER AgentBCommand
    Command to run for agent-b. Same resolution as -AgentACommand.

.PARAMETER AgentBArgs
    Same expert override behavior as -AgentAArgs, for agent-b.

.PARAMETER AgentBModel
    Model assigned to agent-b. If omitted (and -AgentBArgs was not
    explicitly bound), opens the model/settings picker. The picker defaults
    to gpt-6.1-sol when it is available.

.PARAMETER AgentBEffort
    Optional reasoning effort for agent-b.

.PARAMETER AgentBContext
    Optional context tier for agent-b: default or long_context.

.PARAMETER UseWindowsTerminal
    Launch via `wt.exe` new tabs instead of plain new console windows.
    Defaults to $true — automatically used whenever `wt.exe` is found on
    PATH (silently falls back to plain console windows otherwise, so this
    is a no-op default change for anyone without Windows Terminal). The
    two agent tabs land in the most-recently-used wt.exe window (Microsoft's
    own "-w 0" idiom) — typically the very window you ran this from — or a
    fresh one if none exists. Pass -UseWindowsTerminal:$false to force
    plain console windows even when `wt.exe` is available.

.PARAMETER NameA
    Session name for agent-a — also becomes its console/wt-tab title.
    Defaults to "cocopilot-agent-a", or "<SessionName> - agent a" when
    -SessionName/-Name is given and -NameA isn't itself explicitly passed.
    An explicit -NameA always wins over -SessionName.

.PARAMETER NameB
    Same as -NameA, for agent-b ("cocopilot-agent-b" /
    "<SessionName> - agent b").

.PARAMETER SessionName
    Convenience prefix applied to both -NameA and -NameB when they aren't
    explicitly passed — e.g. -Name "12313 polis" (an alias for
    -SessionName) yields "12313 polis - agent a" / "12313 polis - agent b",
    shown as both the copilot session name and the new window/tab's title.
    Has no effect on a -NameA/-NameB that's explicitly supplied.

.PARAMETER ShellExe
    Path to the pwsh executable used for each new window. Defaults to the
    pwsh host that is running this script (via the running process's own
    path), so the new windows load the same $PROFILE and any shortcut
    functions you rely on via -AgentACommand/-AgentBCommand. cocopilot
    requires PowerShell 7.4 or later: Windows PowerShell (powershell.exe)
    and PowerShell ISE (powershell_ise.exe) are rejected up front, and each
    new window re-checks its own version before it starts copilot.

.PARAMETER Transport
    How an agent is woken when its peer posts an entry. "mailbox" (the
    default) keeps today's behaviour: each agent runs watch-mailbox.ps1 in
    the background, which polls the mailbox. "direct" wakes the peer with
    Copilot's native send_session_message tool instead, so no agent polls.
    Both use the same .mailbox/ as the only source of truth.

    Direct needs the user-level setting sessionManagementTools.enabled on
    (and .message not off, .scope not in-process); the launcher checks it
    with the stock CLI before anything else and stops with the fix command
    otherwise. It gives each agent a fresh session id with --session-id and
    registers both in .mailbox/sessions.json before either window opens, so
    -AgentAArgs/-AgentBArgs may not select a session themselves
    (--session-id, --resume, -r, --continue, --connect). It also adds
    --max-autopilot-continues 0 (unless the arguments already set it): a
    waiting agent ends its turn with no background work, and autopilot
    would otherwise nudge it. A mailbox launch removes a registration left
    by an earlier direct launch.

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project
    # shows the available model catalog, then asks which model/settings to
    # assign to agent-a and agent-b

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project -AgentAModel claude-opus-5.5 -AgentAEffort medium -AgentAContext long_context -AgentBModel gpt-6.1-sol -AgentBEffort medium -AgentBContext long_context
    # non-interactive role assignment with explicit model settings

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\claim -Name "12313 polis"
    # tabs/windows and Copilot sessions are "12313 polis - agent a" /
    # "12313 polis - agent b"

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project -AgentACommand copilot-opus -AgentAArgs @() -AgentBCommand copilot-sol -AgentBArgs @() -UseWindowsTerminal:$false
    # use profile shortcuts that supply their own flags, and force plain
    # console windows instead of Windows Terminal tabs

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project -Transport direct
    # agents wake each other with native peer messages instead of polling
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$ContextRoot,
    [string]$AgentACommand,
    [string[]]$AgentAArgs,
    [string]$AgentAModel,
    [ValidateSet("none", "minimal", "low", "medium", "high", "xhigh", "max")][string]$AgentAEffort,
    [ValidateSet("default", "long_context")][string]$AgentAContext,
    [string]$AgentBCommand,
    [string[]]$AgentBArgs,
    [string]$AgentBModel,
    [ValidateSet("none", "minimal", "low", "medium", "high", "xhigh", "max")][string]$AgentBEffort,
    [ValidateSet("default", "long_context")][string]$AgentBContext,
    [string]$NameA = "cocopilot-agent-a",
    [string]$NameB = "cocopilot-agent-b",
    [Alias("Name")][string]$SessionName,
    [switch]$UseWindowsTerminal = $true,
    [string]$ShellExe = (Get-Process -Id $PID).Path,
    [ValidateSet("mailbox", "direct")][string]$Transport = "mailbox"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")
. (Join-Path $PSScriptRoot "_models.ps1")

$agentAArgsBound = $PSBoundParameters.ContainsKey("AgentAArgs")
$agentBArgsBound = $PSBoundParameters.ContainsKey("AgentBArgs")
$agentATypedSettings = @("AgentAModel", "AgentAEffort", "AgentAContext") |
    Where-Object { $PSBoundParameters.ContainsKey($_) }
$agentBTypedSettings = @("AgentBModel", "AgentBEffort", "AgentBContext") |
    Where-Object { $PSBoundParameters.ContainsKey($_) }

if ($agentAArgsBound -and @($agentATypedSettings).Count -gt 0) {
    throw "-AgentAArgs cannot be combined with -AgentAModel, -AgentAEffort, or -AgentAContext."
}
if ($agentBArgsBound -and @($agentBTypedSettings).Count -gt 0) {
    throw "-AgentBArgs cannot be combined with -AgentBModel, -AgentBEffort, or -AgentBContext."
}
if ($Transport -eq "direct") {
    # The launcher assigns each session id itself and registers it; a raw
    # argument that picks another session would silently break the pair.
    foreach ($rawArgs in @(@{ Label = "-AgentAArgs"; Value = $AgentAArgs }, @{ Label = "-AgentBArgs"; Value = $AgentBArgs })) {
        $conflict = Get-CocopilotSessionSelectionArgument -Arguments @($rawArgs.Value | Where-Object { $null -ne $_ })
        if ($conflict) {
            throw "$($rawArgs.Label) contains '$conflict', but -Transport direct assigns each agent's session id itself. Remove it, or use -Transport mailbox."
        }
    }
}

$NameA = Resolve-CocopilotAgentName -CurrentValue $NameA -ExplicitlyBound $PSBoundParameters.ContainsKey('NameA') -SessionName $SessionName -AgentRole "agent-a"
$NameB = Resolve-CocopilotAgentName -CurrentValue $NameB -ExplicitlyBound $PSBoundParameters.ContainsKey('NameB') -SessionName $SessionName -AgentRole "agent-b"

if ((Split-Path -Leaf $ShellExe) -match '^powershell(_ise)?(\.exe)?$') {
    throw "cocopilot requires PowerShell 7.4 or later (pwsh), but -ShellExe '$ShellExe' is Windows PowerShell. Omit -ShellExe or pass a pwsh path."
}

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
if ($ContextRoot) { $ContextRoot = (Resolve-Path -LiteralPath $ContextRoot).Path }
$cocopilotRoot = Split-Path -Parent $PSScriptRoot
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$mailboxFiles = @("implementer.json", "agent-a.md", "agent-b.md", "session.log.md") |
    ForEach-Object { Join-Path $RepoPath ".mailbox\$_" }

if (@($mailboxFiles | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0) {
    $initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initMailboxScript
    throw "Mailbox state for '$RepoPath' is incomplete; run $initCommand first."
}
# A missing delivery cursor (a mailbox from an older cocopilot) makes that
# agent's first watch replay the whole log, which is the safe default. Only
# the human can decide that the history so far is handled, so the launcher
# warns and never creates a cursor itself.
$agentsWithoutCursor = @(@("agent-a", "agent-b") | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $RepoPath ".mailbox\$_.cursor"))
    })
if ($agentsWithoutCursor.Count -gt 0) {
    $initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initMailboxScript
    $logKilobytes = [Math]::Ceiling((Get-Item -LiteralPath (Join-Path $RepoPath ".mailbox\session.log.md")).Length / 1KB)
    Write-Warning ("The mailbox has no delivery cursor for $($agentsWithoutCursor -join ' and '). The first watch of " +
        "each agent without a cursor replays the whole session log ($logKilobytes KB) from its start. That is the " +
        "safe default. To count the log so far as handled instead, first make sure every entry so far is handled, " +
        "with no STOP or QUESTION still pending. Then stop both agents, run $initCommand -AcknowledgeHistory, and " +
        "start them again.")
}
# Render both role prompts before model discovery, so a missing or broken
# template fails before any window opens. Each window renders its own copy
# again at launch.
$null = Get-CocopilotRolePrompt -CocopilotRoot $cocopilotRoot -AgentRole "agent-a"
$null = Get-CocopilotRolePrompt -CocopilotRoot $cocopilotRoot -AgentRole "agent-b"

$catalog = @()
$agentAModelDescriptor = $null
$agentBModelDescriptor = $null
$promptForAgentASettings = $false
$promptForAgentBSettings = $false
$needsAgentASelection = -not $agentAArgsBound -and [string]::IsNullOrWhiteSpace($AgentAModel)
$needsAgentBSelection = -not $agentBArgsBound -and [string]::IsNullOrWhiteSpace($AgentBModel)
$needsCatalog = $needsAgentASelection -or $needsAgentBSelection

# A role without an explicit command, and any model discovery, use the
# stock CLI by full path, so a same-name profile function cannot replace
# it here or in the new windows. Explicit commands are launched as given.
$agentACommandBound = $PSBoundParameters.ContainsKey("AgentACommand")
$agentBCommandBound = $PSBoundParameters.ContainsKey("AgentBCommand")
$stockCopilot = $null
if ($needsCatalog -or -not $agentACommandBound -or -not $agentBCommandBound -or $Transport -eq "direct") {
    $stockCopilot = Resolve-CocopilotCommand
}
if (-not $agentACommandBound) { $AgentACommand = $stockCopilot }
if (-not $agentBCommandBound) { $AgentBCommand = $stockCopilot }

# Direct transport fails here, before the model picker or any window, when
# the CLI settings cannot let two separate sessions message each other.
if ($Transport -eq "direct") {
    Assert-CocopilotDirectTransportReady -CopilotCommand $stockCopilot
    if ($agentACommandBound -or $agentBCommandBound) {
        Write-Warning ("The direct-transport settings were checked with '$stockCopilot'. A custom -AgentACommand/-AgentBCommand " +
            "must use the same Copilot configuration directory ($(Get-CocopilotConfigDir)), or the agents cannot reach each other.")
    }
}

if ($needsCatalog) {
    $catalog = @(Get-CocopilotModelCatalog -CopilotCommand $stockCopilot)
    Show-CocopilotModelCatalog -Catalog $catalog
}
if ($needsAgentASelection) {
    $agentAModelDescriptor = Read-CocopilotModelChoice -Catalog $catalog -RoleLabel "Agent A" -DefaultModelId "claude-opus-5.5"
    $AgentAModel = $agentAModelDescriptor.Id
    $promptForAgentASettings = $true
}
if ($needsAgentBSelection) {
    $agentBModelDescriptor = Read-CocopilotModelChoice -Catalog $catalog -RoleLabel "Agent B" -DefaultModelId "gpt-6.1-sol"
    $AgentBModel = $agentBModelDescriptor.Id
    $promptForAgentBSettings = $true
}

if (-not $agentAArgsBound) {
    if (-not $agentAModelDescriptor) {
        $agentAModelDescriptor = $catalog | Where-Object { $_.Id -ieq $AgentAModel } | Select-Object -First 1
    }
    if (-not $agentAModelDescriptor) {
        $agentAModelDescriptor = ConvertTo-CocopilotModelDescriptor `
            -Model ([pscustomobject]@{ id = $AgentAModel; name = $AgentAModel }) `
            -Source cli-completion
    }
    $agentAConfiguration = Resolve-CocopilotAgentModelConfiguration `
        -Model $agentAModelDescriptor `
        -RoleLabel "Agent A" `
        -RequestedEffort $AgentAEffort `
        -RequestedContext $AgentAContext `
        -PromptForSettings:$promptForAgentASettings
    $AgentAArgs = @(New-CocopilotAgentArguments `
        -Model $agentAConfiguration.Model `
        -Effort $agentAConfiguration.Effort `
        -Context $agentAConfiguration.Context)
}

if (-not $agentBArgsBound) {
    if (-not $agentBModelDescriptor) {
        $agentBModelDescriptor = $catalog | Where-Object { $_.Id -ieq $AgentBModel } | Select-Object -First 1
    }
    if (-not $agentBModelDescriptor) {
        $agentBModelDescriptor = ConvertTo-CocopilotModelDescriptor `
            -Model ([pscustomobject]@{ id = $AgentBModel; name = $AgentBModel }) `
            -Source cli-completion
    }
    $agentBConfiguration = Resolve-CocopilotAgentModelConfiguration `
        -Model $agentBModelDescriptor `
        -RoleLabel "Agent B" `
        -RequestedEffort $AgentBEffort `
        -RequestedContext $AgentBContext `
        -PromptForSettings:$promptForAgentBSettings
    $AgentBArgs = @(New-CocopilotAgentArguments `
        -Model $agentBConfiguration.Model `
        -Effort $agentBConfiguration.Effort `
        -Context $agentBConfiguration.Context)
}

if ($Transport -eq "direct") {
    # A direct-transport agent waits for its peer by ending its turn with no
    # background work. Autopilot would answer that with automatic
    # continuation nudges, so direct launches allow none: the agent simply
    # waits until a peer message wakes it. Harmless outside autopilot.
    $noContinuations = @("--max-autopilot-continues", "0")
    foreach ($role in @("A", "B")) {
        $roleArgs = if ($role -eq "A") { @($AgentAArgs) } else { @($AgentBArgs) }
        if (@($roleArgs | Where-Object { $_ -match '^--max-autopilot-continues(=|$)' }).Count -gt 0) {
            Write-Warning ("-Agent${role}Args sets --max-autopilot-continues itself. With -Transport direct, a value above 0 lets " +
                "autopilot nudge an agent that is only waiting for its peer.")
            continue
        }
        if ($role -eq "A") { $AgentAArgs = @($roleArgs) + $noContinuations } else { $AgentBArgs = @($roleArgs) + $noContinuations }
    }
}

function Start-CopilotAgent {
    param(
        [string]$RepoPath,
        [string]$ContextRoot,
        [string]$CocopilotRoot,
        [string]$AgentCommand,
        [string[]]$AgentArgs,
        [string]$Name,
        [ValidateSet("agent-a", "agent-b")][string]$AgentRole,
        [string]$ShellExe,
        [switch]$UseWindowsTerminal,
        [ValidateSet("mailbox", "direct")][string]$Transport = "mailbox",
        [string]$SessionId
    )

    $agentCommandQ = ConvertTo-SingleQuoted $AgentCommand
    $agentArgsQ = ($AgentArgs | ForEach-Object { ConvertTo-SingleQuoted $_ }) -join " "
    $repoQ = ConvertTo-SingleQuoted $RepoPath
    $nameQ = ConvertTo-SingleQuoted $Name
    $addDirQ = ConvertTo-SingleQuoted $CocopilotRoot
    $contextRootQ = if ($ContextRoot) { ConvertTo-SingleQuoted $ContextRoot } else { "" }
    $renderScriptQ = ConvertTo-SingleQuoted (Join-Path $CocopilotRoot "scripts\render-prompt.ps1")
    $renderAgent = if ($AgentRole -eq "agent-a") { "a" } else { "b" }

    # The new window renders its own prompt, so the encoded command carries
    # only paths and arguments. An embedded prompt, encoded as UTF-16 Base64,
    # would push long-path launches past the Windows command-line limit of
    # 32,767 characters. A failed render throws before copilot starts. Its
    # warning stream is dropped: the direct-transport restart warning is
    # meant for a manual render, and this window has the registered id.
    $renderContextArg = if ($ContextRoot) { " -ContextRoot $contextRootQ" } else { "" }
    $renderPrompt = "`$prompt = (& $renderScriptQ -Agent $renderAgent -RepoPath $repoQ$renderContextArg -Transport $Transport 3>`$null) -join [Environment]::NewLine; " +
        "if ([string]::IsNullOrWhiteSpace(`$prompt)) { throw 'cocopilot rendered an empty agent prompt.' }; "

    # --add-dir grants read/run access to cocopilot's own install (for
    # COLLABORATION.md and the watch/init scripts) even if AgentCommand's
    # underlying alias doesn't already pass --allow-all-paths. A second
    # --add-dir opens the optional workspace context root; the read-only
    # discipline for it is the protocol's, not the CLI's.
    $contextDirArg = if ($ContextRoot) { "--add-dir $contextRootQ " } else { "" }
    # Direct transport: the id registered in .mailbox/sessions.json, so the
    # peer's send_session_message reaches exactly this session.
    $sessionIdArg = if ($SessionId) { "--session-id $(ConvertTo-SingleQuoted $SessionId) " } else { "" }
    $copilotInvocation = ("& $agentCommandQ " + $(if ($agentArgsQ) { "$agentArgsQ " } else { "" }) + "-C $repoQ -n $nameQ $sessionIdArg--add-dir $addDirQ $contextDirArg-i `$prompt").Trim()

    # Runs first in the new window: an explicit -ShellExe that points at an
    # older pwsh must fail before anything else happens.
    $hostGuard = "if (`$PSVersionTable.PSVersion -lt [version]'7.4') { throw 'cocopilot requires PowerShell 7.4 or later (pwsh).' }; "
    # The new window loads the user's $PROFILE, which may switch native
    # argument passing to Legacy. Legacy does not escape the prompt's
    # embedded double quotes, so copilot would receive the prompt split into
    # many arguments. Windows mode escapes them for native executables such
    # as copilot.exe (it keeps Legacy only for .cmd/.bat-style targets).
    $argumentPassing = "`$PSNativeCommandArgumentPassing = 'Windows'; "
    # Sets the new console's own window title - the only thing that gives
    # the plain (non-Windows-Terminal) console-window path any title at
    # all; harmless alongside wt.exe's own --title/--suppressApplicationTitle
    # below (that pair keeps the wt tab's title fixed regardless of
    # whatever this in-process statement does).
    $innerScript = $hostGuard + $argumentPassing + (Get-CocopilotWindowTitleStatement -Title $Name) + $renderPrompt + $copilotInvocation

    # -EncodedCommand avoids nested PowerShell quoting problems (spaces or
    # quotes in paths or names); the argument-passing pin above covers the
    # native copilot boundary. It still loads $ShellExe's own $PROFILE, so a
    # personal shortcut function passed via -AgentACommand/-AgentBCommand is
    # available in the new window.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerScript))

    if ($UseWindowsTerminal -and (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        $wtArgs = Get-CocopilotWtNewTabArgs -Title $Name -RepoPath $RepoPath -ShellExe $ShellExe -EncodedCommand $encoded
        Start-Process -FilePath "wt.exe" -ArgumentList $wtArgs
    } else {
        Start-Process -FilePath $ShellExe `
            -ArgumentList @("-NoExit", "-EncodedCommand", $encoded) `
            -WorkingDirectory $RepoPath
    }
}

if (-not (Get-Command $AgentACommand -ErrorAction SilentlyContinue)) {
    Write-Warning "'$AgentACommand' isn't a recognized command in this session; make sure it's on PATH (or defined in your `$PROFILE if you passed a personal shortcut)."
}
if (-not (Get-Command $AgentBCommand -ErrorAction SilentlyContinue)) {
    Write-Warning "'$AgentBCommand' isn't a recognized command in this session; make sure it's on PATH (or defined in your `$PROFILE if you passed a personal shortcut)."
}

$agentAModelDisplay = Get-CocopilotArgumentValue -Arguments $AgentAArgs -Name "--model"
$agentBModelDisplay = Get-CocopilotArgumentValue -Arguments $AgentBArgs -Name "--model"
$agentAEffortDisplay = Get-CocopilotArgumentValue -Arguments $AgentAArgs -Name "--effort"
$agentBEffortDisplay = Get-CocopilotArgumentValue -Arguments $AgentBArgs -Name "--effort"
$agentAContextDisplay = Get-CocopilotArgumentValue -Arguments $AgentAArgs -Name "--context"
$agentBContextDisplay = Get-CocopilotArgumentValue -Arguments $AgentBArgs -Name "--context"

Write-Host ("Agent A -> '{0}' | command: {1} | model: {2} | effort: {3} | context: {4}" -f
    $NameA, $AgentACommand,
    $(if ($agentAModelDisplay) { $agentAModelDisplay } else { "command default" }),
    $(if ($agentAEffortDisplay) { $agentAEffortDisplay } else { "model default" }),
    $(if ($agentAContextDisplay) { $agentAContextDisplay } else { "model default" })) -ForegroundColor Cyan
Write-Host ("Agent B -> '{0}' | command: {1} | model: {2} | effort: {3} | context: {4}" -f
    $NameB, $AgentBCommand,
    $(if ($agentBModelDisplay) { $agentBModelDisplay } else { "command default" }),
    $(if ($agentBEffortDisplay) { $agentBEffortDisplay } else { "model default" }),
    $(if ($agentBContextDisplay) { $agentBContextDisplay } else { "model default" })) -ForegroundColor Cyan

$sessionIdA = $null
$sessionIdB = $null
$mailboxDir = Join-Path $RepoPath ".mailbox"
if ($Transport -eq "direct") {
    # Both registrations land in one locked write before either window
    # opens, so neither agent can render a banner or post an entry against
    # a half-registered pair.
    $sessionIdA = [Guid]::NewGuid().ToString()
    $sessionIdB = [Guid]::NewGuid().ToString()
    Set-CocopilotSessionRegistration -MailboxDir $mailboxDir -RepoPath $RepoPath -ConfigDir (Get-CocopilotConfigDir) -Agents @{
        "agent-a" = @{ SessionId = $sessionIdA; Name = $NameA }
        "agent-b" = @{ SessionId = $sessionIdB; Name = $NameB }
    }
    Write-Host "Direct transport: agent-a session $sessionIdA, agent-b session $sessionIdB (registered in $mailboxDir\sessions.json)." -ForegroundColor Cyan
} elseif (Remove-CocopilotSessionRegistration -MailboxDir $mailboxDir) {
    Write-Host "Mailbox transport: removed the direct-transport registration left by an earlier launch." -ForegroundColor Cyan
}

Start-CopilotAgent -RepoPath $RepoPath -ContextRoot $ContextRoot -CocopilotRoot $cocopilotRoot -AgentCommand $AgentACommand -AgentArgs $AgentAArgs -Name $NameA -AgentRole "agent-a" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal -Transport $Transport -SessionId $sessionIdA
Start-Sleep -Seconds 1
Start-CopilotAgent -RepoPath $RepoPath -ContextRoot $ContextRoot -CocopilotRoot $cocopilotRoot -AgentCommand $AgentBCommand -AgentArgs $AgentBArgs -Name $NameB -AgentRole "agent-b" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal -Transport $Transport -SessionId $sessionIdB

Write-Host "Launched $NameA via '$AgentACommand' and $NameB via '$AgentBCommand' (shell: $ShellExe, transport: $Transport), paired on $RepoPath." -ForegroundColor Green
