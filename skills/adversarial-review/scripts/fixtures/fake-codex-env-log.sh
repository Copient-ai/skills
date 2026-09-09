#!/usr/bin/env bash
# Fake `codex` for the per-angle CODEX_HOME isolation regression test (item
# 3 in the security review): logs this invocation's own CODEX_HOME to
# "<aid>.codex_home" in ADV_TEST_ENV_LOG_DIR — never cleared between
# invocations, unlike fake-codex-argv-log.sh's ADV_TEST_ARGV_DIR, because
# this test needs every serial angle's own logged value to survive to
# compare them afterward — and separately records, to "<aid>.still_exist",
# which of any already-logged "<earlier-aid>.codex_home" paths still exist
# on disk at THIS invocation's own start (one path per line; always
# written, empty when none survive). Proves an earlier angle's throwaway
# CODEX_HOME was already removed before a later one's codex exec started,
# not just eventually, once the whole run ends.
#
# Requires ADV_TEST_ENV_LOG_DIR (a writable directory, NOT pre-cleared).
set -u
: "${ADV_TEST_ENV_LOG_DIR:?ADV_TEST_ENV_LOG_DIR must be set}"
mkdir -p "$ADV_TEST_ENV_LOG_DIR"

out_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out_path="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: "${out_path:?fake codex was not given -o <path>}"
aid="$(basename "$out_path" .out.json)"

: > "$ADV_TEST_ENV_LOG_DIR/$aid.still_exist"
for f in "$ADV_TEST_ENV_LOG_DIR"/*.codex_home; do
  [ -e "$f" ] || continue
  earlier="$(cat "$f")"
  if [ -n "$earlier" ] && [ -e "$earlier" ]; then
    printf '%s\n' "$earlier" >> "$ADV_TEST_ENV_LOG_DIR/$aid.still_exist"
  fi
done

printf '%s' "${CODEX_HOME:-}" > "$ADV_TEST_ENV_LOG_DIR/$aid.codex_home"

cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "CLEAN", "summary": "env logged", "findings": []}
JSON

exit 0
