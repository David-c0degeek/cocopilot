<p align="center">
  <img src="assets/cocopilot.png" alt="CocoPilot — a small bird in aviator goggles" width="340">
</p>

**Run two GitHub Copilot CLI instances side by side — different models, one repo, working as peers.**

Two senior engineers at the same desk: they think together in a design huddle before any code is written, then one drives while the other navigates — step-by-step syncs, live interjections, rubber-duck questions — through a tiny file-based mailbox with one write-lane per agent. Ownership of the working tree transfers explicitly, and never do both edit the tree at once. You stay the arbiter.

> No daemon. No state machine. No lock-in. Just a convention ([`COLLABORATION.md`](COLLABORATION.md)), a handful of PowerShell scripts, and three role prompts — pointable at **any local Git repository on your Windows machine**.

---

## Why

Different models have different strengths. Instead of picking one:

- 🧠 **They think together first** — a design huddle (`PROPOSAL` → `CHALLENGE` → `DESIGN_AGREED`) happens *before* the first edit, so the wrong approach dies at design time, not in review round 2.
- 🛠️ **One drives** — exactly one agent owns the working tree at a time, narrating every coherent step as a `SYNC`.
- 🧭 **One navigates** — the peer rides along live: acknowledges or interjects on every step (`STOP`/`STEER`/`NOTE`), answers rubber-duck `QUESTION`s the driver blocks on, and still closes each work unit with a real review.
- 🤝 **Explicit handoffs** — ownership transfers by offer → verify → accept, never by timeout or accident.
- 🧑‍⚖️ **You arbitrate** — disagreements escalate to the human after a bounded number of rounds. By design, nothing here automates you away.

## Install

One line on a new machine:

```powershell
irm https://raw.githubusercontent.com/David-c0degeek/cocopilot/main/install.ps1 | iex

# or, if you already have (or prefer) a clone at a location of your choosing:
git clone https://github.com/David-c0degeek/cocopilot D:\repos\cocopilot; & D:\repos\cocopilot\install.ps1
```

The installer updates the clone (`git pull --ff-only`) and adds a tiny marker-guarded block to your PowerShell profile that dot-sources [`profile/cocopilot.profile.ps1`](profile/cocopilot.profile.ps1) — rerunning is idempotent, and future updates need no profile edits. Run it once per PowerShell edition you use (pwsh and Windows PowerShell keep separate profiles). You get:

| Function | Does |
|---|---|
| `cocopilot-start [-RepoPath] [-Name] [-AgentAModel] [-AgentBModel] […]` | Inits the mailbox, lets you assign a model/settings to each role when omitted, and opens both named agent tabs. Defaults to the current directory. |
| `cocopilot-models [-Raw] [-NoFallback]` | Shows the models available to your Copilot account plus supported effort/context settings and token limits. |
| `cocopilot-prompt -Agent a\|b\|verifier [-RepoPath] [-ContextRoot] [-AllowNonGit]` | Copies that role's paste-ready (re)start prompt to the clipboard — for crashed windows, manual role adds, or a fresh verifier session. |
| `cocopilot-cleanup [-RepoPath] [-Recurse] [-WhatIf]` | Removes `.mailbox\` + its `.gitignore` rule when you're done. `-Recurse` cleans every paired repo under `-RepoPath`. |
| `cocopilot-update` | `git pull` + re-register (reruns the installer). |
| `copilot-opus` / `copilot-sol` / `copilot-terra` | Plain `copilot` launchers with cocopilot's default model/flags. |

## Quick start

Requirements: Windows PowerShell 5.1 or pwsh 7, Git, and the `copilot` CLI on PATH.

```powershell
# Starts from the current repo, creates its mailbox if needed, and opens the
# model picker for Agent A and Agent B.
cd C:\Repos\your-project
cocopilot-start -Name "12313 polis"

# When finished:
cocopilot-cleanup

