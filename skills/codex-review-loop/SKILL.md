---
name: codex-review-loop
description: Self-review the current branch with OpenAI Codex's local CLI (`codex review`) in a review→fix loop, without polluting this thread's context. Runs codex review locally (no GitHub round-trip), fixes the issues here, and repeats until no blocking issues remain. The Codex peer to `pr-review-loop` — run both for independent Claude + Codex perspectives. Use when the user says "run the codex review loop", "review with codex until clean", or wants Codex's perspective on the branch.
version: 1.0.0
disable-model-invocation: false
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/skills/codex-review-loop/scripts/"*), Bash(bash .claude/skills/codex-review-loop/scripts/*), Bash(bash .agents/skills/codex-review-loop/scripts/*), Bash(codex review:*), Bash(git:*), Bash(gh:*), Read, Edit, Write, Grep, Glob
---

# Codex Review Loop

> **On names.** Under the Claude Code plugin these skills are prefixed with the
> plugin name — `copient:codex-review-loop`, `copient:pr-review-loop`. Installed
> with `npx skills` they keep their bare frontmatter names and that prefix does
> not resolve. This file uses the bare names, which are correct either way.

## Host requirement

**Any agent that can run bash.** The review itself happens in the `codex` CLI, a
separate process, so nothing here depends on a particular host agent's features.
Claude Code, Codex, Cursor, Warp and OpenCode can all drive it.

Contrast `pr-review-loop`, which is Claude Code only because its isolation
*is* the `Task` subagent.

## Overview

Run a **review → fix → re-review** loop on the current branch using OpenAI
Codex's local CLI, keeping the heavy review output out of this thread's context.

This is the **Codex peer to `pr-review-loop`**. Both run locally and converge
the same way; they differ only in *who reviews*:

| | `pr-review-loop` | `codex-review-loop` (this) |
|---|---|---|
| Reviewer | Claude, in an isolated subagent | OpenAI Codex, via `codex review` CLI |
| Isolation | subagent returns only a verdict | `codex-review.sh` keeps the ~100KB transcript in a log file, prints only findings |

Run them back to back for two independent perspectives (Claude's is typically
the more thorough; Codex catches a different slice). Neither uses the GitHub
review cycle — this is fully local, no push required to review.

**Convergence policy (same as `pr-review-loop`):**
- **Blocking issues (Codex P0/P1) always get fixed** — they gate convergence.
- **Nits (P2/P3): be ambitious.** Fix worthwhile, low-risk ones. But nits never
  block, and a nit you deliberately decline must not be re-fixed because a fresh
  review flags it again (oscillation guard).
- **Converged** when a review returns no blocking issues and no new actionable
  nits remain. `CODEX_REVIEW: CLEAN` is emitted only when no findings parsed at
  all, so it always converges — but it is not *required*: `BLOCKING=0` with
  every listed nit already in your ledger converges just as well. See the
  large-branch guideline under Guidelines.
- **Cap: 3 iterations.** Push once on convergence; never push if escalating.

## Prerequisites

One-time setup per machine:

1. Install the `codex` CLI and sign in — `codex login`.
2. Trust the repo you are reviewing in `~/.codex/config.toml`, so `codex review`
   can run without an approval prompt on every file it reads.

The helper script fails with a clear message if `codex` is missing from `PATH`.

## Locating the helper

The scripts live in **this skill's own directory**, under `scripts/`. The rule is
just that: use the directory *this file was loaded from*. Resolve it once at the
start of the loop and use the same literal path for every call.

Do not work from a list of known install locations — there is no such list. The
`npx` installer writes wherever the target agent keeps skills, which for a
Claude Code project is `.claude/skills/`, for most other agents `.agents/skills/`,
and for an agent with its own convention somewhere else again. These are common
cases, not an enumeration:

| Install path | Skill directory |
|---|---|
| Claude Code plugin | `${CLAUDE_PLUGIN_ROOT}/skills/codex-review-loop` |
| `npx skills add`, Claude Code project | `.claude/skills/codex-review-loop` |
| `npx skills add`, most other agents | `.agents/skills/codex-review-loop` |
| anything else | wherever you were loaded from — that is the answer |

If `scripts/codex-review.sh` is not under the directory you were loaded from,
stop and say so. Do not go hunting for a copy elsewhere on the machine: a second
copy is very likely a *different version*, and running an old parser is how you
get a clean verdict for a branch nobody reviewed.

Do **not** resolve the path into a shell variable and invoke `bash "$VAR"` —
permission matching reads the literal command text, so a variable silently drops
out of the allowlist and every call falls back to an approval prompt. Write the
path out.

`allowed-tools` covers the first three rows as a convenience. Any other location
prompts on first use, which is deliberate: a prompt is a visible, honest outcome.
To stop seeing it, allowlist the path your install actually uses:

