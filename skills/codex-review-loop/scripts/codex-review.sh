#!/usr/bin/env bash
# Run `codex review` locally and print ONLY the findings — not the full session
# transcript (which can be ~100KB of tool calls and diff). The full log is saved
# to a file so this stays out of the calling context.
#
# `codex review` streams an agent session and ends with a summary + a findings
# list ("Full review comments:" for several, "Review comment:" for one) of
# `- [Pn] Title — path:line` items (often duplicated). This extracts the summary
# (once) and the findings (once), counts
# blocking (P0/P1) vs nits (P2/P3), and prints a compact, parseable block.
#
# Usage:
#   codex-review.sh [--base BRANCH | --commit SHA | --uncommitted] [--prompt TEXT]
#                   [--log FILE] [--raw] [--timeout SEC]
#   codex-review.sh --from-log FILE        # just re-extract from an existing transcript
#   codex-review.sh --version              # print the parser version and exit
#
#   Scope (default: --base <PR base, else main>):
#     --base BRANCH    review all changes vs BRANCH
#     --commit SHA     review one commit's changes
#     --uncommitted    review staged/unstaged/untracked changes
#   --prompt TEXT      UNUSABLE with a scope: `codex review` rejects [PROMPT]
#                      alongside --base/--commit/--uncommitted, and this wrapper
#                      always scopes. Kept so the conflict fails fast and clearly;
#                      run `codex review <prompt>` directly instead.
#   --log FILE         where to save the full transcript (default: mktemp; path printed)
#   --raw              print the full transcript instead of the distilled findings
#   --timeout SEC      max seconds for the review (default 600)
#   --from-log FILE    skip running codex; extract from FILE (testing / re-parse)
#   --version          print the parser version and exit. Compare it against the
#                      version in Copient-ai/skills: an older copy may still carry
#                      a false-CLEAN bug that has since been fixed, and a review
#                      tool that silently approves unread branches is the one
#                      failure this script exists to prevent.
#
#   Env overrides:
#     CODEX_REVIEW_MODEL    model passed to `codex review` (default: gpt-5.6-sol)
#     CODEX_REVIEW_EFFORT   reasoning effort passed to `codex review` (default: xhigh)
#
# Output:
#   CODEX_REVIEW: CLEAN | FINDINGS | UNPARSED
#   (UNPARSED, exit 4 = the findings section could not be parsed; read the log.
#    Never treat it as a clean review.)
#   BLOCKING=<n>  NITS=<n>
#   LOG=<transcript path>
#   --- SUMMARY ---
#   <summary>
#   --- FINDINGS ---   (omitted when CLEAN)
#   <- [Pn] ... items>
# Severity: P0/P1 = blocking, P2/P3 = nit.
set -euo pipefail

# Bump on every change to the parsing behaviour, so an installed copy can be
# compared against the repo. See --version.
CODEX_REVIEW_VERSION="1.0.0"

# --- Portability shims (work on both GNU/Linux and BSD/macOS) ----------------
# ESC byte for stripping ANSI color: GNU sed's `\x1b` escape isn't portable to
# BSD sed, which would silently leave color codes in place.
ESC=$(printf '\033')

# Run a command with a time limit using GNU `timeout`, else macOS `gtimeout`
# (brew coreutils), else with no limit (the caller's environment may impose its
# own). A real timeout still returns 124 so the caller's timeout branch works.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    echo "note: no timeout/gtimeout found; running without a time limit" >&2
    "$@"
  fi
}

# Codex repeats its final response verbatim, including when that response is a
# clean summary with no findings header. Collapse an exactly-doubled block back
# to one copy; leave anything else untouched.
dedupe_doubled() {
  awk '{ a[NR] = $0 } END {
    if (NR < 2 || NR % 2) { for (i = 1; i <= NR; i++) print a[i]; exit }
    h = NR / 2
    for (i = 1; i <= h; i++) if (a[i] != a[i + h]) {
      for (j = 1; j <= NR; j++) print a[j]; exit
    }
    for (i = 1; i <= h; i++) print a[i]
  }'
}

