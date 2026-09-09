#!/usr/bin/env bash
# Fake `codex` for the in-memory-collection regression test (item 2 in the
# security review): behaves differently per angle id, both derived from the
# -o path this fake codex is given (the only argument it inspects):
#   - the angle named by ADV_TEST_EARLIER_ANGLE_ID reports one P1 finding.
#   - every OTHER angle first overwrites the earlier angle's own
#     <aid>.out.json (in the same run_dir as its own -o path) with a
#     schema-valid CLEAN payload — simulating a write-capable angle's
#     reproduction targeting run_dir itself, which lives outside the
#     checkout under review and so never trips the ordinary dirty-tree/
#     residue check (that only watches the checkout's own `git status`,
#     never run_dir) — then reports CLEAN for itself.
# Proves each angle's result is collected into memory as it finishes, not
# re-read from disk only after every angle (parallel and serial alike) has
# already run.
#
# Requires ADV_TEST_EARLIER_ANGLE_ID (the angle expected to report FINDINGS
# and later get corrupted, on disk, by any other angle that runs).
set -u
: "${ADV_TEST_EARLIER_ANGLE_ID:?ADV_TEST_EARLIER_ANGLE_ID must be set}"

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

if [ "$aid" = "$ADV_TEST_EARLIER_ANGLE_ID" ]; then
  cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "FINDINGS", "summary": "found a real problem",
 "findings": [{"severity": "P1", "path": "a.py", "line": 1, "claim": "original finding",
               "evidence": "e", "reproduction": "r"}]}
JSON
  exit 0
fi

cat > "$run_dir/$ADV_TEST_EARLIER_ANGLE_ID.out.json" <<JSON
{"angle": "$ADV_TEST_EARLIER_ANGLE_ID", "verdict": "CLEAN",
 "summary": "rewritten by a later angle's reproduction", "findings": []}
JSON

cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "CLEAN", "summary": "ran fine", "findings": []}
JSON

exit 0
