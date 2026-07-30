# Copilot A + Copilot B Collaboration

> The standing operating agreement between two GitHub Copilot CLI instances
> that work together on a shared **target repository**, each under a
> different model. This file itself lives in the cocopilot install, but the
> agreement applies to whichever repository the two of you were paired on
> for this session — see the session-context banner in your prompt for that
> repository's exact path. Roles and the ownership handoff below are the
> coordination mechanism; the durable ownership record lives in
> `.mailbox/implementer.json` inside that target repository (git-ignored,
> per-machine). The ephemeral turn-by-turn scratchpads live alongside it as
> one **lane per agent** — `.mailbox/agent-a.md` and `.mailbox/agent-b.md`
> (also git-ignored, each written ONLY by the agent it names, overwritten on
> that agent's turns); every entry written to a lane is also appended to
> `.mailbox/session.log.md`, the write-once session history (see "Mailbox
> lanes and the session log" below).
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
diff, and challenges material assumptions — and it does this continuously,
riding along through both the thinking and the implementation as the
**navigator** (see "Thinking together" and "Paired implementation" below),
not as a reviewer waiting at the finish line. Roles may remain stable for
continuity and rotate only when useful, never for symmetry.

Engineering posture: understand the relevant repository boundary before
editing; follow established patterns and stack unless evidence justifies
change; prefer the smallest coherent solution; avoid speculative
infrastructure and unrelated cleanup; use abstraction only when it improves
the present design.

## Workspace context (optional)

A pairing may be launched with a **workspace context root** — a parent
folder (often not itself a git repository) containing the target
repository alongside sibling repos. When the session banner names one:

- Both agents may READ anywhere under it: search sibling repositories,
  trace cross-repo callers, read shared contracts. That is its purpose —
  system-wide context.
- Nothing else widens. Ownership, epochs, diffs, reviews, and **every
  write** stay bound to the single target repository named in the banner.
  Sibling repositories are evidence, never workspace.
- Work that turns out to require editing a sibling repository is out of
  scope for the current pairing: record it in your lane (options +
  consequences) and hand it to the user, who can open a second pairing on
  that repository.

## Thinking together — the design huddle

Collaboration starts before the first edit, not after it. When a work unit
opens, both agents think in parallel and in public:

- Either agent may post `THINKING` entries to its lane at any point —
  short, unpolished reasoning at a fork: "considering X vs Y, leaning X
  because Z — thoughts?". These are conversation, not documentation;
  several small entries beat one polished essay.
- The implementer opens the huddle with a `PROPOSAL`: the problem restated,
  the 2–3 candidate approaches actually considered, the chosen one and why,
  known risks, and open questions. Written **before any tracked-file
  edit**.
- The peer answers with a `CHALLENGE`: agree with reasons, counter with an
  alternative plus evidence, or probe assumptions. Engaging with the
  reasoning is the job; an unexamined "agree" is the same protocol
  violation as an uninspected review.
- Convergence is recorded as `DESIGN_AGREED`: the chosen approach, the
  alternatives rejected and why, and any agreed guardrails. The implementer
  writes it only after the peer's explicit agreement in the peer's lane.
  Implementation may not begin before `DESIGN_AGREED` (or a logged skip —
  below).

A huddle is capped at 3 `PROPOSAL`/`CHALLENGE` rounds. Still divergent at
the cap: stop, record options + consequences, the user decides — the same
escalation as review disagreement.

Skip rule: for a trivial work unit (typo, mechanical rename, comment fix)
the implementer may write `HUDDLE: SKIPPED — <one-line reason>` in its
first `SYNC`/`STATUS` entry instead. The peer may object with
`INTERJECT [STOP]`, which makes the huddle required after all.

## Paired implementation — driver and navigator

During implementation the active implementer is the **driver**; the peer is
the **navigator**. The navigator does not wait for a finished diff — it
rides along step by step, like the second engineer at the same desk.

Driver cadence — post a `SYNC` entry at every commitment point:

- a coherent step completed (a function, a file, a passing/failing test
  run);
- before starting the next file or function;
- a huddle assumption broke, or the code surprised you;
- before any risky or hard-to-undo command.

Never more than one coherent step without a `SYNC`. Each carries a
per-work-unit ordinal (`SYNC #4`) and answers: what was just done, why,
what comes next, plus any open question. Immediately after posting, the
driver **reads the navigator's lane before continuing** — that is the
moment interjections land. Then keep moving: `SYNC` is non-blocking. The
driver blocks (watch command, end of turn) only at: a `QUESTION`, an open
`PROPOSAL`/`CHALLENGE` round, a `HANDOFF_OFFER`, a `VERIFY_REQUEST`, and
the end-of-unit review.

`QUESTION #n` is the rubber-duck: the driver writes its current reasoning
and one specific question, then blocks on the watch until `ANSWER #n`
arrives. Use it whenever two alternatives have materially different
consequences and the choice isn't obvious — thinking out loud with the
peer beats deciding alone and defending it in review.

Navigator duties, on every wake:

- Read the driver's lane **and the actual diff so far** — not just the
  SYNC prose.
- Answer every `SYNC` with either `ACK #n` (seen, no objection — cheap and
  expected) or `INTERJECT #n [STOP|STEER|NOTE]`. Batching is fine
  (`ACK #2-#4`).
- Severities map to review severities: **STOP** = blocking — the driver
  must resolve it before its next step. **STEER** = important — the driver
  absorbs it at the next natural boundary. **NOTE** = optional — batched
  into the end-of-unit review.
- Answer a `QUESTION` promptly with `ANSWER #n` — the driver is blocked on
  it. Rubber-ducking the driver is the navigator's highest-priority job;
  preparing review notes comes second.
- Re-launch the watch command and stay in the loop.

Interjection disagreements follow the standard rule: one focused evidence
cycle, then unresolved material tradeoffs go to the user. A navigator STOP
the driver believes is wrong is never overridden silently — it is answered
with evidence in the driver's lane.

The end-of-unit review and its verdict block remain unchanged: NOTEs roll
into `FINDINGS` as Optional (promoted with evidence where deserved), and no
work unit closes without a verdict. A well-run pairing makes most verdicts
`AGREE` on round 1 — the disagreements already happened in small pieces,
while they were cheap to fix.

## Ownership handoff

Ownership uses a monotonic epoch pinned to Git state, recorded in the mailbox
ownership record.

1. The current implementer finishes or safely pauses, records
   `HANDOFF_OFFER {epoch, from, to, head, dirty_manifest}` in its own
   lane, updates `.mailbox/implementer.json` to `"state": "offered"`, and
   then performs no writes.
2. The peer verifies the exact HEAD and working-tree status (`git status`,
   `git log -1`). A clean committed handoff is preferred; intentional dirty
   state must be enumerated and preserved.
3. The peer records `HANDOFF_ACCEPT {same epoch, head}` in its own lane
   and updates `.mailbox/implementer.json` to
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

Every review closes with exactly one verdict block, written to the
reviewing agent's own lane. This is the only accepted form for a review
outcome — prose alone does not close a review:

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

## Mailbox lanes and the session log

Each agent owns exactly one scratchpad lane: `.mailbox/agent-a.md` for
agent-a, `.mailbox/agent-b.md` for agent-b. An agent writes **only its own
lane, ever** — the peer's lane is read-only to it. One writer per file is
what makes simultaneous work safe: there is nothing to race, so both
agents can post at the same moment without clobbering each other.

A lane holds its agent's current turn only and is overwritten on each of
that agent's writes. `.mailbox/session.log.md` is the write-once merged
history of the session; every entry an agent writes to its lane (THINKING /
PROPOSAL / CHALLENGE / DESIGN_AGREED / SYNC / ACK / INTERJECT / QUESTION /
ANSWER / STATUS / HANDOFF_OFFER / HANDOFF_ACCEPT / VERIFY_REQUEST / verdict
block) is also appended to the log under a heading of the form
`## <UTC timestamp> <role>`.

Write order is fixed: append the log entry **first**, overwrite your own
lane **last**. Each agent's watcher observes the peer's lane and the
ownership record, so a peer woken by a lane change always finds the log
entry already present. Log-only appends deliberately do not wake the peer.

The write operation is fixed too: both hosts must produce identical UTF-8
(no BOM) bytes, so use exactly these .NET calls — not `Add-Content`,
`Set-Content`, or `>>` redirection, whose default encodings differ between
Windows PowerShell 5.1 and pwsh 7 and can corrupt non-ASCII content in a
BOM-less file:

```powershell
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::AppendAllText($sessionLogPath, $entry, $utf8)  # 1: log first
[System.IO.File]::WriteAllText($myLanePath, $turn, $utf8)        # 2: own lane last
```

Because both agents may append to the log near-simultaneously, an append
can fail with a sharing violation (`IOException`) while the peer's append
is in flight. That is expected, not corruption: wait about a second and
retry (a few attempts, then surface the error to the user) — never fall
back to `Add-Content` or `>>`.

Never edit or delete existing log content. `init-mailbox.ps1 -Force` resets
the lanes and ownership record but preserves an existing log,
appending a session-reset entry instead; the log is only ever removed by
`cleanup-mailbox.ps1`, which deletes the whole `.mailbox/` directory.

## Verification and handoff evidence

Run verification proportionate to risk and report only checks actually
executed. State unverified areas and residual risk. At meaningful boundaries
report compactly in your own lane: objective, findings, changed
files/behavior, commands and actual results, open concerns, exact
HEAD/status, and recommended next action.

Work is complete when the requested behavior is present, relevant
verification passes or gaps are explicit, Blocking findings are resolved or
decided, material Important findings are fixed/accepted/escalated, scope
remains proportionate, and residual risk is honestly reported. Do not polish
indefinitely.

### Fresh-eyes verification

Recommended before declaring a risky or final work unit complete; skippable
for trivial ones. The implementer writes a `VERIFY_REQUEST` to its own
lane (following the log-first rule like any entry)
containing: the acceptance criteria, how to run the checks, the `WORK_UNIT`
slug, and the exact `ROUND: <n>/<max>` value the verifier must emit — the
next review-attempt ordinal. The verifier may not read the session log and
earlier lane turns are overwritten, so it is handed everything and
derives nothing.

The user (or the peer, via `render-prompt.ps1 -Agent verifier`) opens a
**new** copilot session with the verifier prompt. Fresh context is the
point: the verifier reads only the repository, the diff, the
VERIFY_REQUEST in the active implementer's lane (owner per
`implementer.json`), and this protocol's "Closing a review" section
(solely for the canonical verdict-block format) — explicitly not
`session.log.md` and not the other agent's lane. It is read-only end to
end (no file writes of any kind,
including untracked/generated files; no init; its banner contains no
mutating commands),
stops immediately if the mailbox or the VERIFY_REQUEST is missing, and
emits the verdict block as its final output, carrying the given `WORK_UNIT`
and `ROUND` unchanged whether it agrees or revises.

The active implementer transcribes that block verbatim into its own lane
and the session log, attributed as fresh-verifier
output. A fresh-verifier verdict is a review attempt like any other: it
consumes the same work-unit backstop, and a verifier `REVISE` at the cap
ordinal escalates to the user per the round rules.

## Ownership record format

The durable ownership authority is `.mailbox/implementer.json` (git-ignored,
replaced whole-file via same-directory temp-file rename — crash-safe against
torn writes; concurrent last-writer-wins races remain humanly resolved via
the epoch rule), not the lane prose (which is overwritten each
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