# Resolve a base branch to its remote-tracking ref when one exists. Passing a
# bare name reviews against the LOCAL branch, so a stale local `main` drags
# unrelated upstream commits into the diff — and the fixer then edits changes
# that are not this branch's. Falls back to the bare name (a local-only base,
# or a repo with no matching remote ref) rather than failing.
resolve_base_ref() {
  base="$1"
  for candidate in "origin/$base" $(git remote 2>/dev/null | sed "s@.*@&/$base@"); do
    if git rev-parse --verify --quiet "refs/remotes/$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"; return
    fi
  done
  printf '%s\n' "$base"
}

# Strip leading + trailing blank lines in one pass (no GNU `tac`).
trim() {
  awk 'NF{p=1} p{a[++n]=$0} END{while(n&&a[n]~/^[[:space:]]*$/)n--; for(i=1;i<=n;i++)print a[i]}'
}

SCOPE_ARGS=()
PROMPT=""
LOG=""
RAW=false
TIMEOUT=600
FROM_LOG=""
CODEX_REVIEW_MODEL="${CODEX_REVIEW_MODEL:-gpt-5.6-sol}"
CODEX_REVIEW_EFFORT="${CODEX_REVIEW_EFFORT:-xhigh}"

while [ $# -gt 0 ]; do
  case "$1" in
    --base) SCOPE_ARGS=(--base "$2"); shift 2 ;;
    --commit) SCOPE_ARGS=(--commit "$2"); shift 2 ;;
    --uncommitted) SCOPE_ARGS=(--uncommitted); shift ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --raw) RAW=true; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --from-log) FROM_LOG="$2"; shift 2 ;;
    --version) echo "codex-review.sh $CODEX_REVIEW_VERSION"; exit 0 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# //;s/^#//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Obtain the transcript ---
if [ -n "$FROM_LOG" ]; then
  LOG="$FROM_LOG"
  [ -f "$LOG" ] || { echo "No such log: $LOG" >&2; exit 1; }
else
  command -v codex >/dev/null || { echo "codex CLI not found on PATH." >&2; exit 1; }
  # Default scope: review against the PR base branch, else main.
  if [ "${#SCOPE_ARGS[@]}" -eq 0 ]; then
    BASE=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || echo main)
    SCOPE_ARGS=(--base "$BASE")
  fi
  # Applies to a caller-supplied --base too: the skill passes a bare branch name,
  # so it is just as exposed to a stale local base as the default is.
  if [ "${SCOPE_ARGS[0]}" = "--base" ]; then
    SCOPE_ARGS=(--base "$(resolve_base_ref "${SCOPE_ARGS[1]}")")
  fi
  # `codex review` (v0.145) makes [PROMPT] mutually exclusive with every scope
  # flag — `--base`, `--commit`, and `--uncommitted` all refuse it — and this
  # wrapper always sets a scope, defaulting to --base. So --prompt cannot work
  # here at all, not merely for text starting with a hyphen. Say so plainly
  # instead of forwarding a combination codex will reject with its own opaque
  # "unexpected argument" error.
  if [ -n "$PROMPT" ]; then
    echo "--prompt cannot be combined with a review scope: codex review rejects" >&2
    echo "[PROMPT] alongside --base/--commit/--uncommitted, and this wrapper" >&2
    echo "always scopes the review. Run 'codex review <prompt>' directly for a" >&2
    echo "prompt-driven review." >&2
    exit 2
  fi
  [ -z "$LOG" ] && LOG=$(mktemp "${TMPDIR:-/tmp}/codex-review.XXXXXX")
  PROMPT_ARGS=()
  set +e
  run_with_timeout "$TIMEOUT" codex review -c model="$CODEX_REVIEW_MODEL" -c model_reasoning_effort="$CODEX_REVIEW_EFFORT" "${SCOPE_ARGS[@]}" ${PROMPT_ARGS[@]+-- "${PROMPT_ARGS[@]}"} >"$LOG" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 124 ]; then
    echo "codex review timed out after ${TIMEOUT}s (partial transcript: $LOG)" >&2
    exit 3
  elif [ "$rc" -ne 0 ]; then
    echo "codex review exited $rc (transcript: $LOG)" >&2
    tail -20 "$LOG" >&2
    exit "$rc"
  fi
