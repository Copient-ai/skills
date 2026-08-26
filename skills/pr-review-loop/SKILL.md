---
name: pr-review-loop
description: Self-review the current branch in a tight loop without polluting this thread's context. Spawns an isolated reviewer subagent that returns only a compact verdict, then fixes the issues here, and repeats until no blocking issues remain. Use when the user says "review and fix until clean", "run the review loop", "self-review this branch", or wants to iterate on PR feedback in the main dev thread.
disable-model-invocation: false
allowed-tools: Task, Bash(git:*), Bash(gh:*), Bash(just precommit:*), Bash(just test:*), Bash(just test-module:*), Bash(just check:*), Read, Edit, Write, Grep, Glob
---

# PR Review Loop

## Overview

Run a **review → fix → re-review** loop on the current branch until the code
converges, **keeping the heavy review work out of this thread's context.**

The mechanism that makes this possible: a subagent runs in an isolated context
and only its *final message* returns to the caller. So each iteration spawns a
fresh `general-purpose` reviewer subagent that does the entire review in its own
context and returns **only a compact verdict** (a short issue list). All the diff
reading, file exploration, and analysis stay in the subagent — this thread only
ever ingests the verdict, then does the fixing here, where the development
context lives.

> **Why not just call `/pr-review`?** Subagents cannot spawn subagents, and
> `/pr-review` works by fanning out to specialist subagents — so it can't run
> inside an isolated context. This loop uses one consolidated reviewer instead.

**Convergence policy (chosen for this skill):**
- **Blocking issues always get fixed** — they gate convergence.
- **Nits: be ambitious.** Fix worthwhile, low-risk nits too. But nits never
  block convergence, and a nit you deliberately decline must not be re-fixed
  just because a fresh reviewer flags it again (oscillation guard).
- **Converged** when a review returns no blocking issues and no new actionable
  nits remain.
- **Cap: 3 iterations.** Push once on convergence; never push if escalating.

## Steps

### 0. Pre-flight (once)

- Confirm a branch, not the default branch: `git branch --show-current`. If on
  `main`/`master`, stop and tell the user.
- If the working tree has uncommitted changes (`git status --porcelain`), commit
  them first — the reviewer only sees committed state. Use a message that
  matches the repo's convention (check recent `git log --oneline -5`).
- Note the base branch: `gh pr view --json baseRefName -q .baseRefName 2>/dev/null || echo main`.
- Keep a running **declined-nits ledger** in your working notes this whole loop
  (you persist across iterations; the reviewer does not). Start it empty.
- Set the iteration counter to **0**.

### 1. Review (isolated)

Spawn a **`general-purpose`** subagent with the Task tool. Keep the Task prompt
tiny so nothing heavy enters this thread — point the subagent at the reviewer
prompt file and let it read that itself:

> Read `~/.claude/skills/pr-review-loop/reviewer-prompt.md` and follow it exactly
> to review the current branch against base `<BASE>`. You are read-only. Return
> only the verdict block it specifies.

(`general-purpose` is used because it always exists — a custom agent type would
have to be registered at startup in every environment. The prompt file enforces
read-only behavior and the output contract.) You receive back only the compact
verdict block.

### 2. Parse the verdict

The reviewer returns:

```
VERDICT: CLEAN | NEEDS_WORK | BLOCKED
BLOCKING:
- [SEVERITY] path:line — issue — why it blocks   (or: none)
NITS:
- path:line — issue — suggested change            (or: none)
SUMMARY: ...
```

Decide convergence:
- `VERDICT: BLOCKED` — the reviewer could not review at all. **Never treat it
  as convergence.** Fix what SUMMARY names (usually the base ref or the working
  directory) and re-run step 1. If the same cause survives a fix, it is not
  transient: re-run at most **once**, then escalate to the user rather than
  looping. A repeating BLOCKED is a broken setup, not a review in progress.
- **Converged** if `BLOCKING` is `none` **and** every listed `NIT` is either
  already in your declined-nits ledger or absent. → go to step 4.
- Otherwise → step 3.

