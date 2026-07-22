# cocopilot

Run **two GitHub Copilot CLI instances side by side, each on a different
model**, collaborating as peers on **any repository you point them at**,
instead of one agent working alone. Coordination happens through a small
file-based mailbox instead of the two instances talking to each other
directly.

cocopilot itself stays installed in one place (wherever you cloned it —
e.g. `C:\Repos1\cocopilot`); the repository you actually pair on (the
**target repository**) is a separate `-RepoPath` you pass in each time, and
can be any project on your machine.

The collaboration protocol itself is in [`COLLABORATION.md`](COLLABORATION.md)
— it's a generalized port of a personal Claude Code + Codex
`collaboration.md` operating agreement, adapted for two `copilot` CLI
sessions (identified as `agent-a` / `agent-b`, each with whatever model you
give it).

## Why

Different models have different strengths. Instead of picking one, run both:
one instance implements, the other reviews/challenges, and they hand off
ownership explicitly instead of both editing at once.

## How it works

- Exactly **one** agent is the active implementer at a time (see
  `COLLABORATION.md` → "Working roles"). The other only inspects, runs
  read-only checks, and reviews diffs.
- Ownership is tracked in `<RepoPath>/.mailbox/implementer.json` — inside
  the target repository, git-ignored there, per-machine, and the single
  source of truth for who's active.
- Turn-by-turn notes (handoff offers/accepts, review findings, status) go
  in `<RepoPath>/.mailbox/mailbox.md` — also git-ignored and overwritten
  each turn. Every entry is appended **first** to
  `<RepoPath>/.mailbox/session.log.md`, the write-once session history
  (log first, mailbox last — see `COLLABORATION.md` → "Session log");
  `init-mailbox.ps1 -Force` preserves the log, only `cleanup-mailbox.ps1`
  removes it.
- Handoff is manual and explicit: offer → verify → accept (see
  `COLLABORATION.md` → "Ownership handoff"). There is no timeout takeover.
- Neither agent has to be manually re-prompted to check the mailbox: each
  runs `scripts/watch-mailbox.ps1` in the background while it's waiting on
  its peer, so a completion notification (not the user) wakes it up the
  moment the other side writes something. See "Listening" below.

## Layout

```
COLLABORATION.md              the operating agreement both agents follow
.mailbox/
  implementer.example.json    tracked template for the ownership record
  mailbox.example.md          tracked template for the turn scratchpad
prompts/
  agent-a.md                  role prompt for the first instance (generic —
                               works against any target repo)
  agent-b.md                  role prompt for the second instance
  verifier.md                 read-only fresh-eyes verification role (see
                               COLLABORATION.md → "Fresh-eyes verification")
scripts/
  _common.ps1                 shared helpers: session-context banner +
                               Write-MailboxJson (crash-safe ownership writes)
  init-mailbox.ps1             creates <RepoPath>/.mailbox/*
  start-agents.ps1             opens two terminals, one copilot each, paired
                               on <RepoPath>
  watch-mailbox.ps1            blocks until the peer touches <RepoPath>/.mailbox
  render-prompt.ps1            prints one agent's ready-to-paste prompt, for
                               the manual-launch flow
  cleanup-mailbox.ps1          removes cocopilot's .mailbox/ and its
                               .gitignore rule from <RepoPath>
tests/
  Cocopilot.Tests.ps1          Pester 5 suite (see "Tests" below)
```

Note: `.mailbox/implementer.json`, `mailbox.md`, and `session.log.md` are
**not** created here in cocopilot's own repo — they're created inside
whatever `-RepoPath` you target. cocopilot's own `.mailbox/` only holds the
two tracked `*.example.*` templates (the session log has no template — it's
generated with a header by `init-mailbox.ps1`).

## Quick start

By default `start-agents.ps1` launches each agent as a plain, literal
`copilot` invocation with explicit flags — **not** a personal PowerShell
profile alias — so it works the same for anyone with the `copilot` CLI on
PATH, no particular `$PROFILE` setup required:

```powershell
# 1. Initialize the mailbox inside the repo you actually want to pair on
C:\Repos1\cocopilot\scripts\init-mailbox.ps1 -RepoPath C:\Repos\some-other-project

# 2. Launch both agents, paired on that same repo
C:\Repos1\cocopilot\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project
```

That's the whole default: agent-a runs `copilot --model claude-sonnet-5
--effort max --context long_context --autopilot --allow-all ...`, agent-b
runs the same with `gpt-5.6-terra`. Override the model/flags with
`-AgentAArgs` / `-AgentBArgs` (arrays), e.g.
`-AgentAArgs @("--model","gpt-5.4")`.

If you keep your own profile shortcut functions instead (e.g. a
`copilot-sonnet` function that already bakes in your preferred flags), use
those by name and clear the corresponding args array:

```powershell
# in your $PROFILE, entirely optional
function copilot-sonnet {
    copilot --model claude-sonnet-5 --effort max --context long_context --autopilot --allow-all @args
}

C:\Repos1\cocopilot\scripts\start-agents.ps1 -RepoPath C:\Repos\some-other-project `
    -AgentACommand copilot-sonnet -AgentAArgs @() `
    -AgentBCommand copilot-terra  -AgentBArgs @()
