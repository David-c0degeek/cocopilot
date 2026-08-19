#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 suite for cocopilot's scripts, black-box against fake target
    repositories under $TestDrive.

.DESCRIPTION
    Prerequisite: Pester 5 installed side-by-side for the host running the
    suite — Windows PowerShell 5.1 ships only inbox Pester 3.4, so an
    unqualified Invoke-Pester there runs the wrong major version. See
    README.md "Tests" for the exact fail-closed run commands for both
    hosts.

    Watcher tests run watch-mailbox.ps1 in a child process (a background
    job) with a bounded -TimeoutSeconds, asserting on its exit code and
    output; production internals are not dot-sourced into the test run.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptsDir = Join-Path $script:repoRoot "scripts"
    $script:initScript = Join-Path $script:scriptsDir "init-mailbox.ps1"
    $script:watchScript = Join-Path $script:scriptsDir "watch-mailbox.ps1"
    $script:writeLaneScript = Join-Path $script:scriptsDir "write-lane.ps1"
    $script:cleanupScript = Join-Path $script:scriptsDir "cleanup-mailbox.ps1"
    $script:renderScript = Join-Path $script:scriptsDir "render-prompt.ps1"
    $script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    . (Join-Path $script:scriptsDir "_common.ps1")

    function New-FakeTarget {
        param([Parameter(Mandatory)][string]$Name)
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        git -C $path init -q 2>$null | Out-Null
        return $path
    }

    function Invoke-WatcherChild {
        # Runs the watcher as a child process (job), optionally performing
        # an action after the watcher has taken its baseline hash. Returns
        # the watcher's merged output and exit code.
        param(
            [Parameter(Mandatory)][string]$RepoPath,
            [Parameter(Mandatory)][int]$TimeoutSeconds,
            [string]$Role,
            [scriptblock]$AfterBaseline
        )
        $job = Start-Job -ScriptBlock {
            param($watch, $repo, $timeout, $role)
            $extra = if ($role) { @{ Role = $role } } else { @{} }
            $out = & $watch -RepoPath $repo -TimeoutSeconds $timeout -PollIntervalSeconds 1 @extra *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        } -ArgumentList $script:watchScript, $RepoPath, $TimeoutSeconds, $Role
        Start-Sleep -Seconds 3   # let the child take its baseline hash
        if ($AfterBaseline) { & $AfterBaseline }
        $null = Wait-Job $job -Timeout ($TimeoutSeconds + 15)
        $result = Receive-Job $job
        Remove-Job $job -Force
        return $result
    }
}

