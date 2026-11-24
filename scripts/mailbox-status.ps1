#Requires -Version 7.4

<#
.SYNOPSIS
    Prints a small, read-only index of the mailbox for one agent: the
    ownership line, unread peer entries, the current work unit, the latest
    verdict, the pinned verify request and the entries that need reading.

.DESCRIPTION
    Run this first when an agent starts or restarts. It costs a few lines
    instead of the whole session log. It never writes anything: no cursor,
    ACK, lane, pin, record or temp file changes. The status is an index,
    not a delivery: drain with the watch command (or, with the direct
    transport, the read command) before acting on any entry. The status
    never authorises implementation.

    Every item names its log character offset ("@<offset>"), and items are
    always ordered by offset, never by timestamp: two entries can share
    one second. The output has these parts, in this order:

    OWNERSHIP (current): the compact ownership line of watch-mailbox.ps1.
    head and baseline are shortened for display only. With state offered,
    "PENDING HANDOFF: epoch=<n> from=<role> to=<role>" follows. An invalid
    ownership record fails the run (non-zero exit) before any output.

    UNREAD: the peer entries after this role's cursor, counted with the
    same rules as the watch command: LEGACY, INCOMPLETE and FRAGMENT
    labels, and an unmarked last entry that is still being written counted
    as a "pending tail". A missing, unreadable, other-generation or
    out-of-range cursor reports the replay count from the log's start.

    LAST: per role, the first line of its last complete entry.

    WORK UNIT: the slug of the latest opener line in a complete entry,
    outside fenced code blocks (``` or ~~~) and lines starting with ">".
    Openers (case-sensitive):
    "PROPOSAL (work unit: X)", "PROPOSAL (new work unit: X)",
    "PROPOSAL rN (X)", "PROPOSAL (X)" and "DESIGN_AGREED (X)". The unit
    starts at the first of the latest run of opener entries for that slug.
    AMBIGUOUS when the latest opener entry names different slugs, or its
    opener is not on its first line. UNKNOWN when there is no opener; the
    later parts then cover the whole log.

    VERDICT: the latest canonical verdict block (see COLLABORATION.md,
    "Closing a review"). A REVISE is "(not complete)". When the latest
    verdict-looking block is not canonical, "VERDICT: INVALID @<offset>
    (<reason>)" follows.

    PIN: the pinned verify-request.md - author, epoch, posted, the
    matching VERIFY_REQUEST log entry, STALE when it no longer fits the
    ownership record, and a related verdict for its WORK_UNIT at a later
    offset. The request is the one complete log entry with the pin's
    author, posted stamp and body; AMBIGUOUS when there is not exactly one.
    A pin whose body does not start with VERIFY_REQUEST is INVALID.

    NEEDS READING: since the current unit opened, every first line
    "QUESTION #n" (answered only by a later "ANSWER #n" or "ANSWER to
    QUESTION #n" first line from the other role) and every first line with
    "INTERJECT #n [STOP]" or the unnumbered "INTERJECT [STOP]" (never marked
    resolved), plus an ambiguous opener entry. Each item adds the entry's
    second non-blank line, escaped and cut to 100 characters.

    UNCLASSIFIED since opener: complete agent entries whose first line
    starts with no known protocol keyword.

.PARAMETER RepoPath
    The repository being paired on. Defaults to the current directory.

.PARAMETER Role
    Which agent asks ("agent-a" or "agent-b"): its cursor decides what is
    unread, and the other agent's entries are the peer entries.

.EXAMPLE
    .\scripts\mailbox-status.ps1 -RepoPath C:\Repos\some-other-project -Role agent-a
    # one small index; then drain with the watch or read command
#>
param(
    [string]$RepoPath = (Get-Location).Path,
    [Parameter(Mandatory)][ValidateSet("agent-a", "agent-b")][string]$Role
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_common.ps1")

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$mailboxDir = Open-CocopilotMailbox -RepoPath $RepoPath
$implementerPath = Join-Path $mailboxDir "implementer.json"
$sessionLogPath = Join-Path $mailboxDir "session.log.md"
$cursorPath = Join-Path $mailboxDir "$Role.cursor"
$verifyRequestPath = Join-Path $mailboxDir "verify-request.md"
$peerRole = if ($Role -eq "agent-a") { "agent-b" } else { "agent-a" }
# The watch command's default settle period (poll interval 3 s): an unmarked
# last entry younger than this may still be growing.
$settleSeconds = 6
$slugPattern = '[A-Za-z0-9._-]+'
# The same request check as write-lane.ps1 -VerifyRequest.
$verifyRequestPattern = '^\s*VERIFY_REQUEST\b'
$openerPattern = "^(?:PROPOSAL \((?:new )?work unit: (?<slug>$slugPattern)\)|PROPOSAL r\d+ \((?<slug>$slugPattern)\)|" +
    "PROPOSAL \((?<slug>$slugPattern)\)|DESIGN_AGREED \((?<slug>$slugPattern)\))"
$knownMarkerPattern = '^(?:THINKING|PROPOSAL|CHALLENGE|DESIGN_AGREED|SYNC|ACK|INTERJECT|QUESTION|ANSWER|STATUS|' +
    'HANDOFF_OFFER|HANDOFF_ACCEPT|VERIFY_REQUEST|VERDICT|REVIEW|FINDINGS)(?![A-Za-z0-9_])'

foreach ($p in @($implementerPath, $sessionLogPath)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Missing mailbox file: $p. Run init-mailbox.ps1 first."
    }
}

function Get-EntryLines {
    <#
    .SYNOPSIS
        An entry body's lines. Significant is false inside a fenced code
        block (and for its fence lines) and for lines quoted with ">": a
        marker there is cited text, never the author's own marker.

    .DESCRIPTION
        Fences follow CommonMark: an opening fence is 3 or more backticks or
        3 or more tildes, indented by at most 3 spaces. Only a line of the
        same character, at least as long and followed by nothing but
        whitespace, closes it. An unclosed fence runs to the end of the body.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)

    $lines = [System.Collections.Generic.List[object]]::new()
    $openFence = $null
    foreach ($raw in ($Body -split "\r?\n")) {
        $text = $raw.TrimEnd()
        $fence = [regex]::Match($raw, '^ {0,3}(?<fence>`{3,}|~{3,})(?<rest>.*)$')
        if ($null -ne $openFence) {
            $closes = $fence.Success -and $fence.Groups["fence"].Value[0] -eq $openFence[0] -and
                $fence.Groups["fence"].Value.Length -ge $openFence.Length -and $fence.Groups["rest"].Value.Trim().Length -eq 0
            if ($closes) { $openFence = $null }
            $lines.Add([pscustomobject]@{ Text = $text; Significant = $false })
            continue
        }
        if ($fence.Success) {
            $openFence = $fence.Groups["fence"].Value
            $lines.Add([pscustomobject]@{ Text = $text; Significant = $false })
            continue
        }
        $lines.Add([pscustomobject]@{ Text = $text; Significant = -not $text.TrimStart().StartsWith('>') })
    }
    return $lines.ToArray()
}

