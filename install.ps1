#Requires -Version 7.4

<#
.SYNOPSIS
    Installs or updates cocopilot on this machine: updates the git clone
    (when possible) and registers the profile functions (cocopilot-start,
    cocopilot-models, cocopilot-prompt, cocopilot-cleanup, cocopilot-update,
    copilot-opus, copilot-terra, copilot-sol) in your PowerShell profile,
    then registers the bundled cocopilot-agent-prompt skill with the
    Copilot CLI.

.DESCRIPTION
    Two ways to run it:

      1. From a clone (normal case — also what cocopilot-update reruns):
           git clone https://github.com/David-c0degeek/cocopilot $HOME\cocopilot
           & $HOME\cocopilot\install.ps1

      2. Piped, without cloning first (bootstrap):
           irm https://raw.githubusercontent.com/David-c0degeek/cocopilot/main/install.ps1 | iex
         In this mode there is no script location, so it clones into
         $HOME\cocopilot itself and re-runs the installer from there.
         (Requires the repo to be reachable — for a private repo, clone
         with authenticated git/gh first and use way 1.)

    The profile gets only a tiny marker-guarded block that dot-sources
    profile\cocopilot.profile.ps1 from the install directory — so after
    the first install, `cocopilot-update` (a `git pull` + rerun of this
    script) refreshes everything with no further profile edits. Re-running
    is idempotent: an existing block is replaced in place, never
    duplicated.

    Requires PowerShell 7.4 or later: run it from pwsh. The block is
    written to pwsh's CurrentUserAllHosts profile. A block that an earlier
    version wrote into a Windows PowerShell profile is not removed; delete
    it there by hand.

    After the profile block, the installer registers the bundled skill
    directory <install>\.github\skills (the cocopilot-agent-prompt skill)
    with the stock Copilot CLI: `copilot skill add '<dir>'`, once. It
    first reads `copilot config skillDirectories` and adds nothing when the
    directory is already listed. When the CLI is missing or a step fails,
    it warns and still finishes the install. A checkout without the
    bundled SKILL.md is reported as incomplete. It never removes or disables
    a skill; when another skill named cocopilot-agent-prompt exists, it only
    names that skill's folder and source.

.PARAMETER InstallDir
    The cocopilot clone to register. Defaults to this script's own
    directory; when the script is piped (no directory), the bootstrap
    clone path $HOME\cocopilot is used.

.PARAMETER ProfilePath
    Profile file to write the dot-source block into. Defaults to
    $PROFILE.CurrentUserAllHosts.

.PARAMETER SkipUpdate
    Skip the `git pull` step (used by tests; also handy offline).

.PARAMETER SkipSkillRegistration
    Do not register the bundled skill directory with the Copilot CLI, and
    do not run the CLI at all (used by tests). Register it later with
    `copilot skill add '<install>\.github\skills'`.
#>
param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$ProfilePath,
    [switch]$SkipUpdate,
    [switch]$SkipSkillRegistration
)

# Explicit check on top of #Requires: `irm | iex` ignores #Requires, and
# this must stop before the bootstrap clone and any profile edit below.
if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    throw "cocopilot requires PowerShell 7.4 or later (pwsh). Run this installer from pwsh."
}

$ErrorActionPreference = "Stop"
# Expected non-zero git exits (not a clone, pull failed) are handled through
# $LASTEXITCODE below, whatever the caller's profile sets here. A missing git
# still fails loudly.
$PSNativeCommandUseErrorActionPreference = $false

if (-not $InstallDir) {
    # Piped via `irm | iex`: no script location. Bootstrap: clone, then
    # hand off to the cloned installer so everything below runs from disk.
    $InstallDir = Join-Path $HOME "cocopilot"
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir ".git"))) {
        Write-Host "Bootstrapping: cloning cocopilot into $InstallDir..." -ForegroundColor Cyan
        git clone https://github.com/David-c0degeek/cocopilot $InstallDir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed. For a private repo, clone with authenticated git/gh yourself, then run install.ps1 from the clone." }
    }
    & (Join-Path $InstallDir "install.ps1") -InstallDir $InstallDir -ProfilePath $ProfilePath -SkipUpdate:$SkipUpdate -SkipSkillRegistration:$SkipSkillRegistration
    return
}

