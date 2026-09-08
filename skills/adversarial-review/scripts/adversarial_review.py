#!/usr/bin/env python3
"""Run one `codex exec` per adversarial "angle" from a plan file, in parallel,
each returning schema-enforced JSON findings, then merge and print a compact,
parseable block. Does the real work for adversarial-review.sh, which is a
thin dispatcher (arg pre-scan for --version/--help, environment checks, then
exec's into this file). Stdlib only: argparse, json, subprocess,
concurrent.futures, pathlib, shutil.

Usage mirrors adversarial-review.sh — see that file's header, or run:
    python3 adversarial_review.py --help

Exit codes (same contract as the .sh wrapper):
  0  ok (CLEAN or FINDINGS)
  1  environment (bad path, no git repo, unresolvable base, empty diff, ...)
  2  usage (bad flags, invalid plan JSON, unknown --only id)
  3  codex itself could not be spawned at all for one or more angles — a
     harder failure than a single angle timing out or exiting nonzero, both
     of which are folded into a per-angle UNPARSED result instead (see
     collect_angle_result) so the run still produces a merged report.
  4  unparsed-never-clean (any angle UNPARSED or BLOCKED)
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

# Bump alongside adversarial-review.sh's ADVERSARIAL_REVIEW_VERSION — the two
# must always match (the test suite checks this).
VERSION = "1.0.0"

PROG = "adversarial-review"

CODEX_REVIEW_MODEL = os.environ.get("CODEX_REVIEW_MODEL", "gpt-5.6-sol")
CODEX_REVIEW_EFFORT = os.environ.get("CODEX_REVIEW_EFFORT", "xhigh")
CODEX_BIN = os.environ.get("CODEX_BIN", "codex")

SEVERITIES = ("P0", "P1", "P2", "P3")
BLOCKING_SEVERITIES = ("P0", "P1")
SEVERITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
EXECUTIONS = ("read-only", "workspace-write")
ANGLE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

TOP_REQUIRED = {"angle", "verdict", "summary", "findings"}
FINDING_REQUIRED = {"severity", "path", "line", "claim", "evidence", "reproduction"}

# Used only when no angle-prompt.md is found next to this skill (the file the
# sibling agent owns) — keeps this runner testable and usable standalone.
DEFAULT_ANGLE_PROMPT = """\
You are an adversarial reviewer. Your job is to find real, falsifiable
problems with the change on this branch — not to summarize it, praise it, or
restate the diff.

## What this change claims to do

{{PROMISE}}

Contracts it must uphold:
{{CONTRACTS}}

Invariants that must still hold after this change:
{{INVARIANTS}}

## Your angle: {{ANGLE_TITLE}} ({{ANGLE_ID}})

Mandate: {{MANDATE}}

What a valid finding must include: {{EVIDENCE}}

Files most relevant to this angle:
{{FILES}}

## What to do

Read the actual diff yourself by running:

    {{DIFF_COMMAND}}

against base `{{BASE}}`. Do not rely on any summary of the diff given to you
elsewhere — read the real files and the real diff. For each candidate
problem, try to construct a concrete counterexample or reproduction before
reporting it: an input, a sequence of calls, or a scenario that actually
breaks the claimed contract or invariant. Discard anything you cannot make
concrete.

Report only what your angle is mandated to find. P0/P1 (blocking) means it
breaks a contract or invariant, or is a critical bug; P2/P3 (nit) is
everything else worth mentioning. If you cannot review this change at all
(for example the diff is empty, or you cannot access the repository), set
"verdict" to "BLOCKED", explain why in "summary", and leave "findings" empty.

