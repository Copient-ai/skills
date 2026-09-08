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

# --- Case 5b: a required finding field is blank (empty or whitespace-only) -----
# Regression: findings.schema.json and validate_findings_json both require
# non-empty path/claim/evidence/reproduction (minLength + a non-space
# pattern in the schema; strip-and-check in the Python validator) — a
# whitespace-only "claim" must never be accepted as a hollow-but-valid
# finding.
dir5b=$(stage blank-fields)
out5b=$(bash "$SH" --from-dir "$dir5b" 2>/dev/null); rc5b=$?
echo "--- case 5b: blank-fields ---"
printf '%s\n' "$out5b"

check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out5b"
check "exits 4" test "$rc5b" -eq 4
check "the blank-claim angle names its cause" \
  grep -qx "blank: UNPARSED(schema)" <<<"$out5b"
check "the control angle still ran clean" \
  grep -qx "control: CLEAN" <<<"$out5b"

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

dir7f=$(stage bad-plan-base-int)
err7f=$(bash "$SH" --from-dir "$dir7f" 2>&1); rc7f=$?
echo "--- case 7f: base is an int, not a string ---"
printf '%s\n' "$err7f"
check "int base exits 2" test "$rc7f" -eq 2
check "int base names the problem" grep -qi "'base' must be a non-empty string" <<<"$err7f"

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

# --- Case 9b: residue triggers a compromised cascade for later write-capable --
# angles. compromised-cascade/ carries three angles in plan order — reader
# (read-only, CLEAN), writer (workspace-write, left residue — same as
# fixtures/residue/), writer2 (workspace-write, has only a
# writer2.skipped.txt marker: what run_write_capable_angles now leaves for
# an angle it never ran at all because an earlier one already compromised
# the tree). Exercises collect_angle_result's marker read, not the live
# cascade itself (see case 19b for that).
dir9b=$(stage compromised-cascade)
out9b=$(bash "$SH" --from-dir "$dir9b" 2>/dev/null); rc9b=$?
echo "--- case 9b: compromised-cascade ---"
printf '%s\n' "$out9b"

check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out9b"
check "exits 4" test "$rc9b" -eq 4
check "the residue angle is labeled UNPARSED(residue)" \
  grep -qx "writer: UNPARSED(residue)" <<<"$out9b"
check "the later write-capable angle is labeled UNPARSED(compromised)" \
  grep -qx "writer2: UNPARSED(compromised)" <<<"$out9b"
check "the read-only angle before it still ran clean" \
  grep -qx "reader: CLEAN" <<<"$out9b"
check "counts show 3 angles, 1 ran, 2 unparsed" \
  grep -qx "ANGLES=3  RAN=1  BLOCKED=0  UNPARSED=2" <<<"$out9b"
check "the residue angle's finding is still surfaced in the block" \
  grep -qF -- "- [P1] b.py:20" <<<"$out9b"

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

# --- Case 16b: a spawn failure on a live run clears any stale merged.json ------
# Regression: a reused --dir carrying a merged.json from an earlier
# invocation must never be mistaken for this run's own verdict when this run
# aborts on a spawn failure (exit 3) before ever writing a new one.
# fixtures/fake-codex-unspawnable is a real, executable file that isn't a
# valid program (no shebang, not a recognized binary format) — shutil.which
# finds it fine, but the OS refuses to exec it (Exec format error), which is
# the "codex could not be invoked at all" failure this exercises; a
# CODEX_BIN that simply doesn't exist (e.g. /nonexistent) would instead be
# caught earlier by main()'s own "codex CLI not found on PATH" check
# (exit 1), never reaching this path.
repo16b=$(make_throwaway_repo spawn-failure-stale-merged)
cat > "$repo16b/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
rundir16b="$tmpdir/spawn-failure-stale-merged-run.$$.${RANDOM:-0}"
mkdir -p "$rundir16b"
echo '{"version": 1, "verdict": "CLEAN", "counts": {}, "angles": [], "findings": []}' > "$rundir16b/merged.json"

err16b=$(cd "$repo16b" && CODEX_BIN="$FIXTURES/fake-codex-unspawnable" bash "$SH" --plan plan.json --base main --dir "$rundir16b" 2>&1); rc16b=$?
echo "--- case 16b: spawn failure clears a stale merged.json ---"
printf '%s\n' "$err16b"

