#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for cocopilot's launcher scripts. Dot-source this, don't
    run it directly.
#>

function ConvertTo-SingleQuoted {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Write-MailboxJson {
    <#
    .SYNOPSIS
        Replaces a mailbox JSON file (implementer.json) whole-file via
        same-directory temp-file rename: best-effort crash safety against
        torn/partial writes. Deliberately NOT atomic in any API-contract
        sense, and no protection against two valid concurrent writers —
        last writer wins; the epoch rule and the user resolve those races
        (see COLLABORATION.md).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "Write-MailboxJson: -Path must be a file, but a directory exists there: $Path"
    }

    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
    # -Compress: non-compressed ConvertTo-Json output is formatted
    # differently by Windows PowerShell 5.1 vs pwsh 7, which would make this
    # watched file's bytes churn whenever the peer runs the other host.
    # Compressed output is byte-identical on both.
    $json = ($Object | ConvertTo-Json -Depth 5 -Compress) + "`n"
    $moved = $false
    try {
        # UTF-8 without BOM via .NET so Windows PowerShell 5.1 and pwsh 7
        # produce identical bytes.
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        # -ErrorAction Stop: the failure must terminate regardless of the
        # caller's $ErrorActionPreference, or the finally-cleanup is skipped
        # and a stale temp file leaks.
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        $moved = $true
    } finally {
        if (-not $moved -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

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

    $isGitRepo = $false
    try {
        $null = git -C $RepoPath rev-parse --is-inside-work-tree 2>$null
        $isGitRepo = ($LASTEXITCODE -eq 0)
    } catch { $isGitRepo = $false }

    $allowNonGitFlag = if ($isGitRepo) { "" } else { " -AllowNonGit" }
    return "& $(ConvertTo-SingleQuoted $InitScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath)$allowNonGitFlag"
}

function Resolve-CocopilotAgentName {
    <#
    .SYNOPSIS
        Resolves the effective session/window name for one agent: an
        explicitly-bound -NameA/-NameB always wins; otherwise -SessionName
        (if given) derives "<SessionName>-<AgentRole>"; otherwise the
        caller's own inline default (already in $CurrentValue) stands.
    #>
    param(
        [Parameter(Mandatory)][string]$CurrentValue,
        [Parameter(Mandatory)][bool]$ExplicitlyBound,
        [string]$SessionName,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$AgentRole
    )

    if (-not $ExplicitlyBound -and $SessionName) {
        return "$SessionName-$AgentRole"
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

    return @(
        "-w", "0",
        "new-tab",
        "--title", $Title,
        "--suppressApplicationTitle",
        "--startingDirectory", $RepoPath,
        "--",
        $ShellExe, "-NoExit", "-EncodedCommand", $EncodedCommand
    )
}

function Get-CocopilotSessionBanner {
    <#
    .SYNOPSIS
        Builds the "session context" banner prepended to each agent's
        prompt, so the same static prompts/agent-*.md files can target any
        repository without hardcoding its name or path.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$CocopilotRoot,
        [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b", "verifier")][string]$AgentRole,
        [string]$ContextRoot
    )

    $collaborationPath = Join-Path $CocopilotRoot "COLLABORATION.md"
    $watchScript = Join-Path $CocopilotRoot "scripts\watch-mailbox.ps1"
    $initScript = Join-Path $CocopilotRoot "scripts\init-mailbox.ps1"
    $commonScript = Join-Path $CocopilotRoot "scripts\_common.ps1"
    $implementerJson = Join-Path $RepoPath ".mailbox\implementer.json"
    $watchCmd = "& $(ConvertTo-SingleQuoted $watchScript) -RepoPath $(ConvertTo-SingleQuoted $RepoPath) -Role $AgentRole"
    $initCmd = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript $initScript
    $ownershipCmd = ". $(ConvertTo-SingleQuoted $commonScript); Write-MailboxJson -Path $(ConvertTo-SingleQuoted $implementerJson) -Object `$record"

    $core = @"
## Session context (auto-generated by cocopilot — do not hand-edit)

- Your role: $AgentRole
- Target repository: $RepoPath
- Mailbox: $RepoPath\.mailbox\ (implementer.json, agent-a.md, agent-b.md, session.log.md)
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
    $myLane = Join-Path $RepoPath ".mailbox\$AgentRole.md"
    $peerLane = Join-Path $RepoPath ".mailbox\$peerRole.md"

    return $core + @"

- Your lane (the ONLY mailbox file you may write): $myLane
- Peer lane (read-only to you): $peerLane

- Watch command (wakes only on peer-lane/ownership changes — run in the
  background whenever you're blocked waiting on the peer):
  $watchCmd
- Init command (only if the mailbox files above don't exist yet):
  $initCmd
- Ownership-record update (the ONLY allowed way to write implementer.json —
  build `$record as the complete new object first, then run; never edit the
  file in place):
  $ownershipCmd

---

"@
}