function Get-ShortLine {
    # One escaped display line of at most $MaxLength characters before escaping.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$MaxLength = 120)

    $short = if ($Text.Length -gt $MaxLength) { $Text.Substring(0, $MaxLength - 3) + "..." } else { $Text }
    return ConvertTo-CocopilotDisplayText -Value $short
}

function Get-KindLabel {
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        "Legacy" { return " [LEGACY]" }
        "Incomplete" { return " [INCOMPLETE]" }
        "Fragment" { return " [FRAGMENT]" }
        default { return "" }
    }
}

function Read-VerdictBlock {
    <#
    .SYNOPSIS
        Checks the verdict block that starts at $Lines[$Index] against the
        canonical form: consecutive unquoted, unfenced lines VERDICT,
        WORK_UNIT, ROUND, BLOCKING, IMPORTANT, OPTIONAL, FINDINGS, then the
        finding bullets. Returns Valid and, when invalid, a Reason.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Lines,
        [Parameter(Mandatory)][int]$Index
    )

    $result = [pscustomobject]@{ Valid = $false; Reason = $null; Verdict = $null; Unit = $null; Round = $null; Blocking = 0; Important = 0; Optional = 0 }
    $expected = @(
        @{ Name = "VERDICT"; Pattern = '^VERDICT: (?<value>AGREE|REVISE)$'; Hint = "VERDICT: AGREE or VERDICT: REVISE" }
        @{ Name = "WORK_UNIT"; Pattern = "^WORK_UNIT: (?<value>$slugPattern)$"; Hint = "WORK_UNIT: <slug>" }
        @{ Name = "ROUND"; Pattern = '^ROUND: (?<value>\d{1,6}/\d{1,6})$'; Hint = "ROUND: <n>/<max>" }
        @{ Name = "BLOCKING"; Pattern = '^BLOCKING: (?<value>\d{1,6})$'; Hint = "BLOCKING: <n>" }
        @{ Name = "IMPORTANT"; Pattern = '^IMPORTANT: (?<value>\d{1,6})$'; Hint = "IMPORTANT: <n>" }
        @{ Name = "OPTIONAL"; Pattern = '^OPTIONAL: (?<value>\d{1,6})$'; Hint = "OPTIONAL: <n>" }
        @{ Name = "FINDINGS"; Pattern = '^FINDINGS:$'; Hint = "FINDINGS:" }
    )
    $values = @{}
    for ($offset = 0; $offset -lt $expected.Count; $offset++) {
        $position = $Index + $offset
        $line = if ($position -lt $Lines.Count -and $Lines[$position].Significant) { $Lines[$position].Text } else { $null }
        $match = if ($null -ne $line) { [regex]::Match($line, $expected[$offset].Pattern) } else { $null }
        if ($null -eq $match -or -not $match.Success) {
            $result.Reason = "line $($offset + 1) of the block is not '$($expected[$offset].Hint)'"
            return $result
        }
        $values[$expected[$offset].Name] = $match.Groups["value"].Value
    }

    $bullets = @{ BLOCKING = 0; IMPORTANT = 0; OPTIONAL = 0 }
    for ($position = $Index + $expected.Count; $position -lt $Lines.Count -and $Lines[$position].Significant; $position++) {
        $bullet = [regex]::Match($Lines[$position].Text, '^- \[(?<severity>BLOCKING|IMPORTANT|OPTIONAL)\] \S')
        if (-not $bullet.Success) { break }
        $bullets[$bullet.Groups["severity"].Value]++
    }

    $result.Verdict = $values["VERDICT"]
    $result.Unit = $values["WORK_UNIT"]
    $result.Round = $values["ROUND"]
    $result.Blocking = [int]$values["BLOCKING"]
    $result.Important = [int]$values["IMPORTANT"]
    $result.Optional = [int]$values["OPTIONAL"]
    foreach ($severity in @("BLOCKING", "IMPORTANT", "OPTIONAL")) {
        if ([int]$values[$severity] -ne $bullets[$severity]) {
            $result.Reason = "$severity says $($values[$severity]) but $($bullets[$severity]) [$severity] findings follow"
            return $result
        }
    }
    if ($result.Verdict -eq "AGREE" -and $result.Blocking -gt 0) {
        $result.Reason = "AGREE with BLOCKING > 0"
        return $result
    }
    $result.Valid = $true
    return $result
}

