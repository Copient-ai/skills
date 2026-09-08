#!/usr/bin/env bash
# Fake `codex` for the post-spawn-failure residue regression test: a
# workspace-write angle whose reviewer process actually ran (and modified
# the shared checkout) must still be caught by the post-angle residue check
# even when run_angle() itself goes on to report an error for some other
# reason afterward — see run_write_capable_angles and run_angle's `spawned`
# return value. This fake codex plays that reviewer: it appends to a
# tracked file in its cwd (the repo root — Popen always runs it with
# cwd=root), then, right before exiting, replaces its own <aid>.status path
# with a directory — forcing run_angle's own `write_text` of that same path
# (right after this process exits) to fail with IsADirectoryError. Doing it
# here, this late, matters: creating that directory any earlier (before the
# run starts) would instead make main()'s own upfront clear_stale_artifacts
# pass — which unlinks a *file* left by a prior run — blow up on the same
# IsADirectoryError, before this angle ever got to run at all. Writes a
# minimal valid out.json first, same as fake-codex-argv-log.sh. Parses only
# -o, same as the other fixtures here.
#
# Requires ADV_TEST_DIRTY_FILE: the tracked, already-committed file (a path
# relative to the repo root) this appends to.
set -u
: "${ADV_TEST_DIRTY_FILE:?ADV_TEST_DIRTY_FILE must be set}"

echo "reviewer wrote this" >> "$ADV_TEST_DIRTY_FILE"

out_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out_path="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: "${out_path:?fake codex was not given -o <path>}"

aid="$(basename "$out_path" .out.json)"
run_dir="$(dirname "$out_path")"

cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "CLEAN", "summary": "ran fine but dirtied the tree", "findings": []}
JSON

mkdir -p "$run_dir/$aid.status"

exit 0
