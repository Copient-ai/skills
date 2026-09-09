---
name: adversarial-review
description: Plan and run a targeted adversarial review of the current branch before a PR — derive what the diff itself promises, turn that into a handful of falsifiable attack angles, and run each as an isolated reviewer pass (Codex, and optionally Claude). Composes with codex-review-loop and pr-review-loop, which converge a generic review; this one plans and runs a targeted one first, angle by angle. Use when the user says "adversarial review", "attack the branch", "plan the review", "local review before the PR", or wants the review built around this specific change's own contracts rather than a generic checklist.
version: 1.2.0
disable-model-invocation: false
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/skills/adversarial-review/scripts/"*), Bash(codex exec:*), Bash(git:*), Bash(gh:*), Task, Read, Edit, Write, Grep, Glob
---

# Adversarial Review

> **On names.** Under the Claude Code plugin these skills are prefixed with the
> plugin name — `copient:adversarial-review`, `copient:codex-review-loop`,
> `copient:pr-review-loop`. Installed with `npx skills` they keep their bare
> frontmatter names and that prefix does not resolve. This file uses the bare
> names, which are correct either way.

## Host requirement

**The Codex passes run under any agent that can run bash** — the reviews
themselves happen in the `codex` CLI, a separate process. **The optional
Claude pass needs Claude Code**, because its isolation *is* the `Task`
subagent, same as `pr-review-loop`. Elsewhere, skip that pass and rely on
Codex's angles alone, or run `pr-review-loop` separately afterward.

## Overview

`codex-review-loop` and `pr-review-loop` each converge a **generic** review —
every round asks the same broad questions again. This skill instead runs a
serialized **planning** phase first: read the diff and derive what *this*
change promises — what callers can now rely on, which contracts or invariants
it claims, what's supposed to enforce them — then turn each into a falsifiable
**attack angle** and run each as its own isolated reviewer pass, in parallel.
Findings go through the same fix discipline the two loops use: confirm
against the code, fix blockers, judge nits, ledger the declines, verify,
commit. Nothing here is fixed in advance — a plan that could apply to any PR
is a bad plan; see Guidelines.

Composes with, doesn't replace:

| | `codex-review-loop` / `pr-review-loop` | `adversarial-review` (this) |
|---|---|---|
| Asks | "Is this branch broadly OK?" | "Does THIS branch's own promise survive an attacker who read the diff?" |
| Scope per pass | whatever the reviewer notices | one derived, falsifiable angle |
| Angles | none — one generic reviewer | 3–6, derived from this diff, run in parallel |

Run either loop before or after this one; run both for two independent generic
perspectives regardless. None of the three replaces the formal gate — step 6.

## Prerequisites

One-time setup per machine:

1. Install the `codex` CLI — **0.145.0 or newer** (the runner passes
   `--strict-config` on every call; see The runner below) — and sign in —
   `codex login`.
2. `python3` (3.9 or newer, stdlib only) on `PATH` — the runner uses it, no venv needed.
3. For the optional Claude pass: nothing beyond Claude Code and its `Task` tool.

## Locating the helper

The scripts live in **this skill's own directory**, under `scripts/`. The rule
is just that: use the directory *this file was loaded from*. Resolve it once
at the start and use the same literal path for every call.

Do not work from a list of known install locations — there is no such list.
These are common cases, not an enumeration:

| Install path | Skill directory |
|---|---|
| Claude Code plugin | `${CLAUDE_PLUGIN_ROOT}/skills/adversarial-review` |
| `npx skills add`, Claude Code project | `.claude/skills/adversarial-review` |
| `npx skills add`, most other agents | `.agents/skills/adversarial-review` |
| anything else | wherever you were loaded from — that is the answer |

If `scripts/adversarial-review.sh` is not under the directory you were loaded
from, stop and say so — do not hunt for a copy elsewhere; a second copy is
very likely a *different version*.

Do **not** resolve the path into a shell variable and invoke `bash "$VAR"` —
permission matching reads the literal command text, so a variable silently
drops out of the allowlist and every call falls back to an approval prompt.
Write the path out.

### Why only the plugin path is pre-approved

`allowed-tools` pre-approves exactly one location: the plugin root. Every
other install prompts on first use, and that is not an oversight to be tidied
away.

A project-level `npx` install puts `scripts/adversarial-review.sh` **inside
the checkout** — `.claude/skills/…` or `.agents/skills/…` are ordinary tracked
paths. Pre-approving `bash` for a path inside the repo means the branch under
review can rewrite the helper, and the run step then executes it without a
prompt, *before anything has reviewed that branch*. A review tool that runs
unreviewed code from the thing it is about to review is not a safe default,
however convenient.

