#!/usr/bin/env bash
# Fake `codex` that records its own invocation for offline regression tests
# on the exec argv run_angle() builds — the "--" option terminator inserted
# right before the prompt, and CODEX_BIN being resolved to an absolute path
# before Popen (so a relative CODEX_BIN still spawns correctly even though
# Popen's cwd is the repo root, not wherever the caller invoked from).
#
# Every real codex arg (-s, -C, --output-schema, -c, the prompt text) is
# ignored beyond what's needed to log them and to find -o, so this exits 0
# quickly with a minimal valid out.json — the run completes as CLEAN rather
# than needing a live codex.
#
# Requires ADV_TEST_ARGV_DIR (a writable, emptied-first directory) from the
# test. Each argv element is written to its own file (0, 1, 2, ... in
# order) rather than one-line-per-arg in a single file, because the prompt
# argument itself is multiline — a single log file couldn't tell an
# embedded newline inside one arg apart from a boundary between two args.
# argv[0] (exactly the string Popen was given as cmd[0], not anything the
# shell resolved on its own) is written separately to "argv0".
set -u
: "${ADV_TEST_ARGV_DIR:?ADV_TEST_ARGV_DIR must be set}"

mkdir -p "$ADV_TEST_ARGV_DIR"
rm -f "$ADV_TEST_ARGV_DIR"/*

printf '%s' "$0" > "$ADV_TEST_ARGV_DIR/argv0"

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
cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "CLEAN", "summary": "argv logged", "findings": []}
JSON

exit 0
