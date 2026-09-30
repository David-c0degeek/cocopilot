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

    By default each agent is launched as a plain, literal `copilot`
    invocation — not a personal PowerShell profile function/alias — so this
    works the same for anyone with the `copilot` CLI on PATH, without
    requiring any particular $PROFILE setup. Assign each role with
    -AgentAModel/-AgentBModel and optional effort/context settings. When a
    role has neither a model nor an explicitly-bound raw -AgentAArgs/
    -AgentBArgs array, the launcher shows the available model catalog and
    prompts for that role's model and supported settings.

    If you keep your own shortcut functions (e.g. a `copilot-opus`
    function that already bakes in your preferred flags), pass its name via
    -AgentACommand/-AgentBCommand and explicitly pass the corresponding
    -AgentAArgs/-AgentBArgs @(). An explicitly-bound raw argument array is
    the expert escape hatch: it suppresses the typed model picker for that
    role and is passed through unchanged.

    Opens two new console windows in the same shell you're currently
    running this from (see -ShellExe) and runs, in the target repository:

        <AgentACommand> <AgentAArgs> -C <RepoPath> -n <NameA> -i <banner + prompts/agent-a.md>
        <AgentBCommand> <AgentBArgs> -C <RepoPath> -n <NameB> -i <banner + prompts/agent-b.md>

    The banner (see _common.ps1) tells each agent the target repo path, the
    mailbox location, where to find COLLABORATION.md, and the exact
    watch/init commands to run — all resolved to this cocopilot install, so
    the prompts themselves never need to hardcode a repo name or path.

    Agent A starts as the active implementer/driver (per
    <RepoPath>/.mailbox, see init-mailbox.ps1). Agent B starts as the
    navigator: it reads COLLABORATION.md and the mailbox, thinks along in
    its own lane (huddle challenges, syncs acks, rubber-duck answers), and
    only writes repository files after accepting a HANDOFF_OFFER.

    Run the init-mailbox.ps1 script from this cocopilot install with
    -RepoPath <RepoPath> first if that repository's mailbox doesn't exist yet.

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
    Executable/command to run for agent-a. Defaults to "copilot" (the real
    CLI, expected on PATH). Pass a personal shortcut function name instead
    (e.g. "copilot-opus") if you have one defined in your $PROFILE — in
    that case also pass -AgentAArgs @() since your function already bakes
    in its own flags.

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
    Executable/command to run for agent-b. Defaults to "copilot".

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

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project
    # shows the available model catalog, then asks which model/settings to
    # assign to agent-a and agent-b

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project -AgentAModel claude-opus-5.5 -AgentAEffort max -AgentAContext long_context -AgentBModel gpt-6.1-sol -AgentBEffort max -AgentBContext long_context
    # non-interactive role assignment with explicit model settings

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\claim -Name "12313 polis"
    # tabs/windows and Copilot sessions are "12313 polis - agent a" /
    # "12313 polis - agent b"

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project -AgentACommand copilot-opus -AgentAArgs @() -AgentBCommand copilot-sol -AgentBArgs @() -UseWindowsTerminal:$false
    # use profile shortcuts that supply their own flags, and force plain
    # console windows instead of Windows Terminal tabs
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$ContextRoot,
    [string]$AgentACommand = "copilot",
    [string[]]$AgentAArgs,
    [string]$AgentAModel,
    [ValidateSet("none", "minimal", "low", "medium", "high", "xhigh", "max")][string]$AgentAEffort,
    [ValidateSet("default", "long_context")][string]$AgentAContext,
    [string]$AgentBCommand = "copilot",
    [string[]]$AgentBArgs,
    [string]$AgentBModel,
    [ValidateSet("none", "minimal", "low", "medium", "high", "xhigh", "max")][string]$AgentBEffort,
    [ValidateSet("default", "long_context")][string]$AgentBContext,
    [string]$NameA = "cocopilot-agent-a",
    [string]$NameB = "cocopilot-agent-b",
    [Alias("Name")][string]$SessionName,
    [switch]$UseWindowsTerminal = $true,
    [string]$ShellExe = (Get-Process -Id $PID).Path
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

$NameA = Resolve-CocopilotAgentName -CurrentValue $NameA -ExplicitlyBound $PSBoundParameters.ContainsKey('NameA') -SessionName $SessionName -AgentRole "agent-a"
$NameB = Resolve-CocopilotAgentName -CurrentValue $NameB -ExplicitlyBound $PSBoundParameters.ContainsKey('NameB') -SessionName $SessionName -AgentRole "agent-b"

