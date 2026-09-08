#!/usr/bin/env bash
# Offline regression test for adversarial-review.sh / adversarial_review.py.
#
# Exercises the deterministic `--from-dir` path against synthetic fixture run
# directories under fixtures/, so it needs no live `codex` call and no git
# repo state. Each fixture is copied into a scratch tmpdir before use, so the
# tool's generated merged.json never lands in the checked-in fixtures/ tree.
#
# Usage: bash test-adversarial-review.sh   (exit 0 = all pass)
#
# Deliberately no `set -e`: several cases below expect a nonzero exit from
# the tool under test, and this script's own job is to keep going and tally
# every check rather than abort on the first one.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$SCRIPT_DIR/adversarial-review.sh"
PY="$SCRIPT_DIR/adversarial_review.py"
FIXTURES="$SCRIPT_DIR/fixtures"
fails=0
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/adversarial-review-test.XXXXXX")
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

# Copies fixtures/<name> into a fresh scratch dir and echoes its path, so a
# run's generated merged.json/*.status never touches the checked-in fixture.
stage() { # stage <fixture-name>
  local name="$1"
  local dest="$tmpdir/$name.$$.${RANDOM:-0}"
  cp -R "$FIXTURES/$name" "$dest"
  printf '%s\n' "$dest"
}

# --- Case 1: all angles CLEAN --------------------------------------------------
dir1=$(stage all-clean)
out1=$(bash "$SH" --from-dir "$dir1"); rc1=$?
echo "--- case 1: all-clean ---"
printf '%s\n' "$out1"

check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out1"
check "exits 0" test "$rc1" -eq 0
check "counts show all 3 ran, none blocked/unparsed" \
  grep -qx "ANGLES=3  RAN=3  BLOCKED=0  UNPARSED=0" <<<"$out1"
check "no findings" grep -qx "BLOCKING=0  NITS=0" <<<"$out1"
check "merged.json was written" test -f "$dir1/merged.json"

# --- Case 2: findings across two angles, one duplicate ------------------------
dir2=$(stage dup-finding)
out2=$(bash "$SH" --from-dir "$dir2"); rc2=$?
echo "--- case 2: dup-finding ---"
printf '%s\n' "$out2"

check "verdict is FINDINGS" grep -qx "ADVERSARIAL_REVIEW: FINDINGS" <<<"$out2"
check "exits 0" test "$rc2" -eq 0
check "deduped to one blocking finding (higher severity wins)" \
  grep -qx "BLOCKING=1  NITS=0" <<<"$out2"
check "only one finding line printed" \
  test "$(grep -c '^- \[P' <<<"$out2")" -eq 1
check "the deduped finding carries the higher severity (P0)" \
  grep -qF -- "- [P0] a.py:10" <<<"$out2"
check "the deduped finding lists both contributing angles" \
  grep -qF -- "[angles: logic,security]" <<<"$out2"
check "the deduped finding kept the higher-severity angle's evidence" \
  grep -qF "evidence: the dropped row carries the auth check" <<<"$out2"

# --- Case 3: one angle BLOCKED --------------------------------------------------
dir3=$(stage one-blocked)
out3=$(bash "$SH" --from-dir "$dir3" 2>/dev/null); rc3=$?
echo "--- case 3: one-blocked ---"
printf '%s\n' "$out3"

check "verdict is UNPARSED (a BLOCKED angle is never a clean review)" \
  grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out3"
check "exits 4" test "$rc3" -eq 4
check "counts show one BLOCKED angle" \
  grep -qx "ANGLES=2  RAN=2  BLOCKED=1  UNPARSED=0" <<<"$out3"
check "the blocked angle is labeled BLOCKED" \
  grep -qx "reviewer1: BLOCKED" <<<"$out3"

# --- Case 4: one angle missing out.json (status 124, timeout) -----------------
dir4=$(stage timeout-missing-json)
out4=$(bash "$SH" --from-dir "$dir4" 2>/dev/null); rc4=$?
echo "--- case 4: timeout-missing-json ---"
printf '%s\n' "$out4"

check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out4"
check "exits 4" test "$rc4" -eq 4
check "the timed-out angle names its cause" \
  grep -qx "slow: UNPARSED(timeout)" <<<"$out4"
check "counts show one UNPARSED angle" \
  grep -qx "ANGLES=2  RAN=1  BLOCKED=0  UNPARSED=1" <<<"$out4"

# --- Case 5: out.json violates the schema (bad severity) ----------------------
dir5=$(stage bad-schema)
out5=$(bash "$SH" --from-dir "$dir5" 2>/dev/null); rc5=$?
echo "--- case 5: bad-schema ---"
printf '%s\n' "$out5"

check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out5"
check "exits 4" test "$rc5" -eq 4
check "the bad-schema angle names its cause" \
  grep -qx "a1: UNPARSED(schema)" <<<"$out5"

# --- Case 6: --only restricts --------------------------------------------------
dir6=$(stage all-clean)
out6=$(bash "$SH" --from-dir "$dir6" --only alpha,gamma); rc6=$?
echo "--- case 6: --only restricts ---"
printf '%s\n' "$out6"

check "exits 0" test "$rc6" -eq 0
check "only 2 angles counted" \
  grep -qx "ANGLES=2  RAN=2  BLOCKED=0  UNPARSED=0" <<<"$out6"
