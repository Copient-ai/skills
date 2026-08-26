---
name: codex-review-loop
description: Self-review the current branch with OpenAI Codex's local CLI (`codex review`) in a review→fix loop, without polluting this thread's context. Runs codex review locally (no GitHub round-trip), fixes the issues here, and repeats until no blocking issues remain. The Codex peer to /pr-review-loop — run both for independent Claude + Codex perspectives. Use when the user says "run the codex review loop", "review with codex until clean", or wants Codex's perspective on the branch.
disable-model-invocation: false
allowed-tools: Bash(bash ~/.claude/skills/codex-review-loop/scripts/*), Bash(codex review:*), Bash(git:*), Bash(gh:*), Bash(just precommit:*), Bash(just test:*), Bash(just test-module:*), Bash(just check:*), Read, Edit, Write, Grep, Glob
---

# Codex Review Loop

## Overview

Run a **review → fix → re-review** loop on the current branch using OpenAI
Codex's local CLI, keeping the heavy review output out of this thread's context.

This is the **Codex peer to `/pr-review-loop`**. Both run locally and converge
the same way; they differ only in *who reviews*:

| | `/pr-review-loop` | `/codex-review-loop` (this) |
|---|---|---|
| Reviewer | Claude, in an isolated subagent | OpenAI Codex, via `codex review` CLI |
| Isolation | subagent returns only a verdict | `codex-review.sh` keeps the ~100KB transcript in a log file, prints only findings |

Run them back to back for two independent perspectives (Claude's is typically
the more thorough; Codex catches a different slice). Neither uses the GitHub
review cycle — this is fully local, no push required to review.

**Convergence policy (same as `/pr-review-loop`):**
- **Blocking issues (Codex P0/P1) always get fixed** — they gate convergence.
- **Nits (P2/P3): be ambitious.** Fix worthwhile, low-risk ones. But nits never
  block, and a nit you deliberately decline must not be re-fixed because a fresh
  review flags it again (oscillation guard).
- **Converged** when a review returns no blocking issues and no new actionable
  nits remain.
- **Cap: 3 iterations.** Push once on convergence; never push if escalating.

## Prerequisites

One-time setup per machine:

1. Install the `codex` CLI and sign in — `codex login`.
2. Trust the repo you are reviewing in `~/.codex/config.toml`, so `codex review`
   can run without an approval prompt on every file it reads.

The helper script fails with a clear message if `codex` is missing from `PATH`.

## The helper

**`scripts/codex-review.sh [--base BRANCH | --commit SHA | --uncommitted] [--from-log FILE]`**
runs `codex review` and prints only the distilled result:

```
CODEX_REVIEW: CLEAN | FINDINGS | UNPARSED
BLOCKING=<n>  NITS=<n>
LOG=<full transcript path>
--- SUMMARY ---
<one paragraph>
--- FINDINGS ---            (omitted when CLEAN)
- [Pn] Title — /abs/path:line-range
  explanation
```

Severity maps as **P0/P1 = blocking, P2/P3 = nit**. The full transcript stays in
`LOG=` — read it only if you need more context on a specific finding; never pipe
it into this thread wholesale.

`UNPARSED` (exit 4) means the script refused to guess, and it prints
`PARSE_CAUSE=` naming which of three things went wrong:

| `PARSE_CAUSE` | What it means |
|---|---|
| `nomarker` | No `codex` marker at all — empty or truncated log; the review never ran or never finished. |
| `incomplete` | Marker present, nothing after it — cut off before writing the verdict. |
| `noitems` | A findings header was found but no `P0`–`P3` items parsed out of it — truncated mid-write, or an output format we do not know. |
| `strayitems` | Priority bullets with no recognized findings header — the codex output format has probably changed. |
| `ambiguous` | Nested or conflicting findings sections — a finding quotes a transcript excerpt that looks exactly like a real section. |

Never count any of them as a clean review. Step 2 says what to do with each.

## Steps

### 0. Pre-flight (once)

- Confirm a feature branch, not the default branch (`git branch --show-current`).
- Commit any uncommitted work first — `codex review --base` reviews committed
  state. Match the repo's commit-message convention (`git log --oneline -5`).
- Note the base branch: `gh pr view --json baseRefName -q .baseRefName 2>/dev/null || echo main`.
- Start an empty **declined-nits ledger** in your working notes (you persist
  across iterations; each `codex review` run is fresh).
- Set the iteration counter to **0**.

### 1. Review (isolated by the script)

Run from the root of the checkout under review, and confirm you are actually
there. The Bash tool silently resets cwd after some commands; a review fired
from the reset directory reviews *that* repo and comes back a confident, useless
`CLEAN`:

```bash
git rev-parse --show-toplevel   # must name the checkout under review
bash ~/.claude/skills/codex-review-loop/scripts/codex-review.sh --base <BASE>
```

Use a generous timeout (codex review can take a few minutes on a large branch;
the script's own cap is 600s, and a plain retry after a timeout usually
completes). You receive back only the compact block above.

### 2. Parse and decide convergence

- `CODEX_REVIEW: UNPARSED` (exit 4) — there is no verdict to trust. **Never
  treat it as convergence.** What to do depends on `PARSE_CAUSE`:

  - **`nomarker` / `incomplete` / `noitems`** — the review did not finish
    writing its verdict, so there is nothing to recover. Re-run **once**; if it
    recurs, escalate. Neither attempt counts as an iteration.
  - **`strayitems`** — the findings are there but under a header this script
    does not know, so the codex output format has changed. Read them from the
    transcript and use them; then fix `FRC_RE` in the script, because every
    review is affected until you do.
  - **`ambiguous`** — the transcript holds a real section and a quoted one, and
    **position cannot tell you which is which.** Do *not* take "the last `codex`
    marker" as authoritative: in the shape fixture 8 covers, the last marker
    belongs to the *quoted* section, so that rule discards the outer P0/P1 and
    promotes a quoted nit. Read the transcript and identify the current
    review's section by content — it cites files in *this* branch's diff, and a
    quoted one usually cites other paths or repeats an older run. If you can
    identify it confidently, its findings are authoritative for this iteration:
    carry on to step 3 and count the iteration as normal. **If you cannot, stop
    and escalate** — do not guess.

  `ambiguous` is often deterministic: any repo whose own files contain `codex`
  markers and findings headers reproduces it every run, and this skill's
  fixtures do exactly that. So never resolve it by re-running.

- **Manually verified clean.** If you read the transcript under `UNPARSED` and
  the current review's section genuinely has no findings, that **is**
  convergence. Go to step 4, and say in your summary that the verdict was
  confirmed by reading the transcript rather than from the distilled line.
  Without this, a branch that deterministically trips `UNPARSED` could never
  finish the loop.
- **Converged** if `CODEX_REVIEW: CLEAN`, **or** `BLOCKING=0` and every listed
  nit is already in your declined ledger. → step 4.
- Otherwise → step 3.

**Verify any 0-finding verdict before trusting it.** The distilled line is a
parse of the transcript and it can under-report. Read the tail of the transcript
at the path the script printed on its `LOG=` line:

```bash
tr -d '\0' < <LOG-path-from-the-output> | tail -25
```

Treat the verdict as a failed run, not approval, if:

- the tail disagrees with `BLOCKING=`/`NITS=` — the transcript is authoritative;
- the summary says the diff is empty or that HEAD is the merge-base — you
  reviewed the wrong repo or the wrong base (see the cwd guard in step 1).

A real `CLEAN` reads like a review: Codex ran the tests and lint itself and
closed with a substantive summary. Sanity-check with `git diff --stat
<BASE>...HEAD | tail -1` that there was a diff to review at all. Null bytes in
the log are routine and are *not* by themselves a sign of a misparse — the tell
is disagreement with the transcript. When grepping the log for `P0|P1|P2|P3`,
check the hits are findings and not pre-existing `Codex P2 — ...` comments in
the code under review, which match and inflate the count.

### 3. Fix, then loop

For each **blocking** finding (P0/P1):
- Confirm it against the current code first (read the file; the finding gives
  `path:line`). **If you're confident it's a false positive**, don't contort the
  code — stop and escalate (step 4, escalation path) with your evidence.
- Otherwise fix it, matching surrounding style.

For **nits** (P2/P3) — be ambitious: fix the clear, low-risk ones not already in
your declined ledger. For any nit you decline, add it to the ledger with a one-
line reason so it isn't re-attempted.

Then:
1. Run the narrowest sensible check — `just test-module <path>`, `just check` for
   migrations/config, `just precommit` if non-trivial.
2. **Commit locally** (no push), message matching repo style. One commit per
   iteration (or per fix) for auditability.
3. Increment the counter. If it has **reached 3**, run one final
   **verification review** (step 1) against what you just committed — but do
   **not** fix again. Its result decides which step 4 path you take: clean means
   you converged; remaining findings go to escalation as *verified still-open*.
   Escalating on the pre-fix findings without this review would report issues
   you may have already fixed. Otherwise return to **step 1** — a fresh
   `codex review` re-reviews the new committed state.

### 4. Finish

**Converged:** `git push` once (confirm the branch). Print a compact table:

| Iter | Fixed (sha) | Nits fixed | Nits declined | Codex verdict |
|------|-------------|-----------|---------------|---------------|

End with Codex's final SUMMARY and confirm the push.

**Escalation** (cap hit with blockers, or a disputed blocker): do **not** push.
Report the open blocking finding(s), your reasoning if you dispute one, and the
local commits made so far. Hand the decision to the user.

## Guidelines

- **Never dump the transcript into this thread.** The script already keeps it in
  `LOG=`; read targeted slices only if a finding needs more context.
- **Fresh review every iteration** — each `codex review` run is stateless and
  re-reviews the latest commit. The oscillation guard (declined ledger) lives in
  *this* thread, which persists.
- **Fix where you have context** — the development history is here, not in Codex.
- **Don't reward-hack the reviewer** — decline (and record) nits whose "fix"
  would worsen the code.
- **Close the whole class, not the instance.** On a large branch each fresh
  review drills into progressively rarer variants of the same issue, so fixing
  one field at a time makes the tail endless. When a finding names an instance
  of a class you have already accepted, audit the siblings and fix them all in
  that round. On a big branch, converge on *0 blockers + rounds of only
  ledger-repeats and shrinking same-class instances* — a literal `CLEAN` is not
  a terminating condition.
- **Local until clean** — commit across iterations; single push on convergence.
- **Verify before committing** — run the relevant tests/lint for what you touched.

## Notes

- `codex review` runs the model locally — each iteration costs a Codex call and a
  few minutes; the iteration cap bounds it.
- The script pins `codex review` to `gpt-5.6-sol` at `xhigh` reasoning effort;
  override with `CODEX_REVIEW_MODEL` / `CODEX_REVIEW_EFFORT` if needed.
- The script's regression test needs no live Codex call:
  `bash ~/.claude/skills/codex-review-loop/scripts/test-codex-review.sh`.
- Distinct from `pr-comments`, which addresses review threads already posted on
  the GitHub PR (e.g. Codex's auto-review on push or a human reviewer). This loop
  is local and pre-push.
- A natural follow-up, if you want both perspectives in one command, is an
  alternating loop that runs a Claude round then a Codex round until both are
  clean — ask and I'll build it on top of these two skills.