fi

if [ "$RAW" = true ]; then
  cat "$LOG"; exit 0
fi

# --- Extract summary + findings (ANSI-stripped) ---
CLEAN=$(mktemp "${TMPDIR:-/tmp}/codex-clean.XXXXXX")
trap 'rm -f "$CLEAN"' EXIT
# NUL bytes are routine in a codex transcript, and one is enough to make grep
# treat this file as binary: it reports "binary file matches" and prints no line
# numbers, so header extraction yields nothing and a transcript full of blockers
# distills to CLEAN. Strip them before anything parses the file.
tr -d '\0' < "$LOG" | sed "s/${ESC}\[[0-9;]*m//g" > "$CLEAN"

# Codex labels the findings list differently depending on count — "Full review
# comments:" for several, "Review comment:" for one — so match the known
# variants rather than a single fixed string (a too-rigid anchor reports a
# single finding as CLEAN, a false convergence for the loop).
FRC_RE='^(Full review comments?|Review comments?):$'

# Neither marker is trustworthy on its own. A finding's own body can contain a
# bare `codex` line, a findings header, or both — a finding that quotes a
# transcript excerpt does exactly that — so picking the last occurrence of
# either lands inside the findings body and the section boundaries invert.
#
# Anchor on the PAIR: a real section is a `codex` marker actually followed by a
# findings header. That still leaves the ambiguity codex prints legitimately —
# it emits the same block more than once — versus a quoted section nested inside
# a real finding. Those are indistinguishable by position, so distinguish them
# by CONTENT: collapsing multiple sections is only safe when they are verbatim
# duplicates. Anything else means one section is quoted inside another, and
# picking either one would silently drop the other's findings. Refuse instead.
read -r codex_line frc_line parse_state <<EOF
$(awk -v re="$FRC_RE" '
  function rtrim(s) { sub(/[ \t\n]+$/, "", s); return s }
  { line[NR] = $0 }
  $0 == "codex" { pending = NR; last_codex = NR; next }
  pending && $0 ~ re { np++; C[np] = pending; F[np] = NR; pending = 0 }
  END {
    if (np == 0) {
      # No marker at all means this is not a completed review — an empty or
      # truncated transcript, or an output format we do not know. The no-header
      # path below would call that CLEAN, which authorizes a push.
      if (last_codex == 0) { print 0, 0, "nomarker"; exit }
      # A marker with nothing after it means the final response was never
      # written — codex was killed or the log was truncated mid-stream. The
      # no-header path would report that as CLEAN with an empty summary.
      for (j = last_codex + 1; j <= NR; j++)
        if (line[j] ~ /[^ \t]/) { print last_codex, 0, "none"; exit }
      print last_codex, 0, "incomplete"; exit
    }
    if (np == 1) { print C[1], F[1], "ok"; exit }
    for (i = 1; i <= np; i++) {
      end = (i < np ? C[i+1] - 1 : NR)
      s = ""
      for (j = F[i] + 1; j <= end; j++) s = s line[j] "\n"
      sec[i] = rtrim(s)
    }
    for (i = 2; i <= np; i++)
      if (sec[i] != sec[1]) { print 0, 0, "ambiguous"; exit }
    print C[np], F[np], "ok"
  }
' "$CLEAN")
EOF

if [ "$parse_state" = "ambiguous" ] || [ "$parse_state" = "nomarker" ] \
   || [ "$parse_state" = "incomplete" ]; then
  echo "CODEX_REVIEW: UNPARSED"
  echo "BLOCKING=?  NITS=?"
  echo "PARSE_CAUSE=$parse_state"
  echo "LOG=$LOG"
  echo "--- SUMMARY ---"
  if [ "$parse_state" = "nomarker" ]; then
    echo "No codex marker in the transcript — the review did not complete (empty"
    echo "or truncated log). Read the transcript directly; this is not a review."
  elif [ "$parse_state" = "incomplete" ]; then
    echo "Transcript ends at the codex marker with no response after it — the"
    echo "review was cut off before writing its verdict. This is not a review."
  else
    echo "Transcript has nested or conflicting findings sections — one is quoted"
    echo "inside another. Read the transcript directly; findings would be dropped."
  fi
  exit 4
fi

if [ "$frc_line" -eq 0 ]; then
  SUMMARY=$(sed -n "$((codex_line+1)),\$p" "$CLEAN" | trim | dedupe_doubled)
  FINDINGS=""
else
  SUMMARY=$(sed -n "$((codex_line+1)),$((frc_line-1))p" "$CLEAN" | trim)
  RAW_FINDINGS=$(sed -n "$((frc_line+1)),\$p" "$CLEAN" | trim)
  # Codex also repeats the final summary+findings with NO second `codex` marker,
  # so the pair anchor cannot see the repeat and everything after frc_line is
  # kept — one P1 reported as BLOCKING=2, printed twice. Emit each distinct
  # finding once: a `- [Pn]` line opens an item, indented/blank lines continue
  # it, and anything else (the repeated summary, a repeated header) ends it.
  FINDINGS=$(printf '%s\n' "$RAW_FINDINGS" | awk '
    function flush() {
      if (!initem) return
      sub(/[ \t\n]+$/, "", cur)
      if (!(cur in seen)) { seen[cur] = 1; out = out (out == "" ? "" : "\n") cur }
      initem = 0; cur = ""
    }
    /^- \[P[0-9]\]/ { flush(); cur = $0; initem = 1; next }
    initem && (/^[ \t]/ || /^$/) { cur = cur "\n" $0; next }
    { flush() }
    END { flush(); if (out != "") print out }
  ')
fi

BLOCKING=$(printf '%s\n' "$FINDINGS" | grep -cE '^- \[P[01]\]' || true)
NITS=$(printf '%s\n' "$FINDINGS" | grep -cE '^- \[P[23]\]' || true)
[ -z "$FINDINGS" ] && { BLOCKING=0; NITS=0; }

# A findings section we DETECTED but read no `- [Pn]` items out of is invalid,
# whether the section is empty (header at EOF, truncated mid-write) or full of
# text we could not parse. Key this on the header having been found, not on the
# section text: an empty section is exactly the truncation case, and reporting
# CLEAN for it authorizes a push. Fail loudly rather than emit counts nobody
# should trust — silence is the one outcome this script must never produce.
if [ "$frc_line" -ne 0 ] && [ "$BLOCKING" -eq 0 ] && [ "$NITS" -eq 0 ]; then
  echo "CODEX_REVIEW: UNPARSED"
  echo "BLOCKING=?  NITS=?"
  echo "PARSE_CAUSE=noitems"
  echo "LOG=$LOG"
  echo "--- SUMMARY ---"
  echo "Findings header found but no P0-P3 items parsed out of it — truncated"
  echo "mid-write, or a format we do not know. Read the transcript directly."
  exit 4
fi

# No findings section was recognized, yet the transcript carries priority
# bullets. That means the format changed under us — a codex release renaming
# the header would otherwise turn every review CLEAN, blockers and all. Only
# checked when NO section was found: bullets outside a section we did find are
# quoted content, already handled by the ambiguity and dedup logic above.
if [ "$frc_line" -eq 0 ] && grep -qE '^- \[P[0-9]\]' "$CLEAN"; then
  echo "CODEX_REVIEW: UNPARSED"
  echo "BLOCKING=?  NITS=?"
  echo "PARSE_CAUSE=strayitems"
  echo "LOG=$LOG"
  echo "--- SUMMARY ---"
  echo "Priority bullets found with no recognized findings header — the codex"
  echo "output format has probably changed. Read the transcript directly."
  exit 4
fi

if [ -z "$FINDINGS" ]; then
  echo "CODEX_REVIEW: CLEAN"
else
  echo "CODEX_REVIEW: FINDINGS"
fi
echo "BLOCKING=$BLOCKING  NITS=$NITS"
echo "LOG=$LOG"
echo "--- SUMMARY ---"
printf '%s\n' "$SUMMARY"
if [ -n "$FINDINGS" ]; then
  echo "--- FINDINGS ---"
  printf '%s\n' "$FINDINGS"
fi
