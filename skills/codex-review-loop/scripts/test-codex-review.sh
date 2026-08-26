#!/usr/bin/env bash
# Offline regression test for codex-review.sh's transcript parsing.
#
# Exercises the deterministic `--from-log` path against synthetic fixtures, so
# it needs no live `codex` call. Designed to catch the cross-platform munging
# bugs (GNU `tac`, GNU `sed \x1b`) that silently broke parsing on macOS:
#   - a fixture with leading/trailing blank lines forces the blank-line trim
#     (formerly `tac`-based);
#   - a fixture with ANSI color forces the ESC strip (formerly GNU-only `\x1b`).
#
# Usage: bash test-codex-review.sh   (exit 0 = all pass)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$SCRIPT_DIR/codex-review.sh"
ESC=$(printf '\033')
fails=0
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/codex-review-test.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

check() { # check <description> <condition-cmd...>
  local desc="$1"; shift
  if "$@"; then
    echo "  ok: $desc"
  else
    echo "  FAIL: $desc"
    fails=$((fails + 1))
  fi
}

# --- Fixture 1: findings, with ANSI color + a duplicated codex/FRC block ------
# (codex commonly prints the summary + findings twice.) The P1 line is wrapped
# in ANSI so it only matches `^- \[` after the ESC strip — guarding that bug.
fix_findings="$tmpdir/findings.log"
cat > "$fix_findings" <<EOF