# Or skip the picker with explicit role assignments:
cocopilot-start -Name "12313 polis" `
    -AgentAModel claude-opus-5.5 -AgentAEffort max -AgentAContext long_context `
    -AgentBModel gpt-6-sol      -AgentBEffort max -AgentBContext long_context
```

The two tabs and Copilot sessions are named **`12313 polis - agent a`** and **`12313 polis - agent b`**.
Agent A still starts as the driver and Agent B as the navigator. The picker only decides which model and settings get
each fixed lane identity. Pressing Enter through the picker keeps the suggested pairing when those models are available:
`claude-opus-5.5` for Agent A and `gpt-6-sol` for Agent B. Each model uses its strongest supported effort and long
context where available.

> `-RepoPath` defaults to the current directory, so you can also just `cd` into the target project first.

## How it works

```mermaid
sequenceDiagram
    participant A as Agent A (driver)
    participant M as .mailbox/
    participant B as Agent B (navigator)
    A->>M: PROPOSAL (huddle: think together before any edit)
    M-->>B: watcher wakes on peer-lane change
    B->>M: CHALLENGE → … → DESIGN_AGREED
    loop every coherent step
        A->>M: SYNC #35;n (did / why / next)
        M-->>B: wake
        B->>M: ACK #35;n or INTERJECT [STOP|STEER|NOTE]
        A->>M: QUESTION #35;n (rubber-duck at a fork — blocks)
        B->>M: ANSWER #35;n
    end
    A->>M: VERIFY_REQUEST / HANDOFF_OFFER
    B->>M: verdict block / HANDOFF_ACCEPT
    Note over A,B: you arbitrate when they disagree
