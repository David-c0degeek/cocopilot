# cocopilot — review findings and recommended upgrades

> Input for a cocopilot pairing session: implement the recommendations below.
> Self-contained — everything needed is in this file plus the repo itself.
> Originally written 2026-07-21 after a full read of the repo (12 files,
> including `scripts/.gitignore`) and a side-by-side comparison with a
> heavyweight two-agent orchestrator (claudex: a state-machine harness for
> *unattended* multi-day runs). Revised 2026-07-22 after independent
> verification of every claim by a second reviewer (codex) against the repo
> and against both installed hosts (Windows PowerShell 5.1, pwsh 7).
> The comparison's conclusion stands: cocopilot's size is right for its job
> (interactive pairing with a human present); it should NOT grow a state
> machine. But several of the orchestrator's properties are cheap to port as
> conventions + small script changes, and they close the gaps that actually
> bite.

## Verified findings

**Keep (correct as-is):**

- Single-implementer ownership with explicit offer→verify→accept and no
  timeout takeover (`COLLABORATION.md` — "Ownership handoff"). Human
  arbitration is the right call for interactive sessions.
- Banner-injected absolute paths so `prompts/agent-*.md` stay generic
  (`scripts/_common.ps1::Get-CocopilotSessionBanner`).
- `-EncodedCommand` launch avoiding nested-quoting failures
  (`scripts/start-agents.ps1::Start-CopilotAgent`).
- Content-hash polling watcher rather than mtime (`scripts/watch-mailbox.ps1::Get-MailboxHash`).
- Cleanup-side target-repo hygiene: defensive un-track + exact block removal
  (`cleanup-mailbox.ps1`). (Init-side hygiene has the right *intent* but the
  wrong ordering and is currently unreachable — see F0.)

