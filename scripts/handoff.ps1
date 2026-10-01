#Requires -Version 7.4

<#
.SYNOPSIS
    Changes the ownership record (implementer.json) the only supported
    way: offer, accept or cancel a handoff, or record the owner's model.

.DESCRIPTION
    Every action takes the mailbox's ownership lock, reads the record,
    checks that the action fits its current state, and only then replaces
    the whole record (see COLLABORATION.md "Ownership handoff"). A refused
    action changes nothing. Each action prints the entry to post in your
    lane with write-lane.ps1.

    Offer (the active owner): computes the dirty manifest - every
    difference between the baseline recorded when this ownership began and
    the current state of the target - and records the offer at the same
    epoch. Accept (the agent the offer names, with -Epoch): recomputes the
    manifest and requires it, and HEAD, to match the offer exactly; then
    records a fresh baseline and makes that agent the active owner at the
    next epoch. Cancel (the offering owner, with -Epoch): withdraws the
    offer at the next epoch, so it can never be accepted later. SetModel
    (the active owner): records which model it runs; the epoch stays.

    Offer and Accept refuse while the current state or the baseline is only
    partly captured: more than 20,000 changed or unversioned files or
    512 MB to hash, or a directory that cannot be listed. A git target is
    captured as its repository's HEAD, staged changes, and every changed or
    untracked path with its content hash, plus the same for every
    repository nested inside it (untracked, ignored or a submodule); a
    non-git workspace root as every git worktree below it plus every other
    file.

.PARAMETER RepoPath
    The repository (or workspace root) being paired on.

.PARAMETER Role
    Your own lane identity from the session banner: agent-a or agent-b.

.PARAMETER Action
    Offer, Accept, Cancel or SetModel.

.PARAMETER Epoch
    The epoch of the offer being accepted or cancelled, as printed by
    Offer. Required for Accept and Cancel.

.PARAMETER OwnerModel
    The model you run. Required for SetModel; recorded by Accept
    ("unknown" when omitted).

.EXAMPLE
    & .\scripts\handoff.ps1 -RepoPath C:\Repos\your-project -Role agent-a -Action Offer

.EXAMPLE
    & .\scripts\handoff.ps1 -RepoPath C:\Repos\your-project -Role agent-b -Action Accept -Epoch 3 -OwnerModel gpt-6.1-sol
#>
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$Role,
    [Parameter(Mandatory)][ValidateSet("Offer", "Accept", "Cancel", "SetModel")][string]$Action,
    [ValidateRange(1, [long]::MaxValue)][long]$Epoch,
    [string]$OwnerModel
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$mailboxDir = Join-Path $RepoPath ".mailbox"
$implementerPath = Join-Path $mailboxDir "implementer.json"
$peer = if ($Role -eq "agent-a") { "agent-b" } else { "agent-a" }

if (-not (Test-Path -LiteralPath $implementerPath -PathType Leaf)) {
    $initCommand = Get-CocopilotInitCommand -RepoPath $RepoPath -InitScript (Join-Path $PSScriptRoot "init-mailbox.ps1")
    throw "Missing mailbox file: $implementerPath. Run $initCommand first."
}
if ($Action -in @("Accept", "Cancel") -and -not $PSBoundParameters.ContainsKey("Epoch")) {
    throw "-Action $Action needs -Epoch: the epoch of the offer, as printed by Offer."
}
if ($Action -eq "SetModel" -and [string]::IsNullOrWhiteSpace($OwnerModel)) {
    throw "-Action SetModel needs -OwnerModel."
}

function Get-CurrentHead {
    # The record's head: HEAD for a git target, the fixed sentinel otherwise.
    $inside = Invoke-CocopilotGit -WorkTree $RepoPath -Arguments @("rev-parse", "--is-inside-work-tree") -AllowedExitCodes @(0, 128)
    if ($inside.ExitCode -eq 0 -and $inside.Output.Trim() -eq "true") { return Get-CocopilotGitHead -WorkTree $RepoPath }
    return "non-git-root"
}

function Get-CompleteCapture {
    # The baseline and the current state, or a refusal when either is partial.
    param([Parameter(Mandatory)]$Record)

    $reference = if ($null -ne $Record.PSObject.Properties["baseline"]) { $Record.baseline } else { $null }
    $baseline = Read-CocopilotBaseline -MailboxDir $mailboxDir -Reference $reference
    if (-not $baseline.Complete) {
        throw "The baseline was only partly captured ($($baseline.Reason)), so no manifest can be proven complete. Nothing was changed."
    }
    $current = Get-CocopilotWorkspaceFingerprint -RepoPath $RepoPath
    if (-not $current.Complete) {
        throw "The current state can only be partly captured ($($current.Reason)), so no manifest can be proven complete. Nothing was changed."
    }
    return [pscustomobject]@{ Baseline = $baseline; Current = $current }
}

function Format-ManifestLines {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Manifest)

    $shown = [Math]::Min($Manifest.Count, 50)
    for ($index = 0; $index -lt $shown; $index++) {
        $entry = $Manifest[$index]
        $before = if ($null -eq $entry.before) { "(absent)" } else { $entry.before }
        $after = if ($null -eq $entry.after) { "(absent)" } else { $entry.after }
        "- $($entry.fact): $before -> $after"
    }
    if ($Manifest.Count -gt $shown) { "- ... $($Manifest.Count - $shown) more entries in implementer.json" }
}

function Remove-SupersededBaseline {
    # A committed record no longer references this baseline; removing it is
    # housekeeping, so a failure is reported, never fatal.
    param([AllowNull()]$Reference)

    if ($null -eq $Reference -or [string]$Reference.id -cnotmatch '^[0-9a-f]{32}$') { return }
    $path = Join-Path $mailboxDir "baseline-$($Reference.id).json"
    try {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    } catch {
        Write-Warning "Could not remove the superseded baseline '$path': $($_.Exception.Message)"
    }
}