check "spawn failure exits 3" test "$rc16b" -eq 3
check "spawn failure names the problem" grep -qi "codex could not be invoked" <<<"$err16b"
check "the stale merged.json was deleted, not left behind" test ! -f "$rundir16b/merged.json"

rm -rf "$rundir16b"

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

# --- Case 17b: a normal (non-timeout) codex exit still reaps its process group --
# fixtures/fake-codex-background-leak.sh exits 0 immediately after
# backgrounding a marker-named `sleep 30`, output redirected so it detaches.
# run_angle() must reap that leftover even though communicate() returned
# without a TimeoutExpired — and the angle's own result must still be judged
# by its out.json/status as usual (verdict CLEAN here), not by the leak.
if ! command -v pgrep >/dev/null 2>&1; then
  echo "--- case 17b: a normal exit still reaps the process group ---"
  echo "  SKIP: pgrep not available on this system"
else
  repo17b=$(make_throwaway_repo normal-exit-reap)
  cat > "$repo17b/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
  rundir17b="$tmpdir/normal-exit-reap-run.$$.${RANDOM:-0}"
  linkdir17b="$tmpdir/normal-exit-reap-links.$$.${RANDOM:-0}"
  mkdir -p "$linkdir17b"
  marker17b="normalexittest$$_${RANDOM:-0}"

  out17b=$(cd "$repo17b" && \
    CODEX_BIN="$FIXTURES/fake-codex-background-leak.sh" \
    ADV_TEST_SLEEP_MARKER="$marker17b" \
    ADV_TEST_SLEEP_LINKDIR="$linkdir17b" \
    bash "$SH" --plan plan.json --base main --dir "$rundir17b" 2>&1)
  rc17b=$?
  echo "--- case 17b: a normal exit still reaps the process group ---"
  printf '%s\n' "$out17b"

  check "exits 0" test "$rc17b" -eq 0
  check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out17b"
  check "the angle's own result is still judged by its out.json/status" \
    grep -qx "alpha: CLEAN" <<<"$out17b"
  check "a note about the terminated leftover background process is printed" \
    grep -qi "left 1 background process" <<<"$out17b"

  # Give the kill a brief moment to land, then confirm no leftover sleep.
  sleep 1
  if pgrep -f "sleep-$marker17b" >/dev/null 2>&1; then
    echo "  FAIL: leftover 'sleep 30' process from this run is still running"
    fails=$((fails + 1))
    pkill -f "sleep-$marker17b" 2>/dev/null || true
  else
    echo "  ok: no leftover 'sleep 30' process from this run"
  fi

  rm -rf "$rundir17b" "$linkdir17b"
fi

# --- Case 18: verdict FINDINGS with an empty findings array is never CLEAN -----
# Regression: a reviewer that mislabels verdict="FINDINGS" while reporting no
# findings at all is self-contradictory and must never be trusted as a clean
# (or even parseable) run.
dir18=$(stage findings-empty)
out18=$(bash "$SH" --from-dir "$dir18" 2>/dev/null); rc18=$?
echo "--- case 18: findings-empty ---"
printf '%s\n' "$out18"

check "verdict is UNPARSED (FINDINGS with no findings is never trusted)" \
  grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out18"
check "exits 4" test "$rc18" -eq 4
check "the empty-findings angle names its cause" \
  grep -qx "alpha: UNPARSED(schema)" <<<"$out18"
check "the control angle still ran clean" \
  grep -qx "beta: CLEAN" <<<"$out18"

# --- Case 19: a reused --dir clears an angle's stale artifacts before rerun ----
# Regression: stage a stale .residue.txt and a stale .out.json for 'alpha' in
# the run dir (as if left behind by an earlier, interrupted invocation), then
# rerun with the hanging fake codex under a short --timeout. The result must
# come from *this* run (a timeout), never from the leftover files.
if ! command -v pgrep >/dev/null 2>&1; then
  echo "--- case 19: stale artifacts are cleared before a reused --dir reruns ---"
  echo "  SKIP: pgrep not available on this system"