Respond with ONLY the JSON object matching the required schema — no prose
before or after it, no markdown code fence.
"""


def usage_error(msg):
    print(f"{PROG}: {msg}", file=sys.stderr)
    sys.exit(2)


def env_error(msg):
    print(f"{PROG}: {msg}", file=sys.stderr)
    sys.exit(1)


def codex_error(msg):
    print(f"{PROG}: {msg}", file=sys.stderr)
    sys.exit(3)


# --- Plan loading + validation ------------------------------------------------

def load_plan(path):
    try:
        text = Path(path).read_text()
    except OSError as e:
        env_error(f"cannot read plan file {path}: {e}")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        usage_error(f"invalid JSON in plan file {path}: {e}")
    validate_plan(data, path)
    return data


def validate_plan(data, source):
    if not isinstance(data, dict):
        usage_error(f"plan {source} must be a JSON object")
    if data.get("version") != 1:
        usage_error(
            f"unsupported plan version {data.get('version')!r} in {source} (expected 1)"
        )
    promise = data.get("promise")
    if not isinstance(promise, str) or not promise.strip():
        usage_error(f"plan {source}: 'promise' must be a non-empty string")
    base = data.get("base")
    if base is not None and not (isinstance(base, str) and base.strip()):
        usage_error(f"plan {source}: 'base' must be a non-empty string")
    for list_field in ("contracts", "invariants"):
        val = data.get(list_field)
        if val is not None and not (
            isinstance(val, list) and all(isinstance(x, str) for x in val)
        ):
            usage_error(f"plan {source}: '{list_field}' must be a list of strings")
    angles = data.get("angles")
    if not isinstance(angles, list) or not angles:
        usage_error(f"plan {source} must have a non-empty 'angles' array")
    seen_ids = set()
    for a in angles:
        if not isinstance(a, dict):
            usage_error(f"plan {source}: each angle must be an object")
        aid = a.get("id")
        if not isinstance(aid, str) or not ANGLE_ID_RE.match(aid):
            usage_error(
                f"plan {source}: invalid angle id {aid!r} "
                f"(must match ^[a-z0-9][a-z0-9-]*$)"
            )
        if aid in seen_ids:
            usage_error(f"plan {source}: duplicate angle id '{aid}'")
        seen_ids.add(aid)
        for req_field in ("title", "mandate", "evidence"):
            val = a.get(req_field)
            if not isinstance(val, str) or not val.strip():
                usage_error(
                    f"plan {source}: angle '{aid}' is missing required field '{req_field}'"
                )
        execu = a.get("execution")
        if execu not in EXECUTIONS:
            usage_error(
                f"plan {source}: angle '{aid}' has invalid execution {execu!r} "
                f"(expected one of {', '.join(EXECUTIONS)})"
            )
        files = a.get("files")
        if files is not None and not (
            isinstance(files, list) and all(isinstance(f, str) for f in files)
        ):
            usage_error(f"plan {source}: angle '{aid}' field 'files' must be a list of strings")


def parse_only(only_arg, known_ids):
    """Returns the subset of known_ids named by --only, in plan order, or
    None when --only was not given (meaning: every angle)."""
    if not only_arg:
        return None
    requested = [x.strip() for x in only_arg.split(",") if x.strip()]
    if not requested:
        usage_error("--only given but no angle ids parsed from it")
    unknown = [x for x in requested if x not in known_ids]
    if unknown:
        usage_error(
            f"--only names unknown angle id(s): {', '.join(unknown)} "
            f"(known: {', '.join(known_ids)})"
        )
    wanted = set(requested)
    return [aid for aid in known_ids if aid in wanted]


def partition_angles(angle_ids, angles_by_id):
    """Splits angle_ids into (parallel, serial) execution groups by each
    angle's 'execution' field, preserving plan order within each group.

    read-only angles are safe to run together in the shared thread pool —
    they don't write to the checkout. workspace-write angles run against the
    same shared checkout (isolating them in a git worktree was rejected: a
    worktree lacks the project's real environment — .venv, caches — that
    reviewers need), so they must run one at a time, never concurrently with
    each other or with a read-only angle, to avoid racing writes. See
    run_write_capable_angles for the clean-tree gate and residue handling
    that go with running them serially."""
    parallel = [aid for aid in angle_ids if angles_by_id[aid]["execution"] == "read-only"]
    serial = [aid for aid in angle_ids if angles_by_id[aid]["execution"] == "workspace-write"]
    return parallel, serial


# --- git helpers (live mode only) --------------------------------------------

def git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def repo_root():
    r = git(["rev-parse", "--show-toplevel"], cwd=os.getcwd())
    if r.returncode != 0:
        env_error("not inside a git repository (git rev-parse --show-toplevel failed)")
    return r.stdout.strip()


def git_verify(ref, cwd):
    r = git(["rev-parse", "--verify", "--quiet", ref], cwd=cwd)
    return r.returncode == 0


def git_status_porcelain(cwd):
    """Raw `git status --porcelain` output (empty string means a clean
    tree). Used to gate and police the write-capable angles, which run
    against the shared checkout rather than an isolated worktree."""
    r = git(["status", "--porcelain"], cwd=cwd)
    if r.returncode != 0:
        env_error(f"git status --porcelain failed: {r.stderr.strip()}")
    return r.stdout


def resolve_base(base, cwd):
    """Mirrors codex-review.sh's resolve_base_ref, but stricter: fails loudly
    (exit 1) if nothing verifies, rather than silently falling back to a bare
    name that a later git command would choke on with a less clear error."""
    remotes_r = git(["remote"], cwd=cwd)
    remotes = [l for l in remotes_r.stdout.splitlines() if l.strip()] if remotes_r.returncode == 0 else []
    candidates = []
    for c in [f"origin/{base}"] + [f"{r}/{base}" for r in remotes if r != "origin"] + [base]:
        if c not in candidates:
            candidates.append(c)
    for c in candidates:
        if git_verify(c, cwd):
            return c
    env_error(f"cannot resolve base ref '{base}': tried {', '.join(candidates)}")


# --- Prompt rendering ---------------------------------------------------------

def bulleted(items, empty):
    items = [str(i).strip() for i in (items or []) if str(i).strip()]
    if not items:
        return empty
    return "\n".join(f"- {i}" for i in items)


def load_angle_prompt_template(path_arg, script_dir):
    if path_arg:
        candidate = Path(path_arg)
        if not candidate.is_file():
            env_error(f"no such angle prompt template: {candidate}")
        return candidate.read_text()
    default_path = script_dir.parent / "angle-prompt.md"
    if default_path.is_file():
        return default_path.read_text()
    return DEFAULT_ANGLE_PROMPT


def render_prompt(template, plan, angle, base_resolved):
    subs = {
        "{{BASE}}": base_resolved,
        "{{PROMISE}}": plan.get("promise", ""),
        "{{CONTRACTS}}": bulleted(plan.get("contracts"), "(none)"),
        "{{INVARIANTS}}": bulleted(plan.get("invariants"), "(none)"),
        "{{ANGLE_ID}}": angle["id"],
        "{{ANGLE_TITLE}}": angle["title"],
        "{{MANDATE}}": angle["mandate"],
        "{{EVIDENCE}}": angle["evidence"],
        "{{FILES}}": bulleted(angle.get("files"), "(all changed files)"),
        # shlex.quote only the base — the quoted and unquoted pieces
        # concatenate to the same single shell token, and a base with shell
        # metacharacters (e.g. from a hand-edited plan) can never break out
        # of the command a reviewer is told to paste and run.
        "{{DIFF_COMMAND}}": f"git diff {shlex.quote(base_resolved)}...HEAD",
    }
    out = template
    for k, v in subs.items():
        out = out.replace(k, v)
    return out


# --- Findings schema validation (no external jsonschema dependency) ----------

def validate_findings_json(data):
    if not isinstance(data, dict):
        return False, "not a JSON object"
    keys = set(data.keys())
    if keys - TOP_REQUIRED:
        return False, f"unexpected top-level keys: {sorted(keys - TOP_REQUIRED)}"
    if TOP_REQUIRED - keys:
        return False, f"missing top-level keys: {sorted(TOP_REQUIRED - keys)}"
    if not isinstance(data["angle"], str):
        return False, "'angle' must be a string"
    if data["verdict"] not in ("CLEAN", "FINDINGS", "BLOCKED"):
        return False, f"'verdict' must be one of CLEAN/FINDINGS/BLOCKED, got {data['verdict']!r}"
    if not isinstance(data["summary"], str):
        return False, "'summary' must be a string"
    findings = data["findings"]
    if not isinstance(findings, list):
        return False, "'findings' must be an array"
    for i, f in enumerate(findings):
        if not isinstance(f, dict):
            return False, f"findings[{i}] must be an object"
        fkeys = set(f.keys())
        if fkeys - FINDING_REQUIRED:
            return False, f"findings[{i}] has unexpected keys: {sorted(fkeys - FINDING_REQUIRED)}"
        if FINDING_REQUIRED - fkeys:
            return False, f"findings[{i}] missing keys: {sorted(FINDING_REQUIRED - fkeys)}"
        if f["severity"] not in SEVERITIES:
            return False, f"findings[{i}].severity must be one of {SEVERITIES}, got {f['severity']!r}"
        if not isinstance(f["path"], str):
            return False, f"findings[{i}].path must be a string"
        if not isinstance(f["line"], int) or isinstance(f["line"], bool):
            return False, f"findings[{i}].line must be an integer"
        for key in ("claim", "evidence", "reproduction"):
            if not isinstance(f[key], str):
                return False, f"findings[{i}].{key} must be a string"
    # verdict="FINDINGS" with an empty findings array is self-contradictory —
    # never trust it as CLEAN (or as FINDINGS with nothing to show); treat it
    # the same as any other schema violation.
    if data["verdict"] == "FINDINGS" and not findings:
        return False, "'verdict' is FINDINGS but 'findings' is empty"
    return True, ""


# --- Per-angle result collection ---------------------------------------------

@dataclass
class AngleResult:
    id: str
    title: str
    kind: str  # CLEAN | FINDINGS | BLOCKED | UNPARSED
    cause: str = ""  # set only when kind == UNPARSED
    summary: str = ""
    findings: list = field(default_factory=list)


# Case-insensitive substrings the provider's content filter is known to emit
# when it refuses an angle's prompt outright (observed: gpt-5.6-sol refusing
# a mandate phrased as an attack recipe). A match distinguishes a refusal
# from an ordinary crash so the SKILL can reword and retry instead of
# treating the angle as broken.
REFUSAL_MARKERS = (
    "flagged for possible cybersecurity risk",
    "content was flagged",
    "trusted access for cyber",
)


def log_refused(log_path):
    """Whether an angle's .log shows the provider's content filter refused
    the prompt, rather than the angle crashing or misbehaving on its own."""
    if not log_path.is_file():
        return False
    text = log_path.read_text(errors="replace").lower()
    return any(marker in text for marker in REFUSAL_MARKERS)


def collect_angle_result(angle, run_dir):
    aid = angle["id"]
    status_path = run_dir / f"{aid}.status"
    out_path = run_dir / f"{aid}.out.json"
    residue_path = run_dir / f"{aid}.residue.txt"
    log_path = run_dir / f"{aid}.log"
    skipped_path = run_dir / f"{aid}.skipped.txt"

    # An angle that run_write_capable_angles decided never to run at all —
    # the dirty-tree gate, or a later angle skipped after an earlier one's
    # residue compromised the shared tree — leaves this marker instead of a
    # .status/.out.json (see run_write_capable_angles). Checked first, ahead
    # of every other file, so a later --from-dir re-merge reports the same
    # UNPARSED(<cause>) rather than misreading stale or absent files.
    if skipped_path.is_file():
        cause = skipped_path.read_text().strip() or "skipped"
        return AngleResult(aid, angle["title"], "UNPARSED", cause=cause)

    # A present out.json is trusted only once its own run reports exit 0 —
    # a missing or unparsable .status file, or one that isn't 0, means the
    # run never properly completed, so out.json (if present at all) is never
    # accepted, however clean it looks: it could be left over from an
    # earlier run, or partially written mid-crash.
    if not status_path.is_file():
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nostatus")
    status_text = status_path.read_text().strip()
    try:
        exit_code = int(status_text)
    except ValueError:
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nostatus")

    if exit_code == 124:
        return AngleResult(aid, angle["title"], "UNPARSED", cause="timeout")
    if exit_code != 0:
        # A nonzero exit with no out.json can mean the provider refused the
        # prompt outright rather than the angle failing to run — distinguish
        # that before falling back to the generic exit<n> cause.
        if not out_path.is_file() and log_refused(log_path):
            print(
                f"{PROG}: angle '{aid}' was refused by the provider's content filter "
                "(reword the mandate and re-run)",
                file=sys.stderr,
            )
            return AngleResult(aid, angle["title"], "UNPARSED", cause="refused")
        return AngleResult(aid, angle["title"], "UNPARSED", cause=f"exit{exit_code}")

    if not out_path.is_file():
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nojson")
    try:
        data = json.loads(out_path.read_text())
    except (OSError, json.JSONDecodeError):
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nojson")

    ok, _err = validate_findings_json(data)
    if not ok:
        return AngleResult(aid, angle["title"], "UNPARSED", cause="schema")

    # Output tagged with a different angle's id is never trusted — a stale
    # file, a copy-paste, or the model answering the wrong mandate — so its
    # findings are not attributed to anything.
    if data["angle"] != aid:
        return AngleResult(aid, angle["title"], "UNPARSED", cause="mistagged")

    findings = data["findings"]

    # A write-capable angle that left the checkout dirty (see
    # run_write_capable_angles) is never trusted as a clean run, however its
    # output parsed — the environment it ran in, and every serial angle
    # after it, may be compromised. Its findings are still surfaced (merged
    # by presence, not by kind — see merge_findings) so nothing is lost, but
    # the angle itself does not count as RAN.
    if residue_path.is_file():
        return AngleResult(
            aid, angle["title"], "UNPARSED", cause="residue",
            summary=data["summary"], findings=findings,
        )

    # BLOCKED takes precedence over a nonempty findings array: a reviewer
    # that could not complete its mandate is never "clean" just because it
    # also reported partial findings before giving up.
    if data["verdict"] == "BLOCKED":
        return AngleResult(aid, angle["title"], "BLOCKED", summary=data["summary"], findings=findings)

    # Trust the findings array over the self-reported verdict text: a model
    # that mislabels verdict="CLEAN" while still listing findings must not
    # have those findings silently dropped.
    if findings:
        return AngleResult(aid, angle["title"], "FINDINGS", summary=data["summary"], findings=findings)
    return AngleResult(aid, angle["title"], "CLEAN", summary=data["summary"])


# --- Merge + dedup -------------------------------------------------------------

def dedup_key(f):
    # The full normalized claim, not a prefix — two findings at the same
    # path:line whose claims share a long common prefix but diverge later
    # are different findings and must both survive the merge.
    claim_norm = re.sub(r"\s+", " ", f["claim"].strip().lower())
    return (f["path"], f["line"], claim_norm)


def merge_findings(results):
    merged = {}
    order = []
    for r in results:
        # Merge by presence, not by kind — a BLOCKED or UNPARSED(residue)
        # angle can still carry real findings (see collect_angle_result) and
        # those must not be silently dropped just because the angle itself
        # didn't count as a clean FINDINGS run.
        if not r.findings:
            continue
        for f in r.findings:
            key = dedup_key(f)
            if key not in merged:
                entry = dict(f)
                entry["angles"] = set()
                merged[key] = entry
                order.append(key)
            entry = merged[key]
            entry["angles"].add(r.id)
            if SEVERITY_RANK[f["severity"]] < SEVERITY_RANK[entry["severity"]]:
                entry["severity"] = f["severity"]
                entry["path"] = f["path"]
                entry["line"] = f["line"]
                entry["claim"] = f["claim"]
                entry["evidence"] = f["evidence"]
                entry["reproduction"] = f["reproduction"]

    findings = [merged[k] for k in order]
    for f in findings:
        f["angles"] = sorted(f["angles"])

    def sort_key(f):
        blocking = 0 if f["severity"] in BLOCKING_SEVERITIES else 1
        return (blocking, f["path"], f["line"], SEVERITY_RANK[f["severity"]])

    findings.sort(key=sort_key)
    return findings


# --- Report rendering ----------------------------------------------------------

def escape_block_text(s):
    """Collapse any literal CR/LF in `s` into a visible two-character `\\n`
    so a multiline path/claim/evidence/reproduction can never inject a bare
    continuation line into the compact block — each finding must render as
    exactly its `- [Pn] ...` line plus the `  evidence:`/`  reproduction:`
    lines that follow it, nothing else. Uses str.replace, not re.sub, so the
    literal backslash-n is never re-interpreted as an escape sequence.
    merged.json is unaffected — JSON handles embedded newlines natively, so
    this only applies to the plain-text block."""
    return s.replace("\r\n", "\\n").replace("\r", "\\n").replace("\n", "\\n")


def build_report(angle_ids, results_by_id, merged_findings, run_dir, merged_path=None):
    unparsed_n = sum(1 for aid in angle_ids if results_by_id[aid].kind == "UNPARSED")
    blocked_n = sum(1 for aid in angle_ids if results_by_id[aid].kind == "BLOCKED")
    ran = len(angle_ids) - unparsed_n
    blocking = sum(1 for f in merged_findings if f["severity"] in BLOCKING_SEVERITIES)
    nits = len(merged_findings) - blocking

    # A review that did not fully run is not a clean review: any UNPARSED or
    # BLOCKED angle banners the whole run UNPARSED, even if every angle that
    # did run came back CLEAN.
    if unparsed_n > 0 or blocked_n > 0:
        banner, rc = "UNPARSED", 4
    elif merged_findings:
        banner, rc = "FINDINGS", 0
    else:
        banner, rc = "CLEAN", 0

    lines = [
        f"ADVERSARIAL_REVIEW: {banner}",
        f"ANGLES={len(angle_ids)}  RAN={ran}  BLOCKED={blocked_n}  UNPARSED={unparsed_n}",
        f"BLOCKING={blocking}  NITS={nits}",
        f"DIR={run_dir}",
    ]
    # merged_path is only ever different from the default <run_dir>/merged.json
    # when --from-dir pointed at a directory inside a real git checkout (see
    # resolve_merged_json_path) — call that out explicitly rather than
    # leaving it to be discovered by listing the run dir.
    if merged_path is not None and merged_path != run_dir / "merged.json":
        lines.append(f"MERGED={merged_path}")
    lines.append("--- ANGLES ---")
    for aid in angle_ids:
        r = results_by_id[aid]
        if r.kind == "UNPARSED":
            lines.append(f"{aid}: UNPARSED({r.cause})")
        elif r.kind == "BLOCKED":
            lines.append(f"{aid}: BLOCKED")
        elif r.kind == "CLEAN":
            lines.append(f"{aid}: CLEAN")
        else:
            lines.append(f"{aid}: FINDINGS({len(r.findings)})")

    lines.append("--- SUMMARY ---")
    for aid in angle_ids:
        r = results_by_id[aid]
        if r.kind == "UNPARSED":
            lines.append(f"{aid}: (unparsed — {r.cause})")
        else:
            lines.append(f"{aid}: {escape_block_text(r.summary)}")

    if merged_findings:
        lines.append("--- FINDINGS ---")
        for f in merged_findings:
            path = escape_block_text(f["path"])
            claim = escape_block_text(f["claim"])
            evidence = escape_block_text(f["evidence"])
            reproduction = escape_block_text(f["reproduction"])
            lines.append(
                f"- [{f['severity']}] {path}:{f['line']} — {claim}  "
                f"[angles: {','.join(f['angles'])}]"
            )
            lines.append(f"  evidence: {evidence}")
            lines.append(f"  reproduction: {reproduction}")

    counts = {
        "angles": len(angle_ids),
        "ran": ran,
        "blocked": blocked_n,
        "unparsed": unparsed_n,
        "blocking": blocking,
        "nits": nits,
    }
    return "\n".join(lines), rc, banner, counts


def dir_in_git_repo(path):
    """Whether `path` sits inside a git working tree (any repo — not just
    the one adversarial-review would review, and no relation to whether
    `path` itself is version-controlled). Used only to decide where
    merged.json is safe to land; a git rev-parse failure (no git on PATH, or
    genuinely not in a repo) is read as "not in a repo" so the normal
    same-directory behavior is the fail-safe default."""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=path, capture_output=True, text=True,
        )
    except OSError:
        return False
    return r.returncode == 0 and r.stdout.strip() == "true"


def resolve_merged_json_path(run_dir, from_dir_mode):
    """Where merged.json for this run should be written. In `--from-dir`
    mode `run_dir` may be a directory the caller doesn't own writing into —
    a fixtures tree, an example checked into some other repo — so if it
    sits inside a git working tree, merged.json is diverted to a temp file
    instead of dirtying that checkout; the report's MERGED= line (see
    build_report) says where it actually landed. Live runs never divert:
    `main` already refuses a run dir inside the repository under review, so
    the default <run_dir>/merged.json is always safe there."""
    if from_dir_mode and dir_in_git_repo(run_dir):
        fd, path = tempfile.mkstemp(prefix="adversarial-review-merged.", suffix=".json")
        os.close(fd)
        return Path(path)
    return run_dir / "merged.json"


def write_merged_json(merged_path, angle_ids, results_by_id, merged_findings, banner, counts):
    doc = {
        "version": 1,
        "verdict": banner,
        "counts": counts,
        "angles": [
            {
                "id": aid,
                "title": results_by_id[aid].title,
                "status": results_by_id[aid].kind,
                "cause": results_by_id[aid].cause or None,
                "summary": results_by_id[aid].summary or None,
            }
            for aid in angle_ids
        ],
        "findings": merged_findings,
    }
    merged_path.write_text(json.dumps(doc, indent=2) + "\n")


def clear_merged_json(run_dir):
    """Best-effort delete of run_dir/merged.json. Called both before a live
    run launches any angle (so a reused --dir's merged.json from a previous
    invocation can never be mistaken for this run's own verdict) and again
    on the spawn-failure abort path in main(), which exits before ever
    writing a new one — an abort must never leave a previous run's verdict
    looking like this run's result. A missing file is not an error."""
    try:
        (run_dir / "merged.json").unlink()
    except FileNotFoundError:
        pass


# --- CLI -----------------------------------------------------------------------

def build_arg_parser():
    p = argparse.ArgumentParser(prog=PROG, add_help=True)
    p.add_argument("--plan", help="plan JSON file (required unless --from-dir)")
    p.add_argument("--base", help="override the plan's base branch")
    p.add_argument("--jobs", type=int, help="read-only angles run in parallel (default: min(#read-only, 4)); workspace-write angles always run serially")
    p.add_argument("--timeout", type=int, default=900, help="per-angle codex timeout, seconds")
    p.add_argument("--dir", help="run directory (default: a fresh mktemp -d)")
    p.add_argument("--only", help="comma-separated angle ids to restrict to")
    p.add_argument("--angle-prompt", help="prompt template file")
    p.add_argument("--from-dir", help="skip codex; merge from an existing run dir")
    p.add_argument("--version", action="store_true", help="print the version and exit")
    return p


def _group_running(pgid):
    """Whether any process still belongs to process group `pgid`. Signal 0
    sends nothing — it only probes whether the target exists — so this is
    safe to call repeatedly while polling."""
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        # Can't tell (e.g. a permissions surprise) — assume it's still
        # there rather than declaring victory early.
        return True


def _group_member_pids(pgid):
    """Best-effort list of pids currently in process group `pgid`, via `ps
    -eo pid=,pgid=` (supported by both GNU/Linux and BSD/macOS ps). Used
    only to size the post-exit leak note in run_angle — never to decide
    whether to act (that's `_group_running`, a plain signal-0 probe that
    doesn't depend on `ps` existing at all). Returns an empty list, not an
    error, if `ps` is missing or its output doesn't parse."""
    try:
        r = subprocess.run(["ps", "-eo", "pid=,pgid="], capture_output=True, text=True)
    except OSError:
        return []
    if r.returncode != 0:
        return []
    pids = []
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pid, pg = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if pg == pgid:
            pids.append(pid)
    return pids


def kill_process_group(proc, grace_sec=2):
    """SIGTERM the whole process group `proc` leads (started with
    start_new_session=True), then verify the group actually died rather than
    just `proc` itself. A timed-out reviewer may have spawned children of its
    own — a test runner, a backgrounded reproduction — that ignore or trap
    SIGTERM even when the reviewer process (`proc`) exits on it normally;
    proc.wait() succeeding only proves the leader is gone, not the group, so
    membership is re-checked with `os.killpg(pgid, 0)` before declaring the
    kill done. If any member survives, SIGKILL the group and poll (bounded by
    `grace_sec`) until no member remains. Best-effort: a process/group that's
    already gone is not an error here.

    `start_new_session=True` makes `proc`'s own pid its process-group id at
    spawn time, and that never changes for the group's lifetime — so pgid is
    just `proc.pid`, not something to look up via `os.getpgid`. That lookup
    would in fact be wrong here: this is also called after `proc` has
    already exited and been reaped (see run_angle's post-exit reap), at
    which point `os.getpgid(proc.pid)` can only fail (ProcessLookupError) or,
    worse, silently return an unrelated process's pgid if the pid number has
    already been recycled by the OS."""
    pgid = proc.pid

    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, OSError):
        return
    try:
        proc.wait(timeout=grace_sec)
    except subprocess.TimeoutExpired:
        pass

    if not _group_running(pgid):
        return

    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, OSError):
        return

    deadline = time.monotonic() + grace_sec
    while time.monotonic() < deadline and _group_running(pgid):
        time.sleep(0.05)


