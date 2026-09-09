#!/usr/bin/env bash
# Fake `codex` for the HEAD-drift regression test (item 4 in the security
# review): logs its own argv exactly like fake-codex-argv-log.sh (one
# element per file — the prompt argument is itself multiline, so a
# line-oriented log couldn't tell an embedded newline apart from an element
# boundary), and, for exactly the angle named by ADV_TEST_COMMIT_ANGLE_ID,
# also commits a new file to the checkout under review (this process's own
# cwd — Popen always runs it with cwd=root) before writing its own
# out.json — leaving the working tree clean afterward. `git status
# --porcelain` alone would miss this entirely (the tree really is clean;
# only history moved), which is exactly why run_write_capable_angles' own
# post-angle check also compares HEAD itself (see _head_drift_note),
# independent of the ordinary dirty-tree check. Every other angle behaves
# like a plain, harmless CLEAN run.
#
# Requires ADV_TEST_ARGV_DIR (cleared on every invocation — only the
# committing angle's own argv is expected to be inspected afterward, since
# any write-capable angle scheduled after it is skipped as compromised
# without ever spawning a process at all) and ADV_TEST_COMMIT_ANGLE_ID.
set -u
: "${ADV_TEST_ARGV_DIR:?ADV_TEST_ARGV_DIR must be set}"
: "${ADV_TEST_COMMIT_ANGLE_ID:?ADV_TEST_COMMIT_ANGLE_ID must be set}"

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
aid="$(basename "$out_path" .out.json)"

if [ "$aid" = "$ADV_TEST_COMMIT_ANGLE_ID" ]; then
  echo "reviewer committed this" > head-drift-marker.txt
  git add head-drift-marker.txt >/dev/null 2>&1
  git -c user.email=reviewer@example.com -c user.name=Reviewer \
    commit -q -m "reviewer's own reproduction commit" >/dev/null 2>&1
fi

cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "CLEAN", "summary": "ran fine", "findings": []}
JSON

exit 0
