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
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/adversarial-review-test.XXXXXX") || {
  echo "test-adversarial-review: mktemp -d failed" >&2
  exit 1
}
if [ -z "$tmpdir" ]; then
  echo "test-adversarial-review: mktemp -d returned an empty path" >&2
  exit 1
fi

# A second scratch root OUTSIDE every sandbox-writable root (tempfile.
# gettempdir()/$TMPDIR/tmp/var-tmp) -- main() now refuses an explicit --dir
# under any of them for a plan carrying a workspace-write angle (see item
# 2's --dir hardening; its own default, unaffected here, picks a directory
# under XDG_CACHE_HOME/~/.cache the same way). Every case below that passes
# an explicit --dir for such a plan builds it under $safe_tmpdir instead of
# $tmpdir. XDG_CACHE_HOME is pinned to a subdirectory of it, namespaced
# apart from "adversarial-review" itself (where a real run's own default
# selection -- see the "default run dir" case -- would land) and always a
# fresh, empty directory, so this suite never depends on, or leaves
# anything behind in, whatever XDG_CACHE_HOME/~/.cache already holds on the
# machine running it.
mkdir -p "$HOME/.cache"
safe_tmpdir=$(mktemp -d "$HOME/.cache/adversarial-review-test-safe.XXXXXX") || {
  echo "test-adversarial-review: mktemp -d (safe) failed" >&2
  exit 1
}
export XDG_CACHE_HOME="$safe_tmpdir/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"

trap 'rm -rf "$tmpdir" "$safe_tmpdir"' EXIT

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

# Regression: ANGLE_ID_RE was checked with .match(), and re's `$` matches
# just before a trailing newline as well as at the true end of string, so an
# id of "alpha\n" slipped through validation. Must be rejected by .fullmatch().
dir7g=$(stage bad-plan-id-newline)
err7g=$(bash "$SH" --from-dir "$dir7g" 2>&1); rc7g=$?
echo "--- case 7g: angle id with an embedded trailing newline ---"
printf '%s\n' "$err7g"
check "id with trailing newline exits 2" test "$rc7g" -eq 2
check "id with trailing newline names the problem" grep -qi "invalid angle id" <<<"$err7g"

# Regression: SKILL.md documents a 3-to-6 angle plan (drop a generic angle
# rather than pad the plan); validate_plan enforced no upper bound at all, so
# a malformed 7+ angle plan launched one paid codex pass per entry instead of
# failing fast at plan-validation time.
dir7h=$(stage bad-plan-too-many-angles)
err7h=$(bash "$SH" --from-dir "$dir7h" 2>&1); rc7h=$?
echo "--- case 7h: more than 6 angles ---"
printf '%s\n' "$err7h"
check "7-angle plan exits 2 (usage/plan-validation)" test "$rc7h" -eq 2
check "7-angle plan names the problem" grep -qi "more than the max of 6" <<<"$err7h"

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
rundir19b="$safe_tmpdir/dirty-tree-stale-run.$$.${RANDOM:-0}"
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

# --- Case 19c: git_status_porcelain sees untracked files under -----------------
# status.showUntrackedFiles=no
# Regression: a user-level (or repo-local) `git config status.showUntracked
# Files no` used to make plain `git status --porcelain` collapse untracked
# directories or omit untracked files, so a reviewer dropping a new file
# during a workspace-write angle could slip past both the clean-tree gate
# and the post-angle residue check unseen. git_status_porcelain now forces
# `--untracked-files=all` on the command line and `-c
# status.showUntrackedFiles=all` at the config layer (belt and suspenders),
# so this can't happen regardless of the ambient git config. Unit-tests the
# helper directly against a throwaway repo with that config set and one
# untracked file.
repo19c=$(make_throwaway_repo untracked-visible)
git -C "$repo19c" config status.showUntrackedFiles no
echo "new" > "$repo19c/untracked.txt"

untracked_check=$(python3 - "$SCRIPT_DIR" "$repo19c" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

status = ar.git_status_porcelain(sys.argv[2])
ok = "untracked.txt" in status
print("OK" if ok else f"MISMATCH: status={status!r}")
PYEOF
)
echo "--- case 19c: git_status_porcelain sees untracked files despite status.showUntrackedFiles=no ---"
printf '%s\n' "$untracked_check"
check "an untracked file is reported even under status.showUntrackedFiles=no" \
  test "$untracked_check" = "OK"

# --- Case 19d: a bad --angle-prompt on a reused --dir must not corrupt it ------
# Regression: main() used to clear merged.json and overwrite run_dir/plan.json
# with the new plan *before* validating --angle-prompt. A reused --dir whose
# previous invocation completed normally, re-run with a typo'd
# --angle-prompt, would exit on that typo only after plan.json had already
# been replaced (and merged.json deleted) but before the per-angle
# clear_stale_artifacts loop ran — leaving the new plan paired with the
# *previous* run's <angle>.status/<angle>.out.json. A later --from-dir on
# that directory would then merge the new (never-run) plan with the old
# angle outputs and could report a false verdict for a run that never
# happened. Every fallible input, --angle-prompt included, is now resolved
# before run_dir is touched at all, so this aborts before plan.json,
# merged.json, or any angle artifact is modified.
repo19d=$(make_throwaway_repo bad-angle-prompt-reuse)
rundir19d="$tmpdir/bad-angle-prompt-reuse-run.$$.${RANDOM:-0}"
mkdir -p "$rundir19d"
cat > "$rundir19d/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Mandate A — the plan that actually ran.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "Mandate A", "evidence": "e", "execution": "read-only"}]}
EOF
printf '0\n' > "$rundir19d/alpha.status"
cat > "$rundir19d/alpha.out.json" <<'EOF'
{"angle": "alpha", "verdict": "CLEAN", "summary": "the earlier valid run", "findings": []}
EOF
echo '{"version": 1, "verdict": "CLEAN", "counts": {}, "angles": [], "findings": []}' > "$rundir19d/merged.json"
expected_plan19d="$tmpdir/bad-angle-prompt-reuse-planA-expected.$$.${RANDOM:-0}.json"
cp "$rundir19d/plan.json" "$expected_plan19d"

planB19d="$tmpdir/bad-angle-prompt-reuse-planB.$$.${RANDOM:-0}.json"
cat > "$planB19d" <<'EOF'
{"version": 1, "base": "main", "promise": "Mandate B — never actually ran.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "Mandate B", "evidence": "e", "execution": "read-only"}]}
EOF

err19d=$(cd "$repo19d" && CODEX_BIN=true bash "$SH" --plan "$planB19d" --base main \
  --dir "$rundir19d" --angle-prompt "$tmpdir/no-such-angle-prompt-19d.md" 2>&1)
rc19d=$?
echo "--- case 19d: bad --angle-prompt on a reused --dir ---"
printf '%s\n' "$err19d"

check "bad --angle-prompt on live run exits 1 (environment error)" test "$rc19d" -eq 1
check "bad --angle-prompt names the problem" \
  grep -qi "no such angle prompt template" <<<"$err19d"
check "plan.json in the reused dir is untouched (still plan A, never overwritten with plan B)" \
  cmp -s "$rundir19d/plan.json" "$expected_plan19d"
check "plan.json does not carry plan B's promise" \
  bash -c '! grep -q "Mandate B" "$1"' _ "$rundir19d/plan.json"
check "the earlier run's alpha.status is untouched" \
  test "$(cat "$rundir19d/alpha.status")" = "0"
check "the earlier run's alpha.out.json is untouched" \
  grep -q "the earlier valid run" "$rundir19d/alpha.out.json"
check "the earlier run's merged.json was not cleared" test -f "$rundir19d/merged.json"

out19d=$(bash "$SH" --from-dir "$rundir19d" 2>&1); rc19d_merge=$?
echo "--- case 19d: --from-dir after the failed reuse reflects the untouched, earlier run ---"
printf '%s\n' "$out19d"
check "--from-dir exits 0" test "$rc19d_merge" -eq 0
check "--from-dir reports CLEAN for the actual (plan A) run that happened, not a false verdict for plan B" \
  grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out19d"
check "--from-dir's summary is the earlier run's own, not something implying plan B ran" \
  grep -qF "the earlier valid run" <<<"$out19d"

rm -rf "$rundir19d"

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
out21_file="$tmpdir/case21-raw.$$.${RANDOM:-0}.txt"
bash "$SH" --from-dir "$dir21" >"$out21_file"; rc21=$?
out21=$(cat "$out21_file")
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

# Regression: escape_block_text only ever collapsed CR/LF — an ESC or NUL
# embedded in a finding field reached the block as a raw byte, invisible or
# terminal-active. The fixture's finding 1 claim now also carries a real ESC
# (0x1b) and a real NUL (0x00), embedded via JSON's own escape sequences
# (see multiline.out.json), so this exercises the actual control
# characters, not their textual names. Checked at the byte level, not
# through the $out21 shell variable — a raw NUL can't survive a bash
# command substitution intact, which would mask rather than catch a
# regression here.
check "the ESC control character is escaped as \\x1b, not passed through raw" \
  grep -qF -- '\x1b' <<<"$out21"
check "the NUL control character is escaped as \\x00, not passed through raw" \
  grep -qF -- '\x00' <<<"$out21"
control_byte_check21=$(python3 - "$out21_file" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
bad = [hex(b) for b in data if (b < 0x20 and b not in (0x09, 0x0a)) or b == 0x7f]
print("OK" if not bad else "BAD: " + repr(bad))
PYEOF
)
check "no raw control byte (below 0x20 sans tab/newline, or 0x7f) leaks into the block" \
  test "$control_byte_check21" = "OK"

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

# --- Case 22b: the interrupt handler waits out an open spawn/track window ------
# Regression: a signal landing between Popen() returning and _track_proc()
# registering the new process could let the handler's snapshot of _LIVE_PROCS
# run before that process was ever registered in it, leaking the process past
# os._exit. _wait_for_in_flight closes this by having the handler (via
# _kill_all_and_exit) wait until the _IN_FLIGHT sentinel list is empty, or 2s
# pass, before it ever snapshots. Drives _kill_all_and_exit directly — with
# an injected exit_fn so this test process doesn't actually exit — against a
# harness that holds _IN_FLIGHT non-empty for 0.5s from a background thread,
# and asserts the wait actually observed that clear rather than returning
# immediately (ignoring _IN_FLIGHT entirely) or blocking for the full 2s
# timeout regardless (also wrong, just less visibly so at 0.5s).
inflight_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys, threading, time
sys.path.insert(0, sys.argv[1])
import adversarial_review as adv

adv._IN_FLIGHT.append(object())

def clear_after(delay):
    time.sleep(delay)
    adv._IN_FLIGHT.clear()

t = threading.Thread(target=clear_after, args=(0.5,))
t.start()

exits = []
start = time.monotonic()
adv._kill_all_and_exit(exit_fn=lambda code: exits.append(code))
elapsed = time.monotonic() - start
t.join()

ok = exits == [130] and not adv._IN_FLIGHT and 0.5 <= elapsed < 2.5
print("OK" if ok else f"MISMATCH: exits={exits} elapsed={elapsed} in_flight={adv._IN_FLIGHT}")
PYEOF
)
echo "--- case 22b: the interrupt handler waits out an open spawn/track window ---"
printf '%s\n' "$inflight_check"
check "the wait observed the in-flight list clear at ~0.5s (0.5s <= elapsed < 2.5s)" \
  test "$inflight_check" = "OK"

# --- Case 22c: SIGINT during a hanging workspace-write angle -------------------
# The serial-phase sibling of case 22. Regression: run_write_capable_angles
# used to run inline on the main thread, so a SIGINT landing inside
# run_angle's own _IN_FLIGHT window (see that comment, and the one on the
# serial ThreadPoolExecutor in main()) would preempt the very main-thread
# frame that was about to finish registering the process -- the interrupt
# handler's own _wait_for_in_flight wait could then only ever be satisfied
# by timing out (2s), never by real forward progress, since the thing it
# was waiting on was itself, one frame further down a stack that couldn't
# resume until the handler returned. The serial phase now runs on its own
# dedicated worker thread, so this must behave exactly like case 22: a
# single workspace-write angle using fake-codex-hang.sh (same fixture,
# same marker-named backgrounded `sleep 30` that ignores SIGTERM), SIGINT
# sent once codex has actually been spawned, and a prompt exit 130 with no
# leftover process -- well inside the 300s --timeout that must never be the
# thing that actually ends this run.
if ! command -v pgrep >/dev/null 2>&1; then
  echo "--- case 22c: SIGINT during a hanging workspace-write angle ---"
  echo "  SKIP: pgrep not available on this system"
else
  repo22c=$(make_throwaway_repo sigint-killpg-serial)
  # The plan lives outside repo22c (not inside it, unlike most --plan cases
  # above): a workspace-write angle's dirty-tree gate (run_write_capable_
  # angles) requires a clean tree before it runs at all, and an untracked
  # plan.json sitting in the checkout would itself now correctly trip that
  # gate (see case 19c) before SIGINT ever gets a chance to land.
  plan22c="$tmpdir/sigint-killpg-serial-plan.$$.${RANDOM:-0}.json"
  cat > "$plan22c" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}]}
EOF
  rundir22c="$safe_tmpdir/sigint-killpg-serial-run.$$.${RANDOM:-0}"
  linkdir22c="$tmpdir/sigint-killpg-serial-links.$$.${RANDOM:-0}"
  mkdir -p "$linkdir22c"
  marker22c="sigintserialtest$$_${RANDOM:-0}"
  stdout22c="$tmpdir/sigint-killpg-serial.stdout"
  stderr22c="$tmpdir/sigint-killpg-serial.stderr"

  CODEX_BIN="$FIXTURES/fake-codex-hang.sh" \
  ADV_TEST_SLEEP_MARKER="$marker22c" \
  ADV_TEST_SLEEP_LINKDIR="$linkdir22c" \
  bash -c 'cd "$1" && exec bash "$2" --plan "$4" --base main --dir "$3" --timeout 300' \
    _ "$repo22c" "$SH" "$rundir22c" "$plan22c" >"$stdout22c" 2>"$stderr22c" &
  runner_pid=$!

  sleep 2
  kill -INT "$runner_pid" 2>/dev/null || true

  start22c=$(date +%s)
  wait "$runner_pid"
  rc22c=$?
  end22c=$(date +%s)
  elapsed22c=$((end22c - start22c))

  echo "--- case 22c: SIGINT during a hanging workspace-write angle ---"
  cat "$stderr22c"
  echo "  elapsed after SIGINT: ${elapsed22c}s"

  check "exits 130" test "$rc22c" -eq 130
  check "finishes within a few seconds of SIGINT (not the 300s --timeout)" \
    test "$elapsed22c" -le 10
  check "stderr reports the interruption" grep -qi "interrupted" "$stderr22c"

  # Give the kill a brief moment to land, then confirm no leftover sleep.
  sleep 1
  if pgrep -f "sleep-$marker22c" >/dev/null 2>&1; then
    echo "  FAIL: leftover 'sleep 30' process from this run is still running"
    fails=$((fails + 1))
    pkill -f "sleep-$marker22c" 2>/dev/null || true
  else
    echo "  ok: no leftover 'sleep 30' process from this run"
  fi

  rm -rf "$rundir22c" "$linkdir22c"
fi

# --- Case 23: dir_in_git_repo fails closed when git cannot be run --------------
# Regression: dir_in_git_repo returned False -- "not in a repo, safe to write
# merged.json in place" -- whenever `git rev-parse` itself could not even be
# run (e.g. no git on PATH), indistinguishable from a real, confident "not a
# repo" answer. It must fail closed instead: a check that never ran means the
# question was never answered. That now applies uniformly to every directory
# resolve_merged_json_path considers -- the staged fixture AND every
# candidate temp directory it might divert into (see case 23f) -- so with
# git entirely unavailable, none of them can be confirmed safe and the run
# must refuse to guess (exit 1) rather than pick one anyway. Invokes
# adversarial_review.py directly rather than through adversarial-review.sh,
# whose own preflight needs `dirname` on PATH too; a staged fixture (not
# itself a git repo) proves the failure comes from git being unusable, not
# from the directory actually being inside one.
dir23=$(stage all-clean)
nogitbin23="$tmpdir/nogit-bin.$$.${RANDOM:-0}"
mkdir -p "$nogitbin23"
ln -s "$(command -v python3)" "$nogitbin23/python3"
out23=$(PATH="$nogitbin23" python3 "$PY" --from-dir "$dir23" 2>&1); rc23=$?
echo "--- case 23: dir_in_git_repo fails closed when git is unavailable ---"
printf '%s\n' "$out23"

check "exits 1 (no candidate directory can be confirmed safe without git)" \
  test "$rc23" -eq 1
check "names the problem" grep -qi "cannot find a temp directory outside every git checkout" <<<"$out23"
check "merged.json was not written into the staged fixture dir" \
  test ! -f "$dir23/merged.json"

# --- Case 23b: an inconclusive git probe (permission denied) still diverts ----
# Regression: dir_in_git_repo used to treat ANY nonzero `git rev-parse` exit
# as a confident "not a repo" (safe to write merged.json in place) as long as
# git itself was runnable at all -- conflating a real "not a repo" answer
# with a probe that never actually answered the question. A directory git
# cannot `cd` into (mode 000) reproduces exactly that: git's own message is
# "fatal: cannot change to '...': Permission denied", which does NOT match
# the canonical "...(or any of the parent directories): .git" git prints
# when a directory is genuinely outside any repo (case 23c) -- so this must
# fail closed, the same as case 23's git-unavailable probe. (A bad GIT_DIR
# used to reproduce this same kind of inconclusive error, but
# dir_in_git_repo now deliberately scrubs GIT_DIR from the probe's own
# environment -- see case 23d -- so a caller-set GIT_DIR can no longer reach
# it at all; permission denial is a real fact about the directory itself,
# not an environment variable, so the scrub can't neutralize it.)
# Unit-tests dir_in_git_repo directly rather than through --from-dir end to
# end: mode 000 also blocks the tool's own earlier reads (plan.json, angle
# outputs) inside that directory, which would fail the run before ever
# reaching this check.
if [ "$(id -u)" = "0" ]; then
  echo "--- case 23b: dir_in_git_repo diverts on an inconclusive git probe (permission denied) ---"
  echo "  SKIP: running as root, permission bits don't block access"
else
  dir23b="$tmpdir/noperm23b.$$.${RANDOM:-0}"
  mkdir -p "$dir23b"
  chmod 000 "$dir23b"
  probe23b=$(python3 - "$SCRIPT_DIR" "$dir23b" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

print(ar.dir_in_git_repo(sys.argv[2]))
PYEOF
)
  chmod 755 "$dir23b"
  echo "--- case 23b: dir_in_git_repo diverts on an inconclusive git probe (permission denied) ---"
  echo "  dir_in_git_repo result: $probe23b"
  check "an inconclusive probe (permission denied, not the canonical message) fails closed to True" \
    test "$probe23b" = "True"
  rm -rf "$dir23b"