**Gaps (each verified in the code/docs, with the consequence it causes):**

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F0 | Baseline artifacts are missing — the repo cannot deliver its own quick start | `README.md` "Layout" documents two tracked templates `.mailbox/implementer.example.json` and `.mailbox/mailbox.example.md`; no `.mailbox/` directory exists anywhere in the repo. `init-mailbox.ps1:51-52,67,78` reads both templates, so a first run fails before ever reaching its `.gitignore` safety code. The only ignore file is `scripts/.gitignore`, whose `.mailbox/*` rules are scoped below `scripts/` and match nothing useful; it belongs at the repo root. Additionally `init-mailbox.ps1` writes `.mailbox/` contents (lines 54–80) *before* appending the target-repo ignore rule (lines 82–95), contrary to README's "before anything is written". (Note: this working copy currently has no `.git` at all, so "tracked templates" is aspirational on this machine — initializing the repo is a user decision, flagged, not assumed.) | `init-mailbox.ps1` fails on any target repository; nothing downstream (watching, pairing, cleanup of a real session) can be exercised end-to-end |
| F1 | The turn scratchpad is overwritten every turn — no durable narrative history | `README.md` ("overwritten each turn"); `mailbox.md` is the only cross-agent narrative record | Earlier narrative turns are lost from cocopilot's own session state; only the latest mailbox turn remains. Working tree, git history, and each agent's own transcript survive, but the *cross-agent* record (who found what, which findings were resolved, why a handoff happened) cannot be reconstructed afterward |
| F2 | No mandatory, greppable review-outcome format | `COLLABORATION.md` "Review and disagreement" defines Blocking/Important/Optional, but no required output form exists anywhere; prompts only say "classify" | Review outcomes are free prose: they can't be grepped, counted, or checked for resolution, and a lazy "looks good" is indistinguishable in the record from a real review. (A fixed form makes deviations *visible*; it cannot *force* compliance — schema validation is rejected below) |
| F3 | The existing disagreement boundary is not represented in the record | `COLLABORATION.md` "after one focused evidence cycle … goes to the user" already bounds disagreement — but nothing in the mailbox shows which cycle a review is on, so compliance is unauditable and the boundary relies entirely on the models' self-restraint | Two stubborn models can ping-pong revisions with nothing in the record revealing that the boundary was passed; the user can't see a violation happening |
| F4 | The final review is context-contaminated | Reviewer peer has read the whole mailbox exchange; no fresh-eyes step exists | The reviewing agent anchors on its own earlier reasoning and the implementer's narrative. Independent-verification value drops precisely at the moment it matters most (final acceptance) |
| F5 | `implementer.json` writes have a torn-write window, and the protocol's atomicity claim is fiction | `init-mailbox.ps1:67-72` writes via in-place `Set-Content`; prompts tell agents to edit the record with whatever tool they choose; `COLLABORATION.md` *claims* "atomically replaced" but nothing implements it | A crash mid-write can leave torn/partial JSON that breaks both agents' next read. (Two *valid* near-simultaneous writers are last-writer-wins with or without this fix — that race stays humanly resolved via the epoch rule, by design; see R5's scope) |
| F6 | Zero tests | No test files anywhere in the repo | The mailbox hashing, init idempotency, gitignore-append matching, and cleanup block-removal regexes are all regex/IO logic that silently breaks on edge cases (CRLF, BOM, trailing whitespace) |

## Recommendations

Ordered by dependency, then value. R0 unblocks everything; R1–R4 are the
substance; R5–R6 are hygiene. **Non-goal:** do not add a state machine,
schemas, token/resource-budget pause-resume machinery, or any daemon —
cocopilot stays a convention + launcher; the human stays the arbiter.

### R0 — Restore the baseline artifacts (fixes F0)

- Create `.mailbox/implementer.example.json` and `.mailbox/mailbox.example.md`
  at the repo root, matching the record shape documented in
  `COLLABORATION.md` ("Ownership record format") and the layout in
  `README.md`.
- Move the ignore rules from `scripts/.gitignore` to a repo-root
  `.gitignore` (ignore `.mailbox/implementer.json` and `.mailbox/mailbox.md`;
  the `*.example.*` templates stay tracked); delete `scripts/.gitignore`.
- Reorder `init-mailbox.ps1`: append the target repo's `.gitignore` rule
  *before* creating or writing anything under `.mailbox/`, making README's
  "before anything is written" true.
- Whether to `git init` this working copy is the user's call — flag it, don't
  do it silently.
- Acceptance: on a clean fake git target, `init-mailbox.ps1` succeeds from
  the restored templates; the ignore-rule append precedes any `.mailbox/`
  write in the script's execution order (verified by code inspection —
  runtime ordering is not black-box observable); a re-run without `-Force`
  is idempotent.

### R1 — Append-only session log (fixes F1)

- New file `<RepoPath>/.mailbox/session.log.md`, created by
  `init-mailbox.ps1` (header: session start timestamp, repo path, initial
  owner). Git-ignored by the `.mailbox/` rule — no gitignore change.
- Protocol + both prompts: every entry an agent writes to `mailbox.md`
  (STATUS / HANDOFF_OFFER / HANDOFF_ACCEPT / REVIEW / VERDICT) is **also
  appended** to `session.log.md` with a `## <UTC timestamp> <role>` heading.
  `mailbox.md` stays the overwritten "current turn" surface; the log is
  write-once history. **Prescribed write order:** append to `session.log.md`
  *first*, overwrite `mailbox.md` *last* — the watcher watches only
  `mailbox.md` + `implementer.json`, so a peer woken by the mailbox change
  always finds the log entry already present.