else
  repo19=$(make_throwaway_repo stale-artifacts)
  cat > "$repo19/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
  rundir19="$tmpdir/stale-artifacts-run.$$.${RANDOM:-0}"
  mkdir -p "$rundir19"
  printf 'M some/file.py\n' > "$rundir19/alpha.residue.txt"
  cat > "$rundir19/alpha.out.json" <<'EOF'
{"angle": "alpha", "verdict": "CLEAN", "summary": "stale run from an earlier invocation", "findings": []}
EOF
  linkdir19="$tmpdir/stale-artifacts-links.$$.${RANDOM:-0}"
  mkdir -p "$linkdir19"
  marker19="staletest$$_${RANDOM:-0}"

  out19=$(cd "$repo19" && \
    CODEX_BIN="$FIXTURES/fake-codex-hang.sh" \
    ADV_TEST_SLEEP_MARKER="$marker19" \
    ADV_TEST_SLEEP_LINKDIR="$linkdir19" \
    bash "$SH" --plan plan.json --base main --dir "$rundir19" --only alpha --timeout 2 2>&1)
  rc19=$?
  echo "--- case 19: stale artifacts are cleared before a reused --dir reruns ---"
  printf '%s\n' "$out19"

  check "exits 4" test "$rc19" -eq 4
  check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out19"
  check "the angle is marked UNPARSED(timeout), not residue or the stale JSON" \
    grep -qx "alpha: UNPARSED(timeout)" <<<"$out19"
  check "the stale summary never appears in the report" \
    bash -c '! grep -q "stale run from an earlier invocation" <<<"$1"' _ "$out19"
  check "the stale residue.txt was deleted before this run, not left behind" \
    test ! -f "$rundir19/alpha.residue.txt"
  check "the stale out.json was deleted before this run, not left behind" \
    test ! -f "$rundir19/alpha.out.json"

  sleep 1
  pkill -f "sleep-$marker19" 2>/dev/null || true
  rm -rf "$rundir19" "$linkdir19"
fi

# --- Case 19b: a dirty-tree skip clears an angle's stale artifacts first -------
# Regression: stage a stale writer.out.json/.status (verdict CLEAN, as if
# left behind by an earlier invocation of a reused --dir) and leave the
# checkout itself dirty before this run, so the dirty-tree gate fires. The
# skip must clear those stale files and write a 'writer.skipped.txt' marker
# — never let a later --from-dir re-merge of this same --dir read the old
# CLEAN out.json instead.
repo19b=$(make_throwaway_repo dirty-tree-stale)
cat > "$repo19b/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}]}
EOF
rundir19b="$tmpdir/dirty-tree-stale-run.$$.${RANDOM:-0}"
mkdir -p "$rundir19b"
cat > "$rundir19b/writer.out.json" <<'EOF'
{"angle": "writer", "verdict": "CLEAN", "summary": "stale run from an earlier invocation", "findings": []}
EOF
printf '0\n' > "$rundir19b/writer.status"
echo "uncommitted" > "$repo19b/dirty.txt"

out19b=$(cd "$repo19b" && CODEX_BIN=true bash "$SH" --plan plan.json --base main --dir "$rundir19b" 2>&1); rc19b=$?
echo "--- case 19b: dirty-tree skip clears stale artifacts ---"
printf '%s\n' "$out19b"

check "exits 4" test "$rc19b" -eq 4
check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out19b"
check "counts show one UNPARSED angle, none RAN" \
  grep -qx "ANGLES=1  RAN=0  BLOCKED=0  UNPARSED=1" <<<"$out19b"
check "the angle is marked UNPARSED(dirty-tree), not the stale CLEAN" \
  grep -qx "writer: UNPARSED(dirty-tree)" <<<"$out19b"
check "the stale summary never appears in the report" \
  bash -c '! grep -q "stale run from an earlier invocation" <<<"$1"' _ "$out19b"
check "the stale out.json was deleted, not left behind" \
  test ! -f "$rundir19b/writer.out.json"
check "the stale status was deleted, not left behind" \
  test ! -f "$rundir19b/writer.status"
check "a dirty-tree marker was written for the skipped angle" \
  grep -qx "dirty-tree" "$rundir19b/writer.skipped.txt"

rm -rf "$rundir19b"

# --- Case 20: --from-dir must never write merged.json into a real checkout -----
# Regression: pointed directly at fixtures/all-clean (part of this repo, not
# staged into the scratch tmpdir), the run must not dirty the tree — merged.json
# goes to a temp file instead, named by a MERGED= line in the report.
if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "--- case 20: --from-dir against a directory inside a real checkout ---"
  echo "  SKIP: this checkout of the skill is not itself a git repository"