# Every file collect_angle_result (or a human re-running --from-dir) would
# read for one angle. A reused --dir (an explicit --dir re-run of the same
# plan, or --only re-running just a few ids) must never let one of these
# survive from an earlier run — a stale .out.json or .residue.txt sitting
# next to a failed re-run would be misread as this run's own result.
ANGLE_ARTIFACT_SUFFIXES = (".prompt.txt", ".out.json", ".log", ".status", ".residue.txt", ".skipped.txt")


def clear_stale_artifacts(aid, run_dir):
    """Delete any leftover files for angle `aid` in `run_dir` before it's
    launched again. Best-effort: a file that's already gone is not an
    error."""
    for suffix in ANGLE_ARTIFACT_SUFFIXES:
        try:
            (run_dir / f"{aid}{suffix}").unlink()
        except FileNotFoundError:
            pass


def run_angle(aid, angle, plan, base_resolved, template, run_dir, root, schema_path, timeout_sec):
    clear_stale_artifacts(aid, run_dir)
    prompt_text = render_prompt(template, plan, angle, base_resolved)
    (run_dir / f"{aid}.prompt.txt").write_text(prompt_text)
    out_path = run_dir / f"{aid}.out.json"
    log_path = run_dir / f"{aid}.log"
    cmd = [
        CODEX_BIN, "exec", "--ephemeral",
        "-s", angle["execution"],
        "-C", root,
        "--output-schema", str(schema_path),
        "-o", str(out_path),
        "-c", f"model={CODEX_REVIEW_MODEL}",
        "-c", f"model_reasoning_effort={CODEX_REVIEW_EFFORT}",
        prompt_text,
    ]
    try:
        with open(log_path, "wb") as logfh:
            # start_new_session makes this process its own process-group
            # leader, so a timeout can reap everything it spawned via
            # killpg — not just its own pid, which is all subprocess.run's
            # built-in timeout kill would reach.
            proc = subprocess.Popen(
                cmd, stdin=subprocess.DEVNULL, stdout=logfh, stderr=subprocess.STDOUT,
                cwd=root, start_new_session=True,
            )
            try:
                proc.communicate(timeout=timeout_sec)
                (run_dir / f"{aid}.status").write_text(f"{proc.returncode}\n")
                # A normal exit only proves the reviewer process itself is
                # gone, not anything it backgrounded (a detached
                # reproduction, a leftover server) — that survives in the
                # same process group exactly as it would after a timeout,
                # so reap it here too rather than only on TimeoutExpired.
                if _group_running(proc.pid):
                    survivors = _group_member_pids(proc.pid)
                    kill_process_group(proc)
                    count = len(survivors) if survivors else "some"
                    note = (
                        f"{PROG}: angle '{aid}' reviewer left {count} background "
                        "process(es) running after exit; terminated\n"
                    )
                    logfh.write(note.encode())
                    logfh.flush()
                    print(note, end="", file=sys.stderr)
            except subprocess.TimeoutExpired:
                kill_process_group(proc)
                (run_dir / f"{aid}.status").write_text("124\n")
        return None
    except OSError as e:
        return str(e)


