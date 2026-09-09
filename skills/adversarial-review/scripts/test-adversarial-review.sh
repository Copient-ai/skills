#!/usr/bin/env bash
# Offline regression test for adversarial-review.sh's verdict/exit-code
# contract. Entirely --from-dir based — no live `codex` call and no
# fake-codex shim anywhere in this file (see codex-review-loop's own
# --from-log suite for the sibling idiom this one follows).
#
# Usage: bash test-adversarial-review.sh   (exit 0 = all pass)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$SCRIPT_DIR/adversarial-review.sh"
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

# --- Case 1: every angle CLEAN --------------------------------------------
dir="$tmpdir/clean"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [
    {"id": "alpha", "title": "Alpha", "mandate": "Look for logic bugs.", "evidence": "A failing input.", "execution": "read-only"},
    {"id": "beta", "title": "Beta", "mandate": "Look for security holes.", "evidence": "An exploit.", "execution": "read-only"}
  ]
}
EOF
for aid in alpha beta; do
  printf '0\n' > "$dir/$aid.status"
  printf '{"angle": "%s", "verdict": "CLEAN", "summary": "Nothing found.", "findings": []}\n' "$aid" > "$dir/$aid.out.json"
  printf 'codex exec log for %s\n' "$aid" > "$dir/$aid.log"
done

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "all angles CLEAN -> banner CLEAN and exit 0" \
  bash -c 'grep -qx "ADVERSARIAL_REVIEW: CLEAN" <<<"$1" && [ "$2" -eq 0 ]' _ "$out" "$rc"

# --- Case 2: one angle has real findings ----------------------------------
dir="$tmpdir/findings"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [
    {"id": "alpha", "title": "Alpha", "mandate": "Look for logic bugs.", "evidence": "A failing input.", "execution": "read-only"},
    {"id": "beta", "title": "Beta", "mandate": "Look for security holes.", "evidence": "An exploit.", "execution": "read-only"}
  ]
}
EOF
printf '0\n' > "$dir/alpha.status"
printf '{"angle": "alpha", "verdict": "CLEAN", "summary": "Nothing found.", "findings": []}\n' > "$dir/alpha.out.json"
printf '0\n' > "$dir/beta.status"
cat > "$dir/beta.out.json" <<'EOF'
{"angle": "beta", "verdict": "FINDINGS", "summary": "One real bug.", "findings": [
  {"severity": "P1", "path": "src/thing.py", "line": 10, "claim": "Something breaks",
   "evidence": "Line 10 raises on empty input.", "reproduction": "Call thing() with no args."}
]}
EOF

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "one angle FINDINGS -> banner FINDINGS, exit 0, correct BLOCKING/NITS" \
  bash -c 'grep -qx "ADVERSARIAL_REVIEW: FINDINGS" <<<"$1" && [ "$2" -eq 0 ] && grep -qx "BLOCKING=1  NITS=0" <<<"$1"' \
  _ "$out" "$rc"
check "the finding line is present in --- FINDINGS ---" \
  grep -qF -- "- [P1] src/thing.py:10 — Something breaks" <<<"$out"

# --- Case 3: missing .status file for an angle ----------------------------
dir="$tmpdir/nostatus"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [
    {"id": "alpha", "title": "Alpha", "mandate": "Look for logic bugs.", "evidence": "A failing input.", "execution": "read-only"},
    {"id": "beta", "title": "Beta", "mandate": "Look for security holes.", "evidence": "An exploit.", "execution": "read-only"}
  ]
}
EOF
printf '0\n' > "$dir/alpha.status"
printf '{"angle": "alpha", "verdict": "CLEAN", "summary": "Nothing found.", "findings": []}\n' > "$dir/alpha.out.json"
# beta.status is deliberately absent.

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "missing .status -> UNPARSED(nostatus), banner UNPARSED, exit 4 (never CLEAN)" \
  bash -c 'grep -qF "beta: UNPARSED(nostatus)" <<<"$1" && grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$1" && [ "$2" -eq 4 ]' \
  _ "$out" "$rc"