else
  before20=$(git -C "$SCRIPT_DIR" status --porcelain)
  out20=$(bash "$SH" --from-dir "$FIXTURES/all-clean"); rc20=$?
  after20=$(git -C "$SCRIPT_DIR" status --porcelain)
  echo "--- case 20: --from-dir against a directory inside a real checkout ---"
  printf '%s\n' "$out20"

  check "exits 0" test "$rc20" -eq 0
  check "git status is unchanged by the run (merged.json was not written into the checkout)" \
    test "$before20" = "$after20"
  merged20=$(grep '^MERGED=' <<<"$out20" | sed 's/^MERGED=//')
  check "a MERGED= line was printed" test -n "$merged20"
  check "the MERGED= path exists" test -f "$merged20"
  check "merged.json was not created next to the fixture" \
    test ! -f "$FIXTURES/all-clean/merged.json"

  rm -f "$merged20" "$FIXTURES/all-clean/merged.json"
fi

# --- Case 21: multiline claim/evidence/reproduction render as one line each ----
# Regression: an embedded \r\n or \n in path/claim/evidence/reproduction must
# never introduce a bare continuation line into the compact block — each
# finding is exactly one '- [Pn] ...' line plus its evidence/reproduction lines.
# The fixture's 'multiline' angle also carries a multiline summary, and a
# second plain 'control' angle sits alongside it, so the SUMMARY section's
# one-line-per-angle contract is exercised across more than a single angle.
dir21=$(stage multiline-fields)
out21=$(bash "$SH" --from-dir "$dir21"); rc21=$?
echo "--- case 21: multiline-fields ---"
printf '%s\n' "$out21"

check "exits 0" test "$rc21" -eq 0
check "verdict is FINDINGS" grep -qx "ADVERSARIAL_REVIEW: FINDINGS" <<<"$out21"
check "counts show both angles ran" \
  grep -qx "ANGLES=2  RAN=2  BLOCKED=0  UNPARSED=0" <<<"$out21"
check "exactly one '- [P' line per finding" \
  test "$(grep -c '^- \[P' <<<"$out21")" -eq 2
check "exactly one 'evidence:' line per finding" \
  test "$(grep -c '^  evidence: ' <<<"$out21")" -eq 2
check "exactly one 'reproduction:' line per finding" \
  test "$(grep -c '^  reproduction: ' <<<"$out21")" -eq 2
check "the findings block has no lines beyond those 6 (no bare continuation lines)" \
  test "$(awk '/^--- FINDINGS ---$/{f=1;next} f && NF' <<<"$out21" | wc -l | tr -d ' ')" -eq 6
check "the multiline claim's embedded newline is escaped, not a bare line break" \
  grep -qF -- "Line one of the claim\\nLine two of the claim" <<<"$out21"
check "the CRLF evidence's embedded newline is escaped" \
  grep -qF -- "Evidence line one\\nEvidence line two" <<<"$out21"
check "the multiline reproduction's embedded newlines are escaped" \
  grep -qF -- "Repro step one\\nRepro step two\\nRepro step three" <<<"$out21"
check "the SUMMARY section has exactly one line per angle (2)" \
  test "$(awk '/^--- SUMMARY ---$/{f=1;next} /^--- FINDINGS ---$/{f=0} f && NF' <<<"$out21" | wc -l | tr -d ' ')" -eq 2
check "the multiline summary's embedded newline is escaped, not a bare continuation line" \
  grep -qF -- "multiline: Found two issues.\\nSecond line of the summary." <<<"$out21"
check "the control angle's plain summary line is present" \
  grep -qx "control: Control found nothing wrong." <<<"$out21"