function ConvertTo-ComparableBody {
    # LF line breaks and no trailing line breaks (the framing differs between
    # the pin and the log). Spaces and other whitespace stay significant.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n")
}

function Format-Verdict {
    param([Parameter(Mandatory)]$Block)
    $state = if ($Block.Verdict -eq "REVISE") { "REVISE (not complete)" } else { "AGREE" }
    return ("VERDICT: {0} unit={1} round={2} blocking={3} important={4} optional={5} by {6} @{7}" -f
        $state, $Block.Unit, $Block.Round, $Block.Blocking, $Block.Important, $Block.Optional, $Block.Role, $Block.Offset)
}

# --- Discovery: read everything once. Nothing below writes.
$recordText = Read-CocopilotSharedText -Path $implementerPath
$record = ConvertFrom-CocopilotOwnershipRecord -Text $recordText -Path $implementerPath
$logText = Read-CocopilotSharedText -Path $sessionLogPath
$tailSettled = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($sessionLogPath)).TotalSeconds -ge $settleSeconds
$generation = Get-CocopilotLogGeneration -Text $logText
$cursor = Read-CocopilotCursor -Path $cursorPath
$entries = @(Get-CocopilotLogEntries -Text $logText)

$analyzed = @(foreach ($entry in $entries) {
        $lines = @(Get-EntryLines -Body $entry.Body)
        $firstIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Text.Trim().Length -gt 0) { $firstIndex = $i; break }
        }
        $nonBlank = @($lines | Where-Object { $_.Text.Trim().Length -gt 0 })
        [pscustomobject]@{
            Entry      = $entry
            Lines      = $lines
            FirstIndex = $firstIndex
            # The marker line: the first non-blank line, unless it is fenced or quoted.
            FirstLine  = if ($firstIndex -ge 0 -and $lines[$firstIndex].Significant) { $lines[$firstIndex].Text } else { $null }
            Display    = if ($firstIndex -ge 0) { Get-ShortLine -Text $lines[$firstIndex].Text.Trim() } else { "(empty)" }
            # NEEDS READING items add the second non-blank line: the
            # first one usually holds only the marker.
            Detail     = if ($nonBlank.Count -ge 2) { " | " + (Get-ShortLine -Text $nonBlank[1].Text.Trim() -MaxLength 100) } else { "" }
        }
    })