check "alpha is present" grep -qx "alpha: CLEAN" <<<"$out6"
check "gamma is present" grep -qx "gamma: CLEAN" <<<"$out6"
check "beta was excluded" bash -c '! grep -q "^beta:" <<<"$1"' _ "$out6"

# --- Case 7: plan validation errors --------------------------------------------
dir7a=$(stage bad-plan-dup-id)
err7a=$(bash "$SH" --from-dir "$dir7a" 2>&1); rc7a=$?
echo "--- case 7a: duplicate angle id ---"
printf '%s\n' "$err7a"
check "duplicate id exits 2" test "$rc7a" -eq 2
check "duplicate id names the problem" grep -qi "duplicate angle id" <<<"$err7a"

dir7b=$(stage bad-plan-bad-execution)
err7b=$(bash "$SH" --from-dir "$dir7b" 2>&1); rc7b=$?
echo "--- case 7b: bad execution value ---"
printf '%s\n' "$err7b"
check "bad execution exits 2" test "$rc7b" -eq 2
check "bad execution names the problem" grep -qi "invalid execution" <<<"$err7b"

dir7c=$(stage bad-plan-version2)
err7c=$(bash "$SH" --from-dir "$dir7c" 2>&1); rc7c=$?
echo "--- case 7c: unsupported plan version ---"
printf '%s\n' "$err7c"
check "version 2 exits 2" test "$rc7c" -eq 2
check "version 2 names the problem" grep -qi "unsupported plan version" <<<"$err7c"

# --- Case 8: the block format is exact -----------------------------------------
dir8=$(stage exact-format)
out8=$(bash "$SH" --from-dir "$dir8")
norm8=$(printf '%s\n' "$out8" | sed "s#^DIR=.*#DIR=RUNDIR#")
echo "--- case 8: exact format ---"
printf '%s\n' "$out8"

if diff -u "$FIXTURES/exact-format/expected.txt" <(printf '%s\n' "$norm8") >/tmp/adversarial-review-format.diff 2>&1; then
  echo "  ok: output matches expected.txt exactly (DIR= normalized)"
else
  echo "  FAIL: output does not match expected.txt"
  cat /tmp/adversarial-review-format.diff
  fails=$((fails + 1))
fi
rm -f /tmp/adversarial-review-format.diff

# --- --version: sh and py versions must match ----------------------------------
sh_ver=$(bash "$SH" --version | awk '{print $2}')
py_ver=$(python3 "$PY" --version | awk '{print $2}')
echo "--- version check ---"
echo "sh=$sh_ver py=$py_ver"
check "adversarial-review.sh --version exits 0" bash -c 'bash "$1" --version >/dev/null' _ "$SH"
check "sh and py versions are both semver" \
  bash -c '[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]' _ "$sh_ver" "$py_ver"
check "sh and py versions match" test "$sh_ver" = "$py_ver"

# --- Usage errors: missing --plan, unknown --only id ---------------------------
err_noplan=$(bash "$SH" 2>&1); rc_noplan=$?
echo "--- case: no --plan and no --from-dir ---"
printf '%s\n' "$err_noplan"
check "missing --plan exits 2" test "$rc_noplan" -eq 2

dir_only=$(stage all-clean)
err_badonly=$(bash "$SH" --from-dir "$dir_only" --only nope 2>&1); rc_badonly=$?
echo "--- case: unknown --only id ---"
printf '%s\n' "$err_badonly"
check "unknown --only id exits 2" test "$rc_badonly" -eq 2
check "unknown --only id names the problem" grep -qi "unknown angle id" <<<"$err_badonly"

# --- Environment errors: missing --from-dir directory --------------------------
err_nodir=$(bash "$SH" --from-dir "$tmpdir/does-not-exist" 2>&1); rc_nodir=$?
echo "--- case: missing --from-dir directory ---"
printf '%s\n' "$err_nodir"
check "missing run directory exits 1" test "$rc_nodir" -eq 1

# --- Prompt template rendering (offline, no codex) ------------------------------
# Exercises render_prompt directly, since the live codex-invocation path that
# normally builds *.prompt.txt is not reachable from --from-dir mode.
render_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from adversarial_review import render_prompt

plan = {"promise": "Ship it.", "contracts": ["C1"], "invariants": ["I1"]}
angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.",
         "evidence": "A concrete case.", "files": ["a.py", "b.py"]}
template = ("base={{BASE}} promise={{PROMISE}} contracts={{CONTRACTS}} "
            "invariants={{INVARIANTS}} id={{ANGLE_ID}} title={{ANGLE_TITLE}} "
            "mandate={{MANDATE}} evidence={{EVIDENCE}} files={{FILES}} "
            "diff={{DIFF_COMMAND}}")
rendered = render_prompt(template, plan, angle, "origin/main")
expected = ("base=origin/main promise=Ship it. contracts=- C1 "
            "invariants=- I1 id=logic title=Logic mandate=Find bugs. "
            "evidence=A concrete case. files=- a.py\n- b.py "
            "diff=git diff origin/main...HEAD")
print("OK" if rendered == expected else "MISMATCH:\n" + rendered)
PYEOF
)
echo "--- prompt template rendering ---"
printf '%s\n' "$render_check"
check "placeholder substitution is exact" test "$render_check" = "OK"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails CHECK(S) FAILED"
fi
exit "$fails"
