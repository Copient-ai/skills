#!/usr/bin/env bash
# Fake `codex` for the process-group-kill regression test: run_angle() in
# adversarial_review.py starts codex with start_new_session=True and, on
# timeout, os.killpg()s the whole group instead of just the codex pid, so a
# reviewer's own children die with it. Ignores every real codex arg it's
# given (-s, -C, --output-schema, -o, -c, the prompt text) and never writes
# an out.json or .status itself — the harness under test does that.
#
# Requires two env vars from the test:
#   ADV_TEST_SLEEP_MARKER   uniquely names the background sleep below so the
#                           test can `pgrep -f` for exactly this run's
#                           leftover process, not an unrelated sleep already
#                           running on the box.
#   ADV_TEST_SLEEP_LINKDIR  a writable directory to hold that marker-named
#                           symlink to the real `sleep` binary.
set -u
: "${ADV_TEST_SLEEP_MARKER:?ADV_TEST_SLEEP_MARKER must be set}"
: "${ADV_TEST_SLEEP_LINKDIR:?ADV_TEST_SLEEP_LINKDIR must be set}"

real_sleep="$(command -v sleep)"
link="$ADV_TEST_SLEEP_LINKDIR/sleep-$ADV_TEST_SLEEP_MARKER"
ln -sf "$real_sleep" "$link"

# The marker-named leftover the test greps for: a real 30s sleep, invoked
# through a uniquely-named path so its command line is greppable and can't
# be confused with any other sleep on the machine.
"$link" 30 &

# Keep this fake-codex process itself alive well past the test's --timeout,
# so a real TimeoutExpired (and the killpg it triggers) is required to end
# the run at all.
sleep 300 &

wait