```

- **The mailbox is the only channel.** Four files inside the target repo, all git-ignored — and each agent writes **only its own lane**, so both can post at the same moment without ever clobbering each other:

  | File | Purpose | Lifetime |
  |---|---|---|
  | `.mailbox/implementer.json` | Who owns the working tree (single source of truth) | Whole-file temp + rename (best-effort torn-write protection) |
  | `.mailbox/agent-a.md` | Agent A's lane: thinking, syncs, offers, reviews | Overwritten on each of A's turns; written only by A |
  | `.mailbox/agent-b.md` | Agent B's lane: same, for B | Overwritten on each of B's turns; written only by B |
  | `.mailbox/session.log.md` | Complete merged session history | Append-only, survives everything except cleanup |

- **Nobody polls you.** Each agent runs `watch-mailbox.ps1 -Role <its-role>` in the background while blocked on the peer; it watches the *peer's* lane plus the ownership record (its own writes can never wake it), then exits — which wakes the agent like any finished shell command. You never relay "check the mailbox" between windows.

- **Collaboration is continuous, not post-hoc.** The huddle happens before the first edit; during implementation the driver syncs at every commitment point and the navigator answers every sync — so by the time the formal review arrives, the disagreements have usually already been settled in small, cheap pieces.

- **Reviews close with a verdict block** — a fixed, greppable format (`VERDICT` / `WORK_UNIT` / `ROUND` / severity counts / findings), so review outcomes are countable and auditable, never buried in prose:

  ```text
  VERDICT: REVISE
  WORK_UNIT: fix-auth-retry
  ROUND: 2/3
  BLOCKING: 1
  IMPORTANT: 1
  OPTIONAL: 0
  FINDINGS:
  - [BLOCKING] src/auth.ps1:88 — retry loop swallows the timeout error — rethrow after final attempt
  - [IMPORTANT] src/auth.ps1:102 — retry count is a magic number — hoist to a named constant
  ```

- **Disagreement is bounded.** A `REVISE` at `ROUND: 3/3` stops both agents — they write the open options + consequences and wait for **you**. No veto by repetition, no infinite polish loops.

- **Fresh eyes on demand.** Before accepting risky work, render the read-only **verifier** role into a brand-new session: it sees only the repo, the diff, and the verify request — not the session narrative — so its verdict is genuinely independent.

## The roles

| Role | Prompt | Can write? | Job |
|---|---|---|---|
| **agent-a** | [`prompts/agent-a.md`](prompts/agent-a.md) | When owner | Starts as implementer |
| **agent-b** | [`prompts/agent-b.md`](prompts/agent-b.md) | When owner | Starts as reviewer, takes ownership via handoff |
| **verifier** | [`prompts/verifier.md`](prompts/verifier.md) | **Never** | One-shot fresh-eyes check of a finished work unit |

Every prompt is generic — a **session-context banner** (generated per run) injects what each role needs, so nothing ever hardcodes your repo. Peer-role banners get absolute paths plus ready-to-run watch/init/ownership commands; the verifier banner gets only paths — a read-only role is deliberately never handed a mutating command.

## Command reference

All user-facing scripts live in [`scripts/`](scripts) and run on **Windows PowerShell 5.1 and pwsh 7**. Repository-oriented commands take `-RepoPath` (default: current directory, except `write-lane.ps1`, which requires it explicitly); `list-models.ps1` is account-oriented and needs no repository. Files prefixed with `_` are internal helpers, not commands.

### `init-mailbox.ps1` — set up a target repo

```powershell
.\scripts\init-mailbox.ps1 -RepoPath C:\Repos\your-project
```

Creates the ownership record and both per-agent lane scratchpads from the two tracked templates and generates the session log, all inside the target repo's `.mailbox/`. For a Git target not already ignoring `.mailbox/`, it appends the ignore rule **before** creating any mailbox state — so nothing committable ever exists unprotected, even if init is interrupted. Refuses outright if `-RepoPath` resolves to cocopilot's own installed repo — that repo is a tool you pair *from*, never a project you pair *on*, and its `.mailbox/` intentionally tracks the two `*.example.*` templates this script reads from.

| Parameter | Default | Meaning |
|---|---|---|
| `-RepoPath` | current dir | Target repository |
| `-Owner` | `agent-a` | Which role starts as implementer |
| `-OwnerModel` | `unknown` | Informational label for the owner's model |
| `-Force` | off | Reset record + lanes. **The session log is preserved** (a reset entry is appended) |
| `-AllowNonGit` | off | Pair directly on a workspace root that isn't itself a git repo (e.g. `C:\Repos` containing several independent repos as children) — `head` then reads the fixed sentinel `non-git-root` and `dirty_manifest` becomes the authoritative handoff anchor (see `COLLABORATION.md` "Ownership handoff" → "Non-git workspace roots"). If you only need read-only cross-repo context while writing to just ONE child repo, `-ContextRoot` on `start-agents.ps1` is the lighter-weight alternative |

Safe to re-run: existing files are left alone without `-Force`.

### `list-models.ps1` — inspect available models and settings

```powershell
# Installed profile command
cocopilot-models

# Direct script equivalent
.\scripts\list-models.ps1
```

Shows the current account's enabled models with supported reasoning effort levels, `default`/`long_context` token limits, maximum output size, capability category, and price category. The launcher uses this same catalog for its numbered Agent A/Agent B picker, so unsupported effort/context combinations are rejected before tabs are opened.

Account-aware discovery uses the SDK bundled with the installed Copilot CLI when Node.js is on PATH. If that optional path is unavailable, the command warns and falls back to model IDs advertised by `copilot completion bash`; account availability and per-model settings are then shown as `unknown`, and Copilot itself remains the final validator. `-NoFallback` makes exact account discovery mandatory, while `-Raw` returns reusable descriptor objects instead of a table. Node.js is not required when models are supplied explicitly and is not required to launch the agents.

### `start-agents.ps1` — launch the pair

```powershell
# interactive model/settings assignment for both roles
.\scripts\start-agents.ps1 -RepoPath C:\Repos\your-project

