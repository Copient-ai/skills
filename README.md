# Copient Skills

Public, project-agnostic developer skills from [Copient AI](https://github.com/Copient-ai).

Three so far. Two are one idea reviewed by two different models: a
**review → fix → re-review** loop on your branch, run locally, that keeps the
review's bulk out of your working context. No PR, no push, no GitHub round-trip.
The third plans a targeted review first, then runs that same loop angle by angle.

| Skill | Reviewer | Runs on |
|---|---|---|
| `codex-review-loop` | OpenAI Codex, via the `codex` CLI | **Any agent that can run bash** |
| `pr-review-loop` | Claude, in an isolated subagent | **Claude Code only** |
| `adversarial-review` | OpenAI Codex per angle, optionally Claude | **Any agent that can run bash** (Claude pass needs Claude Code) |

Run all three before a PR — they surface different classes of problem.

`pr-review-loop`'s host requirement is not packaging trivia. Its isolation *is*
the `Task` subagent; on an agent without subagents the review runs in your main
context and the guarantee is gone, silently.

## Install — pick one

```bash
npx skills@latest add Copient-ai/skills --global   # recommended
```

Editable copies, any agent, invoked as `codex-review-loop` / `pr-review-loop`.
It asks which agents to install for; add `-a claude-code -s '*' -y` to skip that.

```
/plugin marketplace add Copient-ai/skills          # Claude Code only
/plugin install copient@copient-skills
```

Managed and read-only, invoked as `copient:codex-review-loop` — the plugin name
becomes a prefix.

**Do not install both.** They duplicate rather than layer, and a project-level
copy shadows a user-level one, so the copy you edit may not be the copy that runs.

## Prerequisites

`codex-review-loop` needs the [Codex CLI](https://github.com/openai/codex) on your
`PATH`, `codex login` done, and the repo trusted in `~/.codex/config.toml`.
Untrusted, the review stops for approval on every file it reads.

`pr-review-loop` needs Claude Code and nothing else.

## Verify

These gate a push, so "it looks installed" is not enough.

```bash
bash ~/.claude/skills/codex-review-loop/scripts/codex-review.sh --version
# codex-review.sh 1.0.0   — compare against CHANGELOG.md

bash ~/.claude/skills/codex-review-loop/scripts/test-codex-review.sh
# ALL PASS                — offline, no Codex call needed
```

Adjust the path for your install: `.agents/skills/…` for agents other than Claude
Code, `${CLAUDE_PLUGIN_ROOT}/skills/…` under the plugin.

## Using them

From a feature branch with your work committed:

```
/codex-review-loop
/pr-review-loop
```

Each reviews, you fix, it re-reviews, and it stops when the code stops changing.
Blocking findings always get fixed. Nits are optional but ambitious, and one you
decline is remembered so a later round cannot re-raise it. Three iterations, then
a verification round that reviews without fixing. It pushes once, on convergence,
never while escalating.

A clean verdict is not automatically convergence — a review can come back clean
while listing nits you have neither fixed nor declined. And the rule underneath
all of it: **an iteration whose check did not run is not a completed iteration.**

## Telling the loops how to test your project

They assume no task runner. Commands resolve in this order:

1. **`.review-loop.json` at the repo root wins:**

   ```json
   { "test": "just test-module", "lint": "just precommit" }
   ```

2. **Otherwise, detection from the files your fix touched** — `justfile`,
   `package.json`, `Makefile`, `pyproject.toml`/`pytest.ini`/`tox.ini`,
   `Cargo.toml`, `go.mod`, `.pre-commit-config.yaml`. A fix spanning two runs
   **both**, re-derived after each round. Picking one root marker and keeping it
   would run the JavaScript tests for a Go-only change and call it verified.

3. **Nothing resolves → it stops and asks you,** rather than skipping the check.

Pin a config when detection would guess wrong — a `justfile` whose recipes aren't
named `test`/`test-module`/`precommit`/`check` is the common case.

## Permissions

Two prompts are deliberate.

**The helper script prompts on first use.** Only the plugin copy is pre-approved,
because a project-level install puts the script *inside the repo being reviewed*,
where the branch under review could rewrite it and have it run before anything
reviewed it. Silence it only for a copy outside any checkout:

```json
{ "permissions": { "allow": [
  "Bash(bash ~/.claude/skills/codex-review-loop/scripts/:*)",
  "Bash(just test-module:*)"
] } }
```

**Your test command prompts too** — there's no way to know it in advance. Add it
alongside, as above.

Approving a prompt is fine. Skipping the check to avoid one is not.

## Adversarial review before the PR

`adversarial-review` is a third loop, not a third generic reviewer. Its
planning phase reads the diff itself and derives what *this* branch promises —
nothing pre-baked — then turns each promise into a falsifiable attack angle.
Each angle runs as its own parallel `codex exec` pass, findings enforced
against a JSON schema so a reviewer hands back a reproduction, not prose.
Optionally, each angle also gets an isolated Claude pass. Either way, findings
go through the same verify → fix → re-review discipline as the other two
skills.

Host requirements: bash, git, and `python3` (stdlib only) on `PATH`, plus the
`codex` CLI as above. The optional Claude pass needs Claude Code — same
`Task`-subagent-is-the-isolation reason as `pr-review-loop`.

```bash
bash ~/.claude/skills/adversarial-review/scripts/adversarial-review.sh --version
# adversarial-review.sh 1.0.0

bash ~/.claude/skills/adversarial-review/scripts/test-adversarial-review.sh
# ALL PASS
```

Same permission story as the helper script above: only the plugin-root copy
is pre-approved, for the same reason — see Permissions.

## Staying current

An old copy is a safety problem, not a missing-features one: the bugs fixed in
`codex-review.sh` are false-`CLEAN` bugs, where the tool reports approval for a
branch it never parsed.

```bash
npx skills@latest update --global      # or: /plugin marketplace update copient-skills
```

**Updates overwrite your edits silently** — no warning, no prompt, no diff, just
`✓ Updated`. Keep anything worth keeping in `.review-loop.json`, your own
settings, or a PR here.

**If `~/.claude/skills` is a symlink,** check your links after any real update.
The installer keeps files in `~/.agents/skills/` and links them in *relatively*;
against a symlinked directory those resolve nowhere and the skills stop loading
with no error.

```bash
test -e ~/.claude/skills/codex-review-loop/SKILL.md && echo ok || echo BROKEN
cd ~/.claude/skills && for s in codex-review-loop pr-review-loop; do
  rm -f "$s" && ln -s "$HOME/.agents/skills/$s" "$s"
done
```

## Removing them

```bash
npx skills@latest remove codex-review-loop pr-review-loop
# or: /plugin uninstall copient@copient-skills
```

Nothing else to undo — no config is written outside the skill directories.

## Rolling out to a team

Delete any copies vendored into your repos first, or they shadow whatever people
install and nothing says which one ran. Pick one install path for everyone, since
the invocation name differs between them. Pin `.review-loop.json` in the repos you
review most.

## Contributing

**Everything here is public.** A skill needing Copient context — repo knowledge,
production data, credentials — does not belong in this repo.

**Do not simplify `codex-review.sh`.** It looks over-engineered. Each guard traces
to a reproduced false-`CLEAN`, and together they mean: never report approval for
something you did not parse. `UNPARSED` exists so an unrecognized transcript fails
loudly. Every parser change needs a fixture proven red against the previous
version before it goes green.

CI runs the parser suite on Linux, macOS, and stock macOS bash 3.2, plus
`shellcheck`, on every push.

## Layout

```
skills/            agent-neutral source of truth
.claude-plugin/    Claude Code adapter
```

MIT — see [LICENSE](LICENSE).