```

(`-RepoPath` defaults to the current directory, so `cd`-ing into the target
project first and omitting it also works.)

Each window runs in whichever shell you invoked `start-agents.ps1` from
(pwsh vs Windows PowerShell — see `-ShellExe`; this matters because each
has its own separate `$PROFILE`, so a personal shortcut function defined in
one won't exist in the other), inside the target repo:

```
<AgentXCommand> <AgentXArgs> -C <RepoPath> -n <session-name> --add-dir <cocopilot install> -i <banner + prompts/agent-*.md>
```

`--add-dir <cocopilot install>` guarantees each agent can still read
`COLLABORATION.md` and invoke `watch-mailbox.ps1`/`init-mailbox.ps1` from
cocopilot's own location even though `-C` has moved it into the target
repo. The **banner** prepended to each prompt (see `scripts/_common.ps1`)
is what tells a generic `prompts/agent-*.md` the concrete target repo path,
mailbox location, `COLLABORATION.md` path, and exact watch/init commands
for this run — the prompts themselves never hardcode a repo name.

`agent-a` starts marked active in `implementer.json`, and `agent-b` starts
by reading `COLLABORATION.md` and the mailbox, then waits for a
`HANDOFF_OFFER` before writing anything.

You can also skip `start-agents.ps1` and paste a rendered prompt into an
already-open `copilot` window manually:

```powershell
C:\Repos1\cocopilot\scripts\render-prompt.ps1 -Agent b -RepoPath C:\Repos\some-other-project
# copy the printed text and paste it in
```

That's the minimal way to bring a second model into an existing session.
The same flow with `-Agent verifier` renders the read-only fresh-eyes
verification prompt (paste it into a **new** session — fresh context is
the point; see `COLLABORATION.md` → "Fresh-eyes verification").

## Listening

Both `prompts/agent-a.md` and `prompts/agent-b.md` instruct their agent to
run the watch command (given in their session-context banner) as a
background command whenever it's waiting on its peer (read-only waiting
for an offer, or waiting for an offer it made to be accepted/reviewed),
then end its turn with no further tool calls. The script polls the two
mailbox files by content hash and exits the moment either one changes,
which surfaces to that agent as a background-command-completion
notification — the same mechanism a copilot session already uses to
notice a long-running shell command finishing. The session log is
deliberately **not** watched: its entry always lands before the
`mailbox.md` write it accompanies, so watching `mailbox.md` alone is
sufficient and avoids double-wakes. The agent reads the
mailbox, reacts, and re-launches the watcher for the next round. You
should never need to manually tell either window "check the mailbox now."

```powershell
# The banner gives each agent this fully resolved command; it does not use
# the target repository's .\scripts directory.
& '<cocopilot-install>\scripts\watch-mailbox.ps1' -RepoPath '<target-repository>'                    # wait indefinitely
& '<cocopilot-install>\scripts\watch-mailbox.ps1' -RepoPath '<target-repository>' -TimeoutSeconds 1800  # give up after 30 min of silence
```

## Cleanup

cocopilot's rule is simple: **the target repository should never end up
with anything cocopilot-related committed to it.** `init-mailbox.ps1`
already prevents this going in (it appends a `.mailbox/` `.gitignore` rule
before anything is written), but if you want to fully remove cocopilot's
footprint from a target repo — the `.mailbox/` directory and that
`.gitignore` rule, leaving everything else in the repo untouched — run:

```powershell
C:\Repos1\cocopilot\scripts\cleanup-mailbox.ps1 -RepoPath C:\Repos\some-other-project
# add -WhatIf first if you want to preview what would be removed
```

It also defensively checks for (and un-tracks, without auto-committing)
any `.mailbox/` paths that somehow ended up in the target repo's git
index — this should never happen, but is checked anyway.

## Tests

`tests/Cocopilot.Tests.ps1` is a Pester 5 suite, black-box against fake
target repositories, covering init (creation, idempotency, `-Force`
log-preservation), the watcher (wake on either watched file, no wake on
log-only appends — run as a bounded child process), cleanup (exact block
removal, CRLF and LF), prompt rendering for all three roles, and
`Write-MailboxJson` (replacement, failure cleanup, directory guard).

**Prerequisite:** Pester 5 must be installed side-by-side for *each* host
you run the suite under — Windows PowerShell 5.1 ships only inbox Pester
3.4, so an unqualified `Invoke-Pester` there runs the wrong major version
(`Install-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.999 -Scope
CurrentUser -Force -SkipPublisherCheck`).

Run it fail-closed — same command body under both hosts
(`powershell.exe -NoProfile -Command "…"` and `pwsh -NoProfile -Command "…"`):

```powershell
$ErrorActionPreference='Stop'; $p = Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.999 -Force -PassThru; if ($p.Version.Major -ne 5) { throw 'Pester 5 required' }; Invoke-Pester -Path tests -EnableExit
```

## Notes

- Model/effort/context/permission flags default to literal `copilot ...`
  invocations baked into `start-agents.ps1` (see `-AgentAArgs`/
  `-AgentBArgs`) — not a personal profile shortcut — so the tool works the
  same for anyone with the `copilot` CLI on PATH. `start-agents.ps1` only
  ever adds `-C`, `-n`, `--add-dir`, `-i` after your command/args.
- `init-mailbox.ps1` appends a `.mailbox/` rule to the target repo's own
  `.gitignore` if it's a git repo and doesn't already ignore it — the
  per-machine mailbox state should never end up committed there. Use
  `cleanup-mailbox.ps1` (above) to remove it again when you're done.
- Running against several target repos at once is fine — give each launch
  distinct `-NameA`/`-NameB` so session names don't collide; the mailboxes
  themselves are already isolated per `-RepoPath`.
- Nothing here automates the handoff — by design (see `COLLABORATION.md`).
  A human (you) resolves disagreements and any ownership ambiguity.
