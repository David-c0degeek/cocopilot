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

    Agent A starts as the active implementer (per <RepoPath>/.mailbox, see
    init-mailbox.ps1). Agent B starts by reading COLLABORATION.md and the
    mailbox, then waiting for a HANDOFF_OFFER before writing anything.

    Run the init-mailbox.ps1 script from this cocopilot install with
    -RepoPath <RepoPath> first if that repository's mailbox doesn't exist yet.

.PARAMETER RepoPath
    The repository to pair on. Defaults to the current directory.

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
    to a literal gpt-5.6-terra configuration:
    --model gpt-5.6-terra --effort max --context long_context --autopilot
    --allow-all. Pass @() if AgentBCommand is your own shortcut.

.PARAMETER UseWindowsTerminal
    Launch via `wt.exe` new tabs instead of plain new console windows.

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
    # CLI, claude-sonnet-5 and gpt-5.6-terra respectively, paired on that repo

.EXAMPLE
    .\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project -AgentACommand copilot-sonnet -AgentAArgs @() -AgentBCommand copilot-terra -AgentBArgs @() -UseWindowsTerminal
    # use your own PowerShell profile shortcuts instead of the literal defaults
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$AgentACommand = "copilot",
    [string[]]$AgentAArgs = @("--model", "claude-sonnet-5", "--effort", "max", "--context", "long_context", "--autopilot", "--allow-all"),
    [string]$AgentBCommand = "copilot",
    [string[]]$AgentBArgs = @("--model", "gpt-5.6-terra", "--effort", "max", "--context", "long_context", "--autopilot", "--allow-all"),
    [string]$NameA = "cocopilot-agent-a",
    [string]$NameB = "cocopilot-agent-b",
    [switch]$UseWindowsTerminal,
    [string]$ShellExe = (Get-Process -Id $PID).Path
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

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
$cocopilotRoot = Split-Path -Parent $PSScriptRoot
$promptA = Join-Path $cocopilotRoot "prompts\agent-a.md"
$promptB = Join-Path $cocopilotRoot "prompts\agent-b.md"
$initMailboxScript = Join-Path $PSScriptRoot "init-mailbox.ps1"
$implementerPath = Join-Path $RepoPath ".mailbox\implementer.json"
$mailboxPath = Join-Path $RepoPath ".mailbox\mailbox.md"
$sessionLogPath = Join-Path $RepoPath ".mailbox\session.log.md"

if (-not (Test-Path -LiteralPath $implementerPath) -or -not (Test-Path -LiteralPath $mailboxPath) -or -not (Test-Path -LiteralPath $sessionLogPath)) {
    $initCommand = "& $(ConvertTo-SingleQuoted $initMailboxScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath)"
    throw "Mailbox state for '$RepoPath' is incomplete; run $initCommand first."
}
foreach ($p in @($promptA, $promptB)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing prompt file: $p" }
}

function Start-CopilotAgent {
    param(
        [string]$RepoPath,
        [string]$CocopilotRoot,
        [string]$AgentCommand,
        [string[]]$AgentArgs,
        [string]$Name,
        [string]$PromptPath,
        [ValidateSet("agent-a", "agent-b")][string]$AgentRole,
        [string]$ShellExe,
        [switch]$UseWindowsTerminal
    )

    $banner = Get-CocopilotSessionBanner -RepoPath $RepoPath -CocopilotRoot $CocopilotRoot -AgentRole $AgentRole
    $fullPrompt = $banner + (Get-Content -LiteralPath $PromptPath -Raw)

    $agentCommandQ = ConvertTo-SingleQuoted $AgentCommand
    $agentArgsQ = ($AgentArgs | ForEach-Object { ConvertTo-SingleQuoted $_ }) -join " "
    $repoQ = ConvertTo-SingleQuoted $RepoPath
    $nameQ = ConvertTo-SingleQuoted $Name
    $promptQ = ConvertTo-SingleQuoted $fullPrompt
    $addDirQ = ConvertTo-SingleQuoted $CocopilotRoot

    # --add-dir grants read/run access to cocopilot's own install (for
    # COLLABORATION.md and the watch/init scripts) even if AgentCommand's
    # underlying alias doesn't already pass --allow-all-paths.
    $innerScript = ("& $agentCommandQ " + $(if ($agentArgsQ) { "$agentArgsQ " } else { "" }) + "-C $repoQ -n $nameQ --add-dir $addDirQ -i $promptQ").Trim()

    # -EncodedCommand avoids all nested-quoting problems (works regardless
    # of spaces/quotes in RepoPath or the prompt text) and still loads
    # $ShellExe's own $PROFILE, so a personal shortcut function passed via
    # -AgentACommand/-AgentBCommand is available in the new window.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerScript))

    if ($UseWindowsTerminal -and (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        $wtArgs = @("new-tab", "--title", $Name, "--", $ShellExe, "-NoExit", "-EncodedCommand", $encoded)
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

Start-CopilotAgent -RepoPath $RepoPath -CocopilotRoot $cocopilotRoot -AgentCommand $AgentACommand -AgentArgs $AgentAArgs -Name $NameA -PromptPath $promptA -AgentRole "agent-a" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal
Start-Sleep -Seconds 1
Start-CopilotAgent -RepoPath $RepoPath -CocopilotRoot $cocopilotRoot -AgentCommand $AgentBCommand -AgentArgs $AgentBArgs -Name $NameB -PromptPath $promptB -AgentRole "agent-b" -ShellExe $ShellExe -UseWindowsTerminal:$UseWindowsTerminal

Write-Host "Launched $NameA via '$AgentACommand' and $NameB via '$AgentBCommand' (shell: $ShellExe), paired on $RepoPath." -ForegroundColor Green