Describe "init-mailbox.ps1 (R0/R1)" {
    It "initializes a clean git target from the tracked templates" {
        $t = New-FakeTarget "init-clean"
        & $script:initScript -RepoPath $t *>$null
        Test-Path (Join-Path $t ".mailbox\implementer.json") | Should -BeTrue
        Test-Path (Join-Path $t ".mailbox\agent-a.md") | Should -BeTrue
        Test-Path (Join-Path $t ".mailbox\agent-b.md") | Should -BeTrue
        Test-Path (Join-Path $t ".mailbox\session.log.md") | Should -BeTrue
        (Get-Content -Raw (Join-Path $t ".gitignore")) | Should -Match '(?m)^\.mailbox/\s*$'
        $record = Get-Content -Raw (Join-Path $t ".mailbox\implementer.json") | ConvertFrom-Json
        $record.owner | Should -Be "agent-a"
        $record.state | Should -Be "active"
    }

    It "is idempotent without -Force and does not duplicate the ignore rule" {
        $t = New-FakeTarget "init-idem"
        & $script:initScript -RepoPath $t *>$null
        $laneFile = Join-Path $t ".mailbox\agent-a.md"
        [System.IO.File]::AppendAllText($laneFile, "user content survives`n", $script:utf8NoBom)
        $recordHashBefore = (Get-FileHash (Join-Path $t ".mailbox\implementer.json")).Hash
        & $script:initScript -RepoPath $t *>$null
        (Get-FileHash (Join-Path $t ".mailbox\implementer.json")).Hash | Should -Be $recordHashBefore
        (Get-Content -Raw $laneFile) | Should -Match "user content survives"
        ([regex]::Matches((Get-Content -Raw (Join-Path $t ".gitignore")), '(?m)^\.mailbox/\s*$')).Count | Should -Be 1
    }

    It "-Force resets the record and scratchpad but preserves the session log" {
        $t = New-FakeTarget "init-force"
        & $script:initScript -RepoPath $t *>$null
        $log = Join-Path $t ".mailbox\session.log.md"
        [System.IO.File]::AppendAllText($log, "`n## 2026-01-01 00:00:00Z agent-a`nhistory entry`n", $script:utf8NoBom)
        & $script:initScript -RepoPath $t -Force *>$null
        $logRaw = Get-Content -Raw $log
        $logRaw | Should -Match "history entry"
        $logRaw | Should -Match "session reset \(-Force\)"
    }

    It "creates the session log without a BOM" {
        $t = New-FakeTarget "init-bom"
        & $script:initScript -RepoPath $t *>$null
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $t ".mailbox\session.log.md"))
        $bytes[0] | Should -Not -Be 0xEF
    }

    It "refuses a non-git target without -AllowNonGit and points at -ContextRoot" {
        $t = Join-Path $TestDrive "init-nongit"
        New-Item -ItemType Directory -Force -Path $t | Out-Null
        { & $script:initScript -RepoPath $t *>$null } | Should -Throw "*ContextRoot*"
        Test-Path (Join-Path $t ".mailbox") | Should -BeFalse
    }

    It "initializes a non-git target with -AllowNonGit (non-git-root sentinel, no .gitignore)" {
        $t = Join-Path $TestDrive "init-nongit-allowed"
        New-Item -ItemType Directory -Force -Path $t | Out-Null
        & $script:initScript -RepoPath $t -AllowNonGit *>$null
        $record = Get-Content -Raw (Join-Path $t ".mailbox\implementer.json") | ConvertFrom-Json
        $record.head | Should -Be "non-git-root"
        Test-Path (Join-Path $t ".gitignore") | Should -BeFalse
    }

    It "gives a git repo with no commits yet the zero SHA, not the non-git-root sentinel" {
        # Regression test for the sentinel fix: New-FakeTarget's `git init`
        # never commits, so this is a REAL git repo whose HEAD simply can't
        # resolve yet - it must stay distinguishable from an -AllowNonGit
        # workspace root, which gets the "non-git-root" sentinel instead.
        $t = New-FakeTarget "init-git-no-commits"
        & $script:initScript -RepoPath $t *>$null
        $record = Get-Content -Raw (Join-Path $t ".mailbox\implementer.json") | ConvertFrom-Json
        $record.head | Should -Be ("0" * 40)
    }

    It "refuses to initialize a mailbox in cocopilot's own installed repo" {
        # $script:repoRoot is this checkout's own root - exactly what
        # $PSScriptRoot's parent resolves to inside init-mailbox.ps1 when it
        # runs from here. Regression test for pairing cocopilot on itself
        # (-RepoPath . from inside the cocopilot repo), which must be
        # refused before anything is touched.
        { & $script:initScript -RepoPath $script:repoRoot -AllowNonGit *>$null } | Should -Throw "*cocopilot's own installed repo*"
        Test-Path (Join-Path $script:repoRoot ".mailbox\implementer.example.json") | Should -BeTrue
        Test-Path (Join-Path $script:repoRoot ".mailbox\lane.example.md") | Should -BeTrue
        Test-Path (Join-Path $script:repoRoot ".mailbox\implementer.json") | Should -BeFalse
    }
}