So: approve the prompt when it appears, having satisfied yourself the script is
the one you installed. To silence it, allowlist only a copy that lives
**outside** any checkout — a global install qualifies, a project-level one
does not:

```json
{ "permissions": { "allow": ["Bash(bash ~/.claude/skills/adversarial-review/scripts/:*)"] } }
```

## The plan file

The planning step writes JSON, version 1, to a path this skill chooses (see
step 1):

```json
{"version": 1, "base": "origin/main", "promise": "one paragraph", "contracts": ["..."], "invariants": ["..."],
 "angles": [{"id": "kebab-id", "title": "...", "mandate": "falsifiable instruction", "evidence": "what a finding must include", "execution": "read-only" | "workspace-write", "files": ["optional/paths"]}]}
```

`plan-prompt.md` (this skill dir) is what the agent follows to write it.

## The runner

**`scripts/adversarial-review.sh --plan FILE [--base BRANCH] [--jobs N]
[--timeout SEC] [--dir DIR] [--only ANGLE,...] [--angle-prompt FILE]
[--from-dir DIR] [--allow-writes] [--print-base] [--version] [--help]`**

Env overrides: `CODEX_REVIEW_MODEL`, `CODEX_REVIEW_EFFORT`, `CODEX_BIN`.

### Threat model

**The branch under review is trusted.** This skill reviews your own branches
before you push them, not an adversarial submission. Decline, don't re-raise,
any finding that only makes sense against a hostile branch — a planted
`AGENTS.md`, a hostile reproduction, credential theft via a malicious skill,
HEAD/ref-drift tampering.

Two isolation flags stay on every `codex exec` call anyway, for independence
of judgment rather than security (both verified live against codex-cli
0.145.0): `-c project_doc_max_bytes=0` so an angle's verdict isn't swayed by
the branch's own `AGENTS.md`/`CLAUDE.md` opinion of itself, and
`-c skills.include_instructions=false` for the same reason against the
branch's own `.agents/skills/**/SKILL.md`. `--strict-config` also stays, so a
CLI that doesn't recognize one of those keys fails at startup instead of
silently running that angle unisolated — needs **codex-cli 0.145.0 or newer**.

Each angle runs its own `codex exec --ephemeral -s read-only` (or
`-s workspace-write`, run-wide — see `--allow-writes` below), stdin closed,
under the ambient `CODEX_HOME`, with `--output-schema` enforcing
`scripts/findings.schema.json` (`angle-prompt.md` shows the reviewer the same
shape).

### `--allow-writes`

Sandbox mode is run-wide, not per-angle. Without the flag every angle runs
`-s read-only` regardless of the plan's own `execution` field — reading and
`git` work, anything that writes (a test runner's cache, a script's output)
fails. With `--allow-writes`, every selected angle in *that invocation*
instead runs `-s workspace-write` against the real checkout.

**Never mix modes in one invocation.** If the plan marks one angle
`workspace-write` and the rest `read-only`, run the whole plan once without
`--allow-writes` (the write-marked angle is simply told "read-only," matching
the sandbox it's actually in), then separately re-run just that angle with
`--only <id> --allow-writes` to give it write access. Nothing in the runner
enforces this split; it's on you.

After a `--allow-writes` run, the runner prints one warning line to stderr
plus one `git status --porcelain` — nothing is reverted automatically. Any
angle, in either mode, can come back `UNPARSED(refused)`: it exited nonzero
with no `<angle>.out.json`, and its `.log` shows a provider content-filter
refusal rather than a failure to run.

The run directory (a fresh `mktemp -d` by default, or `--dir DIR`, refused if
it resolves inside the repo under review) keeps `plan.json`,
`<angle>.prompt.txt/.out.json/.log/.status`, and `merged.json`. Re-running an
angle into a reused `--dir` first clears that angle's own prior artifacts, so
a stale file from an earlier run there is never mistaken for this one's
result.

Output:

```
ADVERSARIAL_REVIEW: CLEAN | FINDINGS | UNPARSED
ANGLES=<total>  RAN=<n>  BLOCKED=<n>  UNPARSED=<n>
BLOCKING=<n>  NITS=<n>
DIR=<run dir>
--- ANGLES ---
<id>: CLEAN | FINDINGS(<n>) | BLOCKED | UNPARSED(<cause>)
--- SUMMARY ---
<id>: <summary>
--- FINDINGS ---          (omitted when none)
- [Pn] <path>:<line> — <claim>  [angles: a,b]
  evidence: ...
  reproduction: ...
```

Severity maps as **P0/P1 = blocking, P2/P3 = nit**. Exit codes: `0`
CLEAN/FINDINGS; `1` environment failure (missing `python3`/`codex`, an
unresolvable base, an empty diff); `2` usage error; `3` codex couldn't be
spawned for one or more angles (abort, no merged report); `4` UNPARSED (any
angle `BLOCKED` or unparsable — **never treat as clean**); `130` interrupted.

## Steps

### 0. Pre-flight (once)

- Confirm a feature branch, not the default branch (`git branch --show-current`).
- Commit any uncommitted work first — `codex exec` reads committed state via
  the diff, same as `codex review` does for `codex-review-loop`.
- Note the base branch: `BASE=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || echo main)`.
- Resolve `$BASE` to the exact ref this run will diff against — the
  runner's own remote-first rule (`origin/$BASE`, then `<remote>/$BASE`,
  then `$BASE`), the same one `pr-review-loop`'s reviewer prompt uses — by
  asking the runner itself rather than reimplementing the rule by hand:
  `bash <skill-dir>/scripts/adversarial-review.sh --print-base --base "$BASE"`
  (the literal `<skill-dir>` resolved above). Keep its stdout as `BASE_REF`
  for every diff from here on, including the plan step — a hand-resolved
  guess can silently drift from what the runner itself will diff against.