fi

# --- Case 23c: a directory genuinely outside any repo writes in place ----------
# The other half of case 23b: no GIT_DIR override, and the staged fixture
# really is outside any git working tree (a plain scratch tmpdir), so
# dir_in_git_repo's probe gets the canonical "not a git repository (or any of
# the parent directories)" answer and merged.json lands at <dir>/merged.json
# in place -- no MERGED= diversion line at all.
dir23c=$(stage all-clean)
out23c=$(python3 "$PY" --from-dir "$dir23c" 2>&1); rc23c=$?
echo "--- case 23c: a directory genuinely outside any repo writes merged.json in place ---"
printf '%s\n' "$out23c"

check "exits 0" test "$rc23c" -eq 0
check "no MERGED= diversion line was printed" \
  bash -c '! grep -q "^MERGED=" <<<"$1"' _ "$out23c"
check "merged.json was written in place" test -f "$dir23c/merged.json"

# --- Case 23d: a hostile GIT_CEILING_DIRECTORIES can't fool dir_in_git_repo ----
# Regression: dir_in_git_repo used to run its git probe with whatever
# environment the caller happened to have. GIT_CEILING_DIRECTORIES pointed
# at (or above) the directory being checked stops git's own upward search
# before it ever reaches the real .git, so the probe got back the same
# canonical "not a git repository (or any of the parent directories)"
# message a directory genuinely outside any repo would produce (case 23c)
# -- and merged.json was wrongly written in place. dir_in_git_repo now (a)
# scrubs every discovery-altering GIT_* variable, GIT_CEILING_DIRECTORIES
# included, from the probe's own environment, and (b) independently walks
# path's ancestors for a .git entry -- either signal alone is enough here.
# Run against fixtures/all-clean (part of this repo, not staged into the
# scratch tmpdir -- see case 20) with GIT_CEILING_DIRECTORIES pointed at
# the fixture's own parent, which reproduces the bug (verified directly:
# `GIT_CEILING_DIRECTORIES=.../fixtures git -C .../fixtures/all-clean
# rev-parse --is-inside-work-tree` exits 128 with the canonical message,
# even though all-clean sits squarely inside this repo).
if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "--- case 23d: a hostile GIT_CEILING_DIRECTORIES can't fool dir_in_git_repo ---"
  echo "  SKIP: this checkout of the skill is not itself a git repository"
else
  out23d=$(GIT_CEILING_DIRECTORIES="$FIXTURES" python3 "$PY" --from-dir "$FIXTURES/all-clean" 2>&1); rc23d=$?
  echo "--- case 23d: a hostile GIT_CEILING_DIRECTORIES can't fool dir_in_git_repo ---"
  printf '%s\n' "$out23d"

  check "exits 0" test "$rc23d" -eq 0
  merged23d=$(grep '^MERGED=' <<<"$out23d" | sed 's/^MERGED=//')
  check "a MERGED= line was printed (still diverted, not fooled by GIT_CEILING_DIRECTORIES)" \
    test -n "$merged23d"
  check "the MERGED= path exists" test -f "$merged23d"
  check "merged.json was not created next to the fixture" \
    test ! -f "$FIXTURES/all-clean/merged.json"

  rm -f "$merged23d" "$FIXTURES/all-clean/merged.json"
fi

# --- Case 23e: a worktree defined only by GIT_DIR/GIT_WORK_TREE env vars diverts
# Regression: dir_in_git_repo's git probe deliberately scrubs GIT_DIR/
# GIT_WORK_TREE (see case 23d) so a stray leftover value from an unrelated
# outer caller can't make an ordinary directory look like it's inside a
# repo. But that same scrub blinds it to a directory that IS a real work
# tree right now, defined ONLY by those two variables -- a bare repository
# elsewhere, pointed at an otherwise plain directory that carries no .git
# entry of its own anywhere in its ancestry (so the filesystem-walk signal,
# _ancestor_has_dotgit, can't see it either). A probe run with the ambient
# environment left intact is the only signal that can see this, so
# dir_in_git_repo now runs the probe twice -- once scrubbed, once not --
# and reports "inside" if either does. Verified directly with git first
# (not just assumed): `GIT_DIR=<bare>.git GIT_WORK_TREE=<plain> git -C
# <plain> rev-parse --is-inside-work-tree` really does print "true".
dir23e="$tmpdir/bare-worktree-plain.$$.${RANDOM:-0}"
mkdir -p "$dir23e"
baregit23e="$tmpdir/bare-worktree.$$.${RANDOM:-0}.git"
git init -q --bare "$baregit23e"
probe23e=$(GIT_DIR="$baregit23e" GIT_WORK_TREE="$dir23e" python3 - "$SCRIPT_DIR" "$dir23e" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

print(ar.dir_in_git_repo(sys.argv[2]))
PYEOF
)
echo "--- case 23e: dir_in_git_repo diverts for a GIT_DIR/GIT_WORK_TREE-only worktree ---"
echo "  dir_in_git_repo result: $probe23e"
check "a directory that is a work tree only via env vars is reported inside" \
  test "$probe23e" = "True"
rm -rf "$dir23e" "$baregit23e"

# --- Case 23f: TMPDIR pointing inside a checkout falls back to /tmp, /var/tmp -
# Regression: resolve_merged_json_path assumed tempfile.gettempdir() was
# always a safe place to divert merged.json to, but gettempdir() honors
# TMPDIR -- which can itself point inside a checkout (including the very
# one being diverted away from). Each candidate is now verified with
# dir_in_git_repo before use, falling back from tempfile.gettempdir() to
# /tmp to /var/tmp. Sets TMPDIR to a directory inside a throwaway repo and
# points --from-dir at a fixture staged inside that SAME repo, so the naive
# first candidate (TMPDIR) is itself inside a checkout; the resulting
# MERGED= path must land outside the repo entirely (in practice /tmp or
# /var/tmp, both real directories on every platform this suite targets).
repo23f=$(make_throwaway_repo tmpdir-inside-repo)
fixturedir23f="$repo23f/from-dir-target"
cp -R "$FIXTURES/all-clean" "$fixturedir23f"
faketmp23f="$repo23f/faketmp"
mkdir -p "$faketmp23f"

out23f=$(TMPDIR="$faketmp23f" python3 "$PY" --from-dir "$fixturedir23f" 2>&1); rc23f=$?
echo "--- case 23f: TMPDIR inside a checkout falls back to /tmp or /var/tmp ---"
printf '%s\n' "$out23f"

check "exits 0" test "$rc23f" -eq 0
merged23f=$(grep '^MERGED=' <<<"$out23f" | sed 's/^MERGED=//')
check "a MERGED= line was printed" test -n "$merged23f"
check "the MERGED= path exists" test -f "$merged23f"
check "merged.json was not written under the hostile TMPDIR (inside the repo)" \
  bash -c '[[ "$1" != "$2"/* ]]' _ "$merged23f" "$faketmp23f"
check "merged.json was not written next to the staged fixture" \
  test ! -f "$fixturedir23f/merged.json"
check "merged.json landed under /tmp or /var/tmp, not some other surprise path" \
  bash -c '[[ "$1" == /tmp/* || "$1" == /private/tmp/* || "$1" == /var/tmp/* || "$1" == /private/var/tmp/* ]]' _ "$merged23f"

rm -f "$merged23f"

# --- Case 23g: dir_in_git_repo's git probe is locale-stable ---------------------
# Regression: the "not a git repository (or any of the parent directories)"
# match in _git_probe_inside_work_tree is the literal English string git
# prints -- a localized ambient LANG/LC_ALL (a caller's shell, a CI runner
# set to e.g. de_DE.UTF-8) would make git emit a translated fatal: message
# instead, so the match would silently miss and a genuine "outside any
# repo" directory would fail open to "possibly inside a checkout" (True)
# instead of the correct False. The probe now pins LC_ALL=C/LANG=C in the
# subprocess env it runs with, on a copy, regardless of the caller's own
# environment. /tmp is not inside any git repo, so with git available this
# must report False either way -- the point of this test is that a
# de_DE.UTF-8 LANG exported in the *caller's* environment cannot flip that
# answer.
if ! command -v git >/dev/null 2>&1; then
  echo "--- case 23g: dir_in_git_repo is locale-stable ---"
  echo "  SKIP: git not available"
else
  probe23g=$(LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

print(ar.dir_in_git_repo("/tmp"))
PYEOF
)
  echo "--- case 23g: dir_in_git_repo is locale-stable under a localized caller LANG ---"
  echo "  dir_in_git_repo(/tmp) result: $probe23g"
  check "/tmp reports outside any repo (False) even with LANG=de_DE.UTF-8 exported" \
    test "$probe23g" = "False"
fi

# --- Case 24: stale artifacts are cleared for every selected angle up front ----
# Regression: clear_stale_artifacts(aid, run_dir) ran at the top of run_angle
# itself, so under --jobs 1 a queued (not-yet-started) angle kept whatever
# .out.json an earlier invocation of this same --dir had left, right up until
# an interrupt ended the run before that angle's own worker turn ever came.
# Reuses fake-codex-hang.sh (see case 22): with a single worker, angle 1
# hangs well past the SIGINT this test sends while angles 2 and 3 never start
# at all -- proving their stale artifacts can only have been cleared eagerly,
# not lazily inside a run_angle call that, for them, never happened.
if ! command -v pgrep >/dev/null 2>&1; then
  echo "--- case 24: stale artifacts cleared eagerly, not lazily per worker ---"
  echo "  SKIP: pgrep not available on this system"
else
  repo24=$(make_throwaway_repo stale-artifacts-eager-clear)
  cat > "$repo24/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "gamma", "title": "Gamma", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF
  rundir24="$tmpdir/stale-clear-run.$$.${RANDOM:-0}"
  linkdir24="$tmpdir/stale-clear-links.$$.${RANDOM:-0}"
  mkdir -p "$rundir24" "$linkdir24"
  for aid24 in alpha beta gamma; do
    printf '{"angle": "%s", "verdict": "CLEAN", "summary": "stale", "findings": []}' "$aid24" \
      > "$rundir24/$aid24.out.json"
    printf '0\n' > "$rundir24/$aid24.status"
  done
  marker24="staleclear$$_${RANDOM:-0}"
  stdout24="$tmpdir/stale-clear.stdout"
  stderr24="$tmpdir/stale-clear.stderr"

  CODEX_BIN="$FIXTURES/fake-codex-hang.sh" \
  ADV_TEST_SLEEP_MARKER="$marker24" \
  ADV_TEST_SLEEP_LINKDIR="$linkdir24" \
  bash -c 'cd "$1" && exec bash "$2" --plan plan.json --base main --dir "$3" --jobs 1 --timeout 2' \
    _ "$repo24" "$SH" "$rundir24" >"$stdout24" 2>"$stderr24" &
  runner_pid=$!

  sleep 1
  kill -INT "$runner_pid" 2>/dev/null || true
  wait "$runner_pid"
  rc24=$?

  echo "--- case 24: stale artifacts cleared eagerly, not lazily per worker ---"
  cat "$stderr24"

  check "exits 130" test "$rc24" -eq 130
  for aid24 in alpha beta gamma; do
    check "no stale $aid24.out.json remains" test ! -f "$rundir24/$aid24.out.json"
  done

  sleep 1
  pkill -f "sleep-$marker24" 2>/dev/null || true
  rm -rf "$rundir24" "$linkdir24"
fi

# --- Case 25: --print-base resolves remote-first, matching resolve_base -------
# Regression: plan-prompt.md told the planner to diff against a raw branch
# name, while the runner resolves it remote-first (origin/<base>, then
# <remote>/<base>, then <base>) -- the two could diff against different
# refs whenever a local branch has fallen behind its remote-tracking
# counterpart. --print-base exposes the runner's own resolve_base so the
# planner can ask it directly instead of reimplementing the rule. Builds a
# repo whose local 'main' is deliberately stale (behind origin/main, by
# committing on a clone and pushing back) and confirms --print-base prints
# the fully-qualified "refs/remotes/origin/main", not the stale local ref
# (nor the unqualified "origin/main" shorthand — see case 25d for why that
# distinction matters).
repo25="$tmpdir/print-base.$$.${RANDOM:-0}"
mkdir -p "$repo25"
git init -q -b main "$repo25"
git -C "$repo25" config user.email "test@example.com"
git -C "$repo25" config user.name "Test"
echo base > "$repo25/f.txt"
git -C "$repo25" add -A
git -C "$repo25" commit -q -m base

remote25="$tmpdir/print-base-remote.$$.${RANDOM:-0}.git"
git init -q --bare "$remote25"
git -C "$repo25" remote add origin "$remote25"
git -C "$repo25" push -q origin main

work25="$tmpdir/print-base-work.$$.${RANDOM:-0}"
git clone -q "$remote25" "$work25"
git -C "$work25" config user.email "test@example.com"
git -C "$work25" config user.name "Test"
echo "remote moved on" >> "$work25/f.txt"
git -C "$work25" commit -qam "remote moves ahead"
git -C "$work25" push -q origin main

# repo25's own remote-tracking origin/main now reflects the advanced
# remote; its local 'main' branch is untouched by fetch, so it stays stale.
git -C "$repo25" fetch -q origin

local_sha25=$(git -C "$repo25" rev-parse main)
origin_sha25=$(git -C "$repo25" rev-parse origin/main)

out25=$(cd "$repo25" && CODEX_BIN=true bash "$SH" --print-base --base main 2>&1); rc25=$?
echo "--- case 25: --print-base resolves remote-first ---"
printf '%s\n' "$out25"

check "the local branch really is stale (differs from origin/main)" \
  test "$local_sha25" != "$origin_sha25"
check "exits 0" test "$rc25" -eq 0
check "--print-base prints the fully-qualified refs/remotes/origin/main, not the stale local branch" \
  test "$out25" = "refs/remotes/origin/main"

# --- Case 25b: --print-base without --base is a usage error --------------------
err25b=$(CODEX_BIN=true bash "$SH" --print-base 2>&1); rc25b=$?
echo "--- case 25b: --print-base with no --base ---"
printf '%s\n' "$err25b"
check "missing --base exits 2" test "$rc25b" -eq 2
check "missing --base names the problem" grep -qi -- "--print-base requires --base" <<<"$err25b"

# --- Case 25c: resolve_base checks the remote-ref namespace, not a same- ------
# --- named local branch --------------------------------------------------------
# Regression: resolve_base used to hardcode "origin/<base>" as a candidate
# and verify it with a bare `git rev-parse --verify --quiet origin/<base>`.
# git's own ref disambiguation (gitrevisions(7)) checks refs/heads/<name>
# before refs/remotes/<name>, so a *local* branch literally named
# "origin/main" would satisfy that check even with no "origin" remote
# configured at all -- resolving to the wrong ref entirely. Builds a repo
# with a local branch named "origin/main" (no remote, so no real
# refs/remotes/origin/main exists) and a real local "main", and confirms
# --print-base --base main correctly falls through to the fully-qualified
# "refs/heads/main" rather than being fooled by the decoy branch name.
repo25c="$tmpdir/remote-ref-namespace.$$.${RANDOM:-0}"
mkdir -p "$repo25c"
git init -q -b main "$repo25c"
git -C "$repo25c" config user.email "test@example.com"
git -C "$repo25c" config user.name "Test"
echo base > "$repo25c/f.txt"
git -C "$repo25c" add -A
git -C "$repo25c" commit -q -m base
git -C "$repo25c" branch "origin/main"

out25c=$(cd "$repo25c" && CODEX_BIN=true bash "$SH" --print-base --base main 2>&1); rc25c=$?
echo "--- case 25c: resolve_base is not fooled by a local branch named like a remote ---"
printf '%s\n' "$out25c"

check "exits 0" test "$rc25c" -eq 0
check "--print-base prints refs/heads/main, not the decoy 'origin/main' branch" \
  test "$out25c" = "refs/heads/main"

# --- Case 25d: a qualified base survives a same-named decoy local branch ------
# Regression: resolve_base used to verify the remote candidate through the
# fully-qualified refs/remotes/<remote>/<base> path but then RETURN the bare
# "<remote>/<base>" shorthand -- correct verification, wrong value handed
# downstream. git's own ref disambiguation (gitrevisions(7)) checks
# refs/heads/<name> before refs/remotes/<name>, so a bare "origin/main"
# resolved fresh by a downstream `git diff` or the rendered prompt would hit
# a *local* branch literally named "origin/main" instead of the remote-
# tracking ref resolve_base actually verified, whenever both exist. Builds
# a repo with a REAL refs/remotes/origin/main (a genuine bare-remote push)
# sitting behind HEAD, AND a decoy local branch literally named
# "origin/main" built identical to HEAD (so a diff against the decoy comes
# back empty -- the exact "looks clean" failure mode the shorthand bug
# produced). --print-base must print the fully-qualified
# "refs/remotes/origin/main", and a live run must diff non-empty and carry
# that same qualified ref into the rendered prompt -- proving the runner's
# own diff used it too, not a fresh unqualified re-resolution.
repo25d="$tmpdir/qualified-vs-decoy.$$.${RANDOM:-0}"
mkdir -p "$repo25d"
git init -q -b main "$repo25d"
git -C "$repo25d" config user.email "test@example.com"
git -C "$repo25d" config user.name "Test"
echo base > "$repo25d/f.txt"
git -C "$repo25d" add -A
git -C "$repo25d" commit -q -m base

remote25d="$tmpdir/qualified-vs-decoy-remote.$$.${RANDOM:-0}.git"
git init -q --bare "$remote25d"
git -C "$repo25d" remote add origin "$remote25d"
git -C "$repo25d" push -q origin main
git -C "$repo25d" fetch -q origin

# HEAD moves ahead of the just-pushed origin/main -- the remote-tracking
# ref stays behind, at the base commit.
echo "ahead of origin" >> "$repo25d/f.txt"
git -C "$repo25d" commit -qam "HEAD moves ahead of origin/main"

# The decoy: a LOCAL branch literally named "origin/main", built at HEAD's
# current (ahead) commit -- so a diff against it comes back empty.
git -C "$repo25d" branch "origin/main"

# The fully-qualified path, not bare "origin/main" -- once the decoy branch
# below exists, the bare form is itself ambiguous (git warns and picks one),
# which would silently corrupt this very sanity check with the same bug
# this case exists to catch.
origin_sha25d=$(git -C "$repo25d" rev-parse refs/remotes/origin/main)
head_sha25d=$(git -C "$repo25d" rev-parse HEAD)
decoy_sha25d=$(git -C "$repo25d" rev-parse refs/heads/origin/main)

out25d=$(cd "$repo25d" && CODEX_BIN=true bash "$SH" --print-base --base main 2>&1); rc25d=$?
echo "--- case 25d: --print-base survives a same-named decoy local branch ---"
printf '%s\n' "$out25d"

