#Requires -Version 7.4

<#
.SYNOPSIS
    Prints the ready-to-paste prompt (session-context banner + role prompt)
    for one agent, targeting a given repository.

.DESCRIPTION
    start-agents.ps1 builds this automatically. Use this instead when you
    want to paste a role prompt into an already-running `copilot` window
    manually (see README.md) rather than having start-agents.ps1 launch it
    for you — e.g. to add a second agent to a session you already opened by
    hand. The mailbox lives outside the target, so launch such a window
    with --add-dir <pair dir> (the banner's Mailbox line shows it) and
    --add-dir <cocopilot install>; the same holds for a fresh verifier
    session and for copilot --resume <id>.

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

.PARAMETER Transport
    Which waiting guidance and banner commands to render: "mailbox" (the
    background watch) or "direct" (native peer messages, see
    start-agents.ps1 -Transport). The pair's registration decides: direct
    when the mailbox's sessions.json fits this target and Copilot configuration
    directory, mailbox when there is none. "auto" (the default) follows it;
    an explicit value only asserts it. Any mismatch, or a registration that
    exists but does not fit, stops with the reason, so the two agents of a
    pair never end up on different transports. Rendering never registers a
    session: a direct prompt only works in the window whose session id the
    registration names, for example one restarted with
    `copilot --resume <id>`, and a warning says so.

.EXAMPLE
    .\scripts\render-prompt.ps1 -Agent b -RepoPath C:\Repos\some-other-project
    # copy the output and paste it into your second copilot window
#>
param(
    [Parameter(Mandatory)][ValidateSet("a", "b", "verifier")][string]$Agent,
    [string]$RepoPath = (Get-Location).Path,
    [string]$ContextRoot,
    [ValidateSet("auto", "mailbox", "direct")][string]$Transport = "auto"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
if ($ContextRoot) { $ContextRoot = (Resolve-Path -LiteralPath $ContextRoot).Path }
$cocopilotRoot = Split-Path -Parent $PSScriptRoot
$mailboxDir = Open-CocopilotMailbox -RepoPath $RepoPath
switch ($Agent) {
    "a"        { $agentRole = "agent-a" }
    "b"        { $agentRole = "agent-b" }
    "verifier" { $agentRole = "verifier" }
}

if ($agentRole -eq "verifier") {
    # The verifier never talks to the pair, so the transport does not apply.
    $Transport = "mailbox"
} else {
    # Both agents of a pair must use the transport the pair was launched
    # with, or a direct agent could wait forever for a hint its mailbox peer
    # never sends. Rendering only checks this; it never changes the
    # registration. Only start-agents.ps1 registers or removes it.
    $probe = Get-CocopilotPeerNotification -MailboxDir $mailboxDir -RepoPath $RepoPath -Role $agentRole -ConfigDir (Get-CocopilotConfigDir)
    $relaunch = "Relaunch the pair with start-agents.ps1 -Transport mailbox or -Transport direct."
    switch ($probe.State) {
        "None" {
            if ($Transport -eq "direct") {
                throw "Cannot render the direct transport: there is no sessions.json in this pair's mailbox ($mailboxDir). $relaunch"
            }
            $Transport = "mailbox"
        }
        "Ready" {
            if ($Transport -eq "mailbox") {
                throw "Cannot render the mailbox transport: this pair is registered for the direct transport ($mailboxDir\sessions.json), so its peer would never be woken. $relaunch"
            }
            $Transport = "direct"
        }
        default { throw "Cannot render a prompt for this pair: $($probe.Reason) $relaunch" }
    }
}

$rolePrompt = Get-CocopilotRolePrompt -CocopilotRoot $cocopilotRoot -AgentRole $agentRole -Transport $Transport
$banner = Get-CocopilotSessionBanner -RepoPath $RepoPath -CocopilotRoot $cocopilotRoot -AgentRole $agentRole -ContextRoot $ContextRoot -Transport $Transport
if ($Transport -eq "direct") {
    # The warning stream, so it never becomes part of the copied prompt.
    $ownId = (Read-CocopilotSessionRegistration -MailboxDir $mailboxDir).Record.agents.$agentRole.sessionId
    Write-Warning ("This direct-transport prompt works only in the Copilot session $ownId, the one the pair registered. " +
        "A new window gets another session id, so its peer could not wake it: restart a closed window with " +
        "'copilot --resume $ownId' instead, or relaunch the pair.")
}
$banner + $rolePrompt