$lock = Enter-CocopilotOwnershipLock -MailboxDir $mailboxDir
try {
    $check = Get-CocopilotMailboxFileCheck -Path $implementerPath
    if ($check.State -ne "Cocopilot") {
        throw "implementer.json is not a cocopilot ownership record ($($check.State): $($check.Reason)); nothing was changed."
    }
    $record = Read-CocopilotSharedText -Path $implementerPath | ConvertFrom-Json
    $recordEpoch = [long]$record.epoch
    $state = "epoch $recordEpoch, state $($record.state), owner $($record.owner), to $($record.to)"
    $baselineReference = if ($null -ne $record.PSObject.Properties["baseline"]) { $record.baseline } else { $null }

    switch ($Action) {
        "Offer" {
            if ($record.state -ne "active" -or $record.owner -ne $Role) {
                throw "Only the active owner offers a handoff, and the record says: $state. Nothing was changed."
            }
            $capture = Get-CompleteCapture -Record $record
            $manifest = @(Compare-CocopilotFingerprint -Before $capture.Baseline.Facts -After $capture.Current.Facts)
            $head = Get-CurrentHead
            Write-MailboxJson -Path $implementerPath -Object ([pscustomobject][ordered]@{
                    epoch = $recordEpoch; state = "offered"; owner = $Role; owner_model = $record.owner_model
                    from = $Role; to = $peer; head = $head; dirty_manifest = $manifest; baseline = $baselineReference
                })
            $laneEntry = @(
                "HANDOFF_OFFER"
                "epoch: $recordEpoch"
                "from: $Role"
                "to: $peer"
                "head: $head"
                "dirty_manifest: $($manifest.Count) entries (the complete list is in implementer.json)"
            ) + @(Format-ManifestLines -Manifest $manifest) + @(
                "The peer accepts with: -Action Accept -Epoch $recordEpoch"
            )
        }
        "Accept" {
            if ($record.state -ne "offered" -or $record.to -ne $Role) {
                throw "No handoff is offered to $Role, and the record says: $state. Nothing was changed."
            }
            if ($recordEpoch -ne $Epoch) {
                throw "The open offer is for epoch $recordEpoch, not $Epoch. Nothing was changed."
            }
            $capture = Get-CompleteCapture -Record $record
            $head = Get-CurrentHead
            if ($head -cne [string]$record.head) {
                throw "HEAD is now $head, but the offer recorded $($record.head). Nothing was changed."
            }
            $manifest = @(Compare-CocopilotFingerprint -Before $capture.Baseline.Facts -After $capture.Current.Facts)
            if (-not (Test-CocopilotManifestEqual -Expected @($record.dirty_manifest) -Actual $manifest)) {
                $now = @(Format-ManifestLines -Manifest $manifest) -join "`n"
                throw "The target changed after the offer: its dirty manifest no longer matches. Nothing was changed. Current differences from the baseline:`n$now"
            }
            # The new baseline is written first and committed only by the
            # record: a failure in between leaves an unreferenced file and the
            # offer intact.
            $newBaseline = Save-CocopilotBaseline -MailboxDir $mailboxDir -Fingerprint $capture.Current
            $model = if ([string]::IsNullOrWhiteSpace($OwnerModel)) { "unknown" } else { $OwnerModel }
            Write-MailboxJson -Path $implementerPath -Object ([pscustomobject][ordered]@{
                    epoch = $recordEpoch + 1; state = "active"; owner = $Role; owner_model = $model
                    from = $null; to = $null; head = $head; dirty_manifest = @(); baseline = $newBaseline
                })
            Remove-SupersededBaseline -Reference $baselineReference
            $laneEntry = @(
                "HANDOFF_ACCEPT"
                "epoch: $recordEpoch"
                "head: $head"
                "$Role is now the active owner at epoch $($recordEpoch + 1)."
            )
        }
        "Cancel" {
            if ($record.state -ne "offered" -or $record.from -ne $Role) {
                throw "Only the agent that made the open offer cancels it, and the record says: $state, from $($record.from). Nothing was changed."
            }
            if ($recordEpoch -ne $Epoch) {
                throw "The open offer is for epoch $recordEpoch, not $Epoch. Nothing was changed."
            }
            Write-MailboxJson -Path $implementerPath -Object ([pscustomobject][ordered]@{
                    epoch = $recordEpoch + 1; state = "active"; owner = $Role; owner_model = $record.owner_model
                    from = $null; to = $null; head = $record.head; dirty_manifest = @(); baseline = $baselineReference
                })
            $laneEntry = @(
                "HANDOFF_CANCEL"
                "epoch: $recordEpoch"
                "$Role stays the active owner at epoch $($recordEpoch + 1); the offer can no longer be accepted."
            )
        }
        "SetModel" {
            if ($record.state -ne "active" -or $record.owner -ne $Role) {
                throw "Only the active owner records its model, and the record says: $state. Nothing was changed."
            }
            Write-MailboxJson -Path $implementerPath -Object ([pscustomobject][ordered]@{
                    epoch = $recordEpoch; state = $record.state; owner = $record.owner; owner_model = $OwnerModel
                    from = $record.from; to = $record.to; head = $record.head; dirty_manifest = @($record.dirty_manifest)
                    baseline = $baselineReference
                })
            $laneEntry = @("owner_model is now $OwnerModel (epoch $recordEpoch unchanged).")
        }
    }
} finally {
    $lock.Dispose()
}

Write-Output "implementer.json updated ($Action). Post this entry in your lane with write-lane.ps1:"
Write-Output ""
$laneEntry | ForEach-Object { Write-Output $_ }
