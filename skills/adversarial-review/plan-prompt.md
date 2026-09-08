# Adversarial Review — planning prompt

You are about to write a plan file that drives a set of targeted, adversarial
review passes against the current branch. This is not a review yet — it is the
step that decides *what a review of this specific change should attack*.
Follow this exactly, then write the result to the plan file path you were
given.

## 1. Read the diff and its stated intent

- Resolve the base to the exact ref the runner will diff against — do not
  hand-resolve `<BASE>` yourself (e.g. guessing `origin/<BASE>`); a second,
  independent implementation of that rule can silently drift from the
  runner's own. Ask the runner directly, the same way the SKILL's pre-flight
  step did:
  `bash <skill-dir>/scripts/adversarial-review.sh --print-base --base <BASE>`
  (the same `<skill-dir>` and raw `<BASE>` branch name resolved there). Use
  its stdout, verbatim, as `<BASE_REF>` for everything below and for the
  plan file's own `"base"` field (step 5) — this is exactly what the runner
  itself resolves `--base <BASE>` to at run time, so planning and running
  can never diff against two different refs.
- Run the full diff, not just names, against that resolved ref:
  `git diff <BASE_REF>...HEAD`.
- Gather anything that states intent: a PR body/title if one is already open
  (`gh pr view --json body,title`), a linked issue if the branch name or a
  commit message names one, and the commit messages themselves
  (`git log <BASE_REF>..HEAD`). Use these to learn what the author *claims*
  the change does — the angles you write next exist to test that claim, not
  to restate it.

## 2. Derive what the change promises

Read the diff for four things, not one:

- **Promise** — what can a caller now rely on that they could not before? One
  paragraph. Not "adds X" — what does X now guarantee?
- **Contracts** — any external API, stdlib/framework semantics, protocol,
  schema, or CLI/flag surface the change re-implements, wraps, or replaces.
  Anywhere the change owns behavior it did not originally define is a place it
  can drift from the thing it replaced.
- **Invariants** — properties the change's own logic claims always hold:
  ordering, uniqueness, idempotency, an operation being atomic, a value
  staying in range, a resource always getting released.
- **Enforcement** — the guards, validators, permission checks, linters, or
  tests that are supposed to make the invariants hold. A promise with no
  enforcement mechanism is itself worth an angle: what happens when nothing is
  actually checking it?

Not every diff has all four. A migration may have no API-shaped "contract" but
has invariants (no row dropped, safe to retry, safe to roll back). A pure
refactor may add no new promise, only an invariant that behavior stays
identical — write an angle against exactly that.

## 3. Turn each into an angle

An angle is not a topic ("check error handling") — it is an **instruction to
construct a counterexample**. Phrase the mandate as an order: "produce a
concrete input/program/sequence for which `<the guarantee named above>` fails,
and show it." A reviewer who tries and cannot construct one returns CLEAN —
the mandate does not presume a bug exists, only that one must be looked for.

**Wording matters as much as content.** A mandate must read as verification
of a stated guarantee, not as an attack recipe: prefer "produce a concrete
sequence for which `<guarantee>` does not hold, and show the observed state"
over "bypass", "defeat", "exploit", "evade", "leak", or "attack the guard" —
name the guarantee, the input, and the observation instead of the maneuver.
The reviewer runs behind a provider content filter that refuses prompts
phrased as circumventing protections, and a refusal costs a round.

For each angle also decide:

- **evidence** — what a finding on this angle must include to count. Tie it to
  the specific contract/invariant, not a generic "cite the file."
- **execution** — `read-only` unless demonstrating the counterexample actually
  requires running something (a test, a script, a reproduction harness) — then
  `workspace-write`. Default to read-only; promote only the angles that need
  it. Under read-only, reading and `git` work; anything that writes (a test
  runner writing caches, a script writing output) fails.
- **files** — optional hint: paths most relevant to this angle, if the diff
  makes that obvious. Not exhaustive, and the reviewer isn't bound by it.

## 4. Keep 3 to 6, and only the specific ones

Write 3 to 6 angles, no more. Before finalizing, drop any angle that would read
the same on a different PR — if you could paste it, unedited, into a review of
an unrelated change, it isn't derived from this diff and doesn't belong. Two
or three sharp angles beat six generic ones; each one costs a full reviewer
pass.

## 5. Write the plan file

Write **only** valid JSON, this shape, to the path you were given:

```json
{"version": 1, "base": "origin/main", "promise": "one paragraph", "contracts": ["..."], "invariants": ["..."],
 "angles": [{"id": "kebab-id", "title": "...", "mandate": "falsifiable instruction", "evidence": "what a finding must include", "execution": "read-only", "files": ["optional/paths"]}]}
```

`id` is kebab-case, unique, and should stay stable across re-runs of this
branch — the runner uses it for `--only` and for file names in the run
directory. `execution` is either `"read-only"` or `"workspace-write"`.

## Examples — form only, not content

These show the *shape* of a good angle. They're drawn from three unrelated
domains on purpose — don't reuse their subject matter; derive your own from
the diff in front of you.

- **A wrapper around a library.** `mandate`: "This change replaces calls to
  `<library>.<fn>` with a local reimplementation. Construct an input the
  library's documented contract accepts where the reimplementation returns a
  different result, raises a different exception, or omits a side effect the
  original performed." `evidence`: "the library's documented behavior for that
  input, cited, next to the reimplementation's actual behavior for it."

- **A permission check in a request handler.** `mandate`: "This handler gates
  an action behind `<the stated check>`. Construct a request — a route, a
  method, a parameter, a session state — that reaches the guarded action
  without satisfying the check as written." `evidence`: "the exact request
  shape and the code path it takes around or through the check."

- **A data migration.** `mandate`: "This migration claims `<the stated
  invariant, e.g. no row is dropped, the backfill is idempotent>`. Construct a
  starting data state or an interruption point (partial run, retry, concurrent
  write) for which that claim fails." `evidence`: "the starting state, the
  operation sequence, and the resulting state that violates the claim."

Every angle you write must earn its place the same way these do: name the
specific promise, name the specific way to break it, name what proof would
look like.
