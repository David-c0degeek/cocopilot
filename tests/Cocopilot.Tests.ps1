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
            [scriptblock]$AfterBaseline
        )
        $job = Start-Job -ScriptBlock {
            param($watch, $repo, $timeout)
            $out = & $watch -RepoPath $repo -TimeoutSeconds $timeout -PollIntervalSeconds 1 *>&1 | Out-String
            [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
        } -ArgumentList $script:watchScript, $RepoPath, $TimeoutSeconds
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
        Test-Path (Join-Path $t ".mailbox\mailbox.md") | Should -BeTrue
        Test-Path (Join-Path $t ".mailbox\session.log.md") | Should -BeTrue
        (Get-Content -Raw (Join-Path $t ".gitignore")) | Should -Match '(?m)^\.mailbox/\s*$'
        $record = Get-Content -Raw (Join-Path $t ".mailbox\implementer.json") | ConvertFrom-Json
        $record.owner | Should -Be "agent-a"
        $record.state | Should -Be "active"
    }

    It "is idempotent without -Force and does not duplicate the ignore rule" {
        $t = New-FakeTarget "init-idem"
        & $script:initScript -RepoPath $t *>$null
        $mailboxFile = Join-Path $t ".mailbox\mailbox.md"
        [System.IO.File]::AppendAllText($mailboxFile, "user content survives`n", $script:utf8NoBom)
        $recordHashBefore = (Get-FileHash (Join-Path $t ".mailbox\implementer.json")).Hash
        & $script:initScript -RepoPath $t *>$null
        (Get-FileHash (Join-Path $t ".mailbox\implementer.json")).Hash | Should -Be $recordHashBefore
        (Get-Content -Raw $mailboxFile) | Should -Match "user content survives"
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
}

Describe "watch-mailbox.ps1 (R1) - child process" {
    It "wakes on a one-byte change to mailbox.md" {
        $t = New-FakeTarget "watch-mailbox"
        & $script:initScript -RepoPath $t *>$null
        $result = Invoke-WatcherChild -RepoPath $t -TimeoutSeconds 20 -AfterBaseline {
            [System.IO.File]::AppendAllText((Join-Path $t ".mailbox\mailbox.md"), "x", [System.Text.UTF8Encoding]::new($false))
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
}

Describe "render-prompt.ps1 (R4)" {
    It "renders role '<_>' with the resolved repo path" -ForEach @("a", "b", "verifier") {
        $t = New-FakeTarget "render-$_"
        $out = & $script:renderScript -Agent $_ -RepoPath $t | Out-String
        $out | Should -Match ([regex]::Escape($t))
    }

    It "gives agent roles the watch/init/ownership commands" {
        $t = New-FakeTarget "render-agent-cmds"
        $out = & $script:renderScript -Agent a -RepoPath $t | Out-String
        $out | Should -Match "Watch command"
        $out | Should -Match "Init command"
        $out | Should -Match "Ownership-record update"
    }

    It "omits every mutating command from the verifier banner" {
        $t = New-FakeTarget "render-verifier-cmds"
        $out = & $script:renderScript -Agent verifier -RepoPath $t | Out-String
        $out | Should -Not -Match "Init command"
        $out | Should -Not -Match "Ownership-record update"
        $out | Should -Not -Match "Watch command"
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
