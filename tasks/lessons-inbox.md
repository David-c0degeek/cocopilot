---
last-reviewed: TODO
---

# Lessons inbox

The single candidate state for this repository. Candidates wait here for the curation ritual (nemo-pilot-review-lessons); nothing here is loaded as instructions, and no candidate enters a Learned rules block except through curation. `last-reviewed` is updated only by the curation ritual.

<!-- BEGIN NEMO-PILOT CANDIDATE FORMAT -->
One `###` block per candidate, newest last (children of the `## Candidates` section):

```markdown
### YYYY-MM-DD — Short title
- Trigger: user correction | closeout harvest | manual capture | bug pattern
- Rule: imperative, verifiable rule
- Evidence: repository code pointer path#symbol-or-line preferred; PR/error message accepted at capture, but promotion requires a current code pointer
- Proposed scope: core | domain:<instructions-file> | org
```
<!-- END NEMO-PILOT CANDIDATE FORMAT -->

## Candidates

### 2026-09-03 — Count executed Pester cases
- Trigger: closeout harvest
- Rule: Derive documented test totals from a successful Pester run, not by counting `It` blocks, because parameterized cases expand at runtime.
- Evidence: tests/Cocopilot.Tests.ps1:497
- Proposed scope: core

## Org-forward queue

Accepted org-scope lessons awaiting forwarding to the central repo's `lessons/org-inbox.md`. Excluded from candidate counts and from inbox emptying; remove an entry only after central receipt is confirmed. Entry format (`###` blocks, children of this section):

```markdown
### YYYY-MM-DD — Short title
- Source-repo: <repo name/URL>
- Commit: <immutable commit SHA> (PR link optional context)
- Evidence: <repo-relative pointer path#symbol-or-line>
- Rule: <imperative rule>
- Scope: org
```

_None._
