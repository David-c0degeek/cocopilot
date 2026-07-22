# Copilot A + Copilot B Collaboration

> The standing operating agreement between two GitHub Copilot CLI instances
> that work together on a shared **target repository**, each under a
> different model. This file itself lives in the cocopilot install, but the
> agreement applies to whichever repository the two of you were paired on
> for this session — see the session-context banner in your prompt for that
> repository's exact path. Roles and the ownership handoff below are the
> coordination mechanism; the durable ownership record lives in
> `.mailbox/implementer.json` inside that target repository (git-ignored,
> per-machine). The ephemeral turn-by-turn scratchpad lives alongside it in
> `.mailbox/mailbox.md` (also git-ignored, overwritten each turn); every
> entry written there is also appended to `.mailbox/session.log.md`, the
> write-once session history (see "Session log" below).
>
> This is a direct port of a personal `collaboration.md` used for a
> Claude Code + Codex pairing, generalized so it works for any two `copilot`
> CLI sessions regardless of which model each one runs (`/model` or
> `--model`). Wherever the source doc said "Claude Code" / "Codex", read
> "Agent A" / "Agent B" here.

## Purpose and authority

Agent A and Agent B are equal engineering peers. Neither has inherent or
permanent authority. We optimize for the user's requested outcome: correctness
and safety first, then the simplest maintainable solution. Evidence and
repository facts outrank identity, confidence, verbosity, or persistence.

User intent and applicable system, safety, sandbox, and authorization
constraints outrank this convention. An implementation handoff transfers
responsibility, not broader permission.

## Working roles

Exactly one agent is the active implementer for a work unit; only that agent
may modify tracked files, shared generated assets, commits, or branches. The
engineering peer may inspect and run non-mutating checks, reviews the actual
diff, and challenges material assumptions. Roles may remain stable for
continuity and rotate only when useful, never for symmetry.

Engineering posture: understand the relevant repository boundary before
editing; follow established patterns and stack unless evidence justifies
change; prefer the smallest coherent solution; avoid speculative
infrastructure and unrelated cleanup; use abstraction only when it improves
the present design.

## Ownership handoff

Ownership uses a monotonic epoch pinned to Git state, recorded in the mailbox
ownership record.

1. The current implementer finishes or safely pauses, records
   `HANDOFF_OFFER {epoch, from, to, head, dirty_manifest}` in
   `.mailbox/mailbox.md`, updates `.mailbox/implementer.json` to
   `"state": "offered"`, and then performs no writes.
2. The peer verifies the exact HEAD and working-tree status (`git status`,
   `git log -1`). A clean committed handoff is preferred; intentional dirty
   state must be enumerated and preserved.
3. The peer records `HANDOFF_ACCEPT {same epoch, head}` in
   `.mailbox/mailbox.md` and updates `.mailbox/implementer.json` to
   `"state": "active", "owner": <peer>`. Only then does the peer become
   active and begin writing.
4. There is no timeout takeover. If an owner disappears or state disagrees,
   stop; the user resolves ownership after the tree is inspected.

Review revisions do not transfer ownership: the existing implementer remains
active unless the explicit handoff completes.

## Review and disagreement

Inspect the implementation, not only its summary. Classify findings:

- **Blocking:** concrete correctness, safety, security, data-loss,
  requested-outcome, or definition-of-done failure, with a reproduction or
  clearly explained causal risk.
- **Important:** material maintainability, reliability, or design concern;
  non-blocking unless promoted with evidence.
- **Optional:** worthwhile but not required; never blocking.

Resolve disagreement by identifying facts vs assumptions, inspecting the
repo, and running the smallest useful experiment. After one focused evidence
cycle, unresolved material tradeoffs go to the user with options and
consequences. No veto by repetition.

### Closing a review: the verdict block

Every review closes with exactly one verdict block, written to
`.mailbox/mailbox.md`. This is the only accepted form for a review outcome —
prose alone does not close a review:

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

- The `VERDICT:` line carries one actual value: `AGREE` or `REVISE`.
- `WORK_UNIT` is a stable short slug chosen once, when the work unit opens,
  derived from the user-scoped objective — never from who currently holds
  ownership. An ownership handoff does not change it.
- `ROUND` is the review-attempt ordinal for that work unit, over a default
  cap of 3: the first verdict on a work unit carries `ROUND: 1/3`; every
  subsequent verdict — `AGREE` or `REVISE`, including a fresh-verifier
  verdict — carries the prior ordinal + 1. Mechanical; no judgment call.
- A `REVISE` carrying the cap ordinal (`ROUND: 3/3`) ends the loop: neither
  agent writes another revision; both stop, record the open items in the
  mailbox as options + consequences, and wait for the user. (The rule
  above still applies independently: one focused evidence cycle, then
  unresolved material tradeoffs go to the user — that can escalate well
  before the cap.)
- Reset: a genuinely new user-scoped objective opens a new `WORK_UNIT`,
  whose first verdict carries `ROUND: 1/3`. After user input resolves an
  escalation, the next verdict may carry an explicit `ROUND_RESET` note and
  restart the ordinal at 1.
- `REVISE` is mandatory whenever `BLOCKING > 0`. An `AGREE` with
  `BLOCKING > 0` is a protocol violation: the implementer must bounce it
  back rather than build on it.