- Start an empty **declined-findings ledger** (you persist across rounds; each
  angle run is fresh). Set the round counter to **0**.

### 1. Plan (the heart of this skill)

Read `git diff "$BASE_REF"...HEAD`, plus any PR body, linked issue, or commit
messages available, and follow `<skill-dir>/plan-prompt.md` exactly to write
the plan file. No special isolation is needed for this step — the branch
under review is trusted (see The runner's Threat model above). It covers:
what to derive (the promise, the contracts/invariants, what enforces them),
how to phrase an angle — a mandate is an instruction to construct a
counterexample ("produce a concrete input/program/sequence for which
`<guarantee>` fails, and show it"), not a topic — what evidence each angle
demands, the read-only/workspace-write choice, and the 3-to-6 cap with the
rule that a generic angle gets dropped, not kept as padding.

Write the plan to `${TMPDIR:-/tmp}/adversarial-review/<branch>-<timestamp>.json`
(create the directory if needed) and print the full path to the user for
review before the first run. Once step 2 has run once, every later invocation
in this round-trip (step 3's single-angle re-run, step 5's re-runs) switches
`--plan` to `<DIR>/plan.json` — the copy the runner itself wrote into the run
directory — and repeats `--dir <DIR>`, never this original path again.

If a person is present in this session, show them the plan (promise,
contracts, invariants, and each angle's title + mandate) and pause for edits
before running — they can strike an angle, sharpen a mandate, or add one you
missed. If no one is present to respond (a scripted or unattended run), say so
explicitly and proceed without pausing.

### 2. Run

```bash
bash <skill-dir>/scripts/adversarial-review.sh --plan <plan-file> --base <BASE>
```

Add `--allow-writes` only when re-running a single `workspace-write` angle
with `--only <id>` (see The runner's `--allow-writes` above) — never for a
plan's first, full run if it mixes execution modes.

Capture the run directory it prints (`DIR=`) as `RUN_DIR` — every later
invocation in this round-trip (step 3's single-angle re-run, step 5's
re-runs) repeats `--dir "$RUN_DIR"` and switches `--plan` to
`"$RUN_DIR/plan.json"`, per step 1.

Optionally, also run one Claude reviewer per angle: for each entry in the
plan's `angles`, spawn a `Task` subagent pointed at
`<skill-dir>/claude-angle-prompt.md` with that angle's fields substituted, the
same way `pr-review-loop` spawns its reviewer — isolated, read-only, returning
only the `VERDICT:`/`BLOCKING:`/`NITS:`/`SUMMARY:` block with the angle id as
SUMMARY's first token. These are not merged automatically by the script;
transcribe each returned block by hand into the same findings ledger the
runner's `merged.json` holds, tagged with its angle id and `claude` as the
source, before moving to step 3.

Don't run a Claude read-only pass concurrently with an `--allow-writes`
invocation of the same angle — both would be reading/writing the same
checkout at once.

### 3. Parse and decide

Read the runner's compact block, not the run directory's contents.

- Any angle `BLOCKED`, or `UNPARSED(<cause>)` — `nostatus`, `timeout`,
  `refused`, `exit<n>`, `nojson`, `schema`, or `mistagged` — **never treat
  the run as clean**, even if `ADVERSARIAL_REVIEW: CLEAN` covers the rest.
  Re-run just that angle once with `--dir "$RUN_DIR" --plan
  "$RUN_DIR/plan.json" --only <id>`. If it recurs, escalate it in the final
  report as unreviewed rather than looping on it.
- `UNPARSED(refused)` — the provider's content filter refused the angle's
  prompt; it is not a crash. Re-run that angle once as is. If it recurs,
  reword the angle's mandate in the plan per `plan-prompt.md`'s wording
  guidance and re-run once more before escalating. Never treat it as clean.
- `ADVERSARIAL_REVIEW: UNPARSED` at the top level — same rule as the parsers
  in the sibling skills: it means the script refused to guess, not that
  nothing was found. Read the angle's `.log`/`.out.json` in the run directory
  before deciding anything.
- **Never clean on an empty diff.** If the plan's own promise/contracts read
  as boilerplate because the diff was empty when you planned, or the runner's
  environment-error exit (`1`) fires, that's a failed run, not approval —
  fix the cause (usually the base) and re-run.
- Otherwise, findings are in `--- FINDINGS ---`, one line each, tagged with
  which angles raised them; go to step 4.

Never dump a `.log` or `.out.json` file into this thread — read a targeted
slice only if a specific finding needs more context than the merged block
gives you.

### 4. Verify, then fix

Adversarial reviewers over-claim by design — a mandate that says "construct a
counterexample" rewards finding one. Confirm every finding against the actual
code before touching anything:

- Read the file at `path:line`. If the reproduction doesn't reproduce, it's a
  **declined finding** — record it in the ledger with why, same as a declined
  nit in the sibling skills, so a later round doesn't re-litigate it.
- Confirmed **blockers (P0/P1)** always get fixed.
- Confirmed **nits (P2/P3)**: use judgment, same as the sibling loops — fix
  the clear, low-risk ones; decline and ledger the rest.
- When a finding names one instance of a class you've already accepted, audit
  the siblings and fix them together in this round — "close the class, not
  the instance," `codex-review-loop`'s Guidelines.

Then run this project's checks. Resolve the test/lint commands exactly the way
`codex-review-loop` and `pr-review-loop` do — `.review-loop.json` first, then
detection from the files this round touched, else stop and ask; see either
skill's *Finding this project's checks* section, not repeated here so the two
copies can't drift. **A round whose check didn't run is not a completed
round.**

Commit locally (no push) once verification passes, message matching repo
style.

### 5. Re-run only what changed

Increment the round counter. For angles whose files changed this round,
re-run just them: `--dir "$RUN_DIR" --plan "$RUN_DIR/plan.json" --only
<id1>,<id2>`. Reserve a full re-plan for when the
diff's *promises* changed — a fix that alters what the branch guarantees needs
new angles, not a re-check of the old ones.

Cap: **3 rounds**. At the cap, run one final verification pass on whatever
angles still have open findings — don't fix again — and report per step 6
either way.

### 6. Hand off

**Converged** means every angle reached `CLEAN`, or every finding it raised is
either fixed or ledgered as declined with a reason. That is not the same as
"this branch is ready to merge" — the formal gate (a GitHub reviewer like
Codex on the actual PR, CI, a human) is unchanged and comes after, exactly as
it does for `codex-review-loop` and `pr-review-loop`. This skill's job ends
where theirs does: local, pre-push.

`git push` once on convergence (confirm the branch first); never push while
escalating. Final report:

| Angle | Verdict | Findings fixed | Findings declined | Round |
|---|---|---|---|---|

## Guidelines

- **Never dump run-dir logs into this thread.** The runner's compact block and
  `merged.json`'s summaries are enough for routine work; read a raw `.log`
  only when one finding needs it.
- **A plan that could apply to any PR is a bad plan.** If an angle's mandate
  reads the same after swapping in a different branch's name, it wasn't
  derived from this diff — drop it in step 1, don't carry it into step 2.
- **Don't reward-hack the reviewers.** A "fix" that only makes a mandate
  harder to construct a counterexample against — without changing the
  underlying behavior — is not a fix; decline it and say why.
- **Cost.** One `codex exec` call per angle per round, plus one Claude `Task`
  call per angle per round if you're running that pass too. A 5-angle plan
  across 3 rounds is up to 15 Codex calls (fewer in practice — `--only` narrows
  most rounds to whichever angles actually changed).