# explicit role assignment (no picker)
.\scripts\start-agents.ps1 -RepoPath C:\Repos\your-project `
    -Name "12313 polis" `
    -AgentAModel gpt-5.4         -AgentAEffort xhigh -AgentAContext long_context `
    -AgentBModel claude-opus-5.5 -AgentBEffort max   -AgentBContext long_context

# expert escape hatch: profile functions supply every model/setting flag
.\scripts\start-agents.ps1 -RepoPath C:\Repos\your-project `
    -AgentACommand copilot-opus -AgentAArgs @() `
    -AgentBCommand copilot-sol  -AgentBArgs @()
```

When a role has no `-Agent*Model` and no explicitly-bound raw `-Agent*Args`, the launcher shows the shared model catalog once, then asks for that role's model and only the settings that model supports. A supplied model skips the picker for that role; omitted effort/context values then use the Copilot CLI's model defaults. The selected mapping is printed before launch, making it explicit which model is Agent A and which is Agent B.

Each tab runs a literal `copilot` invocation (no profile magic required) with role prompt + banner injected via `-i`, working directory set to the target repo, and read access back to the cocopilot install via `--add-dir`. Whenever `wt.exe` (Windows Terminal) is on PATH, both agents open as tabs in the most-recently-used wt.exe window — typically the very window you ran this from — instead of separate OS windows; pass `-UseWindowsTerminal:$false` to force plain console windows regardless.

| Parameter | Default | Meaning |
|---|---|---|
| `-ContextRoot` | (none) | Workspace folder (e.g. a parent dir of many repos) granted as a **read-only search scope** via an extra `--add-dir` + banner note — cross-repo context without widening ownership or writes |
| `-AgentACommand` / `-AgentBCommand` | `copilot` | Executable or profile function per agent |
| `-AgentAModel` / `-AgentBModel` | picker (`claude-opus-5.5` / `gpt-6-sol` suggested) | Model assigned to that fixed lane identity. Supplying one skips that role's model picker |
| `-AgentAEffort` / `-AgentBEffort` | picker: strongest supported; explicit model: CLI default | `none` · `minimal` · `low` · `medium` · `high` · `xhigh` · `max`; the account-aware picker offers only levels supported by the selected model |
| `-AgentAContext` / `-AgentBContext` | picker: `long_context` when supported; explicit model: CLI default | `default` · `long_context`; account-aware selection rejects a tier the model does not support |
| `-AgentAArgs` / `-AgentBArgs` | not bound | Expert complete argument array before `-C/-n/-i`. Explicitly binding it suppresses all typed model settings and the picker for that role; pass `@()` when a profile function supplies its own flags |
| `-NameA` / `-NameB` | `cocopilot-agent-a/b` | Session names, and each new window/tab's title. An explicit value always wins; otherwise derived from `-SessionName` |
| `-SessionName` / `-Name` | (none) | Shared name for both tabs and Copilot sessions — e.g. `-Name "12313 polis"` yields `12313 polis - agent a` / `12313 polis - agent b` |
| `-UseWindowsTerminal` | `$true` | `wt.exe` tabs whenever available (silently falls back to plain console windows otherwise — a no-op default for anyone without Windows Terminal); pass `-UseWindowsTerminal:$false` to force plain windows even when `wt.exe` is installed |
| `-ShellExe` | current host | Shell for the new windows (pwsh vs powershell matters for `$PROFILE`); `powershell_ise.exe` auto-falls back to `powershell.exe` |

### `watch-mailbox.ps1` — the listening half

```powershell
.\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\your-project -Role agent-a          # wake only on agent-b / ownership
.\scripts\watch-mailbox.ps1 -RepoPath C:\Repos\your-project -TimeoutSeconds 1800   # watch everything, give up after 30 min
```

Blocks until a watched file changes (content hash, not mtime), then exits `0`. With `-Role`, watches `implementer.json` plus the **peer's** lane only — an agent's own writes can never wake it; without `-Role`, watches both lanes (for you, or any outside observer). Agents run it in the background and get woken by its completion. Exits `1` on timeout. One-shot by design — re-arm after each wake. The session log is deliberately **not** watched (its entry always lands before the lane write it accompanies).