${ESC}[2msome streamed tool output${ESC}[0m
codex
Summary first line.
Summary second line.

Full review comments:

${ESC}[1m- [P1] A blocking thing${ESC}[0m — /path/file.ts:10
  explanation of the blocker
- [P2] A nit — /path/file.ts:20
  explanation
- [P3] Another nit — /path/file.ts:30
  explanation

codex
Summary first line.
Summary second line.

Full review comments:

${ESC}[1m- [P1] A blocking thing${ESC}[0m — /path/file.ts:10
  explanation of the blocker
- [P2] A nit — /path/file.ts:20
  explanation
- [P3] Another nit — /path/file.ts:30
  explanation

EOF

out=$(bash "$REVIEW" --from-log "$fix_findings")
echo "--- findings fixture output ---"
printf '%s\n' "$out"

check "verdict is FINDINGS" grep -qx "CODEX_REVIEW: FINDINGS" <<<"$out"
check "counts are BLOCKING=1 NITS=2" grep -qx "BLOCKING=1  NITS=2" <<<"$out"
check "P1 finding present (ANSI stripped, not double-counted)" \
  grep -qF -- "- [P1] A blocking thing — /path/file.ts:10" <<<"$out"
check "summary present" grep -qF "Summary first line." <<<"$out"
# No raw ESC byte should survive into the distilled output.
if printf '%s' "$out" | grep -q "$ESC"; then
  echo "  FAIL: ANSI escape leaked into output"
  fails=$((fails + 1))
else
  echo "  ok: ANSI escapes stripped"
fi

# --- Fixture 2: clean (a codex summary, no 'Full review comments:') -----------
fix_clean="$tmpdir/clean.log"
cat > "$fix_clean" <<EOF
codex
No issues found. Looks good.
EOF

out_clean=$(bash "$REVIEW" --from-log "$fix_clean")
echo "--- clean fixture output ---"
printf '%s\n' "$out_clean"

check "verdict is CLEAN" grep -qx "CODEX_REVIEW: CLEAN" <<<"$out_clean"
check "counts are zero" grep -qx "BLOCKING=0  NITS=0" <<<"$out_clean"

# --- Fixture 3: single finding under the "Review comment:" (singular) header --
# Codex uses this phrasing when there is exactly one finding; the parser must
# not treat it as CLEAN.
fix_single="$tmpdir/single.log"
cat > "$fix_single" <<EOF
codex
A single nit was found.

Review comment:

- [P2] Lonely nit — /path/file.ts:5
  explanation
EOF

out_single=$(bash "$REVIEW" --from-log "$fix_single")
echo "--- single-finding fixture output ---"
printf '%s\n' "$out_single"

check "single-finding verdict is FINDINGS" \
  grep -qx "CODEX_REVIEW: FINDINGS" <<<"$out_single"
check "single-finding counts are BLOCKING=0 NITS=1" \
  grep -qx "BLOCKING=0  NITS=1" <<<"$out_single"

# --- Fixture 4: findings alongside a NUL byte in the transcript ---------------
# NUL bytes are routine in a real codex transcript. One is enough to make grep
# treat the normalized file as binary, at which point it prints no line numbers
# and the parser sees no findings header — distilling a branch with a P1 blocker
# down to CLEAN. The script must strip NULs before parsing.
fix_nul="$tmpdir/nul.log"
cat > "$fix_nul" <<EOF
codex
A blocker was found.

Full review comments:

- [P1] Real blocker — /path/file.ts:10
  explanation of the blocker
EOF
printf 'trailing tool output with a NUL:\000here\n' >> "$fix_nul"

out_nul=$(bash "$REVIEW" --from-log "$fix_nul" 2>/dev/null)
echo "--- NUL-byte fixture output ---"
printf '%s\n' "$out_nul"

check "NUL-byte transcript is not misparsed as CLEAN" \
  grep -qx "CODEX_REVIEW: FINDINGS" <<<"$out_nul"
check "NUL-byte transcript counts the blocker" \
  grep -qx "BLOCKING=1  NITS=0" <<<"$out_nul"

# --- Fixture 5: a stray findings header before the final 'codex' marker --------
# Streamed tool output can contain a literal "Full review comments:" line — a
# review of this repo hits that, since the fixtures above contain one. Selecting
# the header from anywhere in the file pairs it with an empty first_frc and
# hands sed an invalid range, so the script dies instead of reporting CLEAN.
fix_stray="$tmpdir/stray.log"
cat > "$fix_stray" <<EOF
Full review comments:
(streamed tool output that happened to read a test fixture)

codex
No issues found. Looks good.
EOF

out_stray=$(bash "$REVIEW" --from-log "$fix_stray" 2>/dev/null)
stray_rc=$?
echo "--- stray-header fixture output ---"
printf '%s\n' "$out_stray"

check "stray header does not crash the parser" test "$stray_rc" -eq 0
check "stray header still reports CLEAN" grep -qx "CODEX_REVIEW: CLEAN" <<<"$out_stray"

# --- Fixture 6: a bare 'codex' marker inside a finding's body -----------------
# A finding that quotes a transcript excerpt puts a standalone `codex` line in
# the findings body. Selecting the LAST such line lands the marker inside the
# body, after the real header, so the section boundaries invert and a P1 blocker
# is emitted as CLEAN. Section anchoring must use a marker that is actually
# followed by a findings header.
fix_marker="$tmpdir/marker.log"
cat > "$fix_marker" <<EOF
codex
A blocker was found.

Full review comments:

- [P1] Parser mishandles transcript excerpts — /path/file.ts:10
  The finding quotes a transcript, which contains a bare marker line:
codex
  ...and then keeps explaining.
EOF

out_marker=$(bash "$REVIEW" --from-log "$fix_marker" 2>/dev/null)
echo "--- in-body marker fixture output ---"
printf '%s\n' "$out_marker"

check "in-body 'codex' marker does not hide the findings" \
  grep -qx "CODEX_REVIEW: FINDINGS" <<<"$out_marker"
check "in-body 'codex' marker still counts the blocker" \
  grep -qx "BLOCKING=1  NITS=0" <<<"$out_marker"
check "summary is the real summary, not finding text" \
  grep -qF "A blocker was found." <<<"$out_marker"

# --- Fixture 7: a findings section that yields no items -----------------------
# A finding body can quote a whole mini-transcript — marker and header included
# — and no line-based anchor rules that out. When the anchors land wrong the
# section parses to zero items; the script must say so and exit non-zero rather
# than report counts (or a CLEAN) that nobody should trust.
fix_unparsed="$tmpdir/unparsed.log"
cat > "$fix_unparsed" <<EOF
codex
A blocker was found.

Full review comments:

- [P1] Finding that quotes a whole mini-transcript — /path/file.ts:10
  For example the parser sees:
codex
  Some summary.
Full review comments:
  - [P2] a quoted nit — /x.ts:1
EOF

out_unparsed=$(bash "$REVIEW" --from-log "$fix_unparsed" 2>/dev/null)
unparsed_rc=$?
echo "--- unparseable fixture output ---"
printf '%s\n' "$out_unparsed"

check "unparseable section is not reported as CLEAN" \
  bash -c '! grep -qx "CODEX_REVIEW: CLEAN" <<<"$1"' _ "$out_unparsed"
check "unparseable section is flagged UNPARSED" \
  grep -qx "CODEX_REVIEW: UNPARSED" <<<"$out_unparsed"
check "unparseable section exits non-zero" test "$unparsed_rc" -ne 0

# --- Fixture 8: a real finding quoting a COMPLETE section ---------------------
# The nastiest shape. A real finding quotes a whole mini-transcript — marker,
# header, and a bullet at column 0 — so the quoted pair looks exactly like a
# final section and the quoted bullet gives a nonzero count, slipping past the
# zero-item guard. Taking the last valid-looking pair reports BLOCKING=0 NITS=1
# and silently drops the real P0 above it, which converges the loop and pushes.
# Only VERBATIM duplicate sections may be collapsed; this must be refused.
fix_nested="$tmpdir/nested.log"
cat > "$fix_nested" <<EOF
codex
Two blockers were found.

Full review comments:

- [P0] Credentials logged in plaintext — /app/auth.py:41
  Real blocker. For context the earlier run reported:
codex
  Some summary.

Full review comments:

- [P2] a quoted nit — /x.ts:1
EOF

out_nested=$(bash "$REVIEW" --from-log "$fix_nested" 2>/dev/null)
nested_rc=$?
echo "--- nested-section fixture output ---"
printf '%s\n' "$out_nested"

check "nested section does not report BLOCKING=0" \
  bash -c '! grep -q "BLOCKING=0" <<<"$1"' _ "$out_nested"
check "nested section is refused as UNPARSED" \
  grep -qx "CODEX_REVIEW: UNPARSED" <<<"$out_nested"
check "nested section exits non-zero" test "$nested_rc" -ne 0

# --- Fixture 9: transcript with no codex marker at all ------------------------
# An empty or truncated log (codex crashed, was killed, or never ran) has no
# marker. The no-header path called that CLEAN, which authorizes convergence
# and a push on a branch nothing ever reviewed.
fix_empty="$tmpdir/empty.log"
: > "$fix_empty"
out_empty=$(bash "$REVIEW" --from-log "$fix_empty" 2>/dev/null)
empty_rc=$?
echo "--- empty-transcript fixture output ---"
printf '%s\n' "$out_empty"

check "empty transcript is not CLEAN" \
  bash -c '! grep -qx "CODEX_REVIEW: CLEAN" <<<"$1"' _ "$out_empty"
check "empty transcript is UNPARSED" \
  grep -qx "CODEX_REVIEW: UNPARSED" <<<"$out_empty"
check "empty transcript exits non-zero" test "$empty_rc" -ne 0

fix_trunc="$tmpdir/trunc.log"
printf 'thinking...\nreading files\n' > "$fix_trunc"
out_trunc=$(bash "$REVIEW" --from-log "$fix_trunc" 2>/dev/null)
check "truncated transcript is not CLEAN" \
  bash -c '! grep -qx "CODEX_REVIEW: CLEAN" <<<"$1"' _ "$out_trunc"

# --- Fixture 10: final block repeated with NO second codex marker -------------
# Codex repeats its closing summary+findings without re-emitting the marker, so
# the pair anchor cannot see the repeat and everything after the header is kept:
# one P1 counted as BLOCKING=2 and printed twice. Each distinct finding must be
# emitted once.
fix_markerless="$tmpdir/markerless.log"
cat > "$fix_markerless" <<EOF
codex
A summary.

Full review comments:

- [P1] One real blocker — /a.py:1
  explanation
A summary.

Full review comments:

- [P1] One real blocker — /a.py:1
  explanation
EOF

out_markerless=$(bash "$REVIEW" --from-log "$fix_markerless" 2>/dev/null)
echo "--- markerless-duplicate fixture output ---"
printf '%s\n' "$out_markerless"

check "markerless duplicate does not double-count" \
  grep -qx "BLOCKING=1  NITS=0" <<<"$out_markerless"
check "markerless duplicate prints the finding once" \
  test "$(grep -c -- '^- \[P1\] One real blocker' <<<"$out_markerless")" -eq 1

# --- Fixture 11: a detected header with no items after it ---------------------
# A transcript truncated right after the findings header. The section text is
# empty, so a guard keyed on "raw section is non-empty" skips — and the script
# reports CLEAN even though the summary says a blocker was found. Detection of
# the header is what makes zero items invalid, not the section text.
fix_hdr="$tmpdir/hdr_empty.log"
printf 'codex\nA blocker was found.\n\nFull review comments:\n' > "$fix_hdr"
out_hdr=$(bash "$REVIEW" --from-log "$fix_hdr" 2>/dev/null)
echo "--- header-no-items fixture output ---"
printf '%s\n' "$out_hdr"

check "header with no items is not CLEAN" \
  bash -c '! grep -qx "CODEX_REVIEW: CLEAN" <<<"$1"' _ "$out_hdr"
check "header with no items is UNPARSED" \
  grep -qx "CODEX_REVIEW: UNPARSED" <<<"$out_hdr"

# --- Fixture 12: transcript ending at a bare codex marker ---------------------
# codex was killed or the log truncated before the final response was written.
# The marker is present, so a marker-presence check passes, and the no-header
# path emits CLEAN with an empty summary — approval for an unwritten review.
fix_ends="$tmpdir/ends_marker.log"
printf 'tool output\ncodex\n' > "$fix_ends"
out_ends=$(bash "$REVIEW" --from-log "$fix_ends" 2>/dev/null)
echo "--- ends-at-marker fixture output ---"
printf '%s\n' "$out_ends"

check "transcript ending at the marker is not CLEAN" \
  bash -c '! grep -qx "CODEX_REVIEW: CLEAN" <<<"$1"' _ "$out_ends"
check "transcript ending at the marker reports its cause" \
  grep -qx "PARSE_CAUSE=incomplete" <<<"$out_ends"

# --- Fixture 13: a genuinely clean review must still converge -----------------
# The refusals above must not swallow the ordinary clean case, or the loop can
# never finish.
check "a real clean transcript still reports CLEAN" \
  grep -qx "CODEX_REVIEW: CLEAN" <<<"$out_clean"

# --- Fixture 14: every UNPARSED result must name its cause --------------------
# Step 2 dispatches on PARSE_CAUSE, so a refusal without one has no defined
# recovery path.
check "zero-item refusal names its cause" \
  grep -qx "PARSE_CAUSE=noitems" <<<"$out_hdr"
check "ambiguous refusal names its cause" \
  grep -qx "PARSE_CAUSE=ambiguous" <<<"$out_nested"
check "empty-transcript refusal names its cause" \
  grep -qx "PARSE_CAUSE=nomarker" <<<"$out_empty"

# --- Fixture 15: codex duplicates clean responses too -------------------------
# With no findings header there is nothing to anchor dedup on, so both copies of
# a clean summary were kept and the helper printed it twice.
fix_dupclean="$tmpdir/dupclean.log"
printf 'codex\nNo issues found. Looks good.\nNo issues found. Looks good.\n' > "$fix_dupclean"
out_dupclean=$(bash "$REVIEW" --from-log "$fix_dupclean" 2>/dev/null)
echo "--- duplicated-clean-summary fixture output ---"
printf '%s\n' "$out_dupclean"

check "duplicated clean summary is still CLEAN" \
  grep -qx "CODEX_REVIEW: CLEAN" <<<"$out_dupclean"
check "duplicated clean summary prints once" \
  test "$(grep -c "No issues found" <<<"$out_dupclean")" -eq 1

# A non-doubled summary must survive untouched (the dedup must not eat content).
check "single clean summary is preserved" \
  grep -qF "No issues found. Looks good." <<<"$out_clean"

# --- Fixture 16: findings under an unrecognized header ------------------------
# If a codex release renames "Full review comments:", no section is recognized,
# FINDINGS is empty, and every review reports CLEAN with blockers sitting in
# plain sight. Priority bullets with no recognized header must refuse.
fix_noheader="$tmpdir/noheader.log"
cat > "$fix_noheader" <<EOF
codex
I found problems with this branch.

Findings list:

- [P1] Credentials logged in plaintext — /app/auth.py:41
  A real blocker, outside any header this script recognizes.
EOF

out_noheader=$(bash "$REVIEW" --from-log "$fix_noheader" 2>/dev/null)
echo "--- unrecognized-header fixture output ---"
printf '%s\n' "$out_noheader"

check "findings under an unknown header are not CLEAN" \
  bash -c '! grep -qx "CODEX_REVIEW: CLEAN" <<<"$1"' _ "$out_noheader"
check "findings under an unknown header name their cause" \
  grep -qx "PARSE_CAUSE=strayitems" <<<"$out_noheader"
check "a clean review with no bullets is unaffected" \
  grep -qx "CODEX_REVIEW: CLEAN" <<<"$out_clean"

# --- Fixture 17: --version reports a version without needing codex or a log ---
# The staleness check is a safety feature: an installed copy older than the repo
# may still carry a false-CLEAN bug. It has to answer on a machine with no codex
# CLI installed and no transcript to parse, so it must exit before both.
# PATH is emptied rather than just scrubbed of codex, so the check also proves
# --version returns before the script reaches any external command. "$BASH" is
# an absolute path to the running shell, so it still starts with no PATH.
ver_out=$(PATH='' "$BASH" "$REVIEW" --version 2>&1)
ver_rc=$?
echo "--- version output ---"
printf '%s\n' "$ver_out"

check "--version exits 0" test "$ver_rc" -eq 0
check "--version prints a semver, with no codex CLI on PATH" \
  grep -qE '^codex-review\.sh [0-9]+\.[0-9]+\.[0-9]+$' <<<"$ver_out"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails CHECK(S) FAILED"
fi
exit "$fails"
