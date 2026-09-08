# Changelog

Versions here track the plugin. Each helper script reports its own
parser/runner version via `--version` — compare it against your install
before trusting a clean verdict:

```bash
bash <skill-dir>/scripts/codex-review.sh --version
bash <skill-dir>/scripts/adversarial-review.sh --version
```

## 1.1.0

`codex-review.sh`'s parser is unchanged — it still reports `1.0.0`, and
`codex-review-loop` and `pr-review-loop` are byte-identical to their 1.0.0
release.

New skill: `adversarial-review`, with its own runner version `1.0.0`
(`adversarial-review.sh --version`). Where the other two skills converge a
generic review, this one plans first — a serialized planning phase reads the
diff and derives what the branch itself promises, then turns each promise
into a falsifiable attack angle. It adds:

- A **plan phase** that derives contracts, invariants, and 3–6 attack angles
  from the diff itself — nothing pre-baked, no fixed checklist.
- **Parallel `codex exec` angles** — one isolated, ephemeral Codex pass per
  angle, plus an optional isolated Claude pass per angle.
- **Schema-enforced findings** — each pass's output is validated against
  `scripts/findings.schema.json`, so a reviewer hands back a reproduction,
  not prose.
- Exit-code discipline matching the sibling skills: `UNPARSED` and `BLOCKED`
  angles are never counted as clean, even when the rest of the run reports
  `CLEAN`.
- A new host requirement: `python3` (stdlib only) on `PATH`, for the runner.

## 1.0.0

**Security:** `allowed-tools` originally pre-approved `bash` for the helper
script at `.claude/skills/…/scripts/*` and `.agents/skills/…/scripts/*`. Under a
project-level `npx` install those paths are inside the repo being reviewed, so
the branch under review could rewrite `codex-review.sh` and have it run without
a permission prompt — unreviewed branch code executing as part of the review of
that branch. Only the plugin root, which lives outside any checkout, is
pre-approved now; every other install prompts. Corrected before any release tag
existed, so no version carried it.

First release as a standalone repo. Extracted from `lancegoyke/dotfiles` and
`copient-trainer/.claude/skills/`, which both carried their own copies.

- `codex-review.sh` gained `--version`, so an installed copy can be checked
  against this file. The parser itself is unchanged from the dotfiles copy.
- Neither skill hardcodes a task runner any more. `just` recipes are gone from
  `allowed-tools`; each loop now resolves the project's test and lint commands
  from `.review-loop.json` or by detection, and **stops and asks** when
  it cannot, instead of quietly skipping the check.
- Both skills declare a host requirement. `codex-review-loop` runs under any
  agent with bash; `pr-review-loop` is Claude Code only, because its isolation
  is the `Task` subagent and it loses that silently anywhere else.
- Cross-references between the skills use the bare skill names, which resolve
  under every install path. The `copient:` prefix exists only under the Claude
  Code plugin — `npx skills` registers the bare frontmatter names — so each
  skill states the difference once instead of naming a form half its users
  cannot invoke.
- No install path is hardcoded. The helper is located relative to the skill
  directory, and `allowed-tools` covers the plugin root, `.claude/skills/`, and
  the `.agents/skills/` that `npx` uses for non-Claude agents.
- `pr-review-loop`'s final verification round now applies the same convergence
  test as every other round: a `CLEAN` verdict carrying new nits does not
  bypass the declined-nits ledger.
- Both skills state that a `CLEAN` verdict ends the loop but is not required
  for convergence, resolving a contradiction with the large-branch guideline.