| Parameter | Default | Meaning |
|---|---|---|
| `-Role` | (none) | `agent-a` · `agent-b` — watch the peer's lane only |
| `-TimeoutSeconds` | `0` (forever) | Exit 1 after this much silence |
| `-PollIntervalSeconds` | `3` | Hash-check frequency |

### `write-lane.ps1` — post one lane entry

```powershell
.\scripts\write-lane.ps1 -RepoPath C:\Repos\your-project -Role agent-a -Turn $turn
```

The preferred way to post a THINKING/PROPOSAL/SYNC/ACK/etc. entry: appends it to `session.log.md` **first**, then overwrites your own lane (`agent-a.md`/`agent-b.md`) **last** — the exact order the protocol requires — generating the UTC `## <timestamp> <role>` heading for you and preserving `-Turn`'s content exactly (no forced trailing newline). `-Role` determines both destination paths from a value already baked in by your own session banner, so running the given command verbatim removes hand-typed-path mistakes (`agent-a.md` vs. `agent-b.md`) — it does **not** authenticate the caller: `-Role` accepts either valid value, so a wrong-but-valid `-Role` is not itself an error (see COLLABORATION.md's identity-vs-responsibility guidance for the discipline that prevents that). Retries a genuine sharing violation separately for each step (the peer appending at the same moment) — a failure on the lane overwrite never re-appends the log entry.

| Parameter | Default | Meaning |
|---|---|---|
| `-RepoPath` | *(required)* | Unlike the other five commands, no current-directory default — normally invoked with the exact path from the session banner |
| `-Role` | *(required)* | `agent-a` · `agent-b` — which lane to write |
| `-Turn` | *(required)* | Raw entry body — no timestamp or `## ...` heading, generated internally |

### `render-prompt.ps1` — manual launch / add a role to an open session

```powershell
.\scripts\render-prompt.ps1 -Agent b -RepoPath C:\Repos\your-project        # paste into a copilot window
.\scripts\render-prompt.ps1 -Agent verifier -RepoPath C:\Repos\your-project  # paste into a NEW session
```

Prints one role's paste-ready prompt (banner + role file). The verifier's banner deliberately contains **no** mutating commands — a read-only role is never handed a loaded gun.

| Parameter | Values | Meaning |
|---|---|---|
| `-Agent` | `a` · `b` · `verifier` | Which role to render |
| `-ContextRoot` | (none) | Same read-only workspace scope as `start-agents.ps1` — when pasting manually, also launch that window with `--add-dir <ContextRoot>` |

### `cleanup-mailbox.ps1` — leave no trace

```powershell
.\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\your-project          # remove everything
.\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\your-project -WhatIf  # preview first
.\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos -Recurse              # clean every paired repo under C:\Repos
```

Removes `.mailbox/` and exactly the `.gitignore` block init added (your own rules survive, CRLF or LF). Defensively un-tracks any `.mailbox/` paths that somehow reached the git index — staged only, never auto-committed. Refuses outright if `-RepoPath` resolves to cocopilot's own installed repo, the same way `init-mailbox.ps1` does. Supports `-WhatIf` / `-Confirm`.

| Parameter | Default | Meaning |
|---|---|---|
| `-RepoPath` | current dir | Repository to clean up, or — with `-Recurse` — the root to search |
| `-Recurse` | off | Treat `-RepoPath` as a search root: find and clean up every repository with a `.mailbox/` at or below it (including `-RepoPath` itself) |

With `-Recurse`, the walk never descends into a directory named `.git` or `node_modules`, and never follows a reparse point (symbolic link, junction, or mount point) — so a junction can't create a traversal cycle back up the tree or walk the search outside the requested root. A `.mailbox/` that is itself a reparse point is rejected the same way, in both `-Recurse` discovery and the single-target path — cocopilot never creates it that way, and `-Recurse -Force` must never be pointed through a link to an arbitrary, externally-controlled target. cocopilot's own installed repo is excluded from `-Recurse` discovery the same way — reported as a discovery issue, never attempted as a target — so pointing `-Recurse` at a workspace that happens to contain the cocopilot checkout itself can't wipe its tracked templates. A directory that can't be enumerated is recorded as a discovery issue rather than silently skipped. One target failing never stops the others — every discoverable target is attempted, a summary is printed, and the script throws only after every attempt has completed if anything (cleanup or discovery) failed, so a partial cleanup can't be mistaken for full success.