- All writes use explicit UTF-8 encoding that behaves identically on
  Windows PowerShell 5.1 and pwsh 7 (see R5's helper note).
- `-Force` semantics: `init -Force` resets `implementer.json` and
  `mailbox.md` but **preserves** an existing `session.log.md`, appending a
  "session reset" entry instead. Destroying history is only ever done by
  `cleanup-mailbox.ps1` (which already deletes the whole `.mailbox/` dir) —
  the one command that can erase the log is the one whose purpose is erasure.
- `watch-mailbox.ps1` keeps hashing only `implementer.json` + `mailbox.md`.
  Add one sentence to its `.DESCRIPTION` saying the log is deliberately not
  watched. The watcher is polling and one-shot: writes landing within one
  poll interval may coalesce into a single wake, and it must be re-armed
  after each wake — no exactly-once delivery is claimed or needed.
- README layout listing gains the new file; `cleanup-mailbox.ps1` needs no
  change (verify).
- Acceptance: with a watcher armed before each simulated turn and re-armed
  between turns, each watched turn is detected; a log-only append does not
  wake it; after a simulated two-turn exchange `session.log.md` contains
  both turns while `mailbox.md` contains only the last; a grep for
  `^VERDICT:` over `session.log.md` reconstructs every review outcome
  recorded during the exchange (integration criterion for R2's block).

### R2 — Mandatory structured verdict block (fixes F2)

- Define in `COLLABORATION.md` (new subsection under "Review and
  disagreement") one fixed, greppable block a reviewer MUST write to close a
  review — in `mailbox.md` and (once R1 lands) also the log. Example with
  actual values (the `VERDICT:` line carries one value, not a literal
  alternation):

  ```text
  VERDICT: REVISE
  BLOCKING: 1
  IMPORTANT: 2
  OPTIONAL: 0
  FINDINGS:
  - [BLOCKING] src/auth.ps1:88 — retry loop swallows the timeout error — rethrow after final attempt
  - [IMPORTANT] ...
  ```

- R3 later extends this block with `WORK_UNIT:` and `ROUND:` lines — the R2
  increment defines only the fields above, so each increment lands
  internally consistent.
- Rules: `REVISE` is mandatory whenever `BLOCKING > 0`; `AGREE` with
  `BLOCKING > 0` is a protocol violation the implementer must bounce back;
  work is not done while the latest verdict is `REVISE`. The block makes
  deviations visible and greppable; it does not force compliance (schema
  validation stays rejected).
- Update both `prompts/agent-*.md`: replace the loose "classify any review
  feedback" wording with "close every review with the VERDICT block defined
  in the collaboration protocol".
- Acceptance: the format is defined once (protocol), referenced — not
  restated — in both prompts; the protocol example uses actual values. (The
  session-log grep integration check lives in R1's acceptance, where the
  log exists.)

### R3 — Visible round counter with forced escalation (fixes F3)

- This increment **extends the R2 VERDICT block** with two lines:
  `WORK_UNIT: <slug>` and `ROUND: <n>/<max>` (default max 3). `WORK_UNIT`
  is a stable short slug chosen when the work unit opens (from the
  user-scoped objective, not from who currently holds ownership). Review
  bookkeeping stays out of `implementer.json`, which remains purely the
  ownership authority. No JSON or init-script changes.
- Semantics (precise): `ROUND` is the **review-attempt ordinal** for the
  work unit. The first verdict written on a work unit emits `ROUND: 1/3`;
  every subsequent verdict — `AGREE` or `REVISE`, including a fresh-verifier
  verdict — emits the prior ordinal + 1. Mechanical, no judgment call,
  regardless of whether a revision was honest defect-fixing or entrenched
  disagreement. The existing rule — one focused evidence cycle, then
  unresolved *material tradeoffs* go to the user — still applies and can
  escalate well before the cap.
- A `REVISE` verdict carrying the cap ordinal (`ROUND: 3/3`) ends the
  loop: neither agent writes another revision; both stop, write the open
  items to the mailbox as options + consequences, and wait for the user.
- Reset rules: a genuinely new user-scoped objective opens a new `WORK_UNIT`
  (fresh slug; its first verdict emits `ROUND: 1/3`). An ownership handoff
  does **not** reset the counter — the work unit is defined by the
  objective, not the owner. After user input resolves an escalation, the
  next verdict may carry an explicit `ROUND_RESET` note and restart the
  ordinal at 1.
- Protocol + both prompts updated consistently.
- Acceptance: protocol and both prompts agree on the semantics; walking the
  protocol text, a `REVISE` verdict at the cap ordinal (`ROUND: 3/3`) ends
  with both agents waiting on the user; grep for `^ROUND:` reconstructs the
  attempt sequence per work unit. No script enforcement exists or is
  wanted — the *record* is what makes violations visible to the user.

### R4 — Fresh-eyes final verification (fixes F4)

- New optional but recommended closing step in `COLLABORATION.md`
  ("Verification and handoff evidence"): before declaring a work unit
  complete, the implementer writes a `VERIFY_REQUEST` (scope: acceptance
  criteria + how to run checks + the `WORK_UNIT` slug and the **exact
  `ROUND: <n>/<max>` value the verifier must emit** — the next attempt
  ordinal per R3; the verifier may not read the log and the mailbox's
  earlier turns are overwritten, so it derives nothing itself) to the
  mailbox; the user (or the peer, via
  the existing scripts) opens a **new** copilot session with a fresh
  verifier prompt. Fresh context = it reads only the repo, the diff, and the
  VERIFY_REQUEST — explicitly not `session.log.md`.
- The verifier is **read-only end to end**: it must not edit any file, must
  not run the init command, and must stop immediately if the mailbox or the
  VERIFY_REQUEST is missing. It emits the R2 VERDICT block as its final
  *output* (screen text), carrying the `WORK_UNIT` and the exact `ROUND`
  value handed to it in the VERIFY_REQUEST — same value whether its verdict
  is `AGREE` or `REVISE`, no derivation. A fresh-verifier verdict is a
  review attempt like any other, so it consumes the same work-unit backstop
  (a verifier `REVISE` at the cap ordinal escalates per R3). The **active
  implementer transcribes that block
  verbatim** into `mailbox.md` + `session.log.md`, attributed as
  fresh-verifier output. (This resolves the otherwise-contradiction between
  "read-only role" and R2's "reviewer MUST write".)
- Implement as `prompts/verifier.md` plus explicit role plumbing:
  `render-prompt.ps1 -Agent` gains `verifier` in its ValidateSet **and** an
  explicit three-way mapping — today line 35 maps every non-`a` value to
  `agent-b` and the filename pattern would resolve `verifier` to a
  nonexistent `prompts/agent-verifier.md`; both must be fixed to map
  `verifier` → role `verifier`, prompt `prompts/verifier.md`.
  `_common.ps1::Get-CocopilotSessionBanner`'s `ValidateSet` gains
  `verifier`, and the verifier's banner variant **omits the init command
  line** (a read-only role gets no ready-to-run mutating command).
- Acceptance: `render-prompt.ps1 -Agent verifier -RepoPath <r>` prints a
  paste-ready prompt with resolved paths; the verifier prompt forbids
  writes, forbids running init, and forbids reading the session log; the
  protocol's VERIFY_REQUEST format includes `WORK_UNIT` and the exact
  `ROUND` value the verifier must emit (verifier derives nothing);
  protocol documents when to use it (risky/final work units; skippable for
  trivial ones).

### R5 — Crash-safe ownership writes (fixes F5)

- Scope (narrowed deliberately): this protects against **torn/partial
  files** — a crash mid-write, or a reader catching a half-written JSON. It
  does **not** serialize two valid near-simultaneous writers; that stays
  last-writer-wins, humanly resolved via the epoch rule. No locking, no CAS.
- New shared helper `Write-MailboxJson` in `_common.ps1`: write the full
  content to a **unique temp file in the same directory** as the target
  (same volume), then `Move-Item -Force` onto the target; delete the temp
  file in a `finally` block if the move never happened. Call it what it is —
  *same-directory temp-file replacement*, best-effort crash safety — and
  drop the word "atomic" everywhere: `Move-Item -Force` is documented as
  "overwrite", not as an atomic-rename contract across PS 5.1/7, providers,
  and filesystems.
- Encoding: the helper writes via
  `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))`
  so both hosts produce identical bytes (WinPS 5.1's `-Encoding utf8` adds
  a BOM; pwsh's doesn't).
- Reword `COLLABORATION.md`'s "atomically replaced" to "replaced whole-file
  via same-directory temp-file rename (crash-safe against torn writes;
  concurrent last-writer-wins races remain humanly resolved via the epoch
  rule)".
- Protocol + prompts: agents update ownership **only** by invoking the
  helper — give the exact invocable command in the prompts/banner (e.g.
  `. <cocopilot>\scripts\_common.ps1; Write-MailboxJson -Path <repo>\.mailbox\implementer.json -Object $record`)
  — not "rewrite the whole file" prose that an agent may satisfy with an
  in-place editor.
- `init-mailbox.ps1` uses the helper for its `implementer.json` write.
- Acceptance: no `Set-Content` directly targeting `implementer.json`
  remains; the helper is used by init and its exact invocation appears in
  the protocol/prompts; the temp file is cleaned up on a simulated failed
  move; identical byte output on Windows PowerShell 5.1 and pwsh 7.

### R6 — Minimal Pester suite (fixes F6)

- **Prerequisite, stated explicitly:** Pester 5 is a development-time
  dependency that must be installed side-by-side for *each* host — Windows
  PowerShell 5.1 ships only inbox Pester 3.4.0, so an unqualified
  `Invoke-Pester` there runs Pester 3. The documented run commands fail
  closed: terminating errors, major version constrained *and* asserted,
  test failure propagated via exit code. Same command body under both
  hosts (`powershell.exe -NoProfile -Command "…"` and
  `pwsh -NoProfile -Command "…"`):

  ```powershell
  $ErrorActionPreference='Stop'; $p = Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.999 -Force -PassThru; if ($p.Version.Major -ne 5) { throw 'Pester 5 required' }; Invoke-Pester -Path tests -EnableExit
  ```

- One `tests/Cocopilot.Tests.ps1` (Pester 5 syntax only, `#Requires
  -Version 5.1` header) covering, black-box against a `$TestDrive` fake
  repo: R0 init succeeds from the restored templates, is idempotent without
  `-Force`, and leaves both the ignore rule and the mailbox files present
  (creation *order* is not observable black-box after the process exits —
  ordering stays an R0 code-inspection acceptance, not a flaky temporal
  test);
  `init -Force` preserves `session.log.md` (R1); cleanup removes exactly
  the cocopilot gitignore block (CRLF and LF variants) and leaves user
  rules; `render-prompt` output contains the resolved repo path for each
  role incl. `verifier`; `Write-MailboxJson` replaces content correctly and
  cleans up its temp file on a simulated failed move — on both hosts.
- **Watcher tests run the script as a child process** (bounded by
  `-TimeoutSeconds`), asserting exit code/output for: a one-byte change in
  either watched file → exit 0 / `MAILBOX_CHANGED`; a log-only append →
  timeout exit 1. `Get-MailboxHash` is nested inside a script that loops
  and calls `exit` — do not dot-source production internals into Pester,
  and do not refactor them merely for the test's convenience.
- Acceptance: both documented commands green on Windows PowerShell 5.1
  **and** pwsh 7 (the repo advertises `#Requires -Version 5.1` — keep that
  contract).

## Explicitly rejected (so the implementing session doesn't drift)

- No state machine, no JSON schema validation, no CAS/locking, no automatic
  timeout takeover, no daemon/watcher beyond the existing one-shot script,
  and no token/resource-budget pause-resume machinery. (R3's stop-at-cap is
  a recorded convention — agents stop and ask — not machinery.) Those solve
  *unattended* operation; cocopilot's job is interactive pairing with the
  human as arbiter. If unattended runs become the goal, that is a different
  tool, not a cocopilot feature.
- No committed artifacts in target repos — the `.mailbox/`-stays-ignored
  rule is inviolable; everything above lives inside `.mailbox/` or in the
  cocopilot install.

## Suggested implementation order

R0 (unblocks everything) → R2 (protocol+prompts only) → R1 (log) → R3
(verdict-block counter) → R5 (crash-safe helper) → R4 (verifier role) → R6
(tests last, covering all of it). Update `README.md` sections (Layout, How
it works, Listening) in the same change as each item — the README documents
every behavior precisely; keep it that way.