# --- Case 22: SIGINT during a live run kills every reviewer process group ------
# fixtures/fake-codex-hang.sh backgrounds a marker-named `sleep 30` (which
# ignores SIGTERM, same as case 17) and then hangs itself well past any
# reasonable --timeout. Sends SIGINT to the runner ~2s in — once codex has
# actually been spawned and the main thread is blocked waiting on it — and
# expects a prompt exit 130 with no leftover process, proving the interrupt
# handler kills the whole tracked process group itself rather than relying on
# a --timeout that (deliberately, --timeout 300 here) will never fire in the
# time this test takes.
#
# The runner is launched via `bash -c '... && exec bash "$SH" ...'`, not a
# plain `bash "$SH" ... &`: adversarial-review.sh itself execs into
# adversarial_review.py, so once startup completes the whole chain shares one
# pid, and `exec`ing into it from bash -c (rather than relying on bash's
# unguaranteed last-command tail-call optimization for a `cd x && cmd`
# compound) makes that pid deterministic — it's the one `$!` captures and the
# one SIGINT is sent to.
if ! command -v pgrep >/dev/null 2>&1; then
  echo "--- case 22: SIGINT kills every reviewer process group ---"
  echo "  SKIP: pgrep not available on this system"
else
  repo22=$(make_throwaway_repo sigint-killpg)
  cat > "$repo22/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
  rundir22="$tmpdir/sigint-killpg-run.$$.${RANDOM:-0}"
  linkdir22="$tmpdir/sigint-killpg-links.$$.${RANDOM:-0}"
  mkdir -p "$linkdir22"
  marker22="siginttest$$_${RANDOM:-0}"
  stdout22="$tmpdir/sigint-killpg.stdout"
  stderr22="$tmpdir/sigint-killpg.stderr"

  CODEX_BIN="$FIXTURES/fake-codex-hang.sh" \
  ADV_TEST_SLEEP_MARKER="$marker22" \
  ADV_TEST_SLEEP_LINKDIR="$linkdir22" \
  bash -c 'cd "$1" && exec bash "$2" --plan plan.json --base main --dir "$3" --timeout 300' \
    _ "$repo22" "$SH" "$rundir22" >"$stdout22" 2>"$stderr22" &
  runner_pid=$!

  sleep 2
  kill -INT "$runner_pid" 2>/dev/null || true

  start22=$(date +%s)
  wait "$runner_pid"
  rc22=$?
  end22=$(date +%s)
  elapsed22=$((end22 - start22))

  echo "--- case 22: SIGINT kills every reviewer process group ---"
  cat "$stderr22"
  echo "  elapsed after SIGINT: ${elapsed22}s"

  check "exits 130" test "$rc22" -eq 130
  check "finishes within a few seconds of SIGINT (not the 300s --timeout)" \
    test "$elapsed22" -le 10
  check "stderr reports the interruption" grep -qi "interrupted" "$stderr22"

  # Give the kill a brief moment to land, then confirm no leftover sleep.
  sleep 1
  if pgrep -f "sleep-$marker22" >/dev/null 2>&1; then
    echo "  FAIL: leftover 'sleep 30' process from this run is still running"
    fails=$((fails + 1))
    pkill -f "sleep-$marker22" 2>/dev/null || true
  else
    echo "  ok: no leftover 'sleep 30' process from this run"
  fi

  rm -rf "$rundir22" "$linkdir22"
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

# --- An explicitly empty --only "" is a usage error, not "every angle" ---------
# Regression: parse_only used to treat only_arg == "" the same as --only never
# given at all (both falsy in Python), silently running every angle instead
# of rejecting the empty value as a usage error.
dir_only_empty=$(stage all-clean)
err_emptyonly=$(bash "$SH" --from-dir "$dir_only_empty" --only "" 2>&1); rc_emptyonly=$?
echo "--- case: --only \"\" (explicitly empty) ---"
printf '%s\n' "$err_emptyonly"
check "explicitly empty --only exits 2" test "$rc_emptyonly" -eq 2
check "explicitly empty --only names the problem" \
  grep -qi "no angle ids parsed" <<<"$err_emptyonly"

# --- Environment errors: missing --from-dir directory --------------------------
err_nodir=$(bash "$SH" --from-dir "$tmpdir/does-not-exist" 2>&1); rc_nodir=$?
echo "--- case: missing --from-dir directory ---"
printf '%s\n' "$err_nodir"
check "missing run directory exits 1" test "$rc_nodir" -eq 1

