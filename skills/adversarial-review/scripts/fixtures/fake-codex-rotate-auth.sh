#!/usr/bin/env bash
# Fake `codex` that simulates a file-backed ChatGPT auth rotation: rewrites
# its own $CODEX_HOME/auth.json with new content before exiting, the same
# way a real token refresh persists a new access/refresh token pair back
# into CODEX_HOME/auth.json. Used to test that _propagate_rotated_auth (see
# adversarial_review.py) copies that rotation back to the REAL CODEX_HOME
# before this angle's throwaway copy is deleted, rather than stranding a
# rotated token in a directory about to be rmtree'd.
#
# Requires ADV_TEST_ROTATED_MARKER (the new auth.json content to write).
#
# ADV_TEST_ROTATE_TRUNCATE, if set, ignores ADV_TEST_ROTATED_MARKER and
# instead leaves auth.json looking like a rotation killed mid-write:
# "zero" truncates it to an empty file, anything else writes a partial
# JSON fragment. Used to test that _propagate_rotated_auth refuses to
# propagate a candidate that fails _is_plausible_auth_rotation.
set -u

if [ -n "${CODEX_HOME:-}" ]; then
  if [ -n "${ADV_TEST_ROTATE_TRUNCATE:-}" ]; then
    if [ "$ADV_TEST_ROTATE_TRUNCATE" = "zero" ]; then
      : > "$CODEX_HOME/auth.json"
    else
      printf '%s' '{"tok' > "$CODEX_HOME/auth.json"
    fi
  else
    : "${ADV_TEST_ROTATED_MARKER:?ADV_TEST_ROTATED_MARKER must be set}"
    printf '%s' "$ADV_TEST_ROTATED_MARKER" > "$CODEX_HOME/auth.json"
  fi
fi

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
{"angle": "$aid", "verdict": "CLEAN", "summary": "auth rotated", "findings": []}
JSON

exit 0