## The protocol in 60 seconds

Full text: [`COLLABORATION.md`](COLLABORATION.md) — the binding agreement both agents read on startup.

1. **Think together before editing.** Non-trivial work opens with a design huddle — `PROPOSAL` → `CHALLENGE` → `DESIGN_AGREED`, capped at 3 rounds — and no tracked file changes before it closes (trivial work may log an explicit skip, which the peer can veto).
2. **One implementer at a time.** The driver narrates every coherent step (`SYNC #n`); the navigator answers each one (`ACK` or `INTERJECT [STOP|STEER|NOTE]`), inspects real diffs, and answers rubber-duck `QUESTION`s the driver blocks on.
3. **One lane per agent.** Each agent writes only its own mailbox lane — simultaneous posting can't clobber anything.
4. **Handoff = offer → verify → accept**, recorded with a monotonic epoch pinned to git HEAD. No timeout takeover — a vanished owner is *your* call.
5. **Every review closes with the verdict block.** `REVISE` is mandatory while any Blocking finding is open.
6. **Rounds are counted and capped** (`ROUND: n/3`). A `REVISE` at the cap stops further revisions — both agents hand you the open options and consequences; an unresolved material tradeoff can escalate to you even earlier.
7. **Every lane entry is logged first** to the append-only session log — the full history survives even a `-Force` re-init, and `grep '^VERDICT:'` reconstructs every review outcome of a session.
8. **Fresh-eyes verification** for risky/final work: a new session, read-only, sees only repo + diff + request. Skippable for trivial changes.
9. **Evidence beats identity.** Repository facts outrank confidence, verbosity, or persistence — for both models.

## Layout

```
README.md                     you are here
COLLABORATION.md              the operating agreement both agents follow
install.ps1                   one-line install/update + profile registration
.gitignore                    keeps generated .mailbox state out of this repo
assets/
  cocopilot.png               the logo
profile/
  cocopilot.profile.ps1       the functions install.ps1 dot-sources into
                               your profile (cocopilot-start/-models/…)
.mailbox/
  implementer.example.json    tracked template — ownership record
  lane.example.md             tracked template — per-agent lane scratchpad
prompts/
  agent-a.md · agent-b.md     the two peer roles (generic, banner-driven)
  verifier.md                 read-only fresh-eyes role
scripts/
  _common.ps1                 banner builder + Write-MailboxJson (whole-file
                               JSON writer, temp + rename)
  _models.ps1                 account model discovery, picker, argument helpers
  init-mailbox.ps1            create <RepoPath>/.mailbox/*
  list-models.ps1             show available models + supported settings
  start-agents.ps1            launch both copilot windows
  watch-mailbox.ps1           block until the peer writes
  write-lane.ps1              post one lane entry (log first, lane last)
  render-prompt.ps1           print a role prompt for manual paste
  cleanup-mailbox.ps1         remove cocopilot's footprint from a target
tests/
  Cocopilot.Tests.ps1         Pester 5 suite (72 tests, both hosts)
```

The real `.mailbox/` state is created **inside each target repo** (git-ignored there); cocopilot's own repo only tracks the two `*.example.*` templates.

## Tests

72 black-box Pester 5 tests cover init, watcher wake/no-wake behavior, own-lane writes and append-only logging, safe cleanup (single and recursive), all prompt renders, non-git workspace recovery, session-name/window-title helpers, Windows Terminal command-line quoting, npm-installed Copilot resolution, cross-host model catalog parsing and capability mapping, numbered model selection, supported effort/context validation, independent Agent A/Agent B argument generation, the profile/installer command surface, and whole-file JSON replacement with temp-file cleanup.