$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path
if (-not $ProfilePath) { $ProfilePath = $PROFILE.CurrentUserAllHosts }

$snippetPath = Join-Path $InstallDir "profile\cocopilot.profile.ps1"
if (-not (Test-Path -LiteralPath $snippetPath)) {
    throw "Not a cocopilot install: missing $snippetPath"
}

# 1. Update the clone (best-effort).
if (-not $SkipUpdate) {
    $null = git -C $InstallDir rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Updating $InstallDir (git pull --ff-only)..." -ForegroundColor Cyan
        git -C $InstallDir pull --ff-only
        if ($LASTEXITCODE -ne 0) { Write-Warning "git pull failed (offline? diverged?). Continuing with the currently installed version." }
    } else {
        Write-Warning "$InstallDir is not a git clone; skipping update."
    }
}

# 2. Register the marker-guarded dot-source block in the profile.
$beginMarker = "# >>> cocopilot >>>"
$endMarker = "# <<< cocopilot <<<"
$block = "$beginMarker`n. '$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($snippetPath))'`n$endMarker"

$profileDir = Split-Path -Parent $ProfilePath
if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
    [System.IO.Directory]::CreateDirectory($profileDir) | Out-Null
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
if (Test-Path -LiteralPath $ProfilePath) {
    # An existing empty profile reads back as $null (no pipeline output).
    $raw = Get-Content -LiteralPath $ProfilePath -Raw
    if ($null -eq $raw) { $raw = "" }
    $pattern = "(?s)" + [regex]::Escape($beginMarker) + ".*?" + [regex]::Escape($endMarker)
    if ($raw -match $pattern) {
        $newRaw = [regex]::Replace($raw, $pattern, { param($m) $block })
        $action = "Refreshed the cocopilot block in"
    } elseif ($raw.Trim().Length -eq 0) {
        $newRaw = $block + "`n"
        $action = "Wrote the cocopilot block into the empty profile"
    } else {
        $newRaw = $raw.TrimEnd() + "`n`n" + $block + "`n"
        $action = "Appended the cocopilot block to"
    }
    [System.IO.File]::WriteAllText($ProfilePath, $newRaw, $utf8NoBom)
} else {
    [System.IO.File]::WriteAllText($ProfilePath, $block + "`n", $utf8NoBom)
    $action = "Created"
}

Write-Host "$action $ProfilePath" -ForegroundColor Green
Write-Host "Functions: cocopilot-start, cocopilot-models, cocopilot-prompt, cocopilot-cleanup, cocopilot-update, copilot-opus, copilot-terra, copilot-sol" -ForegroundColor Green
Write-Host "Restart pwsh (or run: . '$snippetPath') to use them now." -ForegroundColor Cyan

# 3. Register the bundled skill directory with the stock Copilot CLI.
if ($SkipSkillRegistration) {
    Write-Host "Skipped registering the cocopilot-agent-prompt skill (-SkipSkillRegistration)." -ForegroundColor Cyan
    return
}

$skillName = "cocopilot-agent-prompt"
$skillsDir = Join-Path $InstallDir ".github\skills"

function ConvertTo-LiteralArgument {
    # A single-quoted PowerShell literal, so a hint copied into PowerShell
    # never expands a '$' in the path. Needs no cocopilot helper.
    param([Parameter(Mandatory)][string]$Value)
    return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'"
}

$registerCommand = "copilot skill add $(ConvertTo-LiteralArgument -Value $skillsDir)"

function Write-SkillNotRegistered {
    # The install itself has succeeded; only the optional skill is missing.
    param([Parameter(Mandatory)][string]$Reason)
    Write-Warning "cocopilot is installed, but the skill $skillName was NOT registered: $($Reason.Trim().TrimEnd('.')). Register it with: $registerCommand"
}

# A bundle without its SKILL.md is a damaged or outdated checkout: adding the
# directory would register nothing useful, so the checkout is repaired first.
$bundledSkill = Join-Path $skillsDir "$skillName\SKILL.md"
if (-not (Test-Path -LiteralPath $bundledSkill -PathType Leaf)) {
    $installLiteral = ConvertTo-LiteralArgument -Value $InstallDir
    Write-Warning ("cocopilot is installed, but the skill $skillName was NOT registered: the checkout $InstallDir is " +
        "incomplete ($bundledSkill is missing). Repair or update the checkout first: git -C $installLiteral status, " +
        "then git -C $installLiteral pull --ff-only, or clone it again. Then rerun: " +
        "& $(ConvertTo-LiteralArgument -Value (Join-Path $InstallDir 'install.ps1'))")
    return
}