# --- Case 4: .out.json is invalid JSON (status 0) -------------------------
dir="$tmpdir/nojson"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [{"id": "solo", "title": "Solo", "mandate": "Look for bugs.", "evidence": "A failing input.", "execution": "read-only"}]
}
EOF
printf '0\n' > "$dir/solo.status"
printf 'not valid json{\n' > "$dir/solo.out.json"

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "invalid JSON out.json -> UNPARSED(nojson), exit 4" \
  bash -c 'grep -qF "solo: UNPARSED(nojson)" <<<"$1" && [ "$2" -eq 4 ]' _ "$out" "$rc"

# --- Case 5: .out.json violates the findings schema -----------------------
dir="$tmpdir/schema"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [{"id": "solo", "title": "Solo", "mandate": "Look for bugs.", "evidence": "A failing input.", "execution": "read-only"}]
}
EOF
printf '0\n' > "$dir/solo.status"
# verdict FINDINGS with an empty findings array is itself a schema violation.
printf '{"angle": "solo", "verdict": "FINDINGS", "summary": "x", "findings": []}\n' > "$dir/solo.out.json"

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "schema-invalid out.json -> UNPARSED(schema), exit 4" \
  bash -c 'grep -qF "solo: UNPARSED(schema)" <<<"$1" && [ "$2" -eq 4 ]' _ "$out" "$rc"

# --- Case 6: .status is 1 and .log shows a content-filter refusal ---------
dir="$tmpdir/refused"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [{"id": "solo", "title": "Solo", "mandate": "Look for bugs.", "evidence": "A failing input.", "execution": "read-only"}]
}
EOF
printf '1\n' > "$dir/solo.status"
# One of REFUSAL_MARKERS in adversarial_review.py, verbatim.
printf 'ERROR: this content was flagged for possible cybersecurity risk.\n' > "$dir/solo.log"

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "refused angle -> UNPARSED(refused), exit 4" \
  bash -c 'grep -qF "solo: UNPARSED(refused)" <<<"$1" && [ "$2" -eq 4 ]' _ "$out" "$rc"

# --- Case 7: .status is 124 (timeout) -------------------------------------
dir="$tmpdir/timeout"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [{"id": "solo", "title": "Solo", "mandate": "Look for bugs.", "evidence": "A failing input.", "execution": "read-only"}]
}
EOF
printf '124\n' > "$dir/solo.status"

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "status 124 -> UNPARSED(timeout), exit 4" \
  bash -c 'grep -qF "solo: UNPARSED(timeout)" <<<"$1" && [ "$2" -eq 4 ]' _ "$out" "$rc"

# --- Case 8: an angle's out.json has verdict BLOCKED ----------------------
dir="$tmpdir/blocked"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [{"id": "solo", "title": "Solo", "mandate": "Look for bugs.", "evidence": "A failing input.", "execution": "read-only"}]
}
EOF
printf '0\n' > "$dir/solo.status"
printf '{"angle": "solo", "verdict": "BLOCKED", "summary": "Could not access the repo.", "findings": []}\n' > "$dir/solo.out.json"

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "BLOCKED verdict -> angle reports BLOCKED (not UNPARSED text), banner UNPARSED, exit 4" \
  bash -c 'grep -qF "solo: BLOCKED" <<<"$1" && grep -qx "ADVERSARIAL_REVIEW: UNPARSED" <<<"$1" && [ "$2" -eq 4 ]' \
  _ "$out" "$rc"

# --- Case 9: every angle CLEAN except one BLOCKED with no findings --------
dir="$tmpdir/mixed"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [
    {"id": "alpha", "title": "Alpha", "mandate": "Look for logic bugs.", "evidence": "A failing input.", "execution": "read-only"},
    {"id": "beta", "title": "Beta", "mandate": "Look for security holes.", "evidence": "An exploit.", "execution": "read-only"}
  ]
}
EOF
printf '0\n' > "$dir/alpha.status"
printf '{"angle": "alpha", "verdict": "CLEAN", "summary": "Nothing found.", "findings": []}\n' > "$dir/alpha.out.json"
printf '0\n' > "$dir/beta.status"
printf '{"angle": "beta", "verdict": "BLOCKED", "summary": "Could not access the repo.", "findings": []}\n' > "$dir/beta.out.json"

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "one CLEAN + one BLOCKED-no-findings -> still exit 4, never 0" \
  test "$rc" -eq 4