# --- Wrapper pre-scan recognizes --from-dir=PATH (equals form) too -------------
# Regression: the .sh dispatcher's own arg pre-scan matched only a
# space-separated "--from-dir PATH", so a single "--from-dir=PATH" token
# fell through to the default case and never set FROM_DIR — the wrapper
# then wrongly required CODEX_BIN to exist on PATH even though --from-dir
# mode needs no codex at all.
dir_eqform=$(stage all-clean)
out_eqform=$(CODEX_BIN=/nonexistent bash "$SH" --from-dir="$dir_eqform" 2>&1); rc_eqform=$?
echo "--- case: --from-dir=PATH (equals form) skips the codex-on-PATH check ---"
printf '%s\n' "$out_eqform"
check "equals-form --from-dir succeeds even with an unusable CODEX_BIN" \
  test "$rc_eqform" -eq 0
check "equals-form --from-dir still merges the fixture" \
  grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out_eqform"

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

# --- The resolved base is shell-quoted in the generated DIFF_COMMAND ------------
# Regression: a base containing shell metacharacters (however it got there —
# a hand-edited plan, an odd branch name) must not be pasted unquoted into
# the "git diff {{DIFF_COMMAND}}" a reviewer is told to run verbatim.
quote_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from adversarial_review import render_prompt

plan = {"promise": "Ship it.", "contracts": [], "invariants": []}
angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.", "evidence": "A concrete case."}
rendered = render_prompt("{{DIFF_COMMAND}}", plan, angle, "feature;echo")
expected = "git diff 'feature;echo'...HEAD"
print("OK" if rendered == expected else "MISMATCH:\n" + rendered)
PYEOF
)
echo "--- prompt rendering: base is shell-quoted in DIFF_COMMAND ---"
printf '%s\n' "$quote_check"
check "a base with shell metacharacters is quoted in the generated diff command" \
  test "$quote_check" = "OK"

# --- Prompt rendering is single-pass: inserted plan text is never re-scanned ---
# Regression: render_prompt used to substitute placeholders one at a time via
# repeated str.replace() calls over the *whole* running string, so a plan
# field's own text (promise, mandate, ...) that happened to contain a literal
# "{{MANDATE}}" would get replaced a second time by a later iteration. A
# single re.sub pass over the original template must never re-scan its own
# substitutions.
reinject_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from adversarial_review import render_prompt

plan = {"promise": "Ship it, handling the literal token {{MANDATE}} verbatim.",
        "contracts": [], "invariants": []}
angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.",
         "evidence": "A concrete case."}
rendered = render_prompt("promise={{PROMISE}} mandate={{MANDATE}}", plan, angle, "main")
expected = ("promise=Ship it, handling the literal token {{MANDATE}} verbatim. "
            "mandate=Find bugs.")
print("OK" if rendered == expected else "MISMATCH:\n" + rendered)
PYEOF
)
echo "--- prompt rendering: inserted plan text is never re-scanned (single pass) ---"
printf '%s\n' "$reinject_check"
check "a literal {{MANDATE}} inside inserted plan text survives untouched" \
  test "$reinject_check" = "OK"

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

# --- Python version gate: python3 must be 3.9+ ----------------------------------
# adversarial_review.py uses Path.is_relative_to (3.9+), so adversarial-review.sh
# gates on `python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'`
# before ever invoking the runner. This unit-tests that exact expression
# against whatever python3 is actually on PATH here — expected to pass, since
# the rest of this suite already depends on 3.9+ behavior (e.g. the runner's
# own use of is_relative_to). Simulating an old python3 well enough to
# exercise the *rejection* path in a hermetic shell fixture is impractical —
# faking sys.version_info convincingly needs a real, older CPython build, not
# a shell shim pretending to be python3 — so that path (the expression exits
# nonzero -> the wrapper prints a message and exits 1) is a direct five-line
# `cmd || { ...; exit 1; }`, the same idiom the two checks above it already
# use, and is verified by inspection rather than an automated negative test.
version_gate_check=$(python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; echo $?)
echo "--- python3 version gate check ---"
echo "version-gate expression exit code (0 = 3.9+, matches this environment's python3): $version_gate_check"
check "the version-gate expression exits 0 against this environment's python3 (3.9+)" \
  test "$version_gate_check" -eq 0
check "adversarial-review.sh itself runs successfully under this python3 (implicitly exercises the gate)" \
  bash -c 'bash "$1" --version >/dev/null 2>&1' _ "$SH"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails CHECK(S) FAILED"
fi
exit "$fails"