try {
    # Same resolution as the launcher: the first native executable or script
    # named copilot on PATH, never a same-name profile function.
    . (Join-Path $InstallDir "scripts\_common.ps1")
    . (Join-Path $InstallDir "scripts\_models.ps1")
    $copilotCommand = Resolve-CocopilotCommand
    $canonicalSkillsDir = Get-CocopilotCanonicalPath -Path $skillsDir
} catch {
    Write-SkillNotRegistered -Reason $_.Exception.Message
    return
}

function Test-SameSkillsDir {
    # Compares canonically: letter case, trailing separators and aliases
    # (junction, subst drive) never count as another directory.
    param([Parameter(Mandatory)][string]$Path)
    try {
        return (Get-CocopilotCanonicalPath -Path $Path) -ieq $canonicalSkillsDir
    } catch {
        return $Path.TrimEnd('\', '/') -ieq $skillsDir.TrimEnd('\', '/')
    }
}

function Invoke-CopilotCapture {
    # Runs the CLI with stdout and stderr kept apart, so a failure always
    # carries its own message and is never read as data.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& $copilotCommand @Arguments 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Stdout   = (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
        Stderr   = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
    }
}

try {
    # An unset list (exit 1, no output) means "nothing registered yet"; any
    # other failure must not be mistaken for it.
    $setting = Get-CocopilotCliSetting -CopilotCommand $copilotCommand -Key "skillDirectories"
    $registeredDirs = @()
    if ($setting.State -eq "Set") {
        $registeredDirs = @($setting.Value -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if (@($registeredDirs | Where-Object { Test-SameSkillsDir -Path $_ }).Count -gt 0) {
        Write-Host "The skill directory $skillsDir is already registered with the Copilot CLI ($skillName)." -ForegroundColor Green
    } else {
        $add = Invoke-CopilotCapture -Arguments @("skill", "add", $skillsDir)
        if ($add.ExitCode -ne 0) {
            $detail = (@($add.Stdout, $add.Stderr) | Where-Object { $_ }) -join " "
            Write-SkillNotRegistered -Reason "'$copilotCommand skill add' failed (exit $($add.ExitCode)): $detail"
            return
        }
        Write-Host "Registered the skill directory $skillsDir with the Copilot CLI ($skillName)." -ForegroundColor Green
    }
} catch {
    Write-SkillNotRegistered -Reason $_.Exception.Message
    return
}

# Another skill with the same name may shadow the bundled one. Only report
# it: removing it is the user's decision, and a remove of its parent folder
# would unregister a whole collection of skills.
try {
    $list = Invoke-CopilotCapture -Arguments @("skill", "list", "--json")
    if ($list.ExitCode -ne 0) {
        $detail = (@($list.Stdout, $list.Stderr) | Where-Object { $_ }) -join " "
        throw "'$copilotCommand skill list --json' failed (exit $($list.ExitCode)): $detail"
    }
    if ([string]::IsNullOrWhiteSpace($list.Stdout)) {
        throw "'$copilotCommand skill list --json' returned no output."
    }
    try {
        $skills = @($list.Stdout | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "'$copilotCommand skill list --json' did not return valid JSON: $($_.Exception.Message)"
    }
    foreach ($skill in $skills) {
        if ([string]$skill.name -ne $skillName -or [string]::IsNullOrWhiteSpace([string]$skill.path)) { continue }
        $skillDir = [string]$skill.path
        if ((Split-Path -Leaf $skillDir) -ieq "SKILL.md") { $skillDir = Split-Path -Parent $skillDir }
        if (Test-SameSkillsDir -Path (Split-Path -Parent $skillDir)) { continue }
        Write-Warning ("Another skill named $skillName is also available: '$skillDir' (source '$($skill.source)'). " +
            "cocopilot leaves it in place. Whether to remove it is your decision; remove a plugin or project skill " +
            "through the plugin or repository that owns it.")
    }
} catch {
    Write-Warning "The skill $skillName is registered, but the duplicate check could not complete: $($_.Exception.Message)"
}