```json
{ "permissions": { "allow": ["Bash(bash ~/.claude/skills/codex-review-loop/scripts/:*)"] } }
```

## Checking you are current

```bash
bash <skill-dir>/scripts/codex-review.sh --version
```

Prints the parser version. A copy older than the current release may carry
false-`CLEAN` bugs that have since been fixed — a review tool that silently
approves branches it did not read. Compare it against
<https://github.com/Copient-ai/skills/blob/main/CHANGELOG.md> before trusting a
clean verdict from an install you have not updated in a while.

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
bash <skill-dir>/scripts/codex-review.sh --base <BASE>
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
1. Run the narrowest sensible check for what you touched, using **this project's**
   test/lint command — see *Finding this project's checks* below.
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

## Finding this project's checks

This skill installs on any repo, so it cannot assume a runner. Resolve the test
and lint commands **once per loop** and reuse them every iteration:

1. **Explicit config wins.** If `.review-loop.json` exists, take `test`
   and `lint` from it verbatim:

   ```json
   { "test": "just test-module", "lint": "just precommit" }
   ```

2. **Otherwise detect from the files you actually changed.** A repo can carry
   more than one toolchain, and first-match on root markers will run the
   JavaScript tests for a Go-only fix and call the iteration verified. Pick by
   what your diff touches; if it touches more than one, **run each of them**.

   | Toolchain marker | Test | Lint |
   |---|---|---|
   | `justfile` / `Justfile` | `just test-module <path>` (else `just test`) | `just precommit` (else `just check`) |
   | `package.json` with a `test` script | `<pm> run test` | `<pm> run lint` if scripted |
   | `Makefile` with a `test` target | `make test` | `make lint` if targeted |
   | `pytest.ini`, or `pyproject.toml` declaring pytest | `pytest <path>` | `ruff check` if configured |
   | `tox.ini` | `tox` (read it — it may not be pytest) | as configured there |
   | `Cargo.toml` | `cargo test` | `cargo clippy` |
   | `go.mod` | `go test ./...` | `go vet ./...` |
   | `.pre-commit-config.yaml` (lint only) | — | `pre-commit run --files <paths>` |

   `<pm>` is the project's own package manager, not `npm`: read the
   `packageManager` field in `package.json`, else the lockfile — `bun.lock` or
   `bun.lockb` → `bun`, `pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`,
   otherwise `npm`. Guessing `npm` breaks Yarn PnP, which needs `yarn` to inject
   its loader, and Bun-only repos, which may not have `npm` installed at all.
   Bun 1.2+ writes the text `bun.lock` by default, so checking only for the
   legacy binary `bun.lockb` misses most current Bun projects.

   Always `<pm> run test`, never `<pm> test`. They are the same command for npm,
   yarn and pnpm, but `bun test` runs Bun's own built-in runner and ignores
   `scripts.test` entirely — so any setup, end-to-end suite or extra step that
   script performs is skipped while the iteration still looks verified.

   Confirm the recipe actually exists before relying on it — `just --list`,
   `<pm> run`, `make -qp`. A `justfile` without a `test-module` recipe is not a
   test command.

3. **Nothing resolved → stop and ask the user** for the command, and record the
   answer for the rest of the loop.

**An iteration whose check did not run is not a completed iteration.** Do not
increment the counter, do not commit it as verified, and never report the loop as
converged on the strength of a check that no-op'd or that you skipped because you
could not find a command. This is the same rule the parser follows for
`UNPARSED`: never report approval for something you did not actually do.

The check command runs under your host agent's normal permission rules and may
prompt the first time. Approve it, or allowlist it in your own settings — do not
work around a prompt by skipping the step.

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
  ledger-repeats and shrinking same-class instances*: a literal `CLEAN` ends the
  loop when you get one, but waiting for it is not the bar — a large branch may
  never produce one, and holding out for it loops forever.
- **Local until clean** — commit across iterations; single push on convergence.
- **Verify before committing** — run the relevant tests/lint for what you touched.

## Notes

- `codex review` runs the model locally — each iteration costs a Codex call and a
  few minutes; the iteration cap bounds it.
- The script pins `codex review` to `gpt-5.6-sol` at `xhigh` reasoning effort;
  override with `CODEX_REVIEW_MODEL` / `CODEX_REVIEW_EFFORT` if needed.
- The script's regression test needs no live Codex call:
  `bash <skill-dir>/scripts/test-codex-review.sh`. It must report `ALL PASS`
  before you trust a verdict from a modified parser.
- Distinct from any skill that addresses review threads already posted on the
  GitHub PR (Codex's auto-review on push, or a human reviewer). This loop is
  local and pre-push — no PR required.
- If you touch the parser, every change needs a fixture proven red against the
  previous version before it goes green. The guards are not decoration; each one
  traces to a reproduced false-`CLEAN`.
