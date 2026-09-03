#Requires -Version 5.1
<#
.SYNOPSIS
    Installs or updates cocopilot on this machine: updates the git clone
    (when possible) and registers the profile functions (cocopilot-start,
    cocopilot-prompt, cocopilot-cleanup, cocopilot-update, copilot-sonnet,
    copilot-terra, copilot-sol) in your PowerShell profile.

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

    The block is written to the CURRENT PowerShell edition's
    CurrentUserAllHosts profile (pwsh and Windows PowerShell keep separate
    profiles) — run the installer once under each host you use.

.PARAMETER InstallDir
    The cocopilot clone to register. Defaults to this script's own
    directory; when the script is piped (no directory), the bootstrap
    clone path $HOME\cocopilot is used.

.PARAMETER ProfilePath
    Profile file to write the dot-source block into. Defaults to
    $PROFILE.CurrentUserAllHosts.

.PARAMETER SkipUpdate
    Skip the `git pull` step (used by tests; also handy offline).
#>
param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$ProfilePath,
    [switch]$SkipUpdate
)

$ErrorActionPreference = "Stop"

if (-not $InstallDir) {
    # Piped via `irm | iex`: no script location. Bootstrap: clone, then
    # hand off to the cloned installer so everything below runs from disk.
    $InstallDir = Join-Path $HOME "cocopilot"
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir ".git"))) {
        Write-Host "Bootstrapping: cloning cocopilot into $InstallDir..." -ForegroundColor Cyan
        git clone https://github.com/David-c0degeek/cocopilot $InstallDir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed. For a private repo, clone with authenticated git/gh yourself, then run install.ps1 from the clone." }
    }
    & (Join-Path $InstallDir "install.ps1") -InstallDir $InstallDir -ProfilePath $ProfilePath -SkipUpdate:$SkipUpdate
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
$block = "$beginMarker`n. '$($snippetPath -replace "'", "''")'`n$endMarker"

$profileDir = Split-Path -Parent $ProfilePath
if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
    [System.IO.Directory]::CreateDirectory($profileDir) | Out-Null
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
if (Test-Path -LiteralPath $ProfilePath) {
    $raw = Get-Content -LiteralPath $ProfilePath -Raw
    $pattern = "(?s)" + [regex]::Escape($beginMarker) + ".*?" + [regex]::Escape($endMarker)
    if ($raw -match $pattern) {
        $newRaw = [regex]::Replace($raw, $pattern, { param($m) $block })
        $action = "Refreshed the cocopilot block in"
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
Write-Host "Functions: cocopilot-start, cocopilot-prompt, cocopilot-cleanup, cocopilot-update, copilot-sonnet, copilot-terra, copilot-sol" -ForegroundColor Green
Write-Host "Restart your shell (or run: . '$snippetPath') to use them now. Run this installer once per PowerShell edition you use (pwsh / Windows PowerShell)." -ForegroundColor Cyan