**A `CLEAN` that reviewed nothing is not convergence.** If the SUMMARY says the
diff was empty or that the base could not be resolved, the run failed — fix the
cause and re-run rather than counting it as a passing iteration. Sanity-check
with `git diff --stat <BASE>...HEAD | tail -1` that there was a diff to review
at all.

### 3. Fix, then loop

For each **BLOCKING** item:
- Confirm it against the current code first. **If you're confident it's a false
  positive**, do not contort the code to satisfy it — stop the loop and escalate
  (step 4, escalation path) with your evidence. Don't burn iterations on a
  dispute.
- Otherwise implement the fix, reusing existing patterns and matching
  surrounding style.

For **NITS** — be ambitious: fix the ones that are clear, low-risk improvements
and *not* already in your declined ledger. For any nit you choose not to fix
(subjective, risky, or you disagree), add it to the declined ledger with a one-
line reason so it won't be re-attempted next iteration.

Then:
1. Run the narrowest sensible check — `just test-module <path>` for touched
   modules, `just check` for migrations/config; `just precommit` if the change
   is non-trivial.
2. **Commit locally** (do not push) with a focused message matching repo style.
   Prefer one commit per iteration (or per fix) so history is auditable.
3. Increment the iteration counter. If it has **reached 3**, run one final
   **verification review** (step 1) against what you just committed — but do
   **not** fix again. Its result decides which step 4 path you take: clean means
   you converged; remaining blockers go to escalation as *verified still-open*.
   Escalating on the pre-fix verdict would report issues you may have already
   fixed. Otherwise return to **step 1** (a fresh reviewer re-reviews the new
   committed state).

### 4. Finish

**Converged path:** `git push` once (confirm the branch first). Then print a
compact summary table:

| Iter | Fixed (sha) | Nits fixed | Nits declined | Verdict |
|------|-------------|-----------|---------------|---------|

End with the final reviewer SUMMARY and confirm the push.

**Escalation path** (cap hit with blockers remaining, or a disputed blocker): do
**not** push. Report what remains — the open blocking item(s), your reasoning if
you dispute one, and the commits made so far (local only) — and hand the decision
to the user.

## Guidelines

- **Never pass the diff into this thread.** The whole point is isolation — let
  the reviewer gather and hold the diff; you only ever read the verdict.
- **Fresh reviewer every iteration** — each Task spawn is a clean context that
  re-reviews the latest commit with no bias. The oscillation guard (declined
  ledger) lives in *this* thread, which persists.
- **Fix where you have context.** This thread has the development history; that's
  why fixing happens here, not in the subagent.
- **Don't reward-hack the reviewer.** If satisfying a nit would make the code
  worse or churnier, decline it and record why.
- **Close the whole class, not the instance.** On a large branch each fresh
  review drills into progressively rarer variants of the same issue, so fixing
  one field at a time makes the tail endless. When a finding names an instance
  of a class you have already accepted, audit the siblings and fix them all in
  that round. On a big branch, converge on *0 blockers + rounds of only
  ledger-repeats and shrinking same-class instances* — a literal `CLEAN` is not
  a terminating condition.
- **Local until clean.** Commits stay local across iterations; a single push
  happens only on convergence so you can rely on inspecting the result.
- **Verify before committing** — run the relevant tests/lint for what you touched.

## Notes

- The reviewer runs as a `general-purpose` subagent following
  `reviewer-prompt.md` (in this skill dir), which calibrates to your
  `security-reviewer` / `code-quality-reviewer` / `refactoring-reviewer` /
  `django-security-reviewer` definitions when present. No custom agent type is
  required, so it works without a Claude Code restart.
- `/codex-review-loop` is the peer to this skill: the same loop, reviewed by
  OpenAI Codex's local CLI instead of Claude. Run both for two independent
  perspectives.
- Per-iteration cost ≈ one reviewer subagent + your fixing. The cap bounds it.
- This is a *convergence* loop, distinct from the interval-based `/loop` skill.
- Complementary to `pr-comments`: this self-reviews before merge; `pr-comments`
  addresses external reviewer threads (e.g. Codex) already posted on the PR.