# --- Decisions: ownership, unread, work unit, verdicts, pin, needs reading.
$output = [System.Collections.Generic.List[string]]::new()
$output.Add((Format-CocopilotOwnershipLine -Record $record -Label "current"))
if ($record.state -ceq "offered") {
    $from = if ($null -ne $record.PSObject.Properties["from"] -and $null -ne $record.from) { [string]$record.from } else { "none" }
    $to = if ($null -ne $record.PSObject.Properties["to"] -and $null -ne $record.to) { [string]$record.to } else { "none" }
    $output.Add(("PENDING HANDOFF: epoch={0} from={1} to={2}" -f $record.epoch, (ConvertTo-CocopilotLineValue -Value $from), (ConvertTo-CocopilotLineValue -Value $to)))
}

$cursorProblem = $null
if (-not $cursor.Valid) { $cursorProblem = $cursor.Reason }
elseif ($cursor.Generation -cne $generation) { $cursorProblem = "the cursor belongs to another log generation" }
elseif ($cursor.Offset -gt $logText.Length) { $cursorProblem = "the cursor points past the end of the log" }

$scanFrom = if ($cursorProblem) { 0L } else { [long]$cursor.Offset }
$scan = Get-CocopilotDeliveryScan -Text $logText -From $scanFrom -TailSettled $tailSettled -Role $Role
$unread = @($scan.Deliver)
$pendingTail = if ($scan.HeldBack -and $scan.HeldBackEntry.Role -ne $Role) { $scan.HeldBackEntry } else { $null }
$pendingNote = if ($pendingTail) { " (+1 pending tail)" } else { "" }
if ($cursorProblem) {
    $output.Add("UNREAD: cursor invalid ($cursorProblem) - replay from start: $($unread.Count) entries$pendingNote")
} else {
    $output.Add("UNREAD: $($unread.Count) after cursor @$($cursor.Offset)$pendingNote")
    foreach ($segment in $unread) {
        $firstLine = (@($segment.Body -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 }) + @("(empty)"))[0].Trim()
        $output.Add("  $($segment.Stamp) $($segment.Role) @$($segment.Start)$(Get-KindLabel -Kind $segment.Kind): $(Get-ShortLine -Text $firstLine)")
    }
    if ($pendingTail) {
        $output.Add("  pending tail: $($pendingTail.Stamp) $($pendingTail.Role) @$($pendingTail.Start) (no end marker yet; still being written)")
    }
}
$output.Add("Status is an index, not a delivery: drain with the read/watch command before acting.")

