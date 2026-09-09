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

New skill: `adversarial-review`, with its own runner version `1.1.0`
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
- **Branch-owned instructions and configuration are never loaded.** Each
  Codex pass runs with `project_doc_max_bytes=0` and `-c skills.include_
  instructions=false`, and under its own fresh, this-angle-only throwaway
  `CODEX_HOME` holding only a copy of `auth.json`, so the reviewed branch's
  own `AGENTS.md`, `.agents/skills/`, and `.codex/config.toml` (hooks, MCP
  servers, exec policy) cannot steer the reviewer even on a checkout the
  user has marked trusted; the Claude pass is told to read such files and
  skills as part of the diff, never as instructions.
- **Write-capable isolation model.** A workspace-write angle's own
  reproduction is already free to write anywhere its sandbox allows — the
  checkout, `tempfile.gettempdir()`/`$TMPDIR`/`/tmp`/`/var/tmp` — so nothing
  the runner needs safe from it is placed anywhere within reach: each
  angle's own throwaway `CODEX_HOME` is created and torn down around that
  one angle, not shared for the whole run; the run directory itself is
  refused (or, by default, relocated to a stable cache directory) under any
  of those roots whenever the plan has a write-capable angle; every result
  is collected into memory the instant its own angle finishes, never
  re-read from the run directory afterward; the post-angle compromise check
  now also compares HEAD's own commit and branch, not just `git status`, so
  a reproduction that commits, checks out, or hard-resets — each of which
  can leave the tree looking clean again — is still caught and cascades the
  same way residue does; and a `--from-dir` merge reads `<angle>.skipped.txt`
  defensively (never following a symlink, never trusting content outside
  its own known cause tokens).
- **Auth rotation, cache-root ancestry, and two more isolation gaps
  closed.** A `-c projects."<root>".trust_level="untrusted"` override was
  tried, live, as a way to run every angle against the real `CODEX_HOME`
  directly instead of copying `auth.json` per angle — rejected: it left an
  already-trusted project still loading its own `config.toml`, and
  separately failed to grant trust to one with no persisted entry, on
  codex-cli 0.145.0. Copying stays, with a fix: a file-backed ChatGPT
  login's mid-run token rotation now propagates back to the real
  `CODEX_HOME` (locked, only when changed) before each angle's throwaway
  copy is deleted, instead of stranding the rotated token there. The
  sandbox-writable-root check the default run directory and every
  throwaway `CODEX_HOME` rely on now rejects a candidate that's a
  *descendant* of `tempfile.gettempdir()`/`$TMPDIR`/`/tmp`/`/var/tmp`, not
  only an exact match — an `XDG_CACHE_HOME` pointed inside one of those
  used to pass through. A reused `--dir`'s broad stale-artifact clear now
  compares only the same provenance fields the per-angle backstop already
  does (plan hash, resolved base and its commit, angle-prompt template
  hash) instead of the whole run record, so HEAD moving alone between two
  runs sharing a `--dir` — a commit made in response to the first run's own
  findings, say — no longer wipes an angle `--only` left out of the second
  run. And throwaway `CODEX_HOME` creation itself now happens inside the
  same in-flight window Popen already used, so a worker cancelled at
  exactly the wrong moment never creates one at all.

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
