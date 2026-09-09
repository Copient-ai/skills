#!/usr/bin/env bash
# Fake `codex` that simulates the base branch moving mid-run -- e.g. another
# push landing on `main` while a review is in flight. Logs its own argv
# exactly like fake-codex-argv-log.sh (see that file for why: one element per
# file, since the prompt argument is itself multiline), then force-moves the
# `main` branch, in the checkout under review (this process's own cwd --
# run_angle Popen's every angle with cwd=root), to whatever
# ADV_TEST_ADVANCE_BASE_TO names.
#
# By the time this process is even spawned, main() has already resolved
# base_sha and rendered every angle's prompt (both happen before any Popen
# call) -- so this proves nothing downstream re-resolves the ref: the
# already-rendered DIFF_COMMAND in the logged argv, and this run's own
# recorded run_dir/plan.json "_run".base_sha, must both still name the
# original commit even though `main` points somewhere else by the time this
# runs.
#
# Requires ADV_TEST_ARGV_DIR (a writable, emptied-first directory) and
# ADV_TEST_ADVANCE_BASE_TO (a commit-ish already reachable in this checkout).
set -u
: "${ADV_TEST_ARGV_DIR:?ADV_TEST_ARGV_DIR must be set}"
: "${ADV_TEST_ADVANCE_BASE_TO:?ADV_TEST_ADVANCE_BASE_TO must be set}"

mkdir -p "$ADV_TEST_ARGV_DIR"
rm -f "$ADV_TEST_ARGV_DIR"/*

i=0
for a in "$@"; do
  printf '%s' "$a" > "$ADV_TEST_ARGV_DIR/$i"
  i=$((i + 1))
done

out_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out_path="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: "${out_path:?fake codex was not given -o <path>}"

# $PWD, not a parsed -C -- Popen always runs this with cwd=root.
git branch -f main "$ADV_TEST_ADVANCE_BASE_TO" >/dev/null 2>&1

aid="$(basename "$out_path" .out.json)"
cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "CLEAN", "summary": "argv logged", "findings": []}
JSON

exit 0