# --- Case 10: --only restricts the merge to one angle ---------------------
dir="$tmpdir/multi"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [
    {"id": "alpha", "title": "Alpha", "mandate": "Look for logic bugs.", "evidence": "A failing input.", "execution": "read-only"},
    {"id": "beta", "title": "Beta", "mandate": "Look for security holes.", "evidence": "An exploit.", "execution": "read-only"},
    {"id": "gamma", "title": "Gamma", "mandate": "Look for contract violations.", "evidence": "A broken contract.", "execution": "read-only"}
  ]
}
EOF
for aid in alpha beta; do
  printf '0\n' > "$dir/$aid.status"
  printf '{"angle": "%s", "verdict": "CLEAN", "summary": "Nothing found.", "findings": []}\n' "$aid" > "$dir/$aid.out.json"
done
printf '0\n' > "$dir/gamma.status"
cat > "$dir/gamma.out.json" <<'EOF'
{"angle": "gamma", "verdict": "FINDINGS", "summary": "One bug.", "findings": [
  {"severity": "P2", "path": "src/other.py", "line": 5, "claim": "A nit",
   "evidence": "Line 5 is odd.", "reproduction": "Read line 5."}
]}
EOF

out=$(bash "$REVIEW" --from-dir "$dir" --only gamma 2>/dev/null); rc=$?
check "--only gamma restricts the merge to gamma alone" \
  bash -c 'grep -qx "ANGLES=1  RAN=1  BLOCKED=0  UNPARSED=0" <<<"$1" && grep -qF "gamma: FINDINGS(1)" <<<"$1" && ! grep -q "^alpha:" <<<"$1"' \
  _ "$out"

# --- Case 11: --only names an id not in the plan --------------------------
out=$(bash "$REVIEW" --from-dir "$dir" --only nope 2>/dev/null); rc=$?
check "--only with an unknown id is a usage error, exit 2" test "$rc" -eq 2

# --- Case 12 (bonus): a plan with a duplicate angle id is a usage error ---
dir="$tmpdir/dupid"
mkdir -p "$dir"
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [
    {"id": "alpha", "title": "Alpha", "mandate": "Look for logic bugs.", "evidence": "A failing input.", "execution": "read-only"},
    {"id": "alpha", "title": "Alpha again", "mandate": "Look for other bugs.", "evidence": "Another input.", "execution": "read-only"}
  ]
}
EOF

out=$(bash "$REVIEW" --from-dir "$dir" 2>/dev/null); rc=$?
check "a duplicate angle id in the plan is a usage error, exit 2" test "$rc" -eq 2

# --- Case 13: --from-dir into a git checkout diverts merged.json ----------
# tmpdir itself is not a repo; make this one case's own dir a throwaway repo
# so it reproduces what a committed fixtures directory (a real git checkout)
# would trigger, without touching one.
dir="$tmpdir/ingit"
mkdir -p "$dir"
git -C "$dir" init --quiet
cat > "$dir/plan.json" <<'EOF'
{
  "version": 1, "promise": "Ships a thing without breaking anything else.",
  "angles": [{"id": "solo", "title": "Solo", "mandate": "Look for bugs.", "evidence": "A failing input.", "execution": "read-only"}]
}
EOF
printf '0\n' > "$dir/solo.status"
printf '{"angle": "solo", "verdict": "CLEAN", "summary": "Nothing found.", "findings": []}\n' > "$dir/solo.out.json"

out=$(bash "$REVIEW" --from-dir "$dir" 2>&1 >/dev/null); rc=$?
check "--from-dir into a git checkout never writes merged.json there" \
  bash -c '[ ! -e "$1/merged.json" ]' _ "$dir"
check "--from-dir into a git checkout warns and diverts merged.json" \
  grep -qF "is inside a git checkout; merged.json written to" <<<"$out"

# --- Case 14: --version answers before touching python3/codex ------------
# PATH is emptied, not just scrubbed of codex/python3, so this also proves
# --version returns before the .sh wrapper's own environment checks run.
ver_out=$(PATH='' "$BASH" "$REVIEW" --version 2>&1)
ver_rc=$?
check "--version exits 0 with no python3/codex on PATH" test "$ver_rc" -eq 0
check "--version prints a semver" \
  grep -qE '^adversarial-review\.sh [0-9]+\.[0-9]+\.[0-9]+$' <<<"$ver_out"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails CHECK(S) FAILED"
fi
exit "$fails"
