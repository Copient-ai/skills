# Copient Skills

Public, project-agnostic developer skills from [Copient AI](https://github.com/Copient-ai).

Two of them so far, and they are the same idea reviewed by two different models:
run a **review → fix → re-review** loop on your branch locally, until it stops
finding things, and keep the review's bulk out of your working context. Neither
needs a PR, a push, or a GitHub round-trip.

| Skill | Reviewer | Isolation | Runs on |
|---|---|---|---|
| `codex-review-loop` | OpenAI Codex, via the `codex` CLI | The transcript stays in a log file; only findings are printed | **Any agent that can run bash** |
| `pr-review-loop` | Claude, in a subagent | The subagent returns only a verdict block | **Claude Code only** |

**What they are called depends on how you install them.** The Claude Code plugin
prefixes both with the plugin name — `copient:codex-review-loop`,
`copient:pr-review-loop`. `npx skills` installs them under their bare frontmatter
names, `codex-review-loop` and `pr-review-loop`, where the prefix does not
resolve. The skills themselves refer to each other by the bare names.

Run both for two independent perspectives — they catch different things.

`pr-review-loop`'s host requirement is not a packaging detail. Its isolation *is*
the `Task` subagent. On an agent without subagents the review runs in your main
context and the guarantee is gone, with nothing to tell you so.

## Install — pick one

### `npx skills` (recommended)

```bash
npx skills@latest add Copient-ai/skills            # this project only
npx skills@latest add Copient-ai/skills --global   # every project
```

You get real, editable copies, invoked as `codex-review-loop` and
`pr-review-loop`. Project installs land in `.claude/skills/` for Claude Code and
`.agents/skills/` for every other agent, alongside a `skills-lock.json` recording
what you installed. Works across Claude
Code, Codex, Cursor, and the other agents the CLI knows about, which is why it is
the recommended path for `codex-review-loop`.

### Claude Code plugin

```
/plugin marketplace add Copient-ai/skills
/plugin install copient@copient-skills
```

A managed, read-only bundle that updates with the marketplace. Skills invoke as
`copient:codex-review-loop` and `copient:pr-review-loop`.

### Do not install both

They do not layer — they duplicate. You end up with two copies of every skill
registered at once, and a project-level copy silently shadows a user-level one of
the same name, so the copy you edit may not be the copy that runs. Pick one path
and remove the other before switching.

## Staying current

For these particular skills, running an old copy is a safety problem rather than
a missing-features problem.

`codex-review.sh` is a parser, and every guard in it exists because a specific
transcript once distilled to a confident `CLEAN` that it had not earned — one of
them a `- [P0]` for plaintext credential logging that came out as `BLOCKING=0`.
A stale copy still reports approval for branches nobody reviewed.

Check what you have:

```bash
bash <skill-dir>/scripts/codex-review.sh --version
```

Compare it against [CHANGELOG.md](CHANGELOG.md). If yours is behind, update
before you trust a clean verdict.

**Updates overwrite your edits, silently.** `npx skills update` re-fetches from
this repo and rewrites the installed files. A file you had modified is replaced
with no warning, no prompt, and no diff — the run just reports `✓ Updated`, and
`skills-lock.json` records a `computedHash` that would have let it notice.

So treat everything under `.claude/skills/` as disposable. Anything you want to
keep belongs somewhere an update cannot reach: `.review-loop.json` for how your
project runs its checks, your own settings for permissions, and a fork for
anything larger. If you have already customised an installed copy, diff it
against this repo before updating.

## Telling the loops how to test your project

Both skills stop and run your project's checks before committing each iteration.
They do not assume a task runner. Each loop resolves the commands once, in this
order:

1. `.review-loop.json`, if you have one — it wins over everything:

   ```json
   {
     "test": "npm test",
     "lint": "npm run lint"
   }
   ```

2. Otherwise detection, first match wins: `justfile`, `package.json` scripts,
   `Makefile`, `pyproject.toml`/`pytest.ini`/`tox.ini`, `Cargo.toml`, `go.mod`,
   `.pre-commit-config.yaml`. The full table is in each skill's *Finding this
   project's checks* section.

3. If nothing resolves, the loop **stops and asks you** rather than skipping the
   check.

That last rule is the point of the whole section. A check that silently does
nothing, in a loop whose job is to gate a push, is worse than no loop at all —
you get the green without the review. An iteration whose check did not run does
not count as an iteration.

## Permissions

The skills declare narrow `allowed-tools`, which deliberately do **not** include
your project's test command — there is no way to know it in advance. Expect an
approval prompt the first time, and allowlist it yourself in
`.claude/settings.json` if you would rather not see it again:

```json
{ "permissions": { "allow": ["Bash(npm test:*)", "Bash(npm run lint:*)"] } }
```

A user-level (`--global`) install of `codex-review-loop` puts the helper script
outside the declared patterns too, so its first call will prompt as well. Add the
path your install actually uses:

```json
{ "permissions": { "allow": ["Bash(bash ~/.claude/skills/codex-review-loop/scripts/:*)"] } }
```

Approving a prompt is fine. Skipping the step to avoid one is not.

## Prerequisites

`codex-review-loop` needs the OpenAI [Codex CLI](https://github.com/openai/codex)
on your `PATH`, signed in (`codex login`), with the repo you are reviewing trusted
in `~/.codex/config.toml` so the review does not stop for an approval on every
file it reads. The helper fails with a clear message if `codex` is missing.

`pr-review-loop` needs Claude Code and nothing else.

## Contributing

**Everything in this repo is public and goes under the `copient:` namespace.** A
skill that needs Copient context to work — repo knowledge, production data,
credentials — does not belong here.

If you touch `codex-review.sh`, two rules:

- **Do not simplify it.** It looks over-engineered. Each guard traces to a
  reproduced false-`CLEAN`, and the rule they add up to is that this script must
  never report approval for something it did not parse. `UNPARSED` exists so an
  unrecognized transcript fails loudly instead of quietly passing.
- **Every parser change needs a fixture proven red against the previous version
  before it goes green.** The offline suite needs no Codex call:

  ```bash
  bash skills/codex-review-loop/scripts/test-codex-review.sh   # expects ALL PASS
  ```

## Layout

```
skills/                  agent-neutral source of truth
  codex-review-loop/
  pr-review-loop/
.claude-plugin/          Claude Code adapter (marketplace + plugin manifests)
```

`skills/` is the source of truth and carries nothing agent-specific. The adapter
sits on top so the plugin path works without the skills themselves knowing about
it.

## License

MIT — see [LICENSE](LICENSE).
