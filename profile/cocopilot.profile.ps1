# cocopilot profile functions — dot-sourced from your PowerShell profile by
# the marker block install.ps1 writes there. Everything resolves off this
# file's own location, so `cocopilot-update` (git pull) refreshes these
# functions with no profile edits. Safe to re-source at any time.

$script:CocopilotRoot = Split-Path -Parent $PSScriptRoot

function copilot-sonnet {
    # Plain copilot CLI pinned to claude-sonnet-5 with cocopilot's default flags.
    copilot --model claude-sonnet-5 --effort max --context long_context --autopilot --allow-all @args
}

function copilot-terra {
    # Plain copilot CLI pinned to gpt-5.6-terra with cocopilot's default flags.
    copilot --model gpt-5.6-terra --effort max --context long_context --autopilot --allow-all @args
}

function Initialize-CocopilotMailboxIfMissing {
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )
    $mailboxDir = Join-Path $RepoPath ".mailbox"
    $required = @("implementer.json", "agent-a.md", "agent-b.md", "session.log.md") |
        ForEach-Object { Join-Path $mailboxDir $_ }
    if (@($required | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0) {
        & (Join-Path $script:CocopilotRoot "scripts\init-mailbox.ps1") -RepoPath $RepoPath
    }
}

function cocopilot-start {
    # Inits the mailbox if missing, then opens both agent windows paired on
    # $RepoPath. -ContextRoot grants a read-only search scope across a
    # workspace of sibling repos (see COLLABORATION.md "Workspace context").
    param(
        [string]$RepoPath = (Get-Location).Path,
        [string]$ContextRoot,
        [switch]$UseWindowsTerminal
    )
    Initialize-CocopilotMailboxIfMissing -RepoPath $RepoPath
    $extra = @{}
    if ($ContextRoot) { $extra.ContextRoot = $ContextRoot }
    if ($UseWindowsTerminal) { $extra.UseWindowsTerminal = $true }
    & (Join-Path $script:CocopilotRoot "scripts\start-agents.ps1") -RepoPath $RepoPath @extra
}

function cocopilot-prompt {
    # Copies the paste-ready (re)start prompt for one role to the clipboard —
    # session-context banner + role instructions, fully resolved to
    # $RepoPath. Paste into a fresh copilot-sonnet/copilot-terra window if
    # one crashes or you add a role manually; "verifier" renders the
    # read-only fresh-eyes role for a brand-new session.
    param(
        [Parameter(Mandatory)][ValidateSet("a", "b", "verifier")][string]$Agent,
        [string]$RepoPath = (Get-Location).Path,
        [string]$ContextRoot
    )
    Initialize-CocopilotMailboxIfMissing -RepoPath $RepoPath
    $extra = @{}
    if ($ContextRoot) { $extra.ContextRoot = $ContextRoot }
    $prompt = & (Join-Path $script:CocopilotRoot "scripts\render-prompt.ps1") -Agent $Agent -RepoPath $RepoPath @extra
    $prompt | Set-Clipboard
    Write-Host "cocopilot $(if ($Agent -eq 'verifier') { 'verifier' } else { "agent-$Agent" }) prompt for '$RepoPath' copied to clipboard - paste it into that window." -ForegroundColor Green
}

function cocopilot-cleanup {
    # Removes cocopilot's .mailbox/ directory and its .gitignore rule from
    # $RepoPath. Supports -WhatIf to preview. With -Recurse, treats
    # $RepoPath as a search root and cleans up every repository with a
    # .mailbox/ found at or below it (e.g. run in C:\Repos to clean every
    # paired repo underneath).
    param(
        [string]$RepoPath = (Get-Location).Path,
        [switch]$Recurse,
        [switch]$WhatIf
    )
    & (Join-Path $script:CocopilotRoot "scripts\cleanup-mailbox.ps1") -RepoPath $RepoPath -Recurse:$Recurse -WhatIf:$WhatIf
}

function cocopilot-update {
    # git pull + re-register: reruns install.ps1 on this install. (A new
    # shell — or dot-sourcing the snippet at the global scope — picks up
    # any changed functions; a dot-source inside this function would not.)
    & (Join-Path $script:CocopilotRoot "install.ps1") -InstallDir $script:CocopilotRoot
}