def _mark_skipped(aid, title, cause, run_dir, synthetic_results):
    """Records that write-capable angle `aid` never ran at all (the
    dirty-tree gate, or the compromised cascade after an earlier angle's
    residue — see run_write_capable_angles). Clears any stale artifacts
    first, so a later --from-dir re-merge of a reused --dir can never read
    an old .out.json/.status left from a prior invocation and misreport
    this angle CLEAN; writes the '<aid>.skipped.txt' marker
    collect_angle_result checks for, so that re-merge reports the same
    UNPARSED(<cause>) this run does; and records the in-memory AngleResult
    for this run's own report."""
    clear_stale_artifacts(aid, run_dir)
    (run_dir / f"{aid}.skipped.txt").write_text(f"{cause}\n")
    synthetic_results[aid] = AngleResult(aid, title, "UNPARSED", cause=cause)


def run_write_capable_angles(serial_ids, angles_by_id, plan, base_resolved, template, run_dir, root, schema_path, timeout_sec):
    """Runs workspace-write angles one at a time against the shared checkout
    (never concurrently with each other or with a read-only angle — see
    partition_angles: isolating them in a git worktree was rejected because
    reviewers need the project's real environment — .venv, caches — which a
    worktree lacks).

    Requires a clean tree before the first one; if the tree is already dirty
    at that point, every write-capable angle is skipped without running, as
    UNPARSED(dirty-tree) — contract, not policy: a dirty tree means we can't
    attribute any residue that follows to a specific angle. After each angle
    that does run, the tree is checked again: a non-empty `git status
    --porcelain` is recorded to <angle>.residue.txt and printed to stderr,
    that angle is marked UNPARSED(residue), and every write-capable angle
    still to come is skipped as UNPARSED(compromised) rather than run
    against a tree an earlier angle already modified — nothing is reverted
    automatically here; that is the SKILL's job (inspect, restore).

    Returns (synthetic_results, spawn_failures). synthetic_results holds
    AngleResult objects for angles that never ran at all (the dirty-tree
    gate, or the compromised cascade) — there is no status/out file for
    those, only the '<aid>.skipped.txt' marker (see _mark_skipped), so they
    bypass collect_angle_result's normal read entirely in this run, though a
    later --from-dir re-merge reads that same marker back through
    collect_angle_result. Angles that did run are left for the caller's
    normal collect_angle_result pass, which also checks for a residue
    marker."""
    synthetic_results = {}
    spawn_failures = []

    if not serial_ids:
        return synthetic_results, spawn_failures

    if git_status_porcelain(root).strip():
        print(
            f"{PROG}: working tree is dirty before the first write-capable angle — "
            f"not running (UNPARSED(dirty-tree)): {', '.join(serial_ids)}",
            file=sys.stderr,
        )
        for aid in serial_ids:
            _mark_skipped(aid, angles_by_id[aid]["title"], "dirty-tree", run_dir, synthetic_results)
        return synthetic_results, spawn_failures

    compromised = False
    for aid in serial_ids:
        if compromised:
            _mark_skipped(aid, angles_by_id[aid]["title"], "compromised", run_dir, synthetic_results)
            continue
        err = run_angle(
            aid, angles_by_id[aid], plan, base_resolved, template,
            run_dir, root, schema_path, timeout_sec,
        )
        if err is not None:
            spawn_failures.append((aid, err))
            continue
        status = git_status_porcelain(root)
        if status.strip():
            (run_dir / f"{aid}.residue.txt").write_text(status)
            print(f"{PROG}: angle '{aid}' left the working tree dirty — not reverting:", file=sys.stderr)
            for line in status.splitlines():
                print(f"  {line}", file=sys.stderr)
            compromised = True

    return synthetic_results, spawn_failures