$lastLines = foreach ($lastRole in @("agent-a", "agent-b")) {
    $last = @($analyzed | Where-Object { $_.Entry.Role -eq $lastRole -and $_.Entry.Kind -eq "Complete" }) | Select-Object -Last 1
    if ($last) {
        [pscustomobject]@{ Offset = [long]$last.Entry.Start; Text = "LAST ${lastRole}: $($last.Entry.Stamp) @$($last.Entry.Start): $($last.Display)" }
    } else {
        [pscustomobject]@{ Offset = [long]::MaxValue; Text = "LAST ${lastRole}: none" }
    }
}
foreach ($line in @($lastLines | Sort-Object -Stable Offset)) { $output.Add($line.Text) }

# Openers come only from complete entries; every significant line counts.
$openerEntries = @(foreach ($item in $analyzed) {
        if ($item.Entry.Kind -ne "Complete") { continue }
        $openers = @(for ($i = 0; $i -lt $item.Lines.Count; $i++) {
                if (-not $item.Lines[$i].Significant) { continue }
                $match = [regex]::Match($item.Lines[$i].Text, $openerPattern)
                if ($match.Success) { [pscustomobject]@{ Index = $i; Slug = $match.Groups["slug"].Value } }
            })
        if ($openers.Count -gt 0) { [pscustomobject]@{ Item = $item; Openers = $openers } }
    })

$boundary = 0L
$ambiguousItem = $null
if ($openerEntries.Count -eq 0) {
    $output.Add("WORK UNIT: UNKNOWN (no opener line in the log; the parts below cover the whole log)")
} else {
    $latest = $openerEntries[$openerEntries.Count - 1]
    $slugs = [System.Collections.Generic.List[string]]::new()
    foreach ($opener in $latest.Openers) { if (-not $slugs.Contains($opener.Slug)) { $slugs.Add($opener.Slug) } }
    $openerOnFirstLine = @($latest.Openers | Where-Object { $_.Index -eq $latest.Item.FirstIndex }).Count -gt 0
    if ($slugs.Count -gt 1 -or -not $openerOnFirstLine) {
        $reasons = @()
        if ($slugs.Count -gt 1) { $reasons += "openers for different work units in one entry" }
        if (-not $openerOnFirstLine) { $reasons += "the opener is not on the entry's first line" }
        $previous = if ($openerEntries.Count -gt 1) { $openerEntries[$openerEntries.Count - 2].Openers[-1].Slug } else { $null }
        $previousNote = if ($previous) { "; previous unit: $previous" } else { "" }
        $boundary = [long]$latest.Item.Entry.Start
        $ambiguousItem = $latest.Item
        $output.Add("WORK UNIT: AMBIGUOUS by $($latest.Item.Entry.Role) @$boundary - candidates: $($slugs -join ', ')$previousNote ($($reasons -join '; '))")
    } else {
        $slug = $latest.Openers[-1].Slug
        # The unit opened at the first entry of the latest run of opener
        # entries for this slug: PROPOSAL (X), PROPOSAL r2 (X) and
        # DESIGN_AGREED (X) belong to one unit.
        $opening = $latest
        for ($i = $openerEntries.Count - 2; $i -ge 0; $i--) {
            $candidate = $openerEntries[$i]
            if (@($candidate.Openers | Where-Object { $_.Slug -cne $slug }).Count -gt 0) { break }
            $opening = $candidate
        }
        $boundary = [long]$opening.Item.Entry.Start
        $latestNote = if ($opening -ne $latest) { "; latest opener @$($latest.Item.Entry.Start)" } else { "" }
        $output.Add("WORK UNIT: $slug (opened by $($opening.Item.Entry.Role) @${boundary}: $($opening.Item.Display)$latestNote)")
    }
}