if ((Split-Path -Leaf $ShellExe) -match '^powershell(_ise)?(\.exe)?$') {
    throw "cocopilot requires PowerShell 7.4 or later (pwsh), but -ShellExe '$ShellExe' is Windows PowerShell. Omit -ShellExe or pass a pwsh path."
}

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
if ($ContextRoot) { $ContextRoot = (Resolve-Path -LiteralPath $ContextRoot).Path }
$cocopilotRoot = Split-Path -Parent $PSScriptRoot
$promptA = Join-Path $cocopilotRoot "prompts\agent-a.md"
$promptB = Join-Path $cocopilotRoot "prompts\agent-b.md"
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$mailboxFiles = @("implementer.json", "agent-a.md", "agent-b.md", "session.log.md") |
    ForEach-Object { Join-Path $RepoPath ".mailbox\$_" }

if (@($mailboxFiles | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0) {
    $initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initMailboxScript
    throw "Mailbox state for '$RepoPath' is incomplete; run $initCommand first."
}
foreach ($p in @($promptA, $promptB)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing prompt file: $p" }
}

$catalog = @()
$agentAModelDescriptor = $null
$agentBModelDescriptor = $null
$promptForAgentASettings = $false
$promptForAgentBSettings = $false
$needsAgentASelection = -not $agentAArgsBound -and [string]::IsNullOrWhiteSpace($AgentAModel)
$needsAgentBSelection = -not $agentBArgsBound -and [string]::IsNullOrWhiteSpace($AgentBModel)

if ($needsAgentASelection -or $needsAgentBSelection) {
    $catalog = @(Get-CocopilotModelCatalog)
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

function Start-CopilotAgent {
    param(
        [string]$RepoPath,
        [string]$ContextRoot,
        [string]$CocopilotRoot,
        [string]$AgentCommand,
        [string[]]$AgentArgs,
        [string]$Name,
        [string]$PromptPath,
        [ValidateSet("agent-a", "agent-b")][string]$AgentRole,
        [string]$ShellExe,
        [switch]$UseWindowsTerminal
    )

    $banner = Get-CocopilotSessionBanner -RepoPath $RepoPath -CocopilotRoot $CocopilotRoot -AgentRole $AgentRole -ContextRoot $ContextRoot
    $fullPrompt = $banner + (Get-Content -LiteralPath $PromptPath -Raw)

    $agentCommandQ = ConvertTo-SingleQuoted $AgentCommand
    $agentArgsQ = ($AgentArgs | ForEach-Object { ConvertTo-SingleQuoted $_ }) -join " "
    $repoQ = ConvertTo-SingleQuoted $RepoPath
    $nameQ = ConvertTo-SingleQuoted $Name
    $promptQ = ConvertTo-SingleQuoted $fullPrompt
    $addDirQ = ConvertTo-SingleQuoted $CocopilotRoot

    # --add-dir grants read/run access to cocopilot's own install (for
    # COLLABORATION.md and the watch/init scripts) even if AgentCommand's
    # underlying alias doesn't already pass --allow-all-paths. A second
    # --add-dir opens the optional workspace context root; the read-only
    # discipline for it is the protocol's, not the CLI's.
    $contextDirArg = if ($ContextRoot) { "--add-dir $(ConvertTo-SingleQuoted $ContextRoot) " } else { "" }
    $copilotInvocation = ("& $agentCommandQ " + $(if ($agentArgsQ) { "$agentArgsQ " } else { "" }) + "-C $repoQ -n $nameQ --add-dir $addDirQ $contextDirArg-i $promptQ").Trim()

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
    $innerScript = $hostGuard + $argumentPassing + (Get-CocopilotWindowTitleStatement -Title $Name) + $copilotInvocation

    # -EncodedCommand avoids nested PowerShell quoting problems (spaces or
    # quotes in RepoPath or the prompt text); the argument-passing pin above
    # covers the native copilot boundary. It still loads $ShellExe's own
    # $PROFILE, so a personal shortcut function passed via
    # -AgentACommand/-AgentBCommand is available in the new window.
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

Start-CopilotAgent -RepoPath $RepoPath -ContextRoot $ContextRoot -CocopilotRoot $cocopilotRoot -AgentCommand $AgentACommand -AgentArgs $AgentAArgs -Name $NameA -PromptPath $promptA -AgentRole "agent-a" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal
Start-Sleep -Seconds 1
Start-CopilotAgent -RepoPath $RepoPath -ContextRoot $ContextRoot -CocopilotRoot $cocopilotRoot -AgentCommand $AgentBCommand -AgentArgs $AgentBArgs -Name $NameB -PromptPath $promptB -AgentRole "agent-b" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal

Write-Host "Launched $NameA via '$AgentACommand' and $NameB via '$AgentBCommand' (shell: $ShellExe), paired on $RepoPath." -ForegroundColor Green
