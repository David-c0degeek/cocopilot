#Requires -Version 5.1
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
    invocation with explicit flags (see -AgentAArgs/-AgentBArgs below) —
    not a personal PowerShell profile function/alias — so this works the
    same for anyone with the `copilot` CLI on PATH, without requiring any
    particular $PROFILE setup. If you do keep your own shortcut functions
    (e.g. a `copilot-sonnet` function that already bakes in your preferred
    flags), pass its name via -AgentACommand/-AgentBCommand and clear the
    corresponding -Args parameter.

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
    (e.g. "copilot-sonnet") if you have one defined in your $PROFILE — in
    that case also pass -AgentAArgs @() since your function already bakes
    in its own flags.

.PARAMETER AgentAArgs
    Extra arguments appended after AgentACommand, before -C/-n/-i. Defaults
    to a literal claude-sonnet-5 configuration:
    --model claude-sonnet-5 --effort max --context long_context --autopilot
    --allow-all. Pass @() if AgentACommand is your own shortcut that
    already includes its own flags.

.PARAMETER AgentBCommand
    Executable/command to run for agent-b. Defaults to "copilot".

.PARAMETER AgentBArgs
    Extra arguments appended after AgentBCommand, before -C/-n/-i. Defaults
    to a literal gpt-5.6-sol configuration:
    --model gpt-5.6-sol --effort max --context long_context --autopilot
    --allow-all. Pass @() if AgentBCommand is your own shortcut.

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
    Defaults to "cocopilot-agent-a", or "<SessionName>-agent-a" when
    -SessionName is given and -NameA isn't itself explicitly passed. An
    explicit -NameA always wins over -SessionName.

.PARAMETER NameB
    Same as -NameA, for agent-b ("cocopilot-agent-b" /
    "<SessionName>-agent-b").

.PARAMETER SessionName
    Convenience prefix applied to both -NameA and -NameB when they aren't
    explicitly passed — e.g. -SessionName "claim" yields "claim-agent-a" /
    "claim-agent-b", shown as both the copilot session name and the new
    window/tab's title, so several concurrent pairings stay identifiable
    at a glance. Has no effect on a -NameA/-NameB that's explicitly
    supplied.

.PARAMETER ShellExe
    Path to the PowerShell executable used for each new window. Defaults to
    whatever host is currently running this script (via the running
    process's own path), so if you invoke start-agents.ps1 from pwsh, the
    new windows are pwsh too — not Windows PowerShell 5.1's powershell.exe,
    which has a separate $PROFILE and would not define any shortcut
    functions you rely on via -AgentACommand/-AgentBCommand. Override this
    if you deliberately want a different shell. If this resolves to
    PowerShell ISE (powershell_ise.exe), it's automatically swapped for
    powershell.exe instead, since ISE isn't a console host and can't run
    the -NoExit/-EncodedCommand invocation this script needs.

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project
    # works out of the box: agent-a and agent-b both via the real `copilot`
    # CLI, claude-sonnet-5 and gpt-5.6-sol respectively, paired on that repo

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project -AgentACommand copilot-sonnet -AgentAArgs @() -AgentBCommand copilot-sol -AgentBArgs @() -UseWindowsTerminal:$false
    # use your own PowerShell profile shortcuts instead of the literal
    # defaults, and force plain console windows instead of wt.exe tabs

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\claim -SessionName claim
    # tabs/windows and copilot session names are "claim-agent-a" /
    # "claim-agent-b" - handy when pairing on several repos at once
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$ContextRoot,
    [string]$AgentACommand = "copilot",
    [string[]]$AgentAArgs = @("--model", "claude-sonnet-5", "--effort", "max", "--context", "long_context", "--autopilot", "--allow-all"),
    [string]$AgentBCommand = "copilot",
    [string[]]$AgentBArgs = @("--model", "gpt-5.6-sol", "--effort", "max", "--context", "long_context", "--autopilot", "--allow-all"),
    [string]$NameA = "cocopilot-agent-a",
    [string]$NameB = "cocopilot-agent-b",
    [string]$SessionName,
    [switch]$UseWindowsTerminal = $true,
    [string]$ShellExe = (Get-Process -Id $PID).Path
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$NameA = Resolve-CocopilotAgentName -CurrentValue $NameA -ExplicitlyBound $PSBoundParameters.ContainsKey('NameA') -SessionName $SessionName -AgentRole "agent-a"
$NameB = Resolve-CocopilotAgentName -CurrentValue $NameB -ExplicitlyBound $PSBoundParameters.ContainsKey('NameB') -SessionName $SessionName -AgentRole "agent-b"

if ((Split-Path -Leaf $ShellExe) -ieq "powershell_ise.exe") {
    # ISE can't be launched with the -NoExit/-EncodedCommand console
    # arguments this script relies on (it isn't a console host), so
    # $ShellExe auto-detecting ISE would otherwise silently fail to spawn
    # working agent windows. Fall back to the real console host instead of
    # leaving this broken.
    Write-Warning "ShellExe resolved to PowerShell ISE ('$ShellExe'), which can't host the console arguments this script needs. Falling back to powershell.exe."
    $ShellExe = "powershell.exe"
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

    # Sets the new console's own window title - the only thing that gives
    # the plain (non-Windows-Terminal) console-window path any title at
    # all; harmless alongside wt.exe's own --title/--suppressApplicationTitle
    # below (that pair keeps the wt tab's title fixed regardless of
    # whatever this in-process statement does).
    $innerScript = (Get-CocopilotWindowTitleStatement -Title $Name) + $copilotInvocation

    # -EncodedCommand avoids all nested-quoting problems (works regardless
    # of spaces/quotes in RepoPath or the prompt text) and still loads
    # $ShellExe's own $PROFILE, so a personal shortcut function passed via
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

Start-CopilotAgent -RepoPath $RepoPath -ContextRoot $ContextRoot -CocopilotRoot $cocopilotRoot -AgentCommand $AgentACommand -AgentArgs $AgentAArgs -Name $NameA -PromptPath $promptA -AgentRole "agent-a" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal
Start-Sleep -Seconds 1
Start-CopilotAgent -RepoPath $RepoPath -ContextRoot $ContextRoot -CocopilotRoot $cocopilotRoot -AgentCommand $AgentBCommand -AgentArgs $AgentBArgs -Name $NameB -PromptPath $promptB -AgentRole "agent-b" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal

Write-Host "Launched $NameA via '$AgentACommand' and $NameB via '$AgentBCommand' (shell: $ShellExe), paired on $RepoPath." -ForegroundColor Green