check "setup: the remote-tracking ref is really behind HEAD" \
  test "$origin_sha25d" != "$head_sha25d"
check "setup: the decoy local branch is really identical to HEAD" \
  test "$decoy_sha25d" = "$head_sha25d"
check "exits 0" test "$rc25d" -eq 0
check "--print-base prints the fully-qualified refs/remotes/origin/main" \
  test "$out25d" = "refs/remotes/origin/main"

# Live run: the runner's own diff must be computed from that same
# fully-qualified value, not a bare "origin/main" re-resolved downstream --
# if it were, the diff would hit the decoy (identical to HEAD) and
# env_error out on an empty diff before ever spawning codex.
argvdir25d="$tmpdir/argv-log-25d.$$.${RANDOM:-0}"
rundir25d="$tmpdir/qualified-vs-decoy-run.$$.${RANDOM:-0}"
cat > "$repo25d/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF

out25d_live=$(cd "$repo25d" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir25d" \
  bash "$SH" --plan plan.json --base main --dir "$rundir25d" 2>&1); rc25d_live=$?
echo "--- case 25d: live run diffs against the remote-tracking commit ---"
printf '%s\n' "$out25d_live"

check "live run exits 0 (the diff was non-empty)" test "$rc25d_live" -eq 0
check "live run verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out25d_live"

argv_n25d=0
for f in "$argvdir25d"/[0-9]*; do
  [ -e "$f" ] && argv_n25d=$((argv_n25d + 1))
done
last25d=$((argv_n25d - 1))
check "argv has at least one element logged" test "$argv_n25d" -ge 1
# DIFF_COMMAND is now pinned to the resolved commits themselves (see case 40
# for base_sha and case 4/HEAD-pinning for head_sha — neither the mutable
# base_resolved ref name nor a bare "HEAD" a downstream `git diff` would
# re-resolve fresh) -- so this checks against origin_sha25d (the commit
# refs/remotes/origin/main actually resolved to above) and head_sha25d
# (HEAD itself, unaffected by any of this), not the ref name. Re-resolving
# the base ref name at this point would hit the decoy (identical to HEAD)
# instead, exactly the bug this case exists to catch.
check "the rendered prompt's diff command is pinned to the resolved commits, not the decoy" \
  grep -qF "git diff $origin_sha25d...$head_sha25d" "$argvdir25d/$last25d"

rm -rf "$rundir25d"

# --- Case 25e: --print-base does not require the codex CLI on PATH ------------
# Regression: adversarial-review.sh's argument pre-scan required codex on
# PATH even for --print-base, which invokes no reviewer at all -- the same
# exemption --from-dir already gets. --print-base is now tracked the same
# way through the pre-scan and skips that requirement.
repo25e=$(make_throwaway_repo print-base-no-codex)
out25e=$(cd "$repo25e" && CODEX_BIN=/nonexistent/codex bash "$SH" --print-base --base main 2>&1); rc25e=$?
echo "--- case 25e: --print-base skips the codex-on-PATH check ---"
printf '%s\n' "$out25e"

check "exits 0 even with an unusable CODEX_BIN" test "$rc25e" -eq 0
check "--print-base still prints the resolved base" \
  test "$out25e" = "refs/heads/main"

# --- Case 26: the codex exec argv gets an option terminator before the prompt --
# Regression: a rendered prompt is arbitrary text a plan or a custom
# --angle-prompt template controls, not this runner -- one that happens to
# start with "-" (a mandate quoting a CLI flag, a markdown "---" rule) could
# be parsed by `codex exec` as another option instead of the positional
# prompt argument. run_angle now inserts "--" immediately before the prompt
# in the argv it hands to Popen. fixtures/fake-codex-argv-log.sh logs every
# argv element to its own file (one per element, not one line per file --
# the prompt itself is multiline, so a line-oriented log couldn't tell an
# embedded newline apart from an element boundary) so this checks the exact
# argv the runner built, not just that the run succeeded.
repo26=$(make_throwaway_repo option-terminator)
cat > "$repo26/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
template26="$tmpdir/dashes-template.$$.${RANDOM:-0}.md"
printf -- '---\nprompt intentionally starting with three dashes, to check the option terminator protects it from being parsed as a codex exec flag\nangle: {{ANGLE_ID}}\n' > "$template26"
argvdir26="$tmpdir/argv-log.$$.${RANDOM:-0}"
rundir26="$tmpdir/option-terminator-run.$$.${RANDOM:-0}"

out26=$(cd "$repo26" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir26" \
  bash "$SH" --plan plan.json --base main --dir "$rundir26" --angle-prompt "$template26" 2>&1); rc26=$?
echo "--- case 26: option terminator before the prompt ---"
printf '%s\n' "$out26"

check "exits 0" test "$rc26" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out26"
# A glob, not `find -maxdepth`, so this runs the same on every `find`
# variant this suite might see -- the argv-index files are named plain
# integers (0, 1, 2, ...; see fake-codex-argv-log.sh), never "argv0"
# (logged separately), so "[0-9]*" alone (no recursion possible from a
# glob) is the same match as the old -name '[0-9]*'.
argv_n26=0
for f in "$argvdir26"/[0-9]*; do
  [ -e "$f" ] && argv_n26=$((argv_n26 + 1))
done
last26=$((argv_n26 - 1))
second_last26=$((argv_n26 - 2))
check "argv has at least two elements logged" test "$argv_n26" -ge 2
check "the element right before the prompt is a bare --" \
  bash -c 'test "$(cat "$1")" = "--"' _ "$argvdir26/$second_last26"
check "the prompt (the last argv element) is the one rendered, starting with ---" \
  bash -c 'case "$(cat "$1")" in ---*) exit 0 ;; *) exit 1 ;; esac' _ "$argvdir26/$last26"

# --- Case 27: a relative CODEX_BIN resolves to an absolute path before Popen ---
# Regression: shutil.which() returns a relative CODEX_BIN (one containing a
# path separator, e.g. "./relative/fake-codex") unchanged -- it only checks
# such a path directly, it never resolves it. Every angle's Popen runs with
# cwd=root (the repo top level), not this process's own invocation
# directory, so a relative CODEX_BIN used as-is would be re-resolved
# against the wrong directory and fail to spawn whenever root differs from
# where the command was invoked -- exactly the case here: CODEX_BIN is
# relative to a SUBdirectory of the repo, not the repo root. Proves this by
# actually spawning: without the fix this fails to find the executable at
# all (a spawn failure); with the fix it runs successfully, and argv0 (the
# literal cmd[0] the fake codex was execve()'d with) is an absolute path.
repo27=$(make_throwaway_repo relative-codex-bin)
mkdir -p "$repo27/sub/relative"
cp "$FIXTURES/fake-codex-argv-log.sh" "$repo27/sub/relative/fake-codex"
chmod +x "$repo27/sub/relative/fake-codex"
cat > "$repo27/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
argvdir27="$tmpdir/argv-log-relative.$$.${RANDOM:-0}"
rundir27="$tmpdir/relative-codex-bin-run.$$.${RANDOM:-0}"

out27=$(cd "$repo27/sub" && CODEX_BIN="./relative/fake-codex" ADV_TEST_ARGV_DIR="$argvdir27" \
  bash "$SH" --plan ../plan.json --base main --dir "$rundir27" 2>&1); rc27=$?
echo "--- case 27: relative CODEX_BIN from a subdirectory resolves absolute ---"
printf '%s\n' "$out27"

check "exits 0 (the relative CODEX_BIN, from a subdirectory, still spawns)" \
  test "$rc27" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out27"
check "argv0 was logged" test -f "$argvdir27/argv0"
check "argv0 is an absolute path, not the raw relative CODEX_BIN string" \
  bash -c 'case "$(cat "$1")" in /*) exit 0 ;; *) exit 1 ;; esac' _ "$argvdir27/argv0"

# --- Case 28: a post-spawn failure still runs the residue check ----------------
# Regression: run_angle() used to fold every error into a single "spawn
# failed" outcome, whether Popen itself never started the process or the
# process ran fine and only a later step (writing .status, the background-
# leak note) failed. run_write_capable_angles then skipped the post-angle
# residue check on ANY error -- so a reviewer that actually ran and dirtied
# the shared checkout, but hit a post-spawn write failure, could slip past
# both the residue check and the compromised cascade, letting the next
# workspace-write angle run against an already-modified tree. run_angle now
# reports whether the process actually spawned; the residue check runs
# whenever it did, error or not -- only a true spawn failure (nothing ever
# ran, nothing to check) skips it. fixtures/fake-codex-dirty-tree.sh plays
# the reviewer that ran, dirtied a tracked file, and (right before exiting)
# turns its own <aid>.status path into a directory, so run_angle's own
# write_text() of that path fails with IsADirectoryError right after a
# real, tree-dirtying process has already exited. Plan has two
# workspace-write angles in order (writer, writer2); only writer's fake
# codex dirties the tree, so writer2 must show up as skipped, never run.
repo28=$(make_throwaway_repo post-spawn-residue)
# The plan lives outside repo28, not inside it (see case 22c): a
# workspace-write angle's dirty-tree gate requires a genuinely clean tree
# before the first angle runs, and an untracked plan.json sitting in the
# checkout would itself trip that gate before writer ever gets to run.
plan28="$tmpdir/post-spawn-residue-plan.$$.${RANDOM:-0}.json"
cat > "$plan28" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"},
   {"id": "writer2", "title": "Writer2", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF
rundir28="$safe_tmpdir/post-spawn-residue-run.$$.${RANDOM:-0}"

out28=$(cd "$repo28" && CODEX_BIN="$FIXTURES/fake-codex-dirty-tree.sh" ADV_TEST_DIRTY_FILE="f.txt" \
  bash "$SH" --plan "$plan28" --base main --dir "$rundir28" 2>&1); rc28=$?
echo "--- case 28: a post-spawn failure still runs the residue check ---"
printf '%s\n' "$out28"

check "exits 3 (a spawn-phase error, not a normal per-angle outcome)" \
  test "$rc28" -eq 3
check "the post-spawn write failure is reported" \
  grep -qi "writer" <<<"$out28"
check "the dirty tree left by the fake codex was caught: a residue marker was written" \
  test -f "$rundir28/writer.residue.txt"
check "the residue marker names the dirtied file" \
  grep -qF "f.txt" "$rundir28/writer.residue.txt"
check "the working-tree-dirty warning was printed for writer" \
  grep -qF "angle 'writer' left the working tree dirty" <<<"$out28"
check "writer2 never ran: it was skipped as compromised" \
  test -f "$rundir28/writer2.skipped.txt"
check "writer2's skip marker names the cause" \
  grep -qx "compromised" "$rundir28/writer2.skipped.txt"
check "writer2 has no out.json -- it truly never ran" \
  test ! -f "$rundir28/writer2.out.json"

rm -rf "$rundir28"

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
         "evidence": "A concrete case.", "files": ["a.py", "b.py"],
         "execution": "read-only"}
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
angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.", "evidence": "A concrete case.",
         "execution": "read-only"}
rendered = render_prompt("{{DIFF_COMMAND}}", plan, angle, "feature;echo")
expected = "git diff 'feature;echo'...HEAD"
print("OK" if rendered == expected else "MISMATCH:\n" + rendered)
PYEOF
)
echo "--- prompt rendering: base is shell-quoted in DIFF_COMMAND ---"
printf '%s\n' "$quote_check"
check "a base with shell metacharacters is quoted in the generated diff command" \
  test "$quote_check" = "OK"

# --- claude-angle-prompt.md's base-resolution block quotes {{BASE_SHELL}} once -
# Regression: the base-resolution shell block in claude-angle-prompt.md used
# to splice the raw {{BASE}} placeholder directly into "origin/{{BASE}}",
# $(git remote | sed "s@.*@&/{{BASE}}@"), and "{{BASE}}" -- each a
# double-quoted (or double-quoted-sed-script) position where a base
# containing shell metacharacters is live shell, not data: a base of
# "feature;$(id)" would splice in a real, executable $(id) command
# substitution. The block now assigns BASE={{BASE_SHELL}} once, from a
# render_prompt-quoted single-quoted literal, and every other use in the
# block is "$BASE" (a plain variable reference to already-safe data, never
# re-spliced text) -- so rendering with a hostile base must produce the
# quoted assignment exactly once and never a second, unquoted copy of the
# dangerous substring anywhere else in the rendered output.
base_shell_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from adversarial_review import render_prompt

template = (Path(sys.argv[1]).parent / "claude-angle-prompt.md").read_text()
plan = {"promise": "Ship it.", "contracts": [], "invariants": []}
angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.", "evidence": "A concrete case.",
         "execution": "read-only"}
rendered = render_prompt(template, plan, angle, "feature;$(id)")

# Scoped to the fenced shell block itself, not the whole rendered doc -- the
# prose line above it deliberately still shows the raw base in backticks
# (a harmless documentation mention, never shell), so counting "$(id)"
# across the entire file would over-count. Locate the block by its BASE=
# assignment (now emitted exactly once) through the next closing fence.
start = rendered.index("BASE=")
end = rendered.index("```", start)
block = rendered[start:end]

has_quoted = "BASE='feature;$(id)'" in block
# Inside the block, the dangerous substring must appear exactly once --
# inside that single-quoted assignment -- and nowhere else unquoted, which
# is what the old {{BASE}}-splicing bug would have left behind at each of
# the other three (now "$BASE") use sites.
count = block.count("$(id)")
ok = has_quoted and count == 1
print("OK" if ok else f"MISMATCH: has_quoted={has_quoted} count={count}\n{block}")
PYEOF
)
echo "--- claude-angle-prompt.md: base-resolution block quotes BASE_SHELL once ---"
printf '%s\n' "$base_shell_check"
check "a hostile base is single-quoted once and never spliced bare elsewhere" \
  test "$base_shell_check" = "OK"

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
         "evidence": "A concrete case.", "execution": "read-only"}
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

# --- {{EXECUTION}} renders per-angle, and only a workspace-write angle's -------
# --- rendered prompt tells the reviewer to run the mandated reproduction -------
# Regression: angle-prompt.md used to tell every reviewer "Read only" with no
# rendered execution mode at all, so a workspace-write reviewer had no signal
# in its own prompt that it was ever allowed to run the reproduction it was
# mandated to demonstrate. {{EXECUTION}} must render to text naming the
# angle's own execution value with no unrendered "{{" left over, and the two
# modes' rendered prompts must differ on whether they tell the reviewer to
# run something.
exec_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from adversarial_review import render_prompt

plan = {"promise": "Ship it.", "contracts": [], "invariants": []}
template = "mode={{EXECUTION}}"

ro_angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.",
            "evidence": "A concrete case.", "execution": "read-only"}
ww_angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.",
            "evidence": "A concrete case.", "execution": "workspace-write"}

ro_rendered = render_prompt(template, plan, ro_angle, "main")
ww_rendered = render_prompt(template, plan, ww_angle, "main")

PHRASE = "run the mandated reproduction"

checks = {
    "read-only render names its own mode": "read-only" in ro_rendered,
    "workspace-write render names its own mode": "workspace-write" in ww_rendered,
    "read-only render has no unrendered {{ left": "{{" not in ro_rendered,
    "workspace-write render has no unrendered {{ left": "{{" not in ww_rendered,
    "workspace-write render tells the reviewer to run the reproduction":
        PHRASE in ww_rendered.lower(),
    "read-only render does not tell the reviewer to run the reproduction":
        PHRASE not in ro_rendered.lower(),
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    print("MISMATCH:\n" + "\n".join(failed) + f"\n\nro={ro_rendered!r}\nww={ww_rendered!r}")
else:
    print("OK")
PYEOF
)
echo "--- prompt rendering: {{EXECUTION}} differs by angle execution mode ---"
printf '%s\n' "$exec_check"
check "EXECUTION renders per-mode and only workspace-write tells the reviewer to run it" \
  test "$exec_check" = "OK"

# --- The fallback DEFAULT_ANGLE_PROMPT carries {{EXECUTION}} too ---------------
# Regression: angle-prompt.md (the sibling agent's own file) renders
# {{EXECUTION}}, but DEFAULT_ANGLE_PROMPT -- used only when no
# angle-prompt.md is found next to this skill -- didn't mention it at all,
# so a reviewer running under the fallback template had no signal whether
# it was allowed to run its own mandated reproduction. Drives
# load_angle_prompt_template(None, script_dir) with a script_dir that has
# no sibling angle-prompt.md (so it must fall back to DEFAULT_ANGLE_PROMPT,
# confirmed by identity below) and renders it for both execution modes, the
# same way case above does for the real template.
fallback_exec_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

template = ar.load_angle_prompt_template(None, Path("/nonexistent-dir-for-this-test"))
plan = {"promise": "Ship it.", "contracts": [], "invariants": []}
ro_angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.",
            "evidence": "A concrete case.", "execution": "read-only"}
ww_angle = {"id": "logic", "title": "Logic", "mandate": "Find bugs.",
            "evidence": "A concrete case.", "execution": "workspace-write"}

ro_rendered = ar.render_prompt(template, plan, ro_angle, "main")
ww_rendered = ar.render_prompt(template, plan, ww_angle, "main")

checks = {
    "the fallback template really is DEFAULT_ANGLE_PROMPT": template is ar.DEFAULT_ANGLE_PROMPT,
    "read-only render names its own mode": "read-only" in ro_rendered,
    "workspace-write render names its own mode": "workspace-write" in ww_rendered,
    "read-only render has no unrendered {{ left": "{{" not in ro_rendered,
    "workspace-write render has no unrendered {{ left": "{{" not in ww_rendered,
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    print("MISMATCH:\n" + "\n".join(failed))
else:
    print("OK")
PYEOF
)
echo "--- fallback template: {{EXECUTION}} renders per-mode even without angle-prompt.md ---"
printf '%s\n' "$fallback_exec_check"
check "DEFAULT_ANGLE_PROMPT carries {{EXECUTION}} with the same per-mode guidance" \
  test "$fallback_exec_check" = "OK"

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

# --- run_angle honors _CANCELLED before ever spawning a reviewer ---------------
# Regression: a SIGINT/SIGTERM landing between Popen() returning and the new
# process being registered in _LIVE_PROCS could let the interrupt handler's
# sweep miss it entirely. run_angle now checks _CANCELLED immediately before
# Popen (and again right after registering); this exercises the simpler,
# hermetic half of that fix directly -- presetting the flag before the call,
# which the real signal-race can't easily be forced into on demand -- and
# proves Popen is never reached at all, with the angle reported the same way
# an interrupt handler's own exit would have left it: UNPARSED(interrupted).
cancel_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

ar._CANCELLED = True

def fail_popen(*a, **kw):
    raise AssertionError("Popen must not be called once _CANCELLED is set")
ar.subprocess.Popen = fail_popen