$verdictBlocks = @(foreach ($item in $analyzed) {
        for ($i = 0; $i -lt $item.Lines.Count; $i++) {
            if (-not $item.Lines[$i].Significant -or -not $item.Lines[$i].Text.StartsWith("VERDICT:", [System.StringComparison]::Ordinal)) { continue }
            $block = Read-VerdictBlock -Lines $item.Lines -Index $i
            if ($block.Valid -and $item.Entry.Kind -ne "Complete") {
                $block.Valid = $false
                $block.Reason = "it is in an entry without an end marker ($($item.Entry.Kind))"
            }
            $block | Add-Member -NotePropertyName Offset -NotePropertyValue ([long]$item.Entry.Start)
            $block | Add-Member -NotePropertyName Role -NotePropertyValue $item.Entry.Role
            $block
        }
    })
$canonicalVerdicts = @($verdictBlocks | Where-Object Valid)
if ($canonicalVerdicts.Count -gt 0) { $output.Add((Format-Verdict -Block $canonicalVerdicts[-1])) } else { $output.Add("VERDICT: none") }
if ($verdictBlocks.Count -gt 0 -and -not $verdictBlocks[-1].Valid) {
    $output.Add("VERDICT: INVALID @$($verdictBlocks[-1].Offset) by $($verdictBlocks[-1].Role) ($($verdictBlocks[-1].Reason))")
}