def main(argv=None):
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    if args.version:
        print(f"adversarial_review.py {VERSION}")
        return 0

    script_dir = Path(__file__).resolve().parent

    if args.from_dir:
        run_dir = Path(args.from_dir).resolve()
        if not run_dir.is_dir():
            env_error(f"no such run directory: {run_dir}")
        plan_path = run_dir / "plan.json"
        if not plan_path.is_file():
            env_error(f"no plan.json in run directory: {plan_path}")
        plan = load_plan(plan_path)
        angle_ids_all = [a["id"] for a in plan["angles"]]
        angles_by_id = {a["id"]: a for a in plan["angles"]}
        angle_ids = parse_only(args.only, angle_ids_all) or angle_ids_all
        results_by_id = {aid: collect_angle_result(angles_by_id[aid], run_dir) for aid in angle_ids}
    else:
        if not args.plan:
            usage_error("--plan FILE is required unless --from-dir is given")
        plan_path = Path(args.plan).resolve()
        if not plan_path.is_file():
            env_error(f"no such plan file: {plan_path}")
        plan = load_plan(plan_path)
        angle_ids_all = [a["id"] for a in plan["angles"]]
        angles_by_id = {a["id"]: a for a in plan["angles"]}
        angle_ids = parse_only(args.only, angle_ids_all) or angle_ids_all

        if shutil.which(CODEX_BIN) is None:
            env_error(f"codex CLI ('{CODEX_BIN}') not found on PATH")

        root = repo_root()
        base = args.base or plan.get("base")
        if not base:
            usage_error("plan has no 'base' and --base was not given")
        base_resolved = resolve_base(base, root)

        diff_check = git(["diff", f"{base_resolved}...HEAD", "--name-only"], root)
        if diff_check.returncode != 0:
            env_error(f"git diff {base_resolved}...HEAD failed: {diff_check.stderr.strip()}")
        if not diff_check.stdout.strip():
            env_error(f"empty diff between {base_resolved} and HEAD — nothing to review")

        if args.jobs is not None and args.jobs < 1:
            usage_error("--jobs must be >= 1")
        if args.timeout < 1:
            usage_error("--timeout must be >= 1")

        if args.dir:
            # Resolved before mkdir and before any use in an -o path passed to
            # codex, which runs with cwd=root — a relative --dir would
            # otherwise land codex's output under root instead of where the
            # caller meant.
            run_dir = Path(args.dir).resolve()
        else:
            # .resolve() here too — mkdtemp's dir= can itself be a symlink
            # (e.g. macOS's /tmp -> /private/tmp), and the containment check
            # below, plus every path handed to codex, must compare against
            # the same fully-resolved form as `root`.
            run_dir = Path(
                tempfile.mkdtemp(prefix="adversarial-review.", dir=os.environ.get("TMPDIR", "/tmp"))
            ).resolve()

        # A run directory inside the repository would let codex's own
        # output (or a workspace-write angle's reproduction) land inside the
        # tree under review, dirtying it under the very git-status gate meant
        # to catch that. --from-dir is exempt (handled in its own branch
        # above) — it only ever reads a prior run's output, never writes.
        if run_dir.is_relative_to(Path(root).resolve()):
            if not args.dir:
                shutil.rmtree(run_dir, ignore_errors=True)
            usage_error(
                f"run directory {run_dir} is inside the repository root {root} — "
                "the run directory must live outside the repository so it cannot dirty the tree"
            )

        if args.dir:
            run_dir.mkdir(parents=True, exist_ok=True)
        # A reused --dir may carry a merged.json from an earlier invocation
        # — clear it before any angle launches, so an abort further down
        # (spawn failure) can never leave that previous verdict looking
        # like this run's own result.
        clear_merged_json(run_dir)
        (run_dir / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")

        template = load_angle_prompt_template(args.angle_prompt, script_dir)
        schema_path = script_dir / "findings.schema.json"

        # Read-only angles don't write to the checkout, so they're safe to
        # race in the shared thread pool. workspace-write angles run against
        # the same shared checkout and must never race each other or a
        # read-only angle — see partition_angles and
        # run_write_capable_angles.
        parallel_ids, serial_ids = partition_angles(angle_ids, angles_by_id)

        spawn_failures = []
        if parallel_ids:
            jobs = args.jobs or min(len(parallel_ids), 4)
            with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
                future_to_id = {
                    ex.submit(
                        run_angle, aid, angles_by_id[aid], plan, base_resolved, template,
                        run_dir, root, schema_path, args.timeout,
                    ): aid
                    for aid in parallel_ids
                }
                for fut in cf.as_completed(future_to_id):
                    err = fut.result()
                    if err is not None:
                        spawn_failures.append((future_to_id[fut], err))

        synthetic_results, serial_spawn_failures = run_write_capable_angles(
            serial_ids, angles_by_id, plan, base_resolved, template,
            run_dir, root, schema_path, args.timeout,
        )
        spawn_failures.extend(serial_spawn_failures)

        if spawn_failures:
            for aid, err in spawn_failures:
                print(f"{PROG}: codex failed to start for angle '{aid}': {err}", file=sys.stderr)
            clear_merged_json(run_dir)
            codex_error(
                "codex could not be invoked for one or more angles — aborting without a "
                "merged report (a review that never started is not the same as one that "
                "ran and timed out or errored, which is instead folded into a per-angle "
                "UNPARSED result)"
            )

        results_by_id = {
            aid: synthetic_results[aid] if aid in synthetic_results
            else collect_angle_result(angles_by_id[aid], run_dir)
            for aid in angle_ids
        }

    merged_findings = merge_findings([results_by_id[aid] for aid in angle_ids])
    merged_path = resolve_merged_json_path(run_dir, from_dir_mode=bool(args.from_dir))
    report, rc, banner, counts = build_report(
        angle_ids, results_by_id, merged_findings, run_dir, merged_path=merged_path,
    )
    write_merged_json(merged_path, angle_ids, results_by_id, merged_findings, banner, counts)
    print(report)
    return rc


if __name__ == "__main__":
    sys.exit(main())
