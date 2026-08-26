# Copient Skills

Public, project-agnostic developer skills from [Copient AI](https://github.com/Copient-ai).

Two so far, and they are one idea reviewed by two different models: run a
**review → fix → re-review** loop on your branch locally until it stops finding
things, keeping the review's bulk out of your working context. Neither needs a
PR, a push, or a GitHub round-trip.

| Skill | Reviewer | Isolation | Runs on |
|---|---|---|---|
| `codex-review-loop` | OpenAI Codex, via the `codex` CLI | Transcript stays in a log file; only findings print | **Any agent that can run bash** |
| `pr-review-loop` | Claude, in a subagent | The subagent returns only a verdict block | **Claude Code only** |

Run both for two independent perspectives — they catch different things.

`pr-review-loop`'s host requirement is not a packaging detail. Its isolation *is*
the `Task` subagent. On an agent without subagents the review runs in your main
context and the guarantee is gone, with nothing to tell you so.

**What they are called depends on how you install them.** The Claude Code plugin
prefixes both with the plugin name — `copient:codex-review-loop`,
`copient:pr-review-loop`. `npx skills` installs them under their bare frontmatter
names, `codex-review-loop` and `pr-review-loop`, where the prefix does not
resolve. The skills refer to each other by the bare names.

## Install — pick one

### `npx skills` (recommended)

```bash
npx skills@latest add Copient-ai/skills --global   # every project
npx skills@latest add Copient-ai/skills            # this project only
```

It asks which agents to install for. Non-interactively, add
`-a claude-code -s '*' -y`.

You get real, editable copies. Claude Code installs land under `.claude/skills/`;
every other agent gets `.agents/skills/`. A `skills-lock.json` records what you
installed.

### Claude Code plugin

```
/plugin marketplace add Copient-ai/skills
/plugin install copient@copient-skills
```

A managed, read-only bundle that updates with the marketplace.

### Do not install both

They do not layer, they duplicate — you end up with two copies of every skill
registered at once. A project-level copy also **shadows** a user-level one of the
same name, so the copy you edit may not be the copy that runs. Pick one path and
remove the other before switching.

## Prerequisites

`codex-review-loop` needs the OpenAI [Codex CLI](https://github.com/openai/codex)
on your `PATH` and signed in:

```bash
codex login
```

Trust the repo you review in `~/.codex/config.toml`, or the review stops for an
approval on every file it reads — which makes it unusable rather than broken. The
helper fails with a clear message if `codex` is missing.

`pr-review-loop` needs Claude Code and nothing else.

## Verify before you rely on it

These skills gate a push, so "it looks installed" is not enough.

```bash
# 1. the parser is the version you think it is
bash ~/.claude/skills/codex-review-loop/scripts/codex-review.sh --version
# codex-review.sh 1.0.0

# 2. the offline parser suite passes here — no Codex call needed
bash ~/.claude/skills/codex-review-loop/scripts/test-codex-review.sh
# ALL PASS

# 3. both skills are registered
npx skills@latest list
```

Adjust the path for your install — `.agents/skills/…` for agents other than
Claude Code, `${CLAUDE_PLUGIN_ROOT}/skills/…` under the plugin.

- [ ] `--version` matches [CHANGELOG.md](CHANGELOG.md)
- [ ] The suite reports `ALL PASS`
- [ ] Both skills appear in your agent's skill list
- [ ] You have run one real loop on a small branch

## Using them

Both take the same shape. You are on a feature branch with committed work; the
loop reviews, you fix, it re-reviews, and it stops when the code stops changing.

```
/codex-review-loop      # Codex reviews, via its CLI
/pr-review-loop         # Claude reviews, in an isolated subagent
```

Reach for `codex-review-loop` when you want a second model's eyes, or when you
are not in Claude Code. Reach for `pr-review-loop` when you want a review
calibrated to your own reviewer-agent definitions. Running both before a PR is
the point — in practice they surface different classes of problem.

What to expect:

- **Blocking findings always get fixed.** They gate convergence.
- **Nits are optional but ambitious.** Worthwhile ones get fixed; one you decline
  goes in a ledger so a later round does not re-raise it and start an
  oscillation.
- **Three iterations, then a verification round.** At the cap the loop reviews
  what you committed without fixing again, so anything it escalates is verified
  still-open rather than already-fixed.
- **A clean verdict is not automatically convergence.** A review can come back
  clean while listing nits you have neither fixed nor declined.
- **It pushes once, on convergence.** Never while escalating.

The single rule underneath all of it: **an iteration whose check did not run is
not a completed iteration.** A loop that gates a push has to know its gate
actually ran.

## Telling the loops how to test your project

They do not assume a task runner. Each loop works out the commands like this:

1. **`.review-loop.json` at the repo root wins,** if you have one:

   ```json
   {
     "test": "just test-module",
     "lint": "just precommit"
   }
   ```

2. **Otherwise it detects the toolchain from the files your fix touched** —
   `justfile`, `package.json` scripts, `Makefile`,
   `pyproject.toml`/`pytest.ini`/`tox.ini`, `Cargo.toml`, `go.mod`,
   `.pre-commit-config.yaml`. A fix spanning two of them runs **both**, and the
   set is re-derived after each round rather than fixed at the start. Picking one
   root marker and sticking with it would run the JavaScript tests for a Go-only
   change and call it verified.

3. **If nothing resolves it stops and asks you** rather than skipping the check.

Pin a `.review-loop.json` when detection would guess wrong — a `justfile` whose
recipes are named something other than `test`/`test-module`/`precommit`/`check`
is the common case, and without a config the loop stops to ask on every run.

## Permissions

Two approval prompts are deliberate. If you assume they are bugs you will route
around them, which defeats the point.

**The helper script prompts on first use.** Only the plugin copy is pre-approved.
A project-level install puts the script *inside the repo being reviewed*, where
the branch under review could rewrite it and have it run before anything reviewed
it. To silence the prompt, allowlist a copy that lives outside any checkout:

```json
{ "permissions": { "allow": [
  "Bash(bash ~/.claude/skills/codex-review-loop/scripts/:*)"
] } }
```

**Your project's test command prompts too.** There is no way to know it in
advance, so it is not in `allowed-tools`:

```json
{ "permissions": { "allow": ["Bash(just test-module:*)"] } }
```

Approving a prompt is fine. Skipping the check step to avoid one is not.

## Staying current

For these skills, running an old copy is a safety problem rather than a
missing-features problem. `codex-review.sh` is a parser, and every guard in it
exists because some transcript once distilled to a confident `CLEAN` it had not
earned — one of them a `- [P0]` for plaintext credential logging that came out as
`BLOCKING=0`. A stale copy goes on reporting approval for branches nobody read.

```bash
npx skills@latest update --global
```

or, on the plugin path:

```
/plugin marketplace update copient-skills
```

**Updates overwrite your edits, silently.** A file you modified is replaced with
no warning, no prompt and no diff — the run just reports `✓ Updated`. Treat
everything under `.claude/skills/` as disposable; anything worth keeping belongs
in `.review-loop.json`, your own settings, or a PR here.

**If `~/.claude/skills` is a symlink,** check your links after an update that
actually changes something. The installer keeps real files in `~/.agents/skills/`
and links them in using a path relative to where it thinks `~/.claude/skills` is;
if that is itself a symlink, the links resolve somewhere that does not exist and
the skills stop loading with no error.

```bash
test -e ~/.claude/skills/codex-review-loop/SKILL.md && echo ok || echo BROKEN

# repair with absolute links
cd ~/.claude/skills
for s in codex-review-loop pr-review-loop; do
  rm -f "$s" && ln -s "$HOME/.agents/skills/$s" "$s"
done
```

## Removing them

```bash
npx skills@latest remove codex-review-loop pr-review-loop
```

or:

```
/plugin uninstall copient@copient-skills
```

Nothing else to undo. No configuration is written outside the skill directories,
and a `.review-loop.json` you added is inert without them.

## Rolling this out to a team

- **Delete any vendored copies first.** If these skills are checked into a repo
  your team works in, the project-level copies shadow whatever each person
  installs — so people get the new version everywhere except the repo they spend
  the most time in, with nothing indicating which one ran. Remove them before
  telling anyone to install.
- **Pick one install path for everyone.** The invocation name differs between
  them, so mixed installs mean docs and muscle memory that only work for half the
  team.
- **Pin `.review-loop.json` in the repos you review most.** One small PR per repo,
  and nobody gets asked for the lint command again.
- **Say the prompts are expected.** Both are described above; the failure mode
  worth naming out loud is someone skipping the check step to avoid one.

## Contributing

**Everything here is public and goes under the `copient:` namespace.** A skill
that needs Copient context — repo knowledge, production data, credentials — does
not belong in this repo.

If you touch `codex-review.sh`, two rules:

- **Do not simplify it.** It looks over-engineered. Each guard traces to a
  reproduced false-`CLEAN`, and together they add up to one rule: this script must
  never report approval for something it did not parse. `UNPARSED` exists so an
  unrecognized transcript fails loudly instead of quietly passing.
- **Every parser change needs a fixture proven red against the previous version
  before it goes green.** The offline suite needs no Codex call:

  ```bash
  bash skills/codex-review-loop/scripts/test-codex-review.sh   # expects ALL PASS
  ```

CI runs that suite on Linux, macOS, and stock macOS bash 3.2 on every push, plus
`shellcheck`.

## Layout

```
skills/                  agent-neutral source of truth
  codex-review-loop/
  pr-review-loop/
.claude-plugin/          Claude Code adapter (marketplace + plugin manifests)
```

`skills/` carries nothing agent-specific. The adapter sits on top, so the plugin
path works without the skills knowing about it.

## License

MIT — see [LICENSE](LICENSE).