angle = {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}
plan = {"promise": "Ships a thing.", "contracts": [], "invariants": []}

with tempfile.TemporaryDirectory() as d:
    run_dir = Path(d)
    run_meta = {"plan_hash": "deadbeef", "base_resolved": "main", "base_sha": "cafef00d"}
    err, spawned = ar.run_angle(
        "alpha", angle, plan, "main", "template {{ANGLE_ID}}",
        run_dir, "/tmp", "schema.json", 5, Path("/tmp/unused-codex-home"), run_meta,
    )
    result = ar.collect_angle_result(angle, run_dir)
    ok = (
        err is None and spawned is False
        and result.kind == "UNPARSED" and result.cause == "interrupted"
    )
    print("OK" if ok else f"MISMATCH: err={err!r} spawned={spawned!r} kind={result.kind!r} cause={result.cause!r}")
PYEOF
)
echo "--- run_angle: cancellation is checked before Popen ---"
printf '%s\n' "$cancel_check"
check "a preset _CANCELLED flag skips Popen and reports UNPARSED(interrupted)" \
  test "$cancel_check" = "OK"

# --- Case 29: -c project_doc_max_bytes=0 is passed for every angle -------------
# Security regression: `codex exec -C <root>` auto-loads AGENTS.md (root and
# every parent up to the git root) as project instructions ahead of the angle
# prompt -- a branch under review controls that file, so without this knob it
# could instruct every angle to report CLEAN regardless of what the diff does.
# run_angle now always includes "-c project_doc_max_bytes=0" in the codex exec
# argv it builds, for every angle regardless of execution mode -- verified
# live against codex-cli 0.145.0 with `codex debug prompt-input`, which shows
# the "# AGENTS.md instructions for <dir>" block disappear from the
# model-visible prompt at this setting. Checks both execution modes, one
# angle at a time via --only (fake-codex-argv-log.sh clears ADV_TEST_ARGV_DIR
# on every invocation, so two angles sharing one run would race).
repo29=$(make_throwaway_repo project-doc-knob)
# The plan lives outside repo29, not inside it (see case 28): the beta
# angle's dirty-tree gate requires a genuinely clean tree before it runs,
# and an untracked plan.json sitting in the checkout would itself trip
# that gate.
plan29="$tmpdir/project-doc-knob-plan.$$.${RANDOM:-0}.json"
cat > "$plan29" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF

for aid29 in alpha beta; do
  argvdir29="$tmpdir/argv-log-doc-knob-$aid29.$$.${RANDOM:-0}"
  rundir29="$safe_tmpdir/project-doc-knob-$aid29-run.$$.${RANDOM:-0}"
  out29=$(cd "$repo29" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir29" \
    bash "$SH" --plan "$plan29" --base main --dir "$rundir29" --only "$aid29" 2>&1); rc29=$?
  echo "--- case 29: project_doc_max_bytes=0 is present for angle '$aid29' (execution=$([ "$aid29" = alpha ] && echo read-only || echo workspace-write)) ---"
  printf '%s\n' "$out29"

  check "angle '$aid29' run exits 0" test "$rc29" -eq 0
  check "angle '$aid29' verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out29"

  n29=0
  for f in "$argvdir29"/[0-9]*; do
    [ -e "$f" ] || continue
    n29=$((n29 + 1))
  done
  found29=false
  if [ "$n29" -ge 2 ]; then
    last_idx29=$((n29 - 1))
    for idx in $(seq 0 $((last_idx29 - 1))); do
      if [ "$(cat "$argvdir29/$idx")" = "-c" ] \
         && [ "$(cat "$argvdir29/$((idx + 1))")" = "project_doc_max_bytes=0" ]; then
        found29=true
        break
      fi
    done
  fi
  check "angle '$aid29''s codex exec argv includes -c project_doc_max_bytes=0" \
    test "$found29" = true

  rm -rf "$rundir29"
done

# --- Case 29a: -c skills.include_instructions=false is passed for every angle -
# Security regression: `codex exec -C <root>` also auto-discovers a matching
# `.agents/skills/**/SKILL.md` from the checkout under review and injects it
# into the model-visible prompt -- branch-controlled, same hazard class as
# the AGENTS.md guard case 29 covers, and neither project_doc_max_bytes=0 nor
# the throwaway CODEX_HOME stops it (verified live against codex-cli 0.145.0
# with `codex debug prompt-input`: a throwaway repo's own
# .agents/skills/review-helper/SKILL.md still appeared with both of those in
# place; `-c skills.include_instructions=false` is what actually removed it).
# run_angle now always includes that override too. Same per-angle, per-
# execution-mode shape as case 29.
repo29a=$(make_throwaway_repo skills-knob)
plan29a="$tmpdir/skills-knob-plan.$$.${RANDOM:-0}.json"
cat > "$plan29a" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF

for aid29a in alpha beta; do
  argvdir29a="$tmpdir/argv-log-skills-knob-$aid29a.$$.${RANDOM:-0}"
  rundir29a="$safe_tmpdir/skills-knob-$aid29a-run.$$.${RANDOM:-0}"
  out29a=$(cd "$repo29a" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir29a" \
    bash "$SH" --plan "$plan29a" --base main --dir "$rundir29a" --only "$aid29a" 2>&1); rc29a=$?
  echo "--- case 29a: skills.include_instructions=false is present for angle '$aid29a' (execution=$([ "$aid29a" = alpha ] && echo read-only || echo workspace-write)) ---"
  printf '%s\n' "$out29a"

  check "angle '$aid29a' run exits 0" test "$rc29a" -eq 0
  check "angle '$aid29a' verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out29a"

  n29a=0
  for f in "$argvdir29a"/[0-9]*; do
    [ -e "$f" ] || continue
    n29a=$((n29a + 1))
  done
  found29a=false
  if [ "$n29a" -ge 2 ]; then
    last_idx29a=$((n29a - 1))
    for idx in $(seq 0 $((last_idx29a - 1))); do
      if [ "$(cat "$argvdir29a/$idx")" = "-c" ] \
         && [ "$(cat "$argvdir29a/$((idx + 1))")" = "skills.include_instructions=false" ]; then
        found29a=true
        break
      fi
    done
  fi
  check "angle '$aid29a''s codex exec argv includes -c skills.include_instructions=false" \
    test "$found29a" = true

  rm -rf "$rundir29a"
done

# --- Case 29b: each angle's codex exec gets an isolated, throwaway CODEX_HOME --
# Security regression: `codex exec -C <root>` on a checkout the *real*
# CODEX_HOME's config.toml marks trusted (a `[projects."<root>"]
# trust_level = "trusted"` entry, set once by accepting the interactive
# trust prompt in any unrelated session, at any point in the past) loads
# that checkout's own repo-local .codex/config.toml -- hooks, MCP servers,
# exec-policy rules, model overrides, all branch-controlled, same hazard
# class as the AGENTS.md guard project_doc_max_bytes=0 closes above.
# Verified empirically against codex-cli 0.145.0 (see
# make_throwaway_codex_home's docstring): a throwaway repo's
# .codex/config.toml setting model_reasoning_effort = "minimal" left `codex
# exec`'s own startup header reading the *ambient* CODEX_HOME's setting
# while the project was untrusted, and switched to "minimal" -- the
# repo-local value, loaded and applied -- the instant a CODEX_HOME's
# config.toml marked that same path trusted; a CODEX_HOME holding only a
# copy of auth.json (no config.toml at all) authenticated normally while
# leaving the header at the built-in default. run_angle now overrides
# CODEX_HOME, per angle, to a fresh run-scoped throwaway directory holding
# only a copy of the real auth.json (see make_throwaway_codex_home) --
# closing that surface regardless of what the real CODEX_HOME's config.toml
# says about the checkout under review.
#
# CODEX_HOME=$fakerealhome29b simulates "the real one" for this test alone
# (never the actual developer machine's ~/.codex); fake-codex-argv-log.sh's
# env_CODEX_HOME log (added alongside its argv log) reveals exactly what
# CODEX_HOME each angle's codex exec process actually saw. Checks both
# execution modes, one angle at a time via --only, same as case 29.
repo29b=$(make_throwaway_repo codex-home-isolation)
plan29b="$tmpdir/codex-home-isolation-plan.$$.${RANDOM:-0}.json"
cat > "$plan29b" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF
fakerealhome29b="$tmpdir/fake-real-codex-home.$$.${RANDOM:-0}"
mkdir -p "$fakerealhome29b"
echo '{"marker": "the-real-users-auth"}' > "$fakerealhome29b/auth.json"
# A separate reference copy, diffed against after each run below, so
# "the ambient CODEX_HOME's auth.json was never touched" is a plain file
# comparison rather than a hand-quoted content check.
expected_auth29b="$tmpdir/fake-real-codex-home-auth-expected.$$.${RANDOM:-0}.json"
cp "$fakerealhome29b/auth.json" "$expected_auth29b"

for aid29b in alpha beta; do
  argvdir29b="$tmpdir/argv-log-codex-home-$aid29b.$$.${RANDOM:-0}"
  rundir29b="$safe_tmpdir/codex-home-isolation-$aid29b-run.$$.${RANDOM:-0}"
  out29b=$(cd "$repo29b" && CODEX_HOME="$fakerealhome29b" \
    CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir29b" \
    bash "$SH" --plan "$plan29b" --base main --dir "$rundir29b" --only "$aid29b" 2>&1)
  rc29b=$?
  echo "--- case 29b: isolated CODEX_HOME for angle '$aid29b' (execution=$([ "$aid29b" = alpha ] && echo read-only || echo workspace-write)) ---"
  printf '%s\n' "$out29b"

  check "angle '$aid29b' run exits 0" test "$rc29b" -eq 0
  check "angle '$aid29b' verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out29b"

  seen_home29b=""
  if [ -f "$argvdir29b/env_CODEX_HOME" ]; then
    seen_home29b=$(cat "$argvdir29b/env_CODEX_HOME")
  fi
  check "angle '$aid29b''s codex exec saw a non-empty CODEX_HOME" test -n "$seen_home29b"
  check "angle '$aid29b''s CODEX_HOME is not the ambient/real one" \
    test "$seen_home29b" != "$fakerealhome29b"
  check "angle '$aid29b''s throwaway CODEX_HOME carried a copy of the real auth.json" \
    grep -q "the-real-users-auth" "$argvdir29b/env_CODEX_HOME_AUTH_JSON"
  check "angle '$aid29b''s throwaway CODEX_HOME was cleaned up after the run" \
    test ! -d "$seen_home29b"
  check "the ambient/real CODEX_HOME's auth.json (fakerealhome29b) was never modified" \
    cmp -s "$fakerealhome29b/auth.json" "$expected_auth29b"

  rm -rf "$rundir29b"
done

# --- Case 29c: each write-capable angle gets its OWN throwaway CODEX_HOME, ----
# not one shared for the whole run
# Security regression (item 3): main() used to create a single throwaway
# CODEX_HOME and pass it to every angle, live or serial — so a
# workspace-write angle's own reproduction (already free to write the
# shared checkout, per this runner's own threat model) could delete that
# CODEX_HOME's auth.json or plant a config.toml for whichever angle runs
# next, before that angle's own codex exec even started. Every angle now
# gets a fresh, this-angle-only CODEX_HOME (see make_throwaway_codex_home /
# _run_angle_isolated), removed immediately once that angle finishes — not
# just at the end of the whole run. fixtures/fake-codex-env-log.sh records
# each angle's own CODEX_HOME (to a per-angle file, never cleared between
# invocations, unlike fake-codex-argv-log.sh's ADV_TEST_ARGV_DIR) and, at
# its own start, which earlier angles' logged CODEX_HOME paths still exist
# on disk — proving removal happens between angles, not only at run end.
repo29c=$(make_throwaway_repo per-angle-codex-home)
# The plan lives outside repo29c, not inside it (see case 28): the first
# write-capable angle's dirty-tree gate requires a genuinely clean tree
# before it runs, and an untracked plan.json sitting in the checkout would
# itself trip that gate.
plan29c="$tmpdir/per-angle-codex-home-plan.$$.${RANDOM:-0}.json"
cat > "$plan29c" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "writer1", "title": "Writer 1", "mandate": "m", "evidence": "e", "execution": "workspace-write"},
   {"id": "writer2", "title": "Writer 2", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF
envlogdir29c="$safe_tmpdir/per-angle-codex-home-envlog.$$.${RANDOM:-0}"
rundir29c="$safe_tmpdir/per-angle-codex-home-run.$$.${RANDOM:-0}"
mkdir -p "$envlogdir29c"

out29c=$(cd "$repo29c" && CODEX_BIN="$FIXTURES/fake-codex-env-log.sh" \
  ADV_TEST_ENV_LOG_DIR="$envlogdir29c" \
  bash "$SH" --plan "$plan29c" --base main --dir "$rundir29c" 2>&1); rc29c=$?
echo "--- case 29c: per-angle throwaway CODEX_HOME isolation ---"
printf '%s\n' "$out29c"

check "exits 0" test "$rc29c" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out29c"

home1_29c=""
home2_29c=""
[ -f "$envlogdir29c/writer1.codex_home" ] && home1_29c=$(cat "$envlogdir29c/writer1.codex_home")
[ -f "$envlogdir29c/writer2.codex_home" ] && home2_29c=$(cat "$envlogdir29c/writer2.codex_home")

check "writer1 saw a non-empty CODEX_HOME" test -n "$home1_29c"
check "writer2 saw a non-empty CODEX_HOME" test -n "$home2_29c"
check "writer1 and writer2 saw DIFFERENT CODEX_HOME values" \
  test "$home1_29c" != "$home2_29c"

outside29c=$(HOME1="$home1_29c" HOME2="$home2_29c" python3 -c '
import os, tempfile
from pathlib import Path
roots = set()
for p in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp", "/var/tmp"):
    if p:
        try:
            roots.add(str(Path(p).resolve()))
        except OSError:
            pass
def outside(p):
    pr = Path(p).resolve()
    return not any(pr == r or str(pr).startswith(r + os.sep) for r in roots)
h1, h2 = os.environ["HOME1"], os.environ["HOME2"]
print("OK" if outside(h1) and outside(h2) else f"MISMATCH: h1={h1!r} h2={h2!r} roots={roots!r}")
')
check "neither CODEX_HOME sits under a sandbox-writable root (/tmp, /var/tmp, \$TMPDIR)" \
  test "$outside29c" = "OK"

check "writer2's still_exist marker was written (the check ran)" \
  test -f "$envlogdir29c/writer2.still_exist"
check "writer1's throwaway CODEX_HOME was already removed before writer2's codex exec started" \
  bash -c 'test ! -s "$1"' _ "$envlogdir29c/writer2.still_exist"

rm -rf "$rundir29c"

# --- Case 29d: --strict-config is passed for every angle ----------------------
# Security regression (item 3): a codex-cli build that doesn't recognize one
# of the -c keys above (an older release, a key renamed upstream) silently
# ignores it rather than erroring, so an isolation knob (project_doc_max_bytes,
# skills.include_instructions) could fail open on such a build with no sign
# anything was skipped. run_angle now always includes "--strict-config" in
# the codex exec argv it builds, for every angle regardless of execution
# mode. Same per-angle, per-execution-mode shape as case 29, but --strict-
# config is a bare flag (no paired value), so the search just looks for the
# literal token rather than a "-c"/value pair.
repo29d=$(make_throwaway_repo strict-config-flag)
plan29d="$tmpdir/strict-config-flag-plan.$$.${RANDOM:-0}.json"
cat > "$plan29d" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF

for aid29d in alpha beta; do
  argvdir29d="$tmpdir/argv-log-strict-config-$aid29d.$$.${RANDOM:-0}"
  rundir29d="$safe_tmpdir/strict-config-$aid29d-run.$$.${RANDOM:-0}"
  out29d=$(cd "$repo29d" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir29d" \
    bash "$SH" --plan "$plan29d" --base main --dir "$rundir29d" --only "$aid29d" 2>&1); rc29d=$?
  echo "--- case 29d: --strict-config is present for angle '$aid29d' (execution=$([ "$aid29d" = alpha ] && echo read-only || echo workspace-write)) ---"
  printf '%s\n' "$out29d"

  check "angle '$aid29d' run exits 0" test "$rc29d" -eq 0
  check "angle '$aid29d' verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out29d"

  found29d=false
  for f in "$argvdir29d"/[0-9]*; do
    [ -e "$f" ] || continue
    if [ "$(cat "$f")" = "--strict-config" ]; then
      found29d=true
      break
    fi
  done
  check "angle '$aid29d''s codex exec argv includes --strict-config" \
    test "$found29d" = true

  rm -rf "$rundir29d"
done

# --- Case 30: a reused --dir with a changed plan + --only never leaks an -------
# unselected angle's stale verdict into a later --from-dir merge
# Regression: run_angle now stamps each angle's own <aid>.meta.json with the
# plan hash + resolved base/sha that produced it (run_meta in main()), and a
# live run whose plan or base differs from --dir's existing plan.json clears
# every angle's artifacts (not only the ones --only selects) before writing
# the new plan.json. Seeds a run with two read-only angles (alpha, beta),
# reruns with a changed plan (different promise) restricted to --only alpha,
# then --from-dir merges the whole --dir: beta's stale CLEAN from the first
# run must never surface as this (different) plan's own verdict.
repo30=$(make_throwaway_repo reused-dir-changed-plan)
planA30="$repo30/planA.json"
cat > "$planA30" <<'EOF'
{"version": 1, "base": "main", "promise": "Plan A.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF
planB30="$repo30/planB.json"
cat > "$planB30" <<'EOF'
{"version": 1, "base": "main", "promise": "Plan B -- a materially different review.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF
rundir30="$tmpdir/reused-dir-changed-plan-run.$$.${RANDOM:-0}"
argvdir30="$tmpdir/reused-dir-changed-plan-argv.$$.${RANDOM:-0}"

out30_1=$(cd "$repo30" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir30" \
  bash "$SH" --plan "$planA30" --base main --dir "$rundir30" 2>&1); rc30_1=$?
echo "--- case 30: first run (plan A, both angles) ---"
printf '%s\n' "$out30_1"
check "first run exits 0" test "$rc30_1" -eq 0
check "first run: alpha CLEAN" grep -qx "alpha: CLEAN" <<<"$out30_1"
check "first run: beta CLEAN" grep -qx "beta: CLEAN" <<<"$out30_1"

out30_2=$(cd "$repo30" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir30" \
  bash "$SH" --plan "$planB30" --base main --dir "$rundir30" --only alpha 2>&1); rc30_2=$?
echo "--- case 30: second run (plan B, --only alpha) ---"
printf '%s\n' "$out30_2"
check "second run exits 0" test "$rc30_2" -eq 0
check "second run only counts alpha" \
  grep -qx "ANGLES=1  RAN=1  BLOCKED=0  UNPARSED=0" <<<"$out30_2"

out30_3=$(bash "$SH" --from-dir "$rundir30" 2>&1); rc30_3=$?
echo "--- case 30: --from-dir merges the reused --dir after the plan changed ---"
printf '%s\n' "$out30_3"
check "--from-dir exits 4 (beta must never resurface as a clean plan-B result)" \
  test "$rc30_3" -eq 4
check "--from-dir verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out30_3"
check "alpha (rerun under plan B) is CLEAN" grep -qx "alpha: CLEAN" <<<"$out30_3"
check "beta is never reported CLEAN (its plan-A artifact must not leak into plan B)" \
  bash -c '! grep -q "^beta: CLEAN" <<<"$1"' _ "$out30_3"

rm -rf "$rundir30"

# --- Case 30b: a meta mismatch alone yields UNPARSED(stale) ---------------------
# Regression: an angle's <aid>.meta.json must be checked field-for-field
# against the run dir's own plan.json "_run" record -- a single mismatched
# field (here, base_sha) is as untrustworthy as a missing meta.json
# entirely, however well-formed the angle's own .status/.out.json otherwise
# look. Hand-crafted directly (no live run needed) to unit-test the
# collect_angle_result check in isolation from main()'s own broad-clear
# defense (case 30 exercises that one together with this backstop) --
# "_run".plan_hash below must be the REAL compute_plan_hash of the plan
# object minus "_run" (see case 36), or --from-dir's own top-level
# plan-edited-since-run check would report UNPARSED(stale) for an unrelated
# reason and this case would no longer isolate the per-field backstop it
# exists to test.
dir30b="$tmpdir/meta-mismatch.$$.${RANDOM:-0}"
mkdir -p "$dir30b"
plan_hash30b=$(python3 -c '
import hashlib, json
plan = {"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "solo", "title": "Solo", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
canonical = json.dumps(plan, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
')
cat > "$dir30b/plan.json" <<EOF
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "solo", "title": "Solo", "mandate": "m", "evidence": "e", "execution": "read-only"}],
 "_run": {"plan_hash": "$plan_hash30b", "base_resolved": "refs/heads/main", "base_sha": "aaaa000"}}
EOF
printf '0\n' > "$dir30b/solo.status"
cat > "$dir30b/solo.out.json" <<'EOF'
{"angle": "solo", "verdict": "CLEAN", "summary": "looks fine", "findings": []}
EOF
cat > "$dir30b/solo.meta.json" <<EOF
{"plan_hash": "$plan_hash30b", "base_resolved": "refs/heads/main", "base_sha": "different-sha"}
EOF

out30b=$(bash "$SH" --from-dir "$dir30b" 2>&1); rc30b=$?
echo "--- case 30b: a meta mismatch alone yields UNPARSED(stale) ---"
printf '%s\n' "$out30b"

check "exits 4" test "$rc30b" -eq 4
check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out30b"
check "the angle is marked UNPARSED(stale), not the well-formed CLEAN it otherwise carries" \
  grep -qx "solo: UNPARSED(stale)" <<<"$out30b"

rm -rf "$dir30b"

# --- Case 30c: an unchanged plan with --only still merges the untouched --------
# angle's earlier result (the documented purpose of --only)
# Companion to case 30: a --dir reused with the SAME plan and base must
# never treat an angle --only left out of this run as stale just because it
# wasn't part of this particular invocation -- both the broad clear (case
# 30) and the meta check (case 30b) key off the plan/base actually
# changing, never off --only being present at all.
repo30c=$(make_throwaway_repo reused-dir-unchanged-plan)
cat > "$repo30c/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF
rundir30c="$tmpdir/reused-dir-unchanged-plan-run.$$.${RANDOM:-0}"
argvdir30c="$tmpdir/reused-dir-unchanged-plan-argv.$$.${RANDOM:-0}"

out30c_1=$(cd "$repo30c" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir30c" \
  bash "$SH" --plan plan.json --base main --dir "$rundir30c" 2>&1); rc30c_1=$?
echo "--- case 30c: first run (both angles) ---"
printf '%s\n' "$out30c_1"
check "first run exits 0" test "$rc30c_1" -eq 0

out30c_2=$(cd "$repo30c" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir30c" \
  bash "$SH" --plan plan.json --base main --dir "$rundir30c" --only alpha 2>&1); rc30c_2=$?
echo "--- case 30c: second run (same plan, --only alpha) ---"
printf '%s\n' "$out30c_2"
check "second run exits 0" test "$rc30c_2" -eq 0
check "second run only counts alpha" \
  grep -qx "ANGLES=1  RAN=1  BLOCKED=0  UNPARSED=0" <<<"$out30c_2"

out30c_3=$(bash "$SH" --from-dir "$rundir30c" 2>&1); rc30c_3=$?
echo "--- case 30c: --from-dir merges both, beta's earlier result survives ---"
printf '%s\n' "$out30c_3"
check "--from-dir exits 0" test "$rc30c_3" -eq 0
check "--from-dir verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out30c_3"
check "--from-dir counts both angles ran" \
  grep -qx "ANGLES=2  RAN=2  BLOCKED=0  UNPARSED=0" <<<"$out30c_3"
check "alpha is CLEAN" grep -qx "alpha: CLEAN" <<<"$out30c_3"
check "beta's untouched earlier result still merges as CLEAN, not stale" \
  grep -qx "beta: CLEAN" <<<"$out30c_3"

rm -rf "$rundir30c"

# --- Case 31: resolve_base handles a base already in "<remote>/<branch>" form --
# Regression: a plan's base can legitimately already be written in the
# documented "<remote>/<branch>" form (e.g. "origin/main"). Before checking
# that form directly, resolve_base's generic remote loop instead probed the
# nonsensical refs/remotes/origin/origin/main (this base's own "origin/"
# prefix, plus the loop's own) -- which never verifies -- and fell through
# to refs/heads/origin/main, which a same-named local branch can satisfy
# instead of the real refs/remotes/origin/main. Same repo shape as case 25d
# (a genuine bare-remote origin/main sitting behind HEAD, plus a decoy local
# branch literally named "origin/main" built at HEAD) but resolved with
# --base origin/main directly, not --base main.
repo31="$tmpdir/prefixed-base.$$.${RANDOM:-0}"
mkdir -p "$repo31"
git init -q -b main "$repo31"
git -C "$repo31" config user.email "test@example.com"
git -C "$repo31" config user.name "Test"
echo base > "$repo31/f.txt"
git -C "$repo31" add -A
git -C "$repo31" commit -q -m base

remote31="$tmpdir/prefixed-base-remote.$$.${RANDOM:-0}.git"
git init -q --bare "$remote31"
git -C "$repo31" remote add origin "$remote31"
git -C "$repo31" push -q origin main
git -C "$repo31" fetch -q origin

echo "ahead of origin" >> "$repo31/f.txt"
git -C "$repo31" commit -qam "HEAD moves ahead of origin/main"

# The decoy: a LOCAL branch literally named "origin/main" -- the exact
# refs/heads/origin/main path resolve_base's old fallback would have hit
# instead of refs/remotes/origin/main.
git -C "$repo31" branch "origin/main"

origin_sha31=$(git -C "$repo31" rev-parse refs/remotes/origin/main)
decoy_sha31=$(git -C "$repo31" rev-parse refs/heads/origin/main)
head_sha31=$(git -C "$repo31" rev-parse HEAD)

out31=$(cd "$repo31" && CODEX_BIN=true bash "$SH" --print-base --base origin/main 2>&1); rc31=$?
echo "--- case 31: --print-base --base origin/main resolves the real remote ref ---"
printf '%s\n' "$out31"

check "setup: the remote-tracking ref is really behind HEAD" test "$origin_sha31" != "$head_sha31"
check "setup: the decoy local branch is really identical to HEAD" test "$decoy_sha31" = "$head_sha31"
check "exits 0" test "$rc31" -eq 0
check "--print-base --base origin/main prints refs/remotes/origin/main, not the decoy" \
  test "$out31" = "refs/remotes/origin/main"

# --- Case 32: a TMPDIR inside the checkout never puts the throwaway CODEX_HOME -
# inside it
# Regression: make_throwaway_codex_home used to call tempfile.mkdtemp() with
# no dir= override at all -- honoring TMPDIR unconditionally, with no check
# that the resulting directory (holding a copy of the real auth.json) sits
# outside every git checkout. A TMPDIR pointed inside the reviewed repo
# would put that copy inside the working tree, where a careless
# workspace-write angle (or just `git status`) could see it. Reuses
# select_dir_outside_git_checkouts (the same helper resolve_merged_json_path
# uses) to fall back to /tmp or /var/tmp instead.
repo32=$(make_throwaway_repo hostile-tmpdir-codex-home)
hostiletmp32="$repo32/.hostile-tmp"
mkdir -p "$hostiletmp32"
fakerealhome32="$tmpdir/fake-real-codex-home-32.$$.${RANDOM:-0}"
mkdir -p "$fakerealhome32"
echo '{"marker": "the-real-users-auth"}' > "$fakerealhome32/auth.json"
cat > "$repo32/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
rundir32="$tmpdir/hostile-tmpdir-codex-home-run.$$.${RANDOM:-0}"
argvdir32="$tmpdir/hostile-tmpdir-codex-home-argv.$$.${RANDOM:-0}"

out32=$(cd "$repo32" && TMPDIR="$hostiletmp32" CODEX_HOME="$fakerealhome32" \
  CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir32" \
  bash "$SH" --plan plan.json --base main --dir "$rundir32" 2>&1); rc32=$?
echo "--- case 32: TMPDIR inside the checkout ---"
printf '%s\n' "$out32"

check "exits 0" test "$rc32" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out32"

seen_home32=""
if [ -f "$argvdir32/env_CODEX_HOME" ]; then
  seen_home32=$(cat "$argvdir32/env_CODEX_HOME")
fi
check "the angle's codex exec saw a non-empty CODEX_HOME" test -n "$seen_home32"
# A plain bash `case "$seen_home32" in "$repo32"/*)` string-prefix match is
# not reliable here: $tmpdir (and so $repo32) comes from `mktemp -d
# "${TMPDIR:-/tmp}/..."`, and a `${TMPDIR:-/tmp}` that already ends in "/"
# leaves a literal doubled slash baked into $repo32 that mkdtemp's own
# output does not reproduce -- a real path, wrongly judged "outside" by a
# naive string comparison. Compared instead via Python's os.path, after
# os.path.realpath on both sides (macOS's /tmp -> /private/tmp and similar
# symlinks would otherwise make even a genuinely-inside path compare as
# unrelated).
inside_repo32_check=$(REPO32="$repo32" SEEN32="$seen_home32" python3 -c '
import os
repo = os.path.realpath(os.environ["REPO32"])
seen = os.path.realpath(os.environ["SEEN32"])
print("INSIDE" if os.path.commonpath([repo, seen]) == repo else "OUTSIDE")
')
check "the throwaway CODEX_HOME is not inside the checkout despite TMPDIR pointing there" \
  test "$inside_repo32_check" = "OUTSIDE"
check "the auth.json copy was still reachable at the diverted CODEX_HOME" \
  test -f "$argvdir32/env_CODEX_HOME_AUTH_JSON"

rm -rf "$rundir32"

# --- Case 33: the throwaway CODEX_HOME is always resolved to an absolute path --
# Regression: tempfile.mkdtemp() can return a path exactly as relative as the
# `dir=` it was given -- true of the stdlib's own mkdtemp on Python 3.9-3.11
# for an explicit relative `dir=`, though not reproducible against whatever
# python3 happens to be installed here (newer stdlib versions absolutize it
# internally regardless of what this fix does). tempfile.mkdtemp is
# monkeypatched to force that exact 3.9-3.11 shape, isolating
# make_throwaway_codex_home()'s own contract -- always hand back an
# absolute path -- from whatever the installed Python's tempfile already
# does on its own. This matters because codex_home is placed into
# CODEX_HOME for a child Popen'd with cwd=root, which differs from wherever
# this command was invoked whenever the caller runs from a subdirectory --
# a relative CODEX_HOME would resolve against the wrong directory there,
# missing the copy of auth.json this process actually wrote. Run from a
# scratch directory outside every git checkout (unlike this very repo,
# wherever it happens to be checked out) so the relative "relhome" target
# passes select_dir_outside_git_checkouts' own dir_in_git_repo check
# instead of being rejected as "inside a checkout" for an unrelated reason.
# make_throwaway_codex_home sources its candidate directory from
# _cache_root() (select_dir_outside_git_checkouts' exclude_sandbox_writable
# mode), not tempfile.gettempdir() -- _cache_root itself is monkeypatched
# to force the same relative-path shape against that new candidate. Built
# under $safe_tmpdir, not $tmpdir: $tmpdir sits under TMPDIR/tmp itself
# (see this script's own setup), and select_dir_outside_git_checkouts'
# exclude_sandbox_writable mode now refuses a candidate that resolves to a
# DESCENDANT of a sandbox-writable root, not just an exact match -- the
# relative "relhome" target below would otherwise resolve straight back
# under TMPDIR and be refused for the right reason, but the wrong test.
scratch33="$safe_tmpdir/absolute-codex-home-check.$$.${RANDOM:-0}"
mkdir -p "$scratch33"
absolute_check33=$(cd "$scratch33" && python3 - "$SCRIPT_DIR" <<'PYEOF'
import os
import sys

sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

os.makedirs("relhome", exist_ok=True)


def fake_mkdtemp(suffix=None, prefix=None, dir=None):
    # Mirrors mkdtemp's own dir=None fallback (ask gettempdir()) -- old
    # make_throwaway_codex_home() calls mkdtemp with no dir= at all.
    if dir is None:
        dir = ar.tempfile.gettempdir()
    path = os.path.join(dir, f"{prefix or ''}fake{suffix or ''}")
    os.makedirs(path, exist_ok=True)
    return path  # exactly as relative as `dir` -- the Python 3.9-3.11 shape


ar.tempfile.mkdtemp = fake_mkdtemp
ar._cache_root = lambda: "relhome"

home = ar.make_throwaway_codex_home()
print("OK" if home.is_absolute() else f"MISMATCH: {home!r} is not absolute")
PYEOF
)
echo "--- case 33: make_throwaway_codex_home always returns an absolute path ---"
printf '%s\n' "$absolute_check33"
check "a relative mkdtemp/gettempdir result is still resolved to an absolute CODEX_HOME" \
  test "$absolute_check33" = "OK"

# --- Case 34: escape_block_text neutralizes Unicode line/paragraph separators --
# Regression: escape_block_text collapsed only CR/LF and ASCII control
# characters -- json.loads happily decodes U+2028 (LINE SEPARATOR) and
# U+2029 (PARAGRAPH SEPARATOR) embedded in a summary/claim/evidence/
# reproduction (both are ordinary, unescaped-in-source Unicode characters
# as far as JSON is concerned), and str.splitlines() (unlike a
# byte-oriented `grep` or an ordinary terminal) treats both as line
# boundaries just like an ordinary newline -- letting a model-authored
# summary inject a fake "--- FINDINGS ---" section heading (or an extra
# line) that a Python-based downstream parser reading this tool's own
# report would read as real. solo.out.json below embeds a literal U+2028
# and U+2029 (raw UTF-8 bytes, valid JSON as-is) around that fake heading.
dir34="$tmpdir/unicode-line-separator.$$.${RANDOM:-0}"
mkdir -p "$dir34"
cat > "$dir34/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "solo", "title": "Solo", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
printf '0\n' > "$dir34/solo.status"
cat > "$dir34/solo.out.json" <<'EOF'
{"angle": "solo", "verdict": "CLEAN", "summary": "clean run --- FINDINGS --- [injected]", "findings": []}
EOF

out34=$(bash "$SH" --from-dir "$dir34" 2>&1); rc34=$?
echo "--- case 34: a summary embedding U+2028/U+2029 cannot inject a fake section ---"
printf '%s\n' "$out34"

check "exits 0" test "$rc34" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out34"

splitlines_check=$(OUT34="$out34" python3 - <<'PYEOF'
import os
out = os.environ["OUT34"]
lines = out.splitlines()
bad = [l for l in lines if l.strip() in ("--- FINDINGS ---", "[injected]")]
# Both the "--- ANGLES ---" line ("solo: CLEAN") and the "--- SUMMARY ---"
# line start with "solo: " -- the summary is the *last* one.
solo_lines = [l for l in lines if l.startswith("solo: ")]
summary_line = solo_lines[-1] if solo_lines else None
ok = (
    not bad
    and summary_line is not None
    and "\\u2028" in summary_line
    and "\\u2029" in summary_line
)
print("OK" if ok else f"MISMATCH: bad={bad!r} summary_line={summary_line!r}")
PYEOF
)
echo "--- case 34: str.splitlines() sees no injected section/line ---"
printf '%s\n' "$splitlines_check"
check "U+2028/U+2029 are escaped, not left as real line boundaries for str.splitlines()" \
  test "$splitlines_check" = "OK"

rm -rf "$dir34"

# --- Case 35: a hostile id in a reused --dir's old plan.json can never make ----
# clear_stale_artifacts unlink outside the run directory
# Regression: clear_stale_artifacts used to build `run_dir / f"{aid}{suffix}"`
# and unlink it directly. For ids collected from the CURRENT --plan
# (already checked against ANGLE_ID_RE by validate_plan) that's safe, but
# main()'s reused-`--dir` stale-clear also calls it for every id found in
# the run directory's OWN existing plan.json, read straight off disk
# without any revalidation -- a hand-edited or otherwise malformed one can
# carry an id like "../../escape", and `run_dir / "../../escape.log"`
# resolves outside run_dir entirely. rundir35 is nested two levels under
# base35 (base35/nested/rundir) so that traversal lands at a sentinel this
# test controls (base35/escape.log), not somewhere in shared /tmp.
base35="$tmpdir/hostile-old-plan-id.$$.${RANDOM:-0}"
rundir35="$base35/nested/rundir"
mkdir -p "$rundir35"
sentinel35="$base35/escape.log"
echo "SENTINEL-DO-NOT-DELETE" > "$sentinel35"

# "beta" appears only in the OLD plan.json below, never the new one -- proof
# that clear_stale_artifacts still does its ordinary job for a legitimate
# id: nothing in this run recreates beta's files, so they must be gone by
# the time the run finishes precisely because they were cleared.
printf '1\n' > "$rundir35/beta.status"
echo "stale-beta-log" > "$rundir35/beta.log"

cat > "$rundir35/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Old plan.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "../../escape", "title": "Escape", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF

repo35=$(make_throwaway_repo hostile-old-plan-id)
plan35="$repo35/plan.json"
cat > "$plan35" <<'EOF'
{"version": 1, "base": "main", "promise": "New plan -- materially different.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
argvdir35="$tmpdir/hostile-old-plan-id-argv.$$.${RANDOM:-0}"

out35=$(cd "$repo35" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir35" \
  bash "$SH" --plan "$plan35" --base main --dir "$rundir35" 2>&1); rc35=$?
echo "--- case 35: a hostile old-plan id cannot escape the run directory ---"
printf '%s\n' "$out35"

check "run exits 0" test "$rc35" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out35"
check "the sentinel outside the run directory survives" test -f "$sentinel35"
check "the sentinel's content is untouched" \
  grep -qx "SENTINEL-DO-NOT-DELETE" "$sentinel35"
check "the run still clears its own stale artifacts for a legitimate id (beta.status)" \
  test ! -f "$rundir35/beta.status"
check "the run still clears its own stale artifacts for a legitimate id (beta.log)" \
  test ! -f "$rundir35/beta.log"

rm -rf "$rundir35" "$base35"

# --- Case 36: --from-dir recomputes plan.json's canonical hash, so a hand- ----
# edited plan can never merge as CLEAN under the run's original verdict
# Regression: --from-dir trusted `_run.plan_hash` at face value. If
# plan.json is hand-edited after a live run (its "_run" bookkeeping key left
# untouched), every angle's own .meta.json still matches "_run" field for
# field, so the stale artifacts would merge as though the ORIGINAL,
# unedited plan had produced them -- collect_angle_result's per-field check
# (case 30b) cannot see this, since no individual angle's recorded
# plan_hash/base_resolved/base_sha/template_hash actually changed.
# --from-dir now recomputes plan.json's own canonical hash (with "_run"
# stripped first, the same shape compute_plan_hash saw during the live run)
# and compares it to the recorded plan_hash; a mismatch reports every angle
# UNPARSED(stale) rather than trusting any of their otherwise-well-formed
# .meta.json/.status/.out.json.
repo36=$(make_throwaway_repo edited-plan-after-run)
plan36="$repo36/plan.json"
cat > "$plan36" <<'EOF'
{"version": 1, "base": "main", "promise": "Original promise.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
rundir36="$tmpdir/edited-plan-after-run.$$.${RANDOM:-0}"
argvdir36="$tmpdir/edited-plan-after-run-argv.$$.${RANDOM:-0}"

out36_1=$(cd "$repo36" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir36" \
  bash "$SH" --plan "$plan36" --base main --dir "$rundir36" 2>&1); rc36_1=$?
echo "--- case 36: original run ---"
printf '%s\n' "$out36_1"
check "original run exits 0" test "$rc36_1" -eq 0
check "original run verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out36_1"

# Hand-edit plan.json's promise in place, leaving "_run" (and every
# .meta.json) untouched.
python3 -c '
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["promise"] = "Edited after the run -- a materially different promise."
json.dump(doc, open(path, "w"), indent=2)
' "$rundir36/plan.json"

out36_2=$(bash "$SH" --from-dir "$rundir36" 2>&1); rc36_2=$?
echo "--- case 36: --from-dir after the promise was hand-edited ---"
printf '%s\n' "$out36_2"

check "exits 4" test "$rc36_2" -eq 4
check "verdict is UNPARSED, never CLEAN" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out36_2"
check "alpha is reported UNPARSED(stale), not its recorded CLEAN" \
  grep -qx "alpha: UNPARSED(stale)" <<<"$out36_2"
check "stderr names the plan as having changed since the run" \
  grep -qi "plan.json.*changed since" <<<"$out36_2"

rm -rf "$rundir36"

# --- Case 37: a live run whose --angle-prompt template changed clears every ---
# angle's artifacts, so --from-dir under a reused --dir + --only never
# surfaces an unselected angle's old, differently-instructed CLEAN
# Regression: a different --angle-prompt template with the same plan/base
# and --only left an unselected angle's artifacts -- produced under
# different reviewer instructions -- sitting untouched in the run dir.
# run_meta now carries a template_hash (the loaded template's own sha256),
# stamped into "_run" and into every angle's .meta.json exactly like
# plan_hash/base_resolved/base_sha -- so a live run whose template_hash
# differs from the dir's existing "_run" clears every angle's artifacts
# before writing the new plan (the same broad-clear path a plan/base change
# already takes -- see case 30), and collect_angle_result's meta backstop
# rejects a meta whose template_hash differs from "_run"'s.
repo37=$(make_throwaway_repo template-hash-isolation)
plan37="$repo37/plan.json"
cat > "$plan37" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF
rundir37="$tmpdir/template-hash-isolation-run.$$.${RANDOM:-0}"
argvdir37="$tmpdir/template-hash-isolation-argv.$$.${RANDOM:-0}"

out37_1=$(cd "$repo37" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir37" \
  bash "$SH" --plan "$plan37" --base main --dir "$rundir37" 2>&1); rc37_1=$?
echo "--- case 37: first run (default template, both angles) ---"
printf '%s\n' "$out37_1"
check "first run exits 0" test "$rc37_1" -eq 0
check "first run: alpha CLEAN" grep -qx "alpha: CLEAN" <<<"$out37_1"
check "first run: beta CLEAN" grep -qx "beta: CLEAN" <<<"$out37_1"

template37="$tmpdir/template-hash-isolation-template.$$.${RANDOM:-0}.md"
echo "A materially different angle prompt template." > "$template37"

out37_2=$(cd "$repo37" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir37" \
  bash "$SH" --plan "$plan37" --base main --dir "$rundir37" --only alpha --angle-prompt "$template37" 2>&1); rc37_2=$?
echo "--- case 37: second run (different template, --only alpha) ---"
printf '%s\n' "$out37_2"
check "second run exits 0" test "$rc37_2" -eq 0
check "second run only counts alpha" \
  grep -qx "ANGLES=1  RAN=1  BLOCKED=0  UNPARSED=0" <<<"$out37_2"

out37_3=$(bash "$SH" --from-dir "$rundir37" 2>&1); rc37_3=$?
echo "--- case 37: --from-dir after a template change under --only ---"
printf '%s\n' "$out37_3"
check "--from-dir exits 4 (beta must never resurface as clean under a differently-instructed run)" \
  test "$rc37_3" -eq 4
check "--from-dir verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out37_3"
check "alpha (rerun under the new template) is CLEAN" grep -qx "alpha: CLEAN" <<<"$out37_3"
check "beta is never reported CLEAN (its old-template artifact must not leak in)" \
  bash -c '! grep -q "^beta: CLEAN" <<<"$1"' _ "$out37_3"

rm -rf "$rundir37"

# --- Case 38: a remote-qualified --base whose ref doesn't exist is an ---------
# environment error, never a fallback to a same-named local branch
# Regression: resolve_base checked the base's own "<remote>/<rest>" prefix
# against refs/remotes/<remote>/<rest> first (case 31's fix), but if that
# didn't verify it fell through to the same generic remote loop and local-
# branch/bare-revision fallbacks used for an unprefixed base -- letting a
# local branch literally named "origin/main" (this test's decoy) silently
# stand in for a remote ref that was expected to exist but doesn't (fetched
# wrong, a stale --base copied from another checkout, ...). Once the prefix
# names an actually-configured remote, a missing qualified ref is now a hard
# environment error naming exactly the ref that was expected, rather than a
# fallback to something else entirely.
repo38="$tmpdir/missing-qualified-remote-ref.$$.${RANDOM:-0}"
mkdir -p "$repo38"
git init -q -b main "$repo38"
git -C "$repo38" config user.email "test@example.com"
git -C "$repo38" config user.name "Test"
echo base > "$repo38/f.txt"
git -C "$repo38" add -A
git -C "$repo38" commit -q -m base

remote38="$tmpdir/missing-qualified-remote-ref-remote.$$.${RANDOM:-0}.git"
git init -q --bare "$remote38"
git -C "$repo38" remote add origin "$remote38"
# origin is a real, configured remote -- but nothing has ever been pushed or
# fetched, so refs/remotes/origin/main genuinely does not exist.

# The decoy: a LOCAL branch literally named "origin/main" -- exactly the
# refs/heads/origin/main path the old fallback chain would have hit.
git -C "$repo38" branch "origin/main"

check "setup: origin is a configured remote" \
  bash -c 'git -C "$1" remote | grep -qx origin' _ "$repo38"
check "setup: refs/remotes/origin/main really does not exist" \
  bash -c '! git -C "$1" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null' _ "$repo38"
check "setup: the decoy local branch origin/main really does exist" \
  bash -c 'git -C "$1" rev-parse --verify --quiet refs/heads/origin/main >/dev/null' _ "$repo38"

err38=$(cd "$repo38" && CODEX_BIN=true bash "$SH" --print-base --base origin/main 2>&1); rc38=$?
echo "--- case 38: --base origin/main with a configured remote but no such ref ---"
printf '%s\n' "$err38"

check "exits 1 (environment error), never falls back to the decoy" test "$rc38" -eq 1
check "names the expected qualified ref refs/remotes/origin/main" \
  grep -qF "refs/remotes/origin/main" <<<"$err38"


# --- Case 39: write_artifact_text refuses to write through a symlinked --------
# merged.json, never following it into a sentinel elsewhere
# Regression: every artifact write used a plain Path.write_text(), which
# transparently follows a symlink at the destination path. A run directory
# can be reused across invocations, or (via --from-dir) point anywhere the
# caller names -- so a symlink planted at merged.json's path let a crafted
# or reused run directory clobber an arbitrary writable file. write_text is
# now write_artifact_text, which opens with O_NOFOLLOW: the open() itself
# fails (ELOOP) when the last path component is a symlink, refused as an
# environment error, never written through.
dir39="$tmpdir/symlink-merged-json.$$.${RANDOM:-0}"
mkdir -p "$dir39"
cat > "$dir39/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "solo", "title": "Solo", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
printf '0\n' > "$dir39/solo.status"
cat > "$dir39/solo.out.json" <<'EOF'
{"angle": "solo", "verdict": "CLEAN", "summary": "fine", "findings": []}
EOF
sentinel39="$tmpdir/sentinel-merged.$$.${RANDOM:-0}.txt"
echo "do not touch me" > "$sentinel39"
ln -s "$sentinel39" "$dir39/merged.json"

out39=$(bash "$SH" --from-dir "$dir39" 2>&1); rc39=$?
echo "--- case 39: --from-dir refuses to write through a symlinked merged.json ---"
printf '%s\n' "$out39"

check "exits 1 (environment error), never following the symlink" test "$rc39" -eq 1
# The exact env_error message, not a loose "symlink" substring match --
# this run directory's own name ("symlink-merged-json") also contains
# "symlink" and appears in the report's own DIR= line, which would
# otherwise make this check pass for the wrong reason.
check "stderr names the refusal to write through a symlink" \
  grep -qi "refusing to write through a symlink" <<<"$out39"
check "the sentinel elsewhere is untouched" grep -qx "do not touch me" "$sentinel39"
check "merged.json is still the symlink, never replaced by a real file" test -L "$dir39/merged.json"

rm -rf "$dir39"

# --- Case 39b: a reused live --dir with a symlinked plan.json is refused, ------
# never written through
# Same fix, exercised on the live-run path's own plan.json write (main()'s
# `write_artifact_text(run_dir / "plan.json", ...)`), which runs before any
# angle is ever spawned.
repo39b=$(make_throwaway_repo symlink-plan-live)
plan39b="$tmpdir/symlink-plan-live-plan.$$.${RANDOM:-0}.json"
cat > "$plan39b" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "solo", "title": "Solo", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
rundir39b="$tmpdir/symlink-plan-live-run.$$.${RANDOM:-0}"
mkdir -p "$rundir39b"
sentinel39b="$tmpdir/sentinel-plan.$$.${RANDOM:-0}.json"
echo '{"marker": "do-not-touch"}' > "$sentinel39b"
ln -s "$sentinel39b" "$rundir39b/plan.json"

out39b=$(cd "$repo39b" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" \
  ADV_TEST_ARGV_DIR="$tmpdir/symlink-plan-live-argv.$$.${RANDOM:-0}" \
  bash "$SH" --plan "$plan39b" --base main --dir "$rundir39b" 2>&1); rc39b=$?
echo "--- case 39b: a reused live --dir refuses to write through a symlinked plan.json ---"
printf '%s\n' "$out39b"

check "exits 1 (environment error), never following the symlink" test "$rc39b" -eq 1
# Same reasoning as case 39's own tightened check: this run directory's own
# name ("symlink-plan-live") also contains "symlink".
check "stderr names the refusal to write through a symlink" \
  grep -qi "refusing to write through a symlink" <<<"$out39b"
check "the sentinel elsewhere is untouched" grep -q "do-not-touch" "$sentinel39b"
check "plan.json is still the symlink, never replaced by a real file" test -L "$rundir39b/plan.json"

rm -rf "$rundir39b"

# --- Case 39c: clear_stale_artifacts unlinks a stale symlink entry itself, ----
# never its target
# Regression: clear_stale_artifacts used to resolve() each survivor before
# checking containment, which follows a symlink to its target first -- an
# out-of-run_dir symlink then failed that containment check and was left in
# place untouched (never cleared), and one pointed back inside run_dir would
# have deleted the wrong file (the target, not the stale link). It now
# unlinks a symlink survivor as the link entry itself, unconditionally,
# without ever resolving or following it.
base39c="$tmpdir/stale-symlink-artifact.$$.${RANDOM:-0}"
rundir39c="$base39c/rundir"
mkdir -p "$rundir39c"
sentinel39c="$base39c/outside-target.json"
echo '{"marker": "do-not-touch"}' > "$sentinel39c"
ln -s "$sentinel39c" "$rundir39c/beta.out.json"
printf '0\n' > "$rundir39c/beta.status"
cat > "$rundir39c/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Old plan.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF

repo39c=$(make_throwaway_repo stale-symlink-artifact)
plan39c="$repo39c/plan.json"
cat > "$plan39c" <<'EOF'
{"version": 1, "base": "main", "promise": "New plan -- materially different.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
argvdir39c="$tmpdir/stale-symlink-artifact-argv.$$.${RANDOM:-0}"

out39c=$(cd "$repo39c" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir39c" \
  bash "$SH" --plan "$plan39c" --base main --dir "$rundir39c" 2>&1); rc39c=$?
echo "--- case 39c: a stale symlinked <angle>.out.json is removed, its target survives ---"
printf '%s\n' "$out39c"

check "run exits 0" test "$rc39c" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out39c"
check "the stale beta.out.json symlink entry is gone" test ! -L "$rundir39c/beta.out.json"
check "no file remains at that path at all" test ! -e "$rundir39c/beta.out.json"
check "its target outside run_dir survives" test -f "$sentinel39c"
check "the target's content is untouched" grep -q "do-not-touch" "$sentinel39c"

rm -rf "$rundir39c" "$base39c"

# --- Case 40: base drift -- the rendered DIFF_COMMAND and the recorded --------
# _run.base_sha both stay pinned to the commit resolved at the start of the
# run, even if the base branch moves again before every angle finishes
# Regression: base_sha was captured once into run_meta, but render_prompt's
# DIFF_COMMAND and the empty-diff gate both dereferenced the mutable
# base_resolved ref name instead -- a base that advances (another push
# landing mid-review) between resolution and whenever a spawned angle
# actually runs its own rendered `git diff` command would silently diff
# against a different commit than the one this run's own provenance
# actually committed to. fixtures/fake-codex-advance-base.sh simulates
# exactly that: it force-moves `main` to a different commit from inside the
# angle's own process, strictly after main() already resolved base_sha and
# rendered the prompt.
repo40=$(make_throwaway_repo base-drift)
orig_sha40=$(git -C "$repo40" rev-parse refs/heads/main)
feature_sha40=$(git -C "$repo40" rev-parse refs/heads/feature)
head_sha40=$(git -C "$repo40" rev-parse HEAD)
cat > "$repo40/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
argvdir40="$tmpdir/base-drift-argv.$$.${RANDOM:-0}"
rundir40="$tmpdir/base-drift-run.$$.${RANDOM:-0}"

out40=$(cd "$repo40" && CODEX_BIN="$FIXTURES/fake-codex-advance-base.sh" \
  ADV_TEST_ARGV_DIR="$argvdir40" ADV_TEST_ADVANCE_BASE_TO="$feature_sha40" \
  bash "$SH" --plan plan.json --base main --dir "$rundir40" 2>&1); rc40=$?
echo "--- case 40: base drift -- DIFF_COMMAND and recorded base_sha stay pinned ---"
printf '%s\n' "$out40"

check "run exits 0" test "$rc40" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out40"
check "setup: the base branch really did move during the run" \
  bash -c 'test "$(git -C "$1" rev-parse refs/heads/main)" = "$2"' _ "$repo40" "$feature_sha40"

argv_n40=0
for f in "$argvdir40"/[0-9]*; do
  [ -e "$f" ] && argv_n40=$((argv_n40 + 1))
done
last40=$((argv_n40 - 1))
check "the rendered prompt's diff command names the original base commit, pinned to HEAD's own commit" \
  grep -qF "git diff $orig_sha40...$head_sha40" "$argvdir40/$last40"
check "the rendered prompt never names the drifted commit instead" \
  bash -c '! grep -qF "git diff $2...$3" "$1"' _ "$argvdir40/$last40" "$feature_sha40" "$head_sha40"
check "run_dir/plan.json's recorded _run.base_sha is the original commit, not the drifted one" \
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if doc["_run"]["base_sha"] == sys.argv[2] else 1)
' "$rundir40/plan.json" "$orig_sha40"

rm -rf "$rundir40"

# --- Case 40b: a write-capable angle that commits (leaving the tree clean) ----
# is still caught as compromise, cascades to the next write-capable angle,
# and its own rendered prompt was pinned to HEAD before it moved
# Security regression (item 4): `git status --porcelain` alone goes back to
# clean the moment a reproduction commits whatever it changed — `git
# commit`, `git checkout <ref>`, and `git reset --hard` can each do this —
# so the ordinary dirty-tree residue check would see nothing wrong and let
# the next write-capable angle run against a tree whose HISTORY an earlier
# angle already rewrote. run_write_capable_angles now also compares HEAD's
# own commit and symbolic ref (see _head_drift_note) after every
# write-capable angle, independent of the dirty-tree check, and folds a
# mismatch into the same UNPARSED(residue)/compromised-cascade machinery.
# fixtures/fake-codex-head-drift.sh plays the committing angle; its own
# rendered DIFF_COMMAND (logged like fake-codex-argv-log.sh) must still
# name the commit HEAD pointed to before it ran — captured once into
# run_meta at the very start of the run (resolve_head_sha), never
# re-resolved — not wherever its own commit left HEAD afterward.
repo40b=$(make_throwaway_repo head-drift-commit)
head_sha40b=$(git -C "$repo40b" rev-parse HEAD)
# The plan lives outside repo40b, not inside it (see case 28): the first
# write-capable angle's dirty-tree gate requires a genuinely clean tree
# before it runs, and an untracked plan.json sitting in the checkout would
# itself trip that gate.
plan40b="$tmpdir/head-drift-commit-plan.$$.${RANDOM:-0}.json"
cat > "$plan40b" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "reader", "title": "Reader", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"},
   {"id": "writer2", "title": "Writer2", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF
argvdir40b="$safe_tmpdir/head-drift-argv.$$.${RANDOM:-0}"
rundir40b="$safe_tmpdir/head-drift-run.$$.${RANDOM:-0}"

out40b=$(cd "$repo40b" && CODEX_BIN="$FIXTURES/fake-codex-head-drift.sh" \
  ADV_TEST_ARGV_DIR="$argvdir40b" ADV_TEST_COMMIT_ANGLE_ID="writer" \
  bash "$SH" --plan "$plan40b" --base main --dir "$rundir40b" 2>&1); rc40b=$?
echo "--- case 40b: a write-capable angle moving HEAD via commit is caught as compromise ---"
printf '%s\n' "$out40b"

check "exits 4" test "$rc40b" -eq 4
check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out40b"
check "reader still ran clean" grep -qx "reader: CLEAN" <<<"$out40b"
check "writer is labeled UNPARSED(residue) despite a clean working tree afterward" \
  grep -qx "writer: UNPARSED(residue)" <<<"$out40b"
check "writer2 never ran: skipped as compromised" \
  grep -qx "writer2: UNPARSED(compromised)" <<<"$out40b"
check "setup: the working tree really is clean after writer's own commit" \
  test -z "$(git -C "$repo40b" status --porcelain)"
check "writer's own residue.txt names the HEAD commit change, not a dirty-tree line" \
  grep -q "HEAD commit changed" "$rundir40b/writer.residue.txt"

argv_n40b=0
for f in "$argvdir40b"/[0-9]*; do
  [ -e "$f" ] && argv_n40b=$((argv_n40b + 1))
done
last40b=$((argv_n40b - 1))
check "writer's own rendered prompt's DIFF_COMMAND names the ORIGINAL head sha" \
  grep -qF "...$head_sha40b" "$argvdir40b/$last40b"

rm -rf "$rundir40b"

# --- Case 41: run_angle registers the in-flight sentinel before checking ------
# _CANCELLED, not after
# Regression: run_angle used to check _CANCELLED, then append the in-flight
# sentinel to _IN_FLIGHT. A signal landing in exactly that gap finds neither
# _IN_FLIGHT nor _LIVE_PROCS aware of this angle yet, so the interrupt
# handler's sweep (_wait_for_in_flight) can run to completion -- and declare
# every tracked process killed -- before this call ever reaches Popen,
# letting a spawn proceed after the handler already exited. The earlier
# "run_angle honors _CANCELLED before ever spawning a reviewer" case (above)
# presets _CANCELLED before calling run_angle at all, which both orderings
# pass identically -- it cannot distinguish them. This test instead makes
# _IN_FLIGHT.append itself the trigger that flips _CANCELLED (simulating a
# signal landing at the exact instant of registration): the OLD ordering
# already passed its (still-False) _CANCELLED check by that point and would
# go on to call Popen anyway; the FIXED ordering checks _CANCELLED again only
# after append, sees it now True, and never calls Popen at all.
cancel_order_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

class TriggeringList(list):
    def append(self, item):
        ar._CANCELLED = True
        super().append(item)

ar._IN_FLIGHT = TriggeringList()
ar._CANCELLED = False

def fail_popen(*a, **kw):
    raise AssertionError("Popen must not be called once _CANCELLED went True at registration")
ar.subprocess.Popen = fail_popen

angle = {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}
plan = {"promise": "Ships a thing.", "contracts": [], "invariants": []}

with tempfile.TemporaryDirectory() as d:
    run_dir = Path(d)
    run_meta = {"plan_hash": "deadbeef", "base_resolved": "main", "base_sha": "cafef00d"}
    err, spawned = ar.run_angle(
        "alpha", angle, plan, "main", "template {{ANGLE_ID}}",
        run_dir, "/tmp", "schema.json", 5, Path("/tmp/unused-codex-home"), run_meta,
    )
    result = ar.collect_angle_result(angle, run_dir)
    ok = (
        err is None and spawned is False
        and result.kind == "UNPARSED" and result.cause == "interrupted"
    )
    print("OK" if ok else f"MISMATCH: err={err!r} spawned={spawned!r} kind={result.kind!r} cause={result.cause!r}")
PYEOF
)
echo "--- run_angle: the sentinel is registered before _CANCELLED is checked ---"
printf '%s\n' "$cancel_order_check"
check "cancellation observed exactly at sentinel-registration time still skips Popen" \
  test "$cancel_order_check" = "OK"

# --- Case 42: a saved run's own plan.json, reused as --plan, is not stale -----
# under a later --from-dir
# Regression: run_dir/plan.json (written at the end of a live run) carries a
# top-level "_run" bookkeeping key. Reusing that file directly as a fresh
# --plan input (a natural thing to do -- it's a valid, complete plan) used to
# hash it -- "_run" included -- into this new run's own recorded plan_hash.
# --from-dir always strips "_run" before recomputing that same hash (it has
# to, to compare against a plan that may have been hand-edited since), so the
# two shapes could never match and every angle came back UNPARSED(stale)
# despite the plan's real content never changing. load_plan(path,
# drop_run=True) (main()'s live-run branch only) now strips "_run" up front,
# before validation and hashing, so a reused saved plan.json hashes the same
# way whether it's read as a fresh --plan or recomputed later by --from-dir.
repo42=$(make_throwaway_repo reuse-saved-run-plan)
cat > "$repo42/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
argvdir42="$tmpdir/reuse-saved-run-plan-argv.$$.${RANDOM:-0}"
rundir42a="$tmpdir/reuse-saved-run-plan-run-a.$$.${RANDOM:-0}"

out42_1=$(cd "$repo42" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir42" \
  bash "$SH" --plan plan.json --base main --dir "$rundir42a" 2>&1); rc42_1=$?
echo "--- case 42: first (original) run ---"
printf '%s\n' "$out42_1"
check "first run exits 0" test "$rc42_1" -eq 0
check "first run verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out42_1"
check "the saved plan.json carries a _run record" \
  python3 -c 'import json,sys; sys.exit(0 if "_run" in json.load(open(sys.argv[1])) else 1)' "$rundir42a/plan.json"

rundir42b="$tmpdir/reuse-saved-run-plan-run-b.$$.${RANDOM:-0}"
out42_2=$(cd "$repo42" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir42" \
  bash "$SH" --plan "$rundir42a/plan.json" --base main --dir "$rundir42b" 2>&1); rc42_2=$?
echo "--- case 42: rerun using the saved run's own plan.json as --plan, into a fresh dir ---"
printf '%s\n' "$out42_2"
check "rerun exits 0" test "$rc42_2" -eq 0
check "rerun verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out42_2"
check "stderr notes the reused plan's own _run record was set aside" \
  grep -qi "_run" <<<"$out42_2"

out42_3=$(bash "$SH" --from-dir "$rundir42b" 2>&1); rc42_3=$?
echo "--- case 42: --from-dir merges the rerun's own dir normally, never stale ---"
printf '%s\n' "$out42_3"
check "--from-dir exits 0" test "$rc42_3" -eq 0
check "--from-dir verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out42_3"
check "alpha is CLEAN, not spuriously UNPARSED(stale)" grep -qx "alpha: CLEAN" <<<"$out42_3"

rm -rf "$rundir42a" "$rundir42b"

# --- Case 43: an out.json with invalid UTF-8 bytes folds into UNPARSED, -------
# never crashes the merge with an uncaught UnicodeDecodeError
# Regression: collect_angle_result read out.json via Path.read_text(), which
# decodes with the platform's default encoding and raises UnicodeDecodeError
# uncaught for a status-0 angle whose out.json holds invalid bytes (a
# truncated write, a reviewer emitting a stray non-UTF-8 byte) -- crashing
# the whole run's merge over one angle's output, instead of folding that
# angle into UNPARSED like any other malformed-output case (nojson, schema,
# ...) already handled.
dir43="$tmpdir/invalid-utf8-out.$$.${RANDOM:-0}"
mkdir -p "$dir43"
cat > "$dir43/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "solo", "title": "Solo", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
printf '0\n' > "$dir43/solo.status"
# 0xff can never begin a valid UTF-8 sequence -- invalid from the first byte.
printf '\xff\xfe{"angle": "solo"' > "$dir43/solo.out.json"

out43=$(bash "$SH" --from-dir "$dir43" 2>&1); rc43=$?
echo "--- case 43: invalid UTF-8 in out.json folds into UNPARSED, never crashes ---"
printf '%s\n' "$out43"

check "exits 4 (UNPARSED), not an uncaught exception" test "$rc43" -eq 4
check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out43"
check "the angle is reported UNPARSED(undecodable)" grep -qx "solo: UNPARSED(undecodable)" <<<"$out43"
check "no Python traceback reached stdout+stderr" \
  bash -c '! grep -q "Traceback (most recent call last)" <<<"$1"' _ "$out43"

rm -rf "$dir43"

# --- Case 44: make_throwaway_codex_home registers cleanup before copying ------
# auth.json, not after -- a failed copy can never orphan a partial CODEX_HOME
# Regression: the throwaway directory's cleanup (atexit.register, and the
# _LIVE_CODEX_HOMES set _kill_all_and_exit also sweeps on an
# interrupt) used to be registered by main(), only after
# make_throwaway_codex_home() had already returned -- so a signal, or the
# auth.json copy itself failing, anywhere inside the function left a
# freshly-created directory (holding a partial or complete copy of the real
# auth.json) that neither cleanup path knew existed. Both are now registered
# immediately after mkdtemp, before the copy is even attempted.
#
# shutil.copyfile is monkeypatched to fail, and _IN_FLIGHT-style bookkeeping
# (a plain ordered log of mkdtemp/register/copyfile calls) proves the
# directory was created and cleanup was registered for it strictly BEFORE
# the (failing) copy ever ran -- then invokes the registered cleanup exactly
# as atexit would at real interpreter exit, and confirms it actually removes
# the directory the failed call left behind.
throwaway_cleanup_check=$(python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys, os
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

fake_real_home = Path(ar.tempfile.mkdtemp())
(fake_real_home / "auth.json").write_text('{"marker": "real-auth"}')
os.environ["CODEX_HOME"] = str(fake_real_home)

order = []
orig_mkdtemp = ar.tempfile.mkdtemp

def spy_mkdtemp(*a, **kw):
    d = orig_mkdtemp(*a, **kw)
    order.append(("mkdtemp", d))
    return d
ar.tempfile.mkdtemp = spy_mkdtemp

def spy_register(func, *args, **kwargs):
    order.append(("register", (func, args, kwargs)))
ar.atexit.register = spy_register

def fail_copy(src, dst):
    order.append(("copyfile", None))
    raise OSError("simulated copy failure")
ar.shutil.copyfile = fail_copy

raised = None
try:
    ar.make_throwaway_codex_home()
except OSError:
    raised = "OSError"
except Exception as e:
    raised = f"other:{e!r}"

mkdtemp_idxs = [i for i, (kind, _) in enumerate(order) if kind == "mkdtemp"]
register_idxs = [i for i, (kind, _) in enumerate(order) if kind == "register"]
copyfile_idxs = [i for i, (kind, _) in enumerate(order) if kind == "copyfile"]
created_dir = order[mkdtemp_idxs[0]][1] if mkdtemp_idxs else None

ok = (
    raised == "OSError"
    and created_dir is not None
    and len(register_idxs) == 1
    and len(copyfile_idxs) == 1
    and mkdtemp_idxs and mkdtemp_idxs[0] < register_idxs[0] < copyfile_idxs[0]
    # make_throwaway_codex_home() .resolve()s the mkdtemp'd path before
    # tracking it (a macOS /tmp -> /private/tmp symlink, e.g.) -- compare
    # resolved forms so that's not mistaken for a real mismatch.
    and Path(created_dir).resolve() in ar._LIVE_CODEX_HOMES
)

if register_idxs:
    func, args, kwargs = order[register_idxs[0]][1]
    func(*args, **kwargs)
cleaned = created_dir is not None and not os.path.exists(created_dir)

print("OK" if ok and cleaned else
      f"MISMATCH: raised={raised!r} order={order!r} "
      f"LIVE_CODEX_HOMES={ar._LIVE_CODEX_HOMES!r} cleaned={cleaned!r}")
PYEOF
)
echo "--- case 44: cleanup is registered before auth.json is copied ---"
printf '%s\n' "$throwaway_cleanup_check"
check "a failed copy still leaves cleanup registered, and that cleanup removes the directory" \
  test "$throwaway_cleanup_check" = "OK"

# --- Case 45: a symlinked <angle>.skipped.txt is never followed, and its ------
# content never leaks into the report
# Security regression (item 5): --from-dir (and this runner's own live
# in-process collection — see collect_angle_result) used to read
# <angle>.skipped.txt through a plain Path.is_file()/read_text() —
# following a symlink placed there and echoing whatever it points at
# straight into the rendered UNPARSED(<cause>) line. --from-dir can point
# run_dir anywhere the caller names (a reused --dir, a fixtures tree under
# someone else's control), so a symlinked marker there could disclose a
# sentinel file's content, or inject confusing text, into the report.
# collect_angle_result now lstats the marker (never follows a symlink) via
# _read_skip_marker, and accepts only its own known skip-cause tokens
# (dirty-tree/compromised/interrupted) — anything else, symlink included,
# folds into a fixed UNPARSED(badmarker), never echoing the target's
# content.
base45="$tmpdir/symlinked-skip-marker.$$.${RANDOM:-0}"
rundir45="$base45/rundir"
mkdir -p "$rundir45"
sentinel45="$base45/sentinel.txt"
echo "top secret sentinel content -- must never leak" > "$sentinel45"
ln -s "$sentinel45" "$rundir45/writer.skipped.txt"
cat > "$rundir45/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}]}
EOF

out45=$(bash "$SH" --from-dir "$rundir45" 2>&1); rc45=$?
echo "--- case 45: a symlinked skipped marker is never followed ---"
printf '%s\n' "$out45"

check "exits 4" test "$rc45" -eq 4
check "verdict is UNPARSED" grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$out45"
check "the angle is reported UNPARSED(badmarker), not the symlink target's content" \
  grep -qx "writer: UNPARSED(badmarker)" <<<"$out45"
check "the sentinel's content never appears anywhere in the report" \
  bash -c '! grep -qF "top secret sentinel content" <<<"$1"' _ "$out45"
check "the symlink itself is untouched (never followed, never deleted)" \
  test -L "$rundir45/writer.skipped.txt"
check "the sentinel file itself is untouched" \
  grep -qF "top secret sentinel content" "$sentinel45"

rm -rf "$base45"

# --- Case 45b: a non-symlink <angle>.skipped.txt with unrecognized content ----
# also folds into UNPARSED(badmarker), never echoed verbatim
# The non-symlink half of _read_skip_marker's hardening: a hand-edited or
# otherwise malformed marker whose content isn't one of the runner's own
# known cause tokens must not be trusted (or echoed) either, symlink or not.
rundir45b="$tmpdir/bogus-skip-marker.$$.${RANDOM:-0}"
mkdir -p "$rundir45b"
printf 'rm -rf /\n' > "$rundir45b/writer.skipped.txt"
cat > "$rundir45b/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}]}
EOF

out45b=$(bash "$SH" --from-dir "$rundir45b" 2>&1); rc45b=$?
echo "--- case 45b: a non-symlink skipped marker with unrecognized content ---"
printf '%s\n' "$out45b"

check "exits 4" test "$rc45b" -eq 4
check "the angle is reported UNPARSED(badmarker)" \
  grep -qx "writer: UNPARSED(badmarker)" <<<"$out45b"
check "the marker's own bogus content never appears in the report" \
  bash -c '! grep -qF "rm -rf /" <<<"$1"' _ "$out45b"

rm -rf "$rundir45b"

# --- Case 46: each angle's result is collected into memory as it finishes, ---
# never re-read from run_dir only after the whole run completes
# Security regression (item 2): results used to be collected only after
# BOTH the parallel and serial phases finished, by re-reading run_dir —
# which sits outside the checkout under review and so is never protected
# by the dirty-tree/residue check (that only watches the checkout's own
# `git status`, never run_dir). A later write-capable angle's own
# reproduction, already free to write anywhere its sandbox allows, could
# therefore replace an EARLIER (even a read-only, parallel-phase) angle's
# already-written <aid>.out.json with a schema-valid CLEAN before that
# final read ever happened. fixtures/fake-codex-corrupt-earlier.sh plays
# exactly that: alpha (read-only) reports one real P1 finding and finishes
# — the parallel phase always completes in full before the serial phase
# even starts — then beta (workspace-write) overwrites alpha's own
# alpha.out.json on disk before reporting CLEAN for itself. Each angle's
# result is now collected the moment it finishes (in main()'s own
# as_completed loop for the parallel phase, and inside
# run_write_capable_angles' serial loop), so the merged report must still
# carry alpha's original finding, not the corrupted CLEAN sitting on disk
# afterward.
repo46=$(make_throwaway_repo in-memory-collection)
# The plan lives outside repo46, not inside it (see case 28): beta's
# dirty-tree gate requires a genuinely clean tree before it runs, and an
# untracked plan.json sitting in the checkout would itself trip that gate.
plan46="$tmpdir/in-memory-collection-plan.$$.${RANDOM:-0}.json"
cat > "$plan46" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
 ]}
EOF
rundir46="$safe_tmpdir/in-memory-collection-run.$$.${RANDOM:-0}"

out46=$(cd "$repo46" && CODEX_BIN="$FIXTURES/fake-codex-corrupt-earlier.sh" \
  ADV_TEST_EARLIER_ANGLE_ID="alpha" bash "$SH" --plan "$plan46" --base main --dir "$rundir46" 2>&1)
rc46=$?
echo "--- case 46: a later write-capable angle overwrites an earlier angle's out.json on disk ---"
printf '%s\n' "$out46"

check "exits 0 (findings, not an error)" test "$rc46" -eq 0
check "verdict is FINDINGS" grep -qx "ADVERSARIAL_REVIEW: FINDINGS" <<<"$out46"
check "alpha's original FINDINGS(1) survives in the report, not CLEAN" \
  grep -qx "alpha: FINDINGS(1)" <<<"$out46"
check "beta ran clean" grep -qx "beta: CLEAN" <<<"$out46"
check "alpha's original finding is in the report" \
  grep -qF -- "- [P1] a.py:1 — original finding" <<<"$out46"
check "setup: the on-disk alpha.out.json really was overwritten (confirms the attack happened)" \
  grep -q "rewritten by a later angle" "$rundir46/alpha.out.json"

rm -rf "$rundir46"

# --- Case 47: an explicit --dir under a sandbox-writable root is refused ------
# when the plan has any write-capable angle
# Security regression (item 2): a workspace-write angle's own reproduction
# is already free to write anywhere its sandbox allows — tempfile.
# gettempdir()/$TMPDIR/tmp/var-tmp — and run_dir holds every angle's own
# artifacts, including another angle's already-collected <aid>.out.json a
# later one could otherwise overwrite (see case 46). main() now refuses an
# explicit --dir under any of those roots whenever the plan has a
# write-capable angle, rather than creating (or reusing) it.
repo47=$(make_throwaway_repo unsafe-dir-refused)
cat > "$repo47/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}]}
EOF
unsafedir47="${TMPDIR:-/tmp}/adversarial-review-unsafe-dir-test.$$.${RANDOM:-0}"

err47=$(cd "$repo47" && CODEX_BIN=true bash "$SH" --plan plan.json --base main --dir "$unsafedir47" 2>&1)
rc47=$?
echo "--- case 47: --dir under a sandbox-writable root is refused for a write-capable plan ---"
printf '%s\n' "$err47"

check "exits 2 (usage error)" test "$rc47" -eq 2
check "names the problem" grep -qi "sandbox-writable" <<<"$err47"
check "the unsafe dir was never created" test ! -d "$unsafedir47"

rm -rf "$unsafedir47" 2>/dev/null

# --- Case 47b: the default run dir for a write-capable plan lands outside -----
# every sandbox-writable root and outside the checkout
# The complement of case 47: with no --dir given at all, main() now picks
# the default run directory via select_dir_outside_git_checkouts'
# exclude_sandbox_writable mode (a stable cache directory) instead of the
# ordinary TMPDIR-based default, whenever the plan has a write-capable
# angle.
repo47b=$(make_throwaway_repo unsafe-dir-default)
# The plan lives outside repo47b, not inside it (see case 28): writer's
# dirty-tree gate requires a genuinely clean tree before it runs, and an
# untracked plan.json sitting in the checkout would itself trip that gate.
plan47b="$tmpdir/unsafe-dir-default-plan.$$.${RANDOM:-0}.json"
cat > "$plan47b" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}]}
EOF
argvdir47b="$safe_tmpdir/unsafe-dir-default-argv.$$.${RANDOM:-0}"

out47b=$(cd "$repo47b" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir47b" \
  bash "$SH" --plan "$plan47b" --base main 2>&1)
rc47b=$?
echo "--- case 47b: default run dir for a write-capable plan ---"
printf '%s\n' "$out47b"

check "exits 0" test "$rc47b" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out47b"

rundir47b=$(grep '^DIR=' <<<"$out47b" | cut -d= -f2-)
check "a run dir was reported" test -n "$rundir47b"
outside47b=$(REPO="$repo47b" RUNDIR="$rundir47b" python3 -c '
import os, tempfile
from pathlib import Path
roots = set()
for p in (tempfile.gettempdir(), os.environ.get("TMPDIR"), "/tmp", "/var/tmp"):
    if p:
        try:
            roots.add(str(Path(p).resolve()))
        except OSError:
            pass
rundir = Path(os.environ["RUNDIR"]).resolve()
repo = Path(os.environ["REPO"]).resolve()
bad = [r for r in roots if rundir == Path(r) or str(rundir).startswith(r + os.sep)]
if rundir == repo or str(rundir).startswith(str(repo) + os.sep):
    bad.append(str(repo))
print("OK" if not bad else f"MISMATCH: rundir={rundir!r} bad={bad!r}")
')
check "the default run dir sits outside every sandbox-writable root and the checkout" \
  test "$outside47b" = "OK"

rm -rf "$rundir47b"

# --- Case 48: XDG_CACHE_HOME pointed inside a sandbox-writable root is -------
# refused, not silently accepted as the default run dir
# Regression: select_dir_outside_git_checkouts' exclude_sandbox_writable
# mode used to reject a candidate only when it was EXACTLY EQUAL to one of
# tempfile.gettempdir()/$TMPDIR/tmp//var/tmp -- XDG_CACHE_HOME (or HOME)
# pointed at a DESCENDANT of one of those (e.g. XDG_CACHE_HOME=$TMPDIR/
# xdg-cache) yields a _cache_root() just as reachable by a workspace-write
# angle's own sandbox as the root itself, and the equality check let it
# straight through. TMPDIR here is pinned to a fresh scratch directory
# (never the real system temp dir) and XDG_CACHE_HOME to a subdirectory of
# it, so _cache_root() -- the sole candidate in this mode -- resolves to a
# descendant of a sandbox-writable root; with the fix, that's refused the
# same as the root itself would be, so main() exits 1 (environment error)
# rather than picking a run directory a malicious reproduction could reach.
repo48=$(make_throwaway_repo cache-root-inside-tmpdir)
cat > "$repo48/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}]}
EOF
faketmp48="$tmpdir/fake-tmpdir-48.$$.${RANDOM:-0}"
mkdir -p "$faketmp48"
xdgcache48="$faketmp48/xdg-cache-inside-tmpdir"

err48=$(cd "$repo48" && TMPDIR="$faketmp48" XDG_CACHE_HOME="$xdgcache48" CODEX_BIN=true \
  bash "$SH" --plan plan.json --base main 2>&1)
rc48=$?
echo "--- case 48: XDG_CACHE_HOME inside \$TMPDIR is refused as the default run dir ---"
printf '%s\n' "$err48"

check "exits 1 (environment error)" test "$rc48" -eq 1
check "names the problem" grep -qi "sandbox-writable" <<<"$err48"

# --- Case 49: a --dir reused after HEAD alone moved (no plan/base change) ----
# never wipes an unselected angle's still-valid earlier result
# Regression: main()'s broad reused-`--dir` clear used to compare the WHOLE
# "_run" dict (run_meta stamped into plan.json), so a head_sha that moved
# between two live runs sharing the same --dir -- committing a fix in
# response to the first run's own findings, say -- alone counted as
# "changed" and cleared EVERY angle's artifacts, including ones --only left
# out of this run. STABLE_RUN_META_FIELDS (plan_hash, base_resolved,
# base_sha, template_hash -- the same fields collect_angle_result's own
# per-angle backstop already checks) is now what's compared; head_sha rides
# along for provenance only. First run produces alpha+beta both CLEAN; a
# commit then moves HEAD (head_sha changes, base_sha/plan_hash/
# template_hash do not, since only main -- the base -- would move
# base_sha); a second run reused the same --dir with --only alpha must
# leave beta's earlier artifacts alone; --from-dir must then merge both.
repo49=$(make_throwaway_repo reused-dir-head-moved)
cat > "$repo49/plan.json" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [
   {"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"},
   {"id": "beta", "title": "Beta", "mandate": "m", "evidence": "e", "execution": "read-only"}
 ]}
EOF
rundir49="$tmpdir/reused-dir-head-moved-run.$$.${RANDOM:-0}"
argvdir49="$tmpdir/reused-dir-head-moved-argv.$$.${RANDOM:-0}"

out49_1=$(cd "$repo49" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir49" \
  bash "$SH" --plan plan.json --base main --dir "$rundir49" 2>&1); rc49_1=$?
echo "--- case 49: first run (both angles, before HEAD moves) ---"
printf '%s\n' "$out49_1"
check "first run exits 0" test "$rc49_1" -eq 0
check "first run: alpha CLEAN" grep -qx "alpha: CLEAN" <<<"$out49_1"
check "first run: beta CLEAN" grep -qx "beta: CLEAN" <<<"$out49_1"

# Moves HEAD alone: a new commit on the same feature branch. base ('main')
# is never touched, so base_sha stays the same while head_sha changes.
echo "more" >> "$repo49/f.txt"
git -C "$repo49" add -A
git -C "$repo49" commit -q -m "a fix in response to round 1"

out49_2=$(cd "$repo49" && CODEX_BIN="$FIXTURES/fake-codex-argv-log.sh" ADV_TEST_ARGV_DIR="$argvdir49" \
  bash "$SH" --plan plan.json --base main --dir "$rundir49" --only alpha 2>&1); rc49_2=$?
echo "--- case 49: second run (--only alpha, after HEAD moved) ---"
printf '%s\n' "$out49_2"
check "second run exits 0" test "$rc49_2" -eq 0
check "second run only counts alpha" \
  grep -qx "ANGLES=1  RAN=1  BLOCKED=0  UNPARSED=0" <<<"$out49_2"

out49_3=$(bash "$SH" --from-dir "$rundir49" 2>&1); rc49_3=$?
echo "--- case 49: --from-dir merges both after HEAD alone moved ---"
printf '%s\n' "$out49_3"
check "--from-dir exits 0 (beta's still-valid CLEAN must survive)" test "$rc49_3" -eq 0
check "--from-dir verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out49_3"
check "--from-dir counts both angles ran" \
  grep -qx "ANGLES=2  RAN=2  BLOCKED=0  UNPARSED=0" <<<"$out49_3"
check "beta is CLEAN (its earlier artifact was never wiped by HEAD moving alone)" \
  grep -qx "beta: CLEAN" <<<"$out49_3"

rm -rf "$rundir49"

# --- Case 50: a cancelled worker never creates a throwaway CODEX_HOME at all -
# Regression: _run_angle_isolated used to call make_throwaway_codex_home()
# unconditionally, outside the _IN_FLIGHT window run_angle's own Popen call
# uses to close the spawn/track race with the interrupt handler (see
# _wait_for_in_flight) -- a signal landing exactly as a worker reached that
# call could let the handler's _LIVE_CODEX_HOMES snapshot run before the
# new home was even registered, leaking a directory holding a copy of
# auth.json past os._exit with nothing left to clean it up. Home creation
# now happens inside the same kind of _IN_FLIGHT-guarded window, checking
# _CANCELLED first -- so once cancellation is visible, no home is created
# at all, closing the race and skipping pointless work. Directly sets the
# module's own _CANCELLED (never delivers a real signal -- this isolates
# the guard itself from OS-level timing) and spies on
# make_throwaway_codex_home to prove it is never called.
scratch50="$tmpdir/cancelled-no-codex-home.$$.${RANDOM:-0}"
mkdir -p "$scratch50"
cancelled_check50=$(python3 - "$SCRIPT_DIR" "$scratch50" <<'PYEOF'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import adversarial_review as ar

run_dir = Path(sys.argv[2]) / "rundir"
run_dir.mkdir(parents=True, exist_ok=True)

calls = []
def spy():
    calls.append(True)
    raise AssertionError("make_throwaway_codex_home must not be called once _CANCELLED")
ar.make_throwaway_codex_home = spy

ar._CANCELLED = True
angle = {"id": "writer", "title": "Writer", "mandate": "m", "evidence": "e", "execution": "workspace-write"}
plan = {"version": 1, "base": "main", "promise": "p", "contracts": [], "invariants": [], "angles": [angle]}
run_meta = {"plan_hash": "x", "base_resolved": "main", "base_sha": "aaa", "template_hash": "y"}

result = ar._run_angle_isolated(
    "writer", angle, plan, "main", "template", run_dir, ".",
    Path("schema.json"), 5, run_meta,
)

marker = run_dir / "writer.skipped.txt"
ok = (
    result == (None, False)
    and calls == []
    and marker.is_file()
    and marker.read_text().strip() == "interrupted"
    and ar._IN_FLIGHT == []
)
print("OK" if ok else
      f"MISMATCH: result={result!r} calls={calls!r} "
      f"marker_exists={marker.is_file()!r} IN_FLIGHT={ar._IN_FLIGHT!r}")
PYEOF
)
echo "--- case 50: a cancelled worker never creates a throwaway CODEX_HOME ---"
printf '%s\n' "$cancelled_check50"
check "make_throwaway_codex_home is never called once _CANCELLED is set, and the angle is marked interrupted" \
  test "$cancelled_check50" = "OK"

# --- Case 51: a rotated auth.json is propagated back to the real CODEX_HOME --
# before this angle's throwaway copy is deleted
# Regression: each angle's codex exec ran under its own throwaway
# CODEX_HOME (see make_throwaway_codex_home) holding only a COPY of the
# real auth.json -- when a file-backed ChatGPT login refreshes mid-run,
# codex rewrites that copy with a rotated refresh token, the copy is then
# deleted with the rest of the throwaway directory, and the real
# auth.json keeps the now-consumed token, so later angles (and any normal
# `codex` run afterward) can fail to authenticate. An alternative -- run
# every angle against the real CODEX_HOME directly and neutralize project
# trust with a `-c projects."<root>".trust_level="untrusted"` override
# instead of copying at all -- was tried and rejected: proven live against
# codex-cli 0.145.0 (see make_throwaway_codex_home's own docstring), the
# override changed nothing in either direction. _propagate_rotated_auth
# now compares each angle's own copy, snapshotted right after creation,
# against that same file once the angle's codex exec exits, and writes any
# change back to the real CODEX_HOME under a lock.
# fixtures/fake-codex-rotate-auth.sh plays the rotating codex process.
repo51=$(make_throwaway_repo auth-rotation-propagated)
plan51="$tmpdir/auth-rotation-plan.$$.${RANDOM:-0}.json"
cat > "$plan51" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
fakerealhome51="$tmpdir/fake-real-codex-home-51.$$.${RANDOM:-0}"
mkdir -p "$fakerealhome51"
echo '{"marker": "pre-rotation-token"}' > "$fakerealhome51/auth.json"
rundir51="$safe_tmpdir/auth-rotation-run.$$.${RANDOM:-0}"

out51=$(cd "$repo51" && CODEX_HOME="$fakerealhome51" \
  CODEX_BIN="$FIXTURES/fake-codex-rotate-auth.sh" \
  ADV_TEST_ROTATED_MARKER='{"marker": "post-rotation-token"}' \
  bash "$SH" --plan "$plan51" --base main --dir "$rundir51" 2>&1)
rc51=$?
echo "--- case 51: a rotated auth.json is propagated back to the real CODEX_HOME ---"
printf '%s\n' "$out51"

check "exits 0" test "$rc51" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out51"
check "the real CODEX_HOME's auth.json now carries the rotated token" \
  grep -q "post-rotation-token" "$fakerealhome51/auth.json"
check "the real CODEX_HOME's auth.json no longer carries the pre-rotation token" \
  bash -c '! grep -q "pre-rotation-token" "$1"' _ "$fakerealhome51/auth.json"

rm -rf "$rundir51"

# --- Case 51b: a truncated/invalid rotated auth.json is never propagated ------
# Regression: _propagate_rotated_auth used to treat ANY byte difference from
# the pre-run snapshot as a successful rotation and write those bytes over
# the real auth.json. An angle killed by its timeout, or a codex process
# that crashed mid-write, can leave its throwaway copy truncated or
# half-written instead — that garbage would otherwise clobber the user's
# real, working credentials. _is_plausible_auth_rotation now requires the
# candidate to parse as a non-empty JSON object whose keys are a superset
# of the snapshot's own keys before any write-back happens; a candidate
# that fails validation is skipped with one stderr warning. Run twice, once
# for a zero-byte truncation and once for a partial-JSON fragment.
for mode51b in zero partial; do
  repo51b=$(make_throwaway_repo "auth-rotation-invalid-$mode51b")
  plan51b="$tmpdir/auth-rotation-invalid-plan.$mode51b.$$.${RANDOM:-0}.json"
  cat > "$plan51b" <<'EOF'
{"version": 1, "base": "main", "promise": "Ships a thing.", "contracts": [], "invariants": [],
 "angles": [{"id": "alpha", "title": "Alpha", "mandate": "m", "evidence": "e", "execution": "read-only"}]}
EOF
  fakerealhome51b="$tmpdir/fake-real-codex-home-51b-$mode51b.$$.${RANDOM:-0}"
  mkdir -p "$fakerealhome51b"
  echo '{"marker": "pre-rotation-token"}' > "$fakerealhome51b/auth.json"
  rundir51b="$safe_tmpdir/auth-rotation-invalid-run-$mode51b.$$.${RANDOM:-0}"

  out51b=$(cd "$repo51b" && CODEX_HOME="$fakerealhome51b" \
    CODEX_BIN="$FIXTURES/fake-codex-rotate-auth.sh" \
    ADV_TEST_ROTATE_TRUNCATE="$mode51b" \
    bash "$SH" --plan "$plan51b" --base main --dir "$rundir51b" 2>&1)
  rc51b=$?
  echo "--- case 51b ($mode51b): a truncated/invalid rotated auth.json is never propagated ---"
  printf '%s\n' "$out51b"

  check "($mode51b) exits 0" test "$rc51b" -eq 0
  check "($mode51b) verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out51b"
  check "($mode51b) the real CODEX_HOME's auth.json is byte-identical to the pre-rotation snapshot" \
    diff -q <(printf '{"marker": "pre-rotation-token"}\n') "$fakerealhome51b/auth.json"
  check "($mode51b) a validation warning was printed" \
    grep -q "rotated auth.json failed validation" <<<"$out51b"

  rm -rf "$rundir51b"
done

# --- Case 52: every text read/write is locale-independent (item 4) ------------
# Regression: every read_text()/open(...)/fdopen(...) this runner uses for a
# plan, prompt, metadata, or artifact file now passes encoding="utf-8"
# explicitly, rather than depending on locale.getpreferredencoding(). Under
# LC_ALL=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 (C-locale coercion and UTF-8
# mode both disabled), that default falls back to ASCII, so load_plan()'s
# own read of plan.json used to raise UnicodeDecodeError -- not caught by
# its "except OSError" -- and crash the run instead of merging, the moment
# the plan held anything outside ASCII. Reruns the suite's own basic
# --from-dir case (case 1's all-clean fixture, staged fresh here so case 1
# itself is untouched) with an em dash spliced into plan.json's "promise"
# field, under that exact hostile locale.
dir52=$(stage all-clean)
python3 - "$dir52/plan.json" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
doc["promise"] = "Ships a thing — nothing more, nothing less."
with open(path, "w", encoding="utf-8") as f:
    # ensure_ascii=False -- the whole point is a literal, un-escaped em
    # dash (UTF-8 bytes \xe2\x80\x94) sitting in plan.json on disk. The
    # default, ensure_ascii=True, backslash-escapes it to six plain-ASCII
    # characters instead, which decodes under any single-byte codec fine
    # and would never exercise the bug this case regresses.
    json.dump(doc, f, ensure_ascii=False)
PYEOF

out52=$(LC_ALL=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 bash "$SH" --from-dir "$dir52" 2>&1); rc52=$?
echo "--- case 52: --from-dir under LC_ALL=C/PYTHONUTF8=0/PYTHONCOERCECLOCALE=0 with a non-ASCII plan ---"
printf '%s\n' "$out52"

check "exits 0" test "$rc52" -eq 0
check "verdict is CLEAN" grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$out52"
check "counts show all 3 ran, none blocked/unparsed" \
  grep -qx "ANGLES=3  RAN=3  BLOCKED=0  UNPARSED=0" <<<"$out52"
check "merged.json was written" test -f "$dir52/merged.json"

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
