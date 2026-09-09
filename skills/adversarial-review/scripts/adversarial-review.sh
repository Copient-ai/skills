#!/usr/bin/env bash
# Run one `codex exec` per adversarial "angle" from a plan file, in parallel,
# each returning schema-enforced JSON findings, then merge and print a
# compact, parseable block. Thin dispatcher: this file only answers
# --version/--help and checks the environment (python3, and — unless
# --from-dir/--print-base is given — the codex CLI) before handing off to
# adversarial_review.py, which does the real work (plan validation, prompt
# rendering, running codex, merging).
#
# We review our own branches here, not a hostile submission — the branch
# under review is trusted. This runner is deliberately thin; almost all the
# value is in the angle prompts, not runner-side defenses.
#
# Usage:
#   adversarial-review.sh --plan FILE [--base BRANCH] [--jobs N]
#                          [--timeout SEC] [--dir DIR] [--only ANGLE,...]
#                          [--angle-prompt FILE] [--allow-writes]
#   adversarial-review.sh --from-dir DIR [--only ANGLE,...]
#   adversarial-review.sh --print-base --base BRANCH
#   adversarial-review.sh --version
#   adversarial-review.sh --help
#
#   --plan FILE          plan JSON (version 1: base, promise, contracts,
#                         invariants, angles[]). Required unless --from-dir.
#   --base BRANCH         override the plan's base branch.
#   --jobs N               angles run in parallel (default: min(#angles, 4),
#                         or 1 under --allow-writes, so write-capable angles
#                         don't race each other by default).
#   --timeout SEC           per-angle codex timeout in seconds (default 900).
#   --dir DIR                run directory (default: a fresh mktemp -d).
#                           Holds plan.json (copy), <angle>.prompt.txt,
#                           <angle>.out.json, <angle>.log, <angle>.status
#                           (exit code), and merged.json.
#   --only ANGLE,...          restrict the run to these angle ids.
#   --angle-prompt FILE        prompt template (default:
#                           <this-skill-dir>/angle-prompt.md; an environment
#                           error if neither exists).
#   --allow-writes               run every selected angle with `-s
#                           workspace-write` instead of the default
#                           read-only, for this invocation only. Prints a
#                           warning plus `git status --porcelain` when done.
#                           Never mix read-only and workspace-write angles in
#                           one invocation — re-run a single angle with
#                           `--only <id> --allow-writes` instead.
#   --from-dir DIR              skip codex entirely; merge from an existing
#                           run dir. This is what the test suite uses.
#   --print-base                  resolve --base to the ref this run would
#                           diff against, print it, and exit (no --plan or
#                           codex needed).
#   --version                    print the version and exit.
#
#   Env overrides:
#     CODEX_REVIEW_MODEL    model passed to `codex exec` (default: gpt-5.6-sol)
#     CODEX_REVIEW_EFFORT   reasoning effort (default: xhigh)
#     CODEX_BIN              codex executable (default: codex on PATH)
#
# Output:
#   ADVERSARIAL_REVIEW: CLEAN | FINDINGS | UNPARSED
#   ANGLES=<n>  RAN=<n>  BLOCKED=<n>  UNPARSED=<n>
#   BLOCKING=<n>  NITS=<n>
#   DIR=<run dir>
#   --- ANGLES ---
#   <id>: CLEAN | FINDINGS(<n>) | BLOCKED | UNPARSED(<cause>)
#   --- SUMMARY ---
#   <one line per angle>
#   --- FINDINGS ---   (omitted when there are none)
#   - [Pn] <path>:<line> — <claim>  [angles: a,b]
#     evidence: <evidence>
#     reproduction: <reproduction>
#
# Exit codes:
#   0  ok — CLEAN or FINDINGS: a completed, parseable review.
#   1  environment — missing python3/codex, a bad --plan/--from-dir path, no
#      git repo, an unresolvable --base, or an empty diff.
#   2  usage — bad flags, invalid plan JSON, an unknown --only id.
#   3  codex itself could not be spawned at all for one or more angles — a
#      harder failure than any single angle timing out or exiting nonzero,
#      both of which are folded into a per-angle UNPARSED result instead so
#      the run still produces a merged report (see exit 4).
#   4  unparsed-never-clean — any angle UNPARSED or BLOCKED. A review that did
#      not fully run is not a clean review, even if every angle that did run
#      came back CLEAN.
# 130  interrupted — SIGINT (Ctrl-C) or SIGTERM during a live run.
set -euo pipefail

# Bump on every change to CLI/output behaviour. Kept equal to VERSION in
# adversarial_review.py — an installed copy can be checked with --version.
ADVERSARIAL_REVIEW_VERSION="1.2.0"

# Single pass over the raw args: answer --version/--help immediately, and
# note whether --from-dir or --print-base was given (codex is not needed in
# either mode — --print-base invokes no reviewer, it only resolves and
# prints a ref). Skips the VALUE of every flag that takes one, so a value
# that happens to spell "--version" is never misread as the flag itself.
ORIG_ARGS=("$@")
FROM_DIR=false
PRINT_BASE=false
n=${#ORIG_ARGS[@]}
i=0
while [ "$i" -lt "$n" ]; do
  a="${ORIG_ARGS[$i]}"
  case "$a" in
    --version)
      echo "adversarial-review.sh $ADVERSARIAL_REVIEW_VERSION"
      exit 0
      ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# //;s/^#//'
      exit 0
      ;;
    --from-dir)
      FROM_DIR=true
      i=$((i + 2))
      ;;
    --from-dir=*)
      # A single "--from-dir=PATH" token, not "--from-dir" + a separate
      # value arg — must still flip FROM_DIR so the codex-on-PATH check
      # below is skipped, same as the space-separated form above.
      FROM_DIR=true
      i=$((i + 1))
      ;;
    --print-base)
      # Boolean flag, no value — unlike --from-dir, there is no "=VALUE"
      # form to account for.
      PRINT_BASE=true
      i=$((i + 1))
      ;;
    --plan|--base|--jobs|--timeout|--dir|--only|--angle-prompt)
      i=$((i + 2))
      ;;
    *)
      i=$((i + 1))
      ;;
  esac
done

# Computed only now, after --version/--help have already exited — dirname is
# an external command, and --version must answer before touching one.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "adversarial-review: python3 not found on PATH." >&2
  exit 1
}

# adversarial_review.py uses Path.is_relative_to, added in 3.9 — check
# explicitly and fail with a clear message rather than let the runner die
# mid-run with an AttributeError on anything older.
python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' || {
  echo "adversarial-review: python3 3.9 or newer is required (this one is older)." >&2
  exit 1
}

if [ "$FROM_DIR" = false ] && [ "$PRINT_BASE" = false ]; then
  CODEX_BIN="${CODEX_BIN:-codex}"
  command -v "$CODEX_BIN" >/dev/null 2>&1 || {
    echo "adversarial-review: codex CLI ('$CODEX_BIN') not found on PATH." >&2
    exit 1
  }
fi

exec python3 "$SCRIPT_DIR/adversarial_review.py" "$@"