if (-not (Test-Path -LiteralPath $verifyRequestPath -PathType Leaf)) {
    $output.Add("PIN: none")
} else {
    # The pin is "<header lines>`n`n<the request's turn>"; write-lane.ps1
    # logs the same turn as the request entry's body.
    $pinText = (Read-CocopilotSharedText -Path $verifyRequestPath).Replace("`r`n", "`n")
    $headerEnd = $pinText.IndexOf("`n`n")
    $header = @($(if ($headerEnd -ge 0) { $pinText.Substring(0, $headerEnd) } else { $pinText }) -split "`n")
    $pinBody = if ($headerEnd -ge 0) { $pinText.Substring($headerEnd + 2) } else { "" }
    $author = @($header | ForEach-Object { [regex]::Match($_, '^- author: (?<v>agent-a|agent-b)$') } | Where-Object Success | Select-Object -First 1)
    $epoch = @($header | ForEach-Object { [regex]::Match($_, '^- epoch: (?<v>\d{1,18})$') } | Where-Object Success | Select-Object -First 1)
    $posted = @($header | ForEach-Object { [regex]::Match($_, '^- posted: (?<v>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z)$') } | Where-Object Success | Select-Object -First 1)
    if ($author.Count -eq 0 -or $epoch.Count -eq 0 -or $posted.Count -eq 0) {
        $output.Add("PIN: INVALID (verify-request.md has no author, epoch and posted header)")
    } elseif ($pinBody -notmatch $verifyRequestPattern) {
        $output.Add("PIN: INVALID (body is not a VERIFY_REQUEST)")
    } else {
        $pinAuthor = $author[0].Groups["v"].Value
        $pinEpoch = [long]$epoch[0].Groups["v"].Value
        $pinPosted = $posted[0].Groups["v"].Value
        $pinUnitLine = @(Get-EntryLines -Body $pinBody | Where-Object { $_.Significant } |
                ForEach-Object { [regex]::Match($_.Text, "^WORK_UNIT: (?<v>$slugPattern)$") } | Where-Object Success | Select-Object -First 1)
        $pinUnit = if ($pinUnitLine.Count -gt 0) { $pinUnitLine[0].Groups["v"].Value } else { $null }

        $staleReasons = @()
        if ($pinAuthor -cne [string]$record.owner) { $staleReasons += "author is not the owner $($record.owner)" }
        if ($pinEpoch -ne [long]$record.epoch) { $staleReasons += "epoch $pinEpoch is not the record epoch $($record.epoch)" }
        if ($record.state -cne "active") { $staleReasons += "state is $($record.state)" }
        $freshness = if ($staleReasons.Count -gt 0) { "STALE ($($staleReasons -join '; '))" } else { "current" }
        $unitText = if ($pinUnit) { $pinUnit } else { "none" }
        $facts = "author=$pinAuthor epoch=$pinEpoch posted=`"$pinPosted`" unit=$unitText $freshness"

        # Only a complete entry with the same author, stamp and body is the
        # pinned request: a stamp has one-second resolution, and an entry
        # without its end marker may be cut off.
        $comparablePin = ConvertTo-ComparableBody -Text $pinBody
        $requests = @($entries | Where-Object {
                $_.Kind -eq "Complete" -and $_.Role -ceq $pinAuthor -and $_.Stamp -ceq $pinPosted -and $_.Body -match $verifyRequestPattern -and
                (ConvertTo-ComparableBody -Text $_.Body) -ceq $comparablePin
            })
        if ($requests.Count -ne 1) {
            $output.Add("PIN: AMBIGUOUS ($($requests.Count) complete log entries match the pin's author, posted stamp and body) $facts")
        } else {
            $requestOffset = [long]$requests[0].Start
            $related = if ($pinUnit) { @($canonicalVerdicts | Where-Object { $_.Unit -ceq $pinUnit -and $_.Offset -gt $requestOffset }) } else { @() }
            $relatedText = if ($related.Count -gt 0) { "$($related[-1].Verdict) by $($related[-1].Role) @$($related[-1].Offset)" } else { "none" }
            $output.Add("PIN: request @$requestOffset $facts; related verdict: $relatedText")
        }
    }
}

$scoped = @($analyzed | Where-Object { $_.Entry.Start -ge $boundary -and $_.Entry.Role -ne "init" })
$needs = [System.Collections.Generic.List[object]]::new()
foreach ($item in $scoped) {
    if ($null -eq $item.FirstLine) { continue }
    $entry = $item.Entry
    $label = Get-KindLabel -Kind $entry.Kind
    $question = [regex]::Match($item.FirstLine, '^QUESTION #(?<n>\d+)(?!\d)')
    if ($question.Success) {
        $n = $question.Groups["n"].Value
        $answerPattern = "^ANSWER(?: to QUESTION)? #$n(?!\d)"
        $answer = @($scoped | Where-Object {
                $_.Entry.Start -gt $entry.Start -and $_.Entry.Kind -eq "Complete" -and $_.Entry.Role -ne $entry.Role -and
                $null -ne $_.FirstLine -and $_.FirstLine -cmatch $answerPattern
            }) | Select-Object -First 1
        $state = if ($answer) { "answered @$($answer.Entry.Start)" } else { "open" }
        $needs.Add([pscustomobject]@{ Offset = [long]$entry.Start; Text = "QUESTION #$n by $($entry.Role) @$($entry.Start)$label ($state): $($item.Display)$($item.Detail)" })
    }
    # The unnumbered form is the veto of a skipped design huddle.
    $stop = [regex]::Match($item.FirstLine, 'INTERJECT(?: #(?<n>\d+))? \[STOP\]')
    if ($stop.Success) {
        $ordinal = if ($stop.Groups["n"].Success) { "#$($stop.Groups['n'].Value)" } else { "(unnumbered)" }
        $needs.Add([pscustomobject]@{ Offset = [long]$entry.Start; Text = "STOP $ordinal by $($entry.Role) @$($entry.Start)$label (resolution not tracked): $($item.Display)$($item.Detail)" })
    }
}
if ($ambiguousItem) {
    $needs.Add([pscustomobject]@{ Offset = [long]$ambiguousItem.Entry.Start; Text = "MIXED entry by $($ambiguousItem.Entry.Role) @$($ambiguousItem.Entry.Start) (work unit ambiguous): $($ambiguousItem.Display)$($ambiguousItem.Detail)" })
}
if ($needs.Count -eq 0) {
    $output.Add("NEEDS READING: none")
} else {
    $output.Add("NEEDS READING: $($needs.Count)")
    foreach ($need in @($needs | Sort-Object -Stable Offset)) { $output.Add("  $($need.Text)") }
}

$unclassified = @($scoped | Where-Object { $_.Entry.Kind -eq "Complete" -and ($null -eq $_.FirstLine -or $_.FirstLine -cnotmatch $knownMarkerPattern) })
$output.Add("UNCLASSIFIED since opener: $($unclassified.Count)")

# --- Output.
$output | Write-Output
