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

# Creates a tiny throwaway git repo (its own dir under $tmpdir) with a
# 'main' branch and a 'feature' branch one commit ahead, so `git diff
# main...feature` is non-empty and resolve_base can find local branch
# 'main' (no 'origin' remote is configured, so the origin/main candidate
# never verifies). Used by the live-ish cases below that need main() to run
# past its git/base/diff preflight checks. Echoes the repo path.
make_throwaway_repo() { # make_throwaway_repo <name>
  local repo="$tmpdir/$1.$$.${RANDOM:-0}"
  mkdir -p "$repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "base" > "$repo/f.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b feature
  echo "changed" >> "$repo/f.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m feature
  printf '%s\n' "$repo"
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

dir7d=$(stage bad-plan-null-promise)
err7d=$(bash "$SH" --from-dir "$dir7d" 2>&1); rc7d=$?
echo "--- case 7d: null promise ---"
printf '%s\n' "$err7d"
check "null promise exits 2" test "$rc7d" -eq 2
check "null promise names the problem" grep -qi "'promise' must be a non-empty string" <<<"$err7d"

dir7e=$(stage bad-plan-string-contracts)
err7e=$(bash "$SH" --from-dir "$dir7e" 2>&1); rc7e=$?
echo "--- case 7e: contracts is a string, not a list ---"
printf '%s\n' "$err7e"
check "string contracts exits 2" test "$rc7e" -eq 2
check "string contracts names the problem" grep -qi "'contracts' must be a list of strings" <<<"$err7e"

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

# --- Case 9: a write-capable angle left residue --------------------------------
# The live serialization path (parallel read-only, then serial
# workspace-write with a clean-tree gate) is not reachable offline — this
# exercises the merge side: an angle dir carrying <angle>.residue.txt must
# never be treated as a clean run, even though its out.json parsed fine.
dir9=$(stage residue)
out9=$(bash "$SH" --from-dir "$dir9" 2>/dev/null); rc9=$?
echo "--- case 9: residue ---"
printf '%s\n' "$out9"

check "verdict is UNPARSED (residue is never a clean run)" \
  grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out9"
check "exits 4" test "$rc9" -eq 4
check "the residue angle is labeled UNPARSED(residue)" \
  grep -qx "writer: UNPARSED(residue)" <<<"$out9"
check "the residue angle does not count as RAN" \
  grep -qx "ANGLES=2  RAN=1  BLOCKED=0  UNPARSED=1" <<<"$out9"
check "the residue angle's finding is still surfaced in the block" \
  grep -qF -- "- [P1] b.py:20" <<<"$out9"
check "the surfaced finding is tagged with the residue angle" \
  grep -qF -- "[angles: writer]" <<<"$out9"

# --- Case 10: BLOCKED with a nonempty findings array ----------------------------
dir10=$(stage blocked-with-findings)
out10=$(bash "$SH" --from-dir "$dir10" 2>/dev/null); rc10=$?
echo "--- case 10: blocked-with-findings ---"
printf '%s\n' "$out10"

check "verdict is UNPARSED (BLOCKED wins over its own findings)" \
  grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out10"
check "exits 4" test "$rc10" -eq 4
check "the angle is labeled BLOCKED, not FINDINGS" \
  grep -qx "reviewer1: BLOCKED" <<<"$out10"
check "BLOCKED still counts as RAN (it produced parseable output)" \
  grep -qx "ANGLES=2  RAN=2  BLOCKED=1  UNPARSED=0" <<<"$out10"
check "the BLOCKED angle's finding is still surfaced in the block" \
  grep -qF -- "- [P1] c.py:5" <<<"$out10"
check "the surfaced finding is tagged with the BLOCKED angle" \
  grep -qF -- "[angles: reviewer1]" <<<"$out10"

# --- Case 11: --from-dir resolves a relative path -------------------------------
# Regression for codex's --output-schema/-o paths landing under root (its
# subprocess cwd) instead of the caller's --dir: --plan, --dir and
# --from-dir are all resolved to absolute paths up front. This exercises
# --from-dir specifically, run from a subdirectory several levels below the
# fixture tree with a relative path back up to it.
dir11=$(stage all-clean)
mkdir -p "$dir11/nested/deeper"
out11=$(cd "$dir11/nested/deeper" && bash "$SH" --from-dir ../..); rc11=$?
echo "--- case 11: --from-dir with a relative path from a subdirectory ---"
printf '%s\n' "$out11"

check "exits 0" test "$rc11" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out11"
check "all 3 angles still merge from the resolved directory" \
  grep -qx "ANGLES=3  RAN=3  BLOCKED=0  UNPARSED=0" <<<"$out11"
check "DIR= in the report is absolute" \
  grep -qE '^DIR=/' <<<"$out11"

# --- Case 12: provider refusal (nonzero exit, no out.json, log shows a -------
# content-filter refusal) must report UNPARSED(refused), not UNPARSED(exit1).
dir12=$(stage refused)
out12=$(bash "$SH" --from-dir "$dir12" 2>"$tmpdir/refused.stderr"); rc12=$?
err12=$(cat "$tmpdir/refused.stderr")
echo "--- case 12: refused ---"
printf '%s\n' "$out12"

check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out12"
check "exits 4" test "$rc12" -eq 4
check "the refused angle names its cause" \
  grep -qx "reassign: UNPARSED(refused)" <<<"$out12"
check "the control angle still ran clean" \
  grep -qx "control: CLEAN" <<<"$out12"
check "counts show one UNPARSED angle" \
  grep -qx "ANGLES=2  RAN=1  BLOCKED=0  UNPARSED=1" <<<"$out12"
check "stderr names the refused angle" grep -qi "reassign" <<<"$err12"
check "stderr says the provider refused" grep -qi "refused" <<<"$err12"
check "the log excerpt itself is not echoed to stdout" \
  bash -c '! grep -qi "flagged for possible cybersecurity risk" <<<"$1"' _ "$out12"

# --- Case 13: out.json present but no .status file at all ----------------------
# A present, well-formed out.json must never be accepted on its own — only a
# .status file that parses as exactly 0 marks the run as having completed.
dir13=$(stage missing-status)
out13=$(bash "$SH" --from-dir "$dir13" 2>/dev/null); rc13=$?
echo "--- case 13: missing-status ---"
printf '%s\n' "$out13"

check "verdict is UNPARSED (no .status means the run is never accepted)" \
  grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out13"
check "exits 4" test "$rc13" -eq 4
check "the angle names its cause" \
  grep -qx "alpha: UNPARSED(nostatus)" <<<"$out13"
check "counts show one UNPARSED angle, none RAN" \
  grep -qx "ANGLES=1  RAN=0  BLOCKED=0  UNPARSED=1" <<<"$out13"

# --- Case 14: out.json is tagged with a different angle's id -------------------
dir14=$(stage mistagged)
out14=$(bash "$SH" --from-dir "$dir14" 2>/dev/null); rc14=$?
echo "--- case 14: mistagged ---"
printf '%s\n' "$out14"

check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out14"
check "exits 4" test "$rc14" -eq 4
check "the mistagged angle names its cause" \
  grep -qx "mismatch: UNPARSED(mistagged)" <<<"$out14"
check "the control angle still ran clean" \
  grep -qx "control: CLEAN" <<<"$out14"
check "the mistagged angle's finding is never attributed" \
  bash -c '! grep -q "must never be attributed" <<<"$1"' _ "$out14"
check "no findings block at all — its only finding came from the mistagged angle" \
  bash -c '! grep -q -- "--- FINDINGS ---" <<<"$1"' _ "$out14"

# --- Case 15: two findings share a claim prefix over 60 chars but diverge later
# Regression for dedup keying on a 60-char claim prefix instead of the full
# normalized claim — these two must NOT collapse into one finding.
dir15=$(stage long-claim-prefix)
out15=$(bash "$SH" --from-dir "$dir15"); rc15=$?
echo "--- case 15: long-claim-prefix ---"
printf '%s\n' "$out15"

check "exits 0" test "$rc15" -eq 0
check "verdict is FINDINGS" grep -qx "ADVERSARIAL_REVIEW: FINDINGS" <<<"$out15"
check "both findings survive — dedup is on the full claim, not a 60-char prefix" \
  test "$(grep -c '^- \[P' <<<"$out15")" -eq 2
check "reader-a's claim is present" \
  grep -qF "logs nothing, so the failure is invisible to on-call" <<<"$out15"
check "reader-b's claim is present" \
  grep -qF "returns a fabricated success response to the caller" <<<"$out15"

# --- Case 16: --dir pointing inside the repository is refused ------------------
repo16=$(make_throwaway_repo dir-inside-repo)
cat > "$repo16/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
err16=$(cd "$repo16" && CODEX_BIN=true bash "$SH" --plan plan.json --base main --dir "$repo16/rundir" 2>&1); rc16=$?
echo "--- case 16: --dir inside the repository ---"
printf '%s\n' "$err16"
check "dir inside repo exits 2" test "$rc16" -eq 2
check "dir inside repo names the problem" \
  grep -qi "run directory must live outside the repository so it cannot dirty the tree" <<<"$err16"

# --- Case 17: a codex timeout kills the whole process group, not just codex ----
# The one live-ish case here: CODEX_BIN points at fixtures/fake-codex-hang.sh,
# a fake codex that backgrounds a marker-named `sleep 30` and then hangs
# itself, so a real --timeout has to fire. Proves run_angle's
# start_new_session + killpg reaps the whole group (subprocess.run's own
# timeout kill would leave the backgrounded sleep orphaned and running).
# Hermetic: no network, no real codex — skipped with a clear message if this
# platform lacks pgrep/process-group semantics.
if ! command -v pgrep >/dev/null 2>&1; then
  echo "--- case 17: timeout kills the process group ---"
  echo "  SKIP: pgrep not available on this system"
else
  repo17=$(make_throwaway_repo timeout-killpg)
  cat > "$repo17/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
  rundir17="$tmpdir/timeout-killpg-run.$$.${RANDOM:-0}"
  linkdir17="$tmpdir/timeout-killpg-links.$$.${RANDOM:-0}"
  mkdir -p "$linkdir17"
  marker17="killpgtest$$_${RANDOM:-0}"

  start17=$(date +%s)
  out17=$(cd "$repo17" && \
    CODEX_BIN="$FIXTURES/fake-codex-hang.sh" \
    ADV_TEST_SLEEP_MARKER="$marker17" \
    ADV_TEST_SLEEP_LINKDIR="$linkdir17" \
    bash "$SH" --plan plan.json --base main --dir "$rundir17" --timeout 2 2>&1)
  rc17=$?
  end17=$(date +%s)
  elapsed17=$((end17 - start17))
  echo "--- case 17: timeout kills the process group ---"
  printf '%s\n' "$out17"
  echo "  elapsed: ${elapsed17}s"

  check "finishes quickly despite the fake codex hanging" test "$elapsed17" -le 15
  check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out17"
  check "exits 4" test "$rc17" -eq 4
  check "the angle is marked UNPARSED(timeout)" \
    grep -qx "alpha: UNPARSED(timeout)" <<<"$out17"

  # Give the kill a brief moment to land, then confirm no leftover sleep.
  sleep 1
  if pgrep -f "sleep-$marker17" >/dev/null 2>&1; then
    echo "  FAIL: leftover 'sleep 30' process from this run is still running"
    fails=$((fails + 1))
    pkill -f "sleep-$marker17" 2>/dev/null || true
  else
    echo "  ok: no leftover 'sleep 30' process from this run"
  fi

  rm -rf "$rundir17" "$linkdir17"
fi

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

# --- Scheduling: read-only runs parallel, workspace-write runs serial ----------
# The live serialization itself (thread pool, then one-at-a-time with the
# clean-tree gate) needs a real git repo and isn't reachable offline; this
# unit-tests the pure split that decides it, directly in Python.
partition_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from adversarial_review import partition_angles

angles_by_id = {
    "a": {"execution": "read-only"},
    "b": {"execution": "workspace-write"},
    "c": {"execution": "read-only"},
    "d": {"execution": "workspace-write"},
    "e": {"execution": "read-only"},
}
angle_ids = ["a", "b", "c", "d", "e"]
parallel, serial = partition_angles(angle_ids, angles_by_id)

ok = parallel == ["a", "c", "e"] and serial == ["b", "d"]

all_ro = partition_angles(["a", "c", "e"], angles_by_id)
ok = ok and all_ro == (["a", "c", "e"], [])

all_ww = partition_angles(["b", "d"], angles_by_id)
ok = ok and all_ww == ([], ["b", "d"])

print("OK" if ok else f"MISMATCH: parallel={parallel} serial={serial}")
PYEOF
)
echo "--- partition_angles scheduling ---"
printf '%s\n' "$partition_check"
check "read-only/workspace-write split preserves plan order in each group" \
  test "$partition_check" = "OK"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails CHECK(S) FAILED"
fi
exit "$fails"
