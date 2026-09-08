#!/usr/bin/env bash
# Fake `codex` for the post-exit reap regression test: run_angle() must reap
# a reviewer's leftover background process even when the reviewer itself
# exits 0 normally — not only on a --timeout (see fake-codex-hang.sh for
# that case). Parses only -o (needed to know where to write its out.json;
# every other real codex arg — -s, -C, --output-schema, -c, the prompt text
# — is ignored) and exits 0 quickly after backgrounding a marker-named
# `sleep 30`, output redirected so it detaches from this script's own
# stdout/stderr (which run_angle() has pointed at the angle's .log file)
# rather than holding them open.
#
# Requires the same two env vars as fake-codex-hang.sh:
#   ADV_TEST_SLEEP_MARKER    uniquely names the background sleep so the
#                            test can pgrep -f for exactly this run's
#                            leftover process.
#   ADV_TEST_SLEEP_LINKDIR   a writable directory to hold that marker-named
#                            symlink to the real `sleep` binary.
set -u
: "${ADV_TEST_SLEEP_MARKER:?ADV_TEST_SLEEP_MARKER must be set}"
: "${ADV_TEST_SLEEP_LINKDIR:?ADV_TEST_SLEEP_LINKDIR must be set}"

out_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out_path="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: "${out_path:?fake codex was not given -o <path>}"

real_sleep="$(command -v sleep)"
link="$ADV_TEST_SLEEP_LINKDIR/sleep-$ADV_TEST_SLEEP_MARKER"
ln -sf "$real_sleep" "$link"

# Backgrounded, not awaited: this script exits and its .log closes while
# the marker sleep keeps running detached, in the same process group
# (start_new_session=True on the Popen that launched this script made it
# the group leader, and this job inherits that group).
"$link" 30 >/dev/null 2>&1 &

aid="$(basename "$out_path" .out.json)"
cat > "$out_path" <<JSON
{"angle": "$aid", "verdict": "CLEAN", "summary": "ran fine, but left a background process behind", "findings": []}
JSON

exit 0