Describe "watch-mailbox.ps1 (R1) - child process" {
    It "wakes on a one-byte change to a lane file (no -Role: both watched)" {
        $t = New-FakeTarget "watch-lane"
        & $script:initScript -RepoPath $t *>$null
        $result = Invoke-WatcherChild -RepoPath $t -TimeoutSeconds 20 -AfterBaseline {
            [System.IO.File]::AppendAllText((Join-Path $t ".mailbox\agent-b.md"), "x", [System.Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        $result.Output | Should -Match "MAILBOX_CHANGED"
        $result.ExitCode | Should -Be 0
    }

    It "wakes on a one-byte change to implementer.json" {
        $t = New-FakeTarget "watch-record"
        & $script:initScript -RepoPath $t *>$null
        $result = Invoke-WatcherChild -RepoPath $t -TimeoutSeconds 20 -AfterBaseline {
            [System.IO.File]::AppendAllText((Join-Path $t ".mailbox\implementer.json"), " ", [System.Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        $result.Output | Should -Match "MAILBOX_CHANGED"
        $result.ExitCode | Should -Be 0
    }

    It "with -Role, wakes on the PEER's lane" {
        $t = New-FakeTarget "watch-role-peer"
        & $script:initScript -RepoPath $t *>$null
        $result = Invoke-WatcherChild -RepoPath $t -TimeoutSeconds 20 -Role "agent-a" -AfterBaseline {
            [System.IO.File]::AppendAllText((Join-Path $t ".mailbox\agent-b.md"), "x", [System.Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        $result.Output | Should -Match "MAILBOX_CHANGED"
        $result.ExitCode | Should -Be 0
    }

    It "with -Role, does NOT wake on its OWN lane (bounded timeout, exit 1)" {
        $t = New-FakeTarget "watch-role-own"
        & $script:initScript -RepoPath $t *>$null
        $result = Invoke-WatcherChild -RepoPath $t -TimeoutSeconds 6 -Role "agent-a" -AfterBaseline {
            [System.IO.File]::AppendAllText((Join-Path $t ".mailbox\agent-a.md"), "x", [System.Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        $result.Output | Should -Match "MAILBOX_WATCH_TIMEOUT"
        $result.ExitCode | Should -Be 1
    }

    It "does not wake on a log-only append (bounded timeout, exit 1)" {
        $t = New-FakeTarget "watch-logonly"
        & $script:initScript -RepoPath $t *>$null
        $result = Invoke-WatcherChild -RepoPath $t -TimeoutSeconds 6 -AfterBaseline {
            [System.IO.File]::AppendAllText((Join-Path $t ".mailbox\session.log.md"), "`n## note`nlog-only`n", [System.Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        $result.Output | Should -Match "MAILBOX_WATCH_TIMEOUT"
        $result.ExitCode | Should -Be 1
    }
}

Describe "write-lane.ps1" {
    It "writes agent-a's turn to its own lane exactly, and leaves agent-b's lane untouched" {
        $t = New-FakeTarget "writelane-a"
        & $script:initScript -RepoPath $t *>$null
        $laneA = Join-Path $t ".mailbox\agent-a.md"
        $laneB = Join-Path $t ".mailbox\agent-b.md"
        $laneBBefore = Get-Content -Raw $laneB

        & $script:writeLaneScript -RepoPath $t -Role "agent-a" -Turn "SYNC #1`nhello"

        (Get-Content -Raw $laneA) | Should -Be "SYNC #1`nhello"
        (Get-Content -Raw $laneB) | Should -Be $laneBBefore
    }

    It "writes agent-b's turn to its own lane exactly, and leaves agent-a's lane untouched" {
        $t = New-FakeTarget "writelane-b"
        & $script:initScript -RepoPath $t *>$null
        $laneA = Join-Path $t ".mailbox\agent-a.md"
        $laneB = Join-Path $t ".mailbox\agent-b.md"
        $laneABefore = Get-Content -Raw $laneA

        & $script:writeLaneScript -RepoPath $t -Role "agent-b" -Turn "ACK #1"

        (Get-Content -Raw $laneB) | Should -Be "ACK #1"
        (Get-Content -Raw $laneA) | Should -Be $laneABefore
    }

    It "appends exactly one correctly-headed log entry at the exact tail, preserving prior content" {
        $t = New-FakeTarget "writelane-log"
        & $script:initScript -RepoPath $t *>$null
        $logPath = Join-Path $t ".mailbox\session.log.md"
        $logBefore = Get-Content -Raw $logPath

        & $script:writeLaneScript -RepoPath $t -Role "agent-a" -Turn "SYNC #7`nbody text"

        $logAfter = Get-Content -Raw $logPath
        # Prefix must be byte-for-byte unchanged...
        $logAfter.Substring(0, $logBefore.Length) | Should -Be $logBefore
        # ...and everything after that exact offset must be ONE well-formed
        # entry, anchored start-to-end - not zero, not two, not appended
        # anywhere but the tail.
        $appended = $logAfter.Substring($logBefore.Length)
        $appended | Should -Match "^`n## \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z agent-a`nSYNC #7`nbody text$"
    }

    It "preserves a turn that does NOT already end in a newline (no forced trailing newline in the lane; log gets exactly one separator)" {
        $t = New-FakeTarget "writelane-noeol"
        & $script:initScript -RepoPath $t *>$null
        $lanePath = Join-Path $t ".mailbox\agent-a.md"
        $logPath = Join-Path $t ".mailbox\session.log.md"
        $logBefore = Get-Content -Raw $logPath

        & $script:writeLaneScript -RepoPath $t -Role "agent-a" -Turn "STATUS`nno trailing newline here"

        (Get-Content -Raw $lanePath) | Should -Be "STATUS`nno trailing newline here"
        $appended = (Get-Content -Raw $logPath).Substring($logBefore.Length)
        $appended | Should -Match "^`n## \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z agent-a`nSTATUS`nno trailing newline here`n$"
    }

    It "preserves a turn that already ends in a newline (no doubled newline in lane or log)" {
        $t = New-FakeTarget "writelane-eol"
        & $script:initScript -RepoPath $t *>$null
        $lanePath = Join-Path $t ".mailbox\agent-a.md"
        $logPath = Join-Path $t ".mailbox\session.log.md"
        $logBefore = Get-Content -Raw $logPath

        & $script:writeLaneScript -RepoPath $t -Role "agent-a" -Turn "STATUS`nalready ends in newline`n"

        (Get-Content -Raw $lanePath) | Should -Be "STATUS`nalready ends in newline`n"
        $appended = (Get-Content -Raw $logPath).Substring($logBefore.Length)
        $appended | Should -Match "^`n## \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z agent-a`nSTATUS`nalready ends in newline`n$"
    }

    It "writes both the log and the lane without a BOM" {
        $t = New-FakeTarget "writelane-bom"
        & $script:initScript -RepoPath $t *>$null
        & $script:writeLaneScript -RepoPath $t -Role "agent-b" -Turn "ACK #1"
        $logBytes = [System.IO.File]::ReadAllBytes((Join-Path $t ".mailbox\session.log.md"))
        $logBytes[0] | Should -Not -Be 0xEF
        $laneBytes = [System.IO.File]::ReadAllBytes((Join-Path $t ".mailbox\agent-b.md"))
        $laneBytes[0] | Should -Not -Be 0xEF
    }

    It "rejects an invalid -Role before touching any file" {
        $t = New-FakeTarget "writelane-badrole"
        & $script:initScript -RepoPath $t *>$null
        $logBefore = Get-Content -Raw (Join-Path $t ".mailbox\session.log.md")
        $laneABefore = Get-Content -Raw (Join-Path $t ".mailbox\agent-a.md")
        $laneBBefore = Get-Content -Raw (Join-Path $t ".mailbox\agent-b.md")
        { & $script:writeLaneScript -RepoPath $t -Role "agent-c" -Turn "x" *>$null } | Should -Throw
        (Get-Content -Raw (Join-Path $t ".mailbox\session.log.md")) | Should -Be $logBefore
        (Get-Content -Raw (Join-Path $t ".mailbox\agent-a.md")) | Should -Be $laneABefore
        (Get-Content -Raw (Join-Path $t ".mailbox\agent-b.md")) | Should -Be $laneBBefore
    }
}

Describe "cleanup-mailbox.ps1 (R0)" {
    It "removes exactly the cocopilot block (CRLF) and keeps user rules" {
        $t = New-FakeTarget "cleanup-crlf"
        $gi = Join-Path $t ".gitignore"
        $content = "node_modules/`r`n`r`n# Per-machine cocopilot mailbox state (see cocopilot's own README/COLLABORATION.md)`r`n.mailbox/`r`n*.log`r`n"
        [System.IO.File]::WriteAllText($gi, $content, $script:utf8NoBom)
        & $script:cleanupScript -RepoPath $t -Confirm:$false *>$null
        $after = Get-Content -Raw $gi
        $after | Should -Match "node_modules/"
        $after | Should -Match "\*\.log"
        $after | Should -Not -Match "cocopilot mailbox state"
        $after | Should -Not -Match '(?m)^\.mailbox/\s*$'
    }

    It "removes exactly the cocopilot block (LF) and keeps user rules" {
        $t = New-FakeTarget "cleanup-lf"
        $gi = Join-Path $t ".gitignore"
        $content = "node_modules/`n`n# Per-machine cocopilot mailbox state (see cocopilot's own README/COLLABORATION.md)`n.mailbox/`n*.log`n"
        [System.IO.File]::WriteAllText($gi, $content, $script:utf8NoBom)
        & $script:cleanupScript -RepoPath $t -Confirm:$false *>$null
        $after = Get-Content -Raw $gi
        $after | Should -Match "node_modules/"
        $after | Should -Match "\*\.log"
        $after | Should -Not -Match "cocopilot mailbox state"
    }

    It "deletes a .gitignore that only ever contained cocopilot's rule, and the .mailbox dir" {
        $t = New-FakeTarget "cleanup-sole"
        & $script:initScript -RepoPath $t *>$null
        Test-Path (Join-Path $t ".mailbox") | Should -BeTrue
        & $script:cleanupScript -RepoPath $t -Confirm:$false *>$null
        Test-Path (Join-Path $t ".mailbox") | Should -BeFalse
        Test-Path (Join-Path $t ".gitignore") | Should -BeFalse
    }

    It "refuses to clean up cocopilot's own installed repo" {
        # Regression test for running cocopilot-cleanup -RepoPath . from
        # inside the cocopilot repo itself: its .mailbox/ intentionally
        # tracks the *.example.* templates and must never be wiped.
        { & $script:cleanupScript -RepoPath $script:repoRoot -Confirm:$false *>$null } | Should -Throw "*cocopilot's own installed repo*"
        Test-Path (Join-Path $script:repoRoot ".mailbox\implementer.example.json") | Should -BeTrue
        Test-Path (Join-Path $script:repoRoot ".mailbox\lane.example.md") | Should -BeTrue
    }
}

Describe "cleanup-mailbox.ps1 -Recurse" {
    It "cleans the root and every nested repo, ignoring .git/node_modules decoys" {
        $t = New-FakeTarget "recurse-basic"
        $child1 = New-FakeTarget "recurse-basic\child1"
        $child2 = New-FakeTarget "recurse-basic\child2"
        & $script:initScript -RepoPath $t *>$null
        & $script:initScript -RepoPath $child1 *>$null
        & $script:initScript -RepoPath $child2 *>$null

        # Decoys placed inside directories the walk must never descend into -
        # if discovery is broken, these would show up as cleaned too.
        $gitDecoy = Join-Path $child1 ".git\.mailbox"
        $nmDecoy = Join-Path $child2 "node_modules\pkg\.mailbox"
        New-Item -ItemType Directory -Force -Path $gitDecoy | Out-Null
        New-Item -ItemType Directory -Force -Path $nmDecoy | Out-Null

        $output = & $script:cleanupScript -RepoPath $t -Recurse -Confirm:$false *>&1 | Out-String

        Test-Path (Join-Path $t ".mailbox") | Should -BeFalse
        Test-Path (Join-Path $child1 ".mailbox") | Should -BeFalse
        Test-Path (Join-Path $child2 ".mailbox") | Should -BeFalse
        Test-Path $gitDecoy | Should -BeTrue
        Test-Path $nmDecoy | Should -BeTrue
        $output | Should -Match "Cleaned successfully:\s*3"
        $output | Should -Match "No changes made \(preview or declined confirmation\):\s*0"
    }

    It "-WhatIf leaves every discovered target's .mailbox and .gitignore untouched" {
        $t = New-FakeTarget "recurse-whatif"
        $child = New-FakeTarget "recurse-whatif\child"
        & $script:initScript -RepoPath $t *>$null
        & $script:initScript -RepoPath $child *>$null

        $output = & $script:cleanupScript -RepoPath $t -Recurse -WhatIf -Confirm:$false *>&1 | Out-String

        Test-Path (Join-Path $t ".mailbox") | Should -BeTrue
        Test-Path (Join-Path $t ".gitignore") | Should -BeTrue
        Test-Path (Join-Path $child ".mailbox") | Should -BeTrue
        Test-Path (Join-Path $child ".gitignore") | Should -BeTrue

        # The summary must never claim a mutation that didn't happen: a
        # -WhatIf run touches nothing, so it must report zero "cleaned" and
        # both targets under the no-op bucket instead.
        $output | Should -Match "Cleaned successfully:\s*0"
        $output | Should -Match "No changes made \(preview or declined confirmation\):\s*2"
    }

    It "never follows a reparse point - no cycle, no escape, and rejects a .mailbox that is itself a link" {
        $t = New-FakeTarget "recurse-junction"
        $child = New-FakeTarget "recurse-junction\child"
        & $script:initScript -RepoPath $t *>$null
        & $script:initScript -RepoPath $child *>$null

        $outside = New-FakeTarget "recurse-junction-outside"
        & $script:initScript -RepoPath $outside *>$null

        # A junction back to an ancestor (cycle) and one out to a sibling
        # directory (escape) - the guard must follow neither.
        $loopback = Join-Path $child "loopback"
        $escape = Join-Path $child "escape"
        New-Item -ItemType Junction -Path $loopback -Target $t | Out-Null
        New-Item -ItemType Junction -Path $escape -Target $outside | Out-Null

        # A repo whose .mailbox is ITSELF a junction to an external,
        # unrelated directory - must be rejected/reported, never treated as
        # a cleanup target (would otherwise -Recurse -Force delete through
        # the link).
        $repoLinked = New-FakeTarget "recurse-junction\repoLinked"
        $externalDir = New-FakeTarget "recurse-junction-external"
        $canary = Join-Path $externalDir "external-canary.txt"
        [System.IO.File]::WriteAllText($canary, "must survive")
        $mailboxLink = Join-Path $repoLinked ".mailbox"
        New-Item -ItemType Junction -Path $mailboxLink -Target $externalDir | Out-Null

        $outFile = Join-Path $TestDrive "recurse-junction-output.txt"
        try {
            # File redirection (not a pipeline) so every line the script
            # writes is flushed to disk as produced - reliable even though
            # this run ends in a throw (the rejected linked .mailbox counts
            # as a discovery issue), unlike piping through Out-String.
            $job = Start-Job -ScriptBlock {
                param($script, $path, $outFile)
                $result = [pscustomobject]@{ Threw = $false; ErrorMessage = $null }
                try {
                    & $script -RepoPath $path -Recurse -WhatIf -Confirm:$false *> $outFile
                } catch {
                    $result.Threw = $true
                    $result.ErrorMessage = $_.Exception.Message
                }
                $result
            } -ArgumentList $script:cleanupScript, $t, $outFile
            $completed = Wait-Job $job -Timeout 20
            if (-not $completed) { Stop-Job $job -ErrorAction SilentlyContinue }
            $result = Receive-Job $job
            Remove-Job $job -Force
            $output = if (Test-Path -LiteralPath $outFile) { Get-Content -Raw $outFile } else { $null }

            $completed | Should -Not -BeNullOrEmpty   # did not time out (no infinite loop via the cycle junction)
            $result.Threw | Should -BeTrue             # a rejected reparse-point .mailbox is a discovery issue -> throws
            $output | Should -Match "Mailboxes found:\s*2"
            $output | Should -Match "is a reparse point"
            Test-Path (Join-Path $outside ".mailbox") | Should -BeTrue   # never reached via the escape junction
            Test-Path -LiteralPath $canary | Should -BeTrue              # never reached via the linked .mailbox
        } finally {
            # Remove every junction non-recursively (link only, never its
            # target) *before* this test hands $TestDrive back. Pester's own
            # TestDrive cleanup is not reparse-point-aware: a stray cycle
            # junction left behind makes IT recurse forever trying to
            # enumerate the tree (proven empirically), taking every later
            # test in the run down with it.
            foreach ($junction in @($loopback, $escape, $mailboxLink)) {
                if (Test-Path -LiteralPath $junction) {
                    [System.IO.Directory]::Delete($junction, $false)
                }
            }
        }
    }

    It "continues past one target's failure and throws only after every target has been attempted" {
        $t = New-FakeTarget "recurse-partial-fail"
        $good = New-FakeTarget "recurse-partial-fail\good"
        $bad = New-FakeTarget "recurse-partial-fail\bad"
        & $script:initScript -RepoPath $good *>$null
        & $script:initScript -RepoPath $bad *>$null

        # Force the "bad" target's cleanup to fail partway through by holding
        # an exclusive lock on a file inside its .mailbox/.
        $lockedFile = Join-Path $bad ".mailbox\implementer.json"
        $fs = [System.IO.File]::Open($lockedFile, 'Open', 'ReadWrite', 'None')
        try {
            { & $script:cleanupScript -RepoPath $t -Recurse -Confirm:$false *>$null } | Should -Throw
        } finally {
            $fs.Dispose()
        }

        Test-Path (Join-Path $good ".mailbox") | Should -BeFalse
        Test-Path (Join-Path $bad ".mailbox") | Should -BeTrue
    }

    It "excludes cocopilot's own installed repo from -Recurse targets, without deleting its templates" {
        # Regression test for `cocopilot-cleanup -RepoPath <workspace> -Recurse`
        # walking over a workspace that contains the cocopilot checkout
        # itself (e.g. run from one level up): it must be reported as a
        # discovery issue, never treated as a cleanup target, and its
        # tracked templates must survive.
        $outFile = Join-Path $TestDrive "recurse-self-output.txt"
        { & $script:cleanupScript -RepoPath $script:repoRoot -Recurse -Confirm:$false *> $outFile } | Should -Throw
        $output = Get-Content -Raw $outFile
        $output | Should -Match "Mailboxes found:\s*0"
        $output | Should -Match "cocopilot's own installed repo"
        Test-Path (Join-Path $script:repoRoot ".mailbox\implementer.example.json") | Should -BeTrue
        Test-Path (Join-Path $script:repoRoot ".mailbox\lane.example.md") | Should -BeTrue
    }
}

Describe "render-prompt.ps1 (R4)" {
    It "renders role '<_>' with the resolved repo path" -ForEach @("a", "b", "verifier") {
        $t = New-FakeTarget "render-$_"
        $out = & $script:renderScript -Agent $_ -RepoPath $t | Out-String
        $out | Should -Match ([regex]::Escape($t))
    }

    It "gives agent roles the watch/init/ownership commands and lane paths" {
        $t = New-FakeTarget "render-agent-cmds"
        $out = & $script:renderScript -Agent a -RepoPath $t | Out-String
        $out | Should -Match "Watch command"
        $out | Should -Match "-Role agent-a"
        $out | Should -Match "Init command"
        $out | Should -Match "Ownership-record update"
        $out | Should -Match "Lane write command"
        $out | Should -Match ([regex]::Escape("write-lane.ps1"))
        $out | Should -Match ([regex]::Escape("-Role agent-a -Turn"))
        $out | Should -Match "Your lane"
        $out | Should -Match ([regex]::Escape("agent-a.md"))
        $out | Should -Match "Peer lane"
        $out | Should -Match ([regex]::Escape("agent-b.md"))
    }

    It "omits every mutating command from the verifier banner" {
        $t = New-FakeTarget "render-verifier-cmds"
        $out = & $script:renderScript -Agent verifier -RepoPath $t | Out-String
        $out | Should -Not -Match "Init command"
        $out | Should -Not -Match "Ownership-record update"
        $out | Should -Not -Match "Watch command"
        $out | Should -Not -Match "Lane write command"
        $out | Should -Not -Match ([regex]::Escape("write-lane.ps1"))
    }

    It "includes the workspace context root when -ContextRoot is passed" {
        $t = New-FakeTarget "render-ctx"
        $ctx = Join-Path $TestDrive "workspace-root"
        New-Item -ItemType Directory -Force -Path $ctx | Out-Null
        $out = & $script:renderScript -Agent a -RepoPath $t -ContextRoot $ctx | Out-String
        $out | Should -Match ([regex]::Escape("Workspace context root (READ-ONLY search scope):"))
        $out | Should -Match ([regex]::Escape($ctx))
    }

    It "omits the workspace context root when -ContextRoot is not passed" {
        $t = New-FakeTarget "render-noctx"
        $out = & $script:renderScript -Agent a -RepoPath $t | Out-String
        $out | Should -Not -Match ([regex]::Escape("Workspace context root (READ-ONLY search scope):"))
    }

    It "embeds -AllowNonGit in the banner's init command for a non-git target" {
        $t = Join-Path $TestDrive "render-nongit"
        New-Item -ItemType Directory -Force -Path $t | Out-Null
        $out = & $script:renderScript -Agent a -RepoPath $t | Out-String
        $out | Should -Match ([regex]::Escape("-AllowNonGit"))
    }

    It "omits -AllowNonGit from the banner's init command for a git target" {
        $t = New-FakeTarget "render-git"
        $out = & $script:renderScript -Agent a -RepoPath $t | Out-String
        $out | Should -Not -Match ([regex]::Escape("-AllowNonGit"))
    }
}

Describe "_common.ps1 helpers" {
    Context "Get-CocopilotInitCommand" {
        It "appends -AllowNonGit for a non-git target" {
            $t = Join-Path $TestDrive "common-initcmd-nongit"
            New-Item -ItemType Directory -Force -Path $t | Out-Null
            $cmd = Get-CocopilotInitCommand -RepoPath $t -InitScript $script:initScript
            $cmd | Should -Match ([regex]::Escape("-AllowNonGit"))
        }

        It "omits -AllowNonGit for a git target" {
            $t = New-FakeTarget "common-initcmd-git"
            $cmd = Get-CocopilotInitCommand -RepoPath $t -InitScript $script:initScript
            $cmd | Should -Not -Match ([regex]::Escape("-AllowNonGit"))
        }
    }

    Context "Resolve-CocopilotAgentName" {
        It "keeps the current value when explicitly bound, even matching the literal default, with -SessionName set" {
            Resolve-CocopilotAgentName -CurrentValue "cocopilot-agent-a" -ExplicitlyBound $true -SessionName "claim" -AgentRole "agent-a" |
                Should -Be "cocopilot-agent-a"
        }

        It "derives SessionName-AgentRole when not bound and -SessionName is set" {
            Resolve-CocopilotAgentName -CurrentValue "cocopilot-agent-b" -ExplicitlyBound $false -SessionName "claim" -AgentRole "agent-b" |
                Should -Be "claim-agent-b"
        }

        It "keeps the current value when not bound and -SessionName is empty" {
            Resolve-CocopilotAgentName -CurrentValue "cocopilot-agent-a" -ExplicitlyBound $false -SessionName $null -AgentRole "agent-a" |
                Should -Be "cocopilot-agent-a"
        }
    }

    Context "Get-CocopilotWindowTitleStatement" {
        It "produces an apostrophe-safe window-title assignment" {
            $stmt = Get-CocopilotWindowTitleStatement -Title "claim's session"
            $stmt | Should -Be "`$host.UI.RawUI.WindowTitle = 'claim''s session'; "
        }
    }

    Context "Get-CocopilotWtNewTabArgs" {
        It "builds the exact expected argument array (-w 0 global, before new-tab)" {
            $args = Get-CocopilotWtNewTabArgs -Title "claim-agent-a" -RepoPath "C:\Repos\claim" -ShellExe "pwsh.exe" -EncodedCommand "BASE64=="
            $expected = @(
                "-w", "0",
                "new-tab",
                "--title", "claim-agent-a",
                "--suppressApplicationTitle",
                "--startingDirectory", "C:\Repos\claim",
                "--",
                "pwsh.exe", "-NoExit", "-EncodedCommand", "BASE64=="
            )
            ($args -join "|") | Should -Be ($expected -join "|")
        }
    }
}

Describe "install.ps1 + profile snippet" {
    BeforeAll {
        $script:installScript = Join-Path $script:repoRoot "install.ps1"
        $script:snippetPath = Join-Path $script:repoRoot "profile\cocopilot.profile.ps1"
    }

    It "profile snippet parses cleanly" {
        $tokens = $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:snippetPath, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It "writes a marker-guarded dot-source block into a fresh profile" {
        $p = Join-Path $TestDrive "profiles\fresh-profile.ps1"
        & $script:installScript -ProfilePath $p -SkipUpdate *>$null
        $raw = Get-Content -Raw $p
        $raw | Should -Match ([regex]::Escape("# >>> cocopilot >>>"))
        $raw | Should -Match ([regex]::Escape($script:snippetPath))
        $raw | Should -Match ([regex]::Escape("# <<< cocopilot <<<"))
    }

    It "is idempotent: rerunning replaces the block instead of duplicating it" {
        $p = Join-Path $TestDrive "profiles\idem-profile.ps1"
        [System.IO.File]::WriteAllText($p, "# user content before`n", $script:utf8NoBom)
        & $script:installScript -ProfilePath $p -SkipUpdate *>$null
        & $script:installScript -ProfilePath $p -SkipUpdate *>$null
        $raw = Get-Content -Raw $p
        ([regex]::Matches($raw, [regex]::Escape("# >>> cocopilot >>>"))).Count | Should -Be 1
        $raw | Should -Match "user content before"
    }
}

Describe "Write-MailboxJson (R5)" {
    It "replaces the record whole-file with parseable compressed JSON" {
        $t = New-FakeTarget "json-replace"
        & $script:initScript -RepoPath $t *>$null
        $path = Join-Path $t ".mailbox\implementer.json"
        $record = Get-Content -Raw $path | ConvertFrom-Json
        $record.owner = "agent-b"
        $record.epoch = 2
        Write-MailboxJson -Path $path -Object $record
        $after = Get-Content -Raw $path | ConvertFrom-Json
        $after.owner | Should -Be "agent-b"
        $after.epoch | Should -Be 2
        @(Get-Content $path).Count | Should -Be 1
    }

    It "throws on a locked target and cleans up its temp file" {
        $t = New-FakeTarget "json-locked"
        & $script:initScript -RepoPath $t *>$null
        $path = Join-Path $t ".mailbox\implementer.json"
        $before = Get-Content -Raw $path
        $fs = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        try {
            { Write-MailboxJson -Path $path -Object @{ epoch = 99 } } | Should -Throw
        } finally {
            $fs.Dispose()
        }
        @(Get-ChildItem (Join-Path $t ".mailbox") -Filter "*.tmp" -Force).Count | Should -Be 0
        Get-Content -Raw $path | Should -Be $before
    }

    It "throws when the target path is a directory" {
        $t = New-FakeTarget "json-dir"
        $dirTarget = Join-Path $t "blocked.json"
        New-Item -ItemType Directory -Force $dirTarget | Out-Null
        { Write-MailboxJson -Path $dirTarget -Object @{ a = 1 } } | Should -Throw
    }
}
