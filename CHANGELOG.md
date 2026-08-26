# Changelog

Versions here track `codex-review.sh`'s parser, which is what `--version`
reports. Compare it against your install before trusting a clean verdict:

```bash
bash <skill-dir>/scripts/codex-review.sh --version
```

## 1.0.0

First release as a standalone repo. Extracted from `lancegoyke/dotfiles` and
`copient-trainer/.claude/skills/`, which both carried their own copies.

- `codex-review.sh` gained `--version`, so an installed copy can be checked
  against this file. The parser itself is unchanged from the dotfiles copy.
- Neither skill hardcodes a task runner any more. `just` recipes are gone from
  `allowed-tools`; each loop now resolves the project's test and lint commands
  from `.claude/review-loop.json` or by detection, and **stops and asks** when
  it cannot, instead of quietly skipping the check.
- Both skills declare a host requirement. `codex-review-loop` runs under any
  agent with bash; `pr-review-loop` is Claude Code only, because its isolation
  is the `Task` subagent and it loses that silently anywhere else.
- Cross-references between the skills use the namespaced `copient:` form, and
  no install path is hardcoded — the helper is located relative to the skill
  directory, which differs per install path.
- `pr-review-loop`'s final verification round now applies the same convergence
  test as every other round: a `CLEAN` verdict carrying new nits does not
  bypass the declined-nits ledger.
- Both skills state that a `CLEAN` verdict ends the loop but is not required
  for convergence, resolving a contradiction with the large-branch guideline.
