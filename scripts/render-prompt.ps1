#Requires -Version 5.1
<#
.SYNOPSIS
    Prints the ready-to-paste prompt (session-context banner + role prompt)
    for one agent, targeting a given repository.

.DESCRIPTION
    start-agents.ps1 builds this automatically. Use this instead when you
    want to paste a role prompt into an already-running `copilot` window
    manually (see README.md) rather than having start-agents.ps1 launch it
    for you — e.g. to add a second agent to a session you already opened by
    hand.

.PARAMETER Agent
    Which role to render: "a", "b", or "verifier" (the read-only fresh-eyes
    verification role — see COLLABORATION.md "Fresh-eyes verification").

.PARAMETER RepoPath
    The repository being paired on. Defaults to the current directory.

.PARAMETER ContextRoot
    Optional workspace root granted as a READ-ONLY search scope in the
    banner (see start-agents.ps1 -ContextRoot and COLLABORATION.md
    "Workspace context"). When pasting manually, also launch the copilot
    window with --add-dir <ContextRoot> so the CLI can actually reach it.

.EXAMPLE
    .\scripts\render-prompt.ps1 -Agent b -RepoPath C:\Repos\some-other-project
    # copy the output and paste it into your second copilot window
#>
param(
    [Parameter(Mandatory)][ValidateSet("a", "b", "verifier")][string]$Agent,
    [string]$RepoPath = (Get-Location).Path,
    [string]$ContextRoot
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
if ($ContextRoot) { $ContextRoot = (Resolve-Path -LiteralPath $ContextRoot).Path }
$cocopilotRoot = Split-Path -Parent $PSScriptRoot
# Explicit three-way mapping — role id and prompt filename don't follow one
# shared pattern ("verifier" has no "agent-" prefix), so map both by name.
switch ($Agent) {
    "a"        { $agentRole = "agent-a";  $promptFile = "agent-a.md" }
    "b"        { $agentRole = "agent-b";  $promptFile = "agent-b.md" }
    "verifier" { $agentRole = "verifier"; $promptFile = "verifier.md" }
}
$promptPath = Join-Path $cocopilotRoot "prompts\$promptFile"

if (-not (Test-Path -LiteralPath $promptPath)) { throw "Missing prompt file: $promptPath" }

$banner = Get-CocopilotSessionBanner -RepoPath $RepoPath -CocopilotRoot $cocopilotRoot -AgentRole $agentRole -ContextRoot $ContextRoot
$banner + (Get-Content -LiteralPath $promptPath -Raw)