- Work is not complete while the latest verdict on it is `REVISE`.
- The counts must match the `FINDINGS` entries. A clean review is
  `VERDICT: AGREE` with all three counts 0 and the `FINDINGS:` heading
  present with no entries beneath it — the field is always written, the
  entries may be empty.
- The block is a convention: it makes lazy or deviant reviews visible and
  greppable in the record; it does not mechanically force compliance.

## Session log

`.mailbox/session.log.md` is the write-once history of the session; the
turn scratchpad `.mailbox/mailbox.md` is overwritten each turn. Every entry
an agent writes to the scratchpad (STATUS / HANDOFF_OFFER / HANDOFF_ACCEPT /
REVIEW / verdict block) is also appended to the log under a heading of the
form `## <UTC timestamp> <role>`.

Write order is fixed: append the log entry **first**, overwrite the
scratchpad **last**. The watcher observes only the scratchpad and the
ownership record, so a peer woken by a scratchpad change always finds the
log entry already present. Log-only appends deliberately do not wake the
peer.

The write operation is fixed too: both hosts must produce identical UTF-8
(no BOM) bytes, so use exactly these .NET calls — not `Add-Content`,
`Set-Content`, or `>>` redirection, whose default encodings differ between
Windows PowerShell 5.1 and pwsh 7 and can corrupt non-ASCII content in a
BOM-less file:

```powershell
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::AppendAllText($sessionLogPath, $entry, $utf8)  # 1: log first
[System.IO.File]::WriteAllText($mailboxPath, $turn, $utf8)       # 2: mailbox last
```

Never edit or delete existing log content. `init-mailbox.ps1 -Force` resets
the scratchpad and ownership record but preserves an existing log,
appending a session-reset entry instead; the log is only ever removed by
`cleanup-mailbox.ps1`, which deletes the whole `.mailbox/` directory.

## Verification and handoff evidence

Run verification proportionate to risk and report only checks actually
executed. State unverified areas and residual risk. At meaningful boundaries
report compactly in `.mailbox/mailbox.md`: objective, findings, changed
files/behavior, commands and actual results, open concerns, exact
HEAD/status, and recommended next action.

Work is complete when the requested behavior is present, relevant
verification passes or gaps are explicit, Blocking findings are resolved or
decided, material Important findings are fixed/accepted/escalated, scope
remains proportionate, and residual risk is honestly reported. Do not polish
indefinitely.

### Fresh-eyes verification

Recommended before declaring a risky or final work unit complete; skippable
for trivial ones. The implementer writes a `VERIFY_REQUEST` to
`.mailbox/mailbox.md` (following the session-log rule like any entry)
containing: the acceptance criteria, how to run the checks, the `WORK_UNIT`
slug, and the exact `ROUND: <n>/<max>` value the verifier must emit — the
next review-attempt ordinal. The verifier may not read the session log and
earlier mailbox turns are overwritten, so it is handed everything and
derives nothing.

The user (or the peer, via `render-prompt.ps1 -Agent verifier`) opens a
**new** copilot session with the verifier prompt. Fresh context is the
point: the verifier reads only the repository, the diff, the
VERIFY_REQUEST, and this protocol's "Closing a review" section (solely
for the canonical verdict-block format) — explicitly not
`session.log.md`. It is read-only end to end (no file writes of any kind,
including untracked/generated files; no init; its banner contains no
mutating commands),
stops immediately if the mailbox or the VERIFY_REQUEST is missing, and
emits the verdict block as its final output, carrying the given `WORK_UNIT`
and `ROUND` unchanged whether it agrees or revises.

The active implementer transcribes that block verbatim into
`.mailbox/mailbox.md` and the session log, attributed as fresh-verifier
output. A fresh-verifier verdict is a review attempt like any other: it
consumes the same work-unit backstop, and a verifier `REVISE` at the cap
ordinal escalates to the user per the round rules.

## Ownership record format

The durable ownership authority is `.mailbox/implementer.json` (git-ignored,
replaced whole-file via same-directory temp-file rename — crash-safe against
torn writes; concurrent last-writer-wins races remain humanly resolved via
the epoch rule), not the mailbox turn prose (which is overwritten each
turn). Every update to it is a whole-file replacement through the
`Write-MailboxJson` helper in cocopilot's `scripts\_common.ps1` — the
session banner gives the resolved, ready-to-run command. Never edit the
file in place with any other tool. Shape:

```json
{
  "epoch": 1,
  "state": "active",
  "owner": "agent-a",
  "owner_model": "claude-sonnet-5",
  "from": null,
  "to": null,
  "head": "<git HEAD>",
  "dirty_manifest": []
}
```

- `epoch` is monotonic across the run; each `HANDOFF_ACCEPT` names the exact
  prior epoch it supersedes, so a stale or replayed offer cannot be accepted
  out of order.
- `state` is `active` in steady state; during a handoff the outgoing owner
  writes `offered` only after it has stopped writing, and the incoming owner
  writes `active` only after validating `head` and working-tree status.
- `owner` is a stable role id (`agent-a` / `agent-b`); `owner_model` is
  informational only (which model that role happens to be running right
  now) and may change across sessions without bumping the epoch.
- There is no lease expiry. A vanished owner is resolved by the user after
  the tree is inspected.

Full handoff automation is deferred until role rotation is first piloted;
until then the record simply names the current active implementer.