**Prerequisite:** Pester 5 side-by-side per host — Windows PowerShell 5.1 ships inbox Pester 3.4 only:

```powershell
Install-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.999 -Scope CurrentUser -Force -SkipPublisherCheck
```

Run fail-closed on both hosts (copy/paste as-is from the repo root):

```powershell
# single-quoted so the outer shell doesn't expand $-variables before they reach the child host
powershell.exe -NoProfile -Command '$ErrorActionPreference="Stop"; $p = Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.999 -Force -PassThru; if ($p.Version.Major -ne 5) { throw "Pester 5 required" }; $c = New-PesterConfiguration; $c.Run.Path = "tests"; $c.Run.Exit = $true; Invoke-Pester -Configuration $c'

pwsh -NoProfile -Command '$ErrorActionPreference="Stop"; $p = Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.999 -Force -PassThru; if ($p.Version.Major -ne 5) { throw "Pester 5 required" }; $c = New-PesterConfiguration; $c.Run.Path = "tests"; $c.Run.Exit = $true; Invoke-Pester -Configuration $c'
```

## FAQ

**Does this need my repo to be on GitHub?** No. Any local Git repository works; cocopilot's scripts never require or access a Git remote. (The Copilot CLI itself talks to its own service, as always.)

**Can I pair on several repos at once?** Yes — mailboxes are per-`-RepoPath`. Give each launch a distinct `-Name`/`-SessionName` (or `-NameA`/`-NameB` directly) so window/tab titles and session names don't collide.

**Can I point one pair directly at a whole workspace of repos (`C:\Repos`) instead of one child repo?** Yes — pass `-AllowNonGit` to `init-mailbox.ps1` (or `cocopilot-start`) to pair directly on a workspace root that isn't itself a git repository, so a single pair can cover a work unit spanning several child repos at once. Ownership then anchors to `dirty_manifest` instead of git HEAD/status: `head` reads the fixed sentinel `non-git-root`, and a `HANDOFF_OFFER` must enumerate every touched git worktree (its own path, HEAD, and status) plus every changed non-repo file (path + a content hash) — see `COLLABORATION.md` "Ownership handoff" → "Non-git workspace roots" for the exact format. If you only need read-only cross-repo context while writing to just ONE child repo — or the work is genuinely independent per repo rather than one coordinated unit — `-ContextRoot` is the lighter-weight alternative: pair on that one repo (`cocopilot-start -RepoPath C:\Repos\claim -ContextRoot C:\Repos`) and both agents can still search every sibling repo for context, while ownership, diffs, and writes stay anchored to the one target; reserve one-pair-per-repo for genuinely independent work units, each with the same `-ContextRoot`.

**What if the two agents deadlock or an owner vanishes?** Review disagreements are bounded by the round cap — a `REVISE` at `3/3` forces both agents to stop and hand you the decision. A vanished *owner* is different: nothing takes over by timeout (deliberately), so a watcher may wait indefinitely — inspect the tree, decide ownership yourself, and if needed re-run init with `-Force` (history survives in the session log).

**Why PowerShell?** The Copilot CLI ships on Windows first-class; the scripts run identically on Windows PowerShell 5.1 and pwsh 7 (byte-identical mailbox writes on both — tested).

**What does cocopilot deliberately NOT do?** No state machine, no schema validation, no file locking, no timeout takeover, no daemon, no committed artifacts in your repos. Those solve *unattended* operation — that's [claudex](https://github.com/David-c0degeek/claudex) territory: a deterministic state-machine orchestrator for headless or live Claude Code + Codex runs. cocopilot is its lightweight sibling: interactive pairing with you as the arbiter.

---

*The protocol is a generalized port of the personal Claude Code + Codex `collaboration.md` operating agreement behind [claudex](https://github.com/David-c0degeek/claudex) — and this repo's current form was itself co-authored and adversarially reviewed by that exact pairing.*
