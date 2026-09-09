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
130  interrupted (SIGINT/Ctrl-C, or SIGTERM) — every tracked reviewer
     process group is killed before exiting.
"""
import argparse
import atexit
import concurrent.futures as cf
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

# Bump alongside adversarial-review.sh's ADVERSARIAL_REVIEW_VERSION — the two
# must always match (the test suite checks this).
VERSION = "1.1.0"

PROG = "adversarial-review"

CODEX_REVIEW_MODEL = os.environ.get("CODEX_REVIEW_MODEL", "gpt-5.6-sol")
CODEX_REVIEW_EFFORT = os.environ.get("CODEX_REVIEW_EFFORT", "xhigh")
CODEX_BIN = os.environ.get("CODEX_BIN", "codex")

SEVERITIES = ("P0", "P1", "P2", "P3")
BLOCKING_SEVERITIES = ("P0", "P1")
SEVERITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
EXECUTIONS = ("read-only", "workspace-write")
ANGLE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# SKILL.md documents 3-6 angles per plan (a generic angle gets dropped, not
# kept as padding); only the upper bound is enforced here — a malformed plan
# past it launches one paid codex pass per entry.
MAX_ANGLES = 6

TOP_REQUIRED = {"angle", "verdict", "summary", "findings"}
FINDING_REQUIRED = {"severity", "path", "line", "claim", "evidence", "reproduction"}

# Used only when no angle-prompt.md is found next to this skill (the file the
# sibling agent owns) — keeps this runner testable and usable standalone.
# Must carry every placeholder render_prompt substitutes, {{EXECUTION}}
# included — a fallback that silently drops the read-only/workspace-write
# distinction would leave a reviewer with no signal it's allowed (or not) to
# run its own mandated reproduction.
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

Execution mode: {{EXECUTION}}

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
concrete. Follow the execution mode above exactly — it says whether you may
run that reproduction yourself or must only describe it.

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
    if len(angles) > MAX_ANGLES:
        usage_error(
            f"plan {source} has {len(angles)} angles, more than the max of "
            f"{MAX_ANGLES} (see SKILL.md's 3-to-6 cap: drop a generic angle "
            "rather than pad the plan)"
        )
    seen_ids = set()
    for a in angles:
        if not isinstance(a, dict):
            usage_error(f"plan {source}: each angle must be an object")
        aid = a.get("id")
        # fullmatch, not match/$ -- re's `$` matches before a trailing
        # newline too, so `.match()` would let an id like "alpha\n" through.
        if not isinstance(aid, str) or not ANGLE_ID_RE.fullmatch(aid):
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


def compute_plan_hash(plan):
    """sha256 hex digest of `plan`'s canonical JSON — sorted keys, compact
    separators — so the same semantic plan always hashes identically
    regardless of key order or the source file's formatting. Computed over
    the plan exactly as loaded, before any run-only bookkeeping (see
    run_meta / the "_run" key stamped into run_dir/plan.json) is attached,
    so it changes if and only if the plan's own content changes. Used to
    detect a `--dir` reused across two live runs whose plan differs — see
    main()'s stale-artifact handling and collect_angle_result's meta check."""
    canonical = json.dumps(plan, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def parse_only(only_arg, known_ids):
    """Returns the subset of known_ids named by --only, in plan order, or
    None when --only was not given at all (meaning: every angle). An
    explicitly empty --only (only_arg == "", as opposed to argparse's own
    default of None when the flag is absent) is not "every angle" — it falls
    through to the empty-`requested` check below and is a usage error."""
    if only_arg is None:
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
    against the shared checkout rather than an isolated worktree — so a
    reviewer dropping a new, merely-untracked file counts as dirtying the
    tree exactly like modifying a tracked one does. Both `--untracked-
    files=all` (recurses into untracked directories instead of collapsing
    them to one line, and can't be shadowed by a `status.showUntrackedFiles
    no` in the user's git config) and `-c status.showUntrackedFiles=all`
    (belt and suspenders — forces the same thing at the config layer, in
    case some other -c or a repo-local setting fights the flag) are passed
    so this can never be blinded to exactly the kind of residue a careless
    reviewer is most likely to leave. `--ignored=no` keeps genuinely
    gitignored paths (build output, caches) out of the picture, same as
    plain `git status` already defaults to."""
    r = git(
        [
            "-c", "status.showUntrackedFiles=all",
            "status", "--porcelain", "--untracked-files=all", "--ignored=no",
        ],
        cwd=cwd,
    )
    if r.returncode != 0:
        env_error(f"git status --porcelain failed: {r.stderr.strip()}")
    return r.stdout


def resolve_base(base, cwd):
    """Mirrors codex-review.sh's resolve_base_ref, but stricter: fails loudly
    (exit 1) if nothing verifies, rather than silently falling back to a bare
    name that a later git command would choke on with a less clear error.

    Remote candidates are verified through the fully-qualified
    refs/remotes/<remote>/<base> path, never the bare "<remote>/<base>" —
    git's own ref disambiguation (gitrevisions(7)) checks refs/heads/<name>
    before refs/remotes/<name>, so a bare "origin/<base>" would verify
    against a *local* branch that merely happens to be named that (e.g.
    "origin/main"), even when no "origin" remote exists at all. Only once
    every actually-configured remote has been checked this way does this
    fall back to the plain local <base> (refs/heads/<base>), then to the
    bare revision (a tag, a commit-ish, ...) as a last resort.

    Every verified case returns the fully-qualified ref
    (refs/remotes/<remote>/<base>, refs/heads/<base>), not the shorthand —
    for the same disambiguation-order reason above: a downstream `git diff`
    or the rendered prompt handed the bare "<remote>/<base>" would resolve
    it fresh, and a local branch literally named e.g. "origin/main" would
    win over the remote-tracking ref this function actually verified. Only
    the last-resort bare revision (a SHA, a tag — nothing this function can
    qualify) is returned as given.

    A `base` already written in the documented "<remote>/<branch>" form
    (e.g. a plan's `"base": "origin/main"`) is checked first, against
    exactly that remote's own refs/remotes/<remote>/<branch> — before it,
    the generic loop below would instead probe the nonsensical
    refs/remotes/origin/origin/main (base's own "origin/" prefix, plus the
    loop's own), which never verifies, and control would fall through to
    refs/heads/origin/main — a wrong answer whenever a local branch happens
    to be named literally "origin/main", the exact decoy this function's
    own fully-qualified-remote design otherwise exists to defeat. If that
    prefix names a remote that really is configured but the qualified ref
    still doesn't verify, this fails immediately, naming the missing ref —
    it never falls through to the generic searches below, which could
    otherwise resolve to something unrelated (that same "origin/main" local
    branch, a different remote's ref, ...) standing in for a remote ref that
    was actually expected to exist."""
    remotes_r = git(["remote"], cwd=cwd)
    remotes = [l for l in remotes_r.stdout.splitlines() if l.strip()] if remotes_r.returncode == 0 else []
    # origin tried first when present, matching the previous candidate order.
    ordered_remotes = [r for r in remotes if r == "origin"] + [r for r in remotes if r != "origin"]

    if "/" in base:
        remote_prefix, _, rest = base.partition("/")
        if remote_prefix in remotes and rest:
            qualified = f"refs/remotes/{remote_prefix}/{rest}"
            if git_verify(qualified, cwd):
                return qualified
            # remote_prefix names a remote that is actually configured, so
            # this is never "maybe base is a local branch/tag instead" —
            # it's a remote ref that was expected to exist (fetched wrong, a
            # --base copied from a different checkout, ...) and doesn't.
            # Falling through to the generic searches below would risk
            # resolving to something else entirely — e.g. a local branch
            # literally named "origin/main" via the refs/heads/<base>
            # fallback further down — silently standing in for the missing
            # remote ref instead of failing loudly.
            env_error(
                f"cannot resolve base ref '{base}': '{remote_prefix}' is a configured "
                f"remote but {qualified} does not exist"
            )

    for remote in ordered_remotes:
        qualified = f"refs/remotes/{remote}/{base}"
        if git_verify(qualified, cwd):
            return qualified

    qualified_local = f"refs/heads/{base}"
    if git_verify(qualified_local, cwd):
        return qualified_local
    if git_verify(base, cwd):
        return base

    tried = [f"{r}/{base}" for r in ordered_remotes] + [base]
    env_error(f"cannot resolve base ref '{base}': tried {', '.join(tried)}")


def resolve_base_sha(base_resolved, cwd):
    """The commit sha `base_resolved` (already verified by resolve_base)
    currently points at. Recorded alongside plan_hash in each angle's
    run-provenance record (see run_meta in main()) so a base whose name is
    unchanged but has since moved — a branch advanced, a remote re-fetched —
    is still detected as "the base changed" for stale-artifact purposes,
    not just a changed base *name*."""
    r = git(["rev-parse", base_resolved], cwd)
    if r.returncode != 0:
        env_error(f"cannot resolve commit for base ref '{base_resolved}': {r.stderr.strip()}")
    return r.stdout.strip()


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


PLACEHOLDER_RE = re.compile(r"\{\{(\w+)\}\}")

# The instruction substituted for {{EXECUTION}}, keyed by angle["execution"].
# Chosen per angle rather than left as a bare "read-only"/"workspace-write"
# label so the two modes' obligations differ in the rendered text itself,
# not just in a word the reviewer has to interpret: a workspace-write
# reviewer is told to run things, a read-only one is told not to.
_EXECUTION_INSTRUCTIONS = {
    "read-only": (
        "`read-only` — read and reason. Run only read-only commands such as "
        "`git` and `grep` to investigate; do not attempt the mandated "
        "reproduction itself. Describe it in `reproduction` as a concrete "
        "input or command sequence instead."
    ),
    "workspace-write": (
        "`workspace-write` — RUN the mandated reproduction or tests and "
        "report what actually happened, not what you expect would happen. "
        "You may run commands freely to do this, but never edit, create, or "
        "delete tracked source files, and never commit."
    ),
}


def render_prompt(template, plan, angle, base_resolved):
    values = {
        "BASE": base_resolved,
        # A shell-quoted literal of the same value, for templates (like
        # claude-angle-prompt.md's base-resolution block) that assign it
        # into a shell variable once and reference "$VAR" from then on,
        # rather than splicing {{BASE}} as raw text into an unquoted or
        # double-quoted position — a base containing shell metacharacters
        # (e.g. "feature;$(id)") would otherwise be live shell, not data, at
        # every point it's spliced in.
        "BASE_SHELL": shlex.quote(base_resolved),
        "PROMISE": plan.get("promise", ""),
        "CONTRACTS": bulleted(plan.get("contracts"), "(none)"),
        "INVARIANTS": bulleted(plan.get("invariants"), "(none)"),
        "ANGLE_ID": angle["id"],
        "ANGLE_TITLE": angle["title"],
        "MANDATE": angle["mandate"],
        "EVIDENCE": angle["evidence"],
        "FILES": bulleted(angle.get("files"), "(all changed files)"),
        "EXECUTION": _EXECUTION_INSTRUCTIONS[angle["execution"]],
        # shlex.quote only the base — the quoted and unquoted pieces
        # concatenate to the same single shell token, and a base with shell
        # metacharacters (e.g. from a hand-edited plan) can never break out
        # of the command a reviewer is told to paste and run.
        "DIFF_COMMAND": f"git diff {shlex.quote(base_resolved)}...HEAD",
    }
    # A single re.sub pass over the *original* template — never a substituted
    # placeholder over its own prior output — so inserted plan/angle text
    # (promise, mandate, ...) is never re-scanned for further placeholders. A
    # promise or mandate that happens to contain a literal "{{MANDATE}}" (a
    # hand-edited plan, an adversarial one) must render as that literal text,
    # not be replaced a second time.
    return PLACEHOLDER_RE.sub(lambda m: values.get(m.group(1), m.group(0)), template)


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
        if not isinstance(f["line"], int) or isinstance(f["line"], bool):
            return False, f"findings[{i}].line must be an integer"
        # Mirrors findings.schema.json's minLength/pattern on these four —
        # a present-but-blank field (isinstance str, all whitespace) is
        # schema-invalid, not a hollow-but-technically-valid finding.
        for key in ("path", "claim", "evidence", "reproduction"):
            if not isinstance(f[key], str) or not f[key].strip():
                return False, f"findings[{i}].{key} must be a non-empty string"
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


def collect_angle_result(angle, run_dir, expected_run_meta=None):
    aid = angle["id"]
    status_path = run_dir / f"{aid}.status"
    out_path = run_dir / f"{aid}.out.json"
    residue_path = run_dir / f"{aid}.residue.txt"
    log_path = run_dir / f"{aid}.log"
    skipped_path = run_dir / f"{aid}.skipped.txt"
    meta_path = run_dir / f"{aid}.meta.json"

    # An angle that run_write_capable_angles decided never to run at all —
    # the dirty-tree gate, or a later angle skipped after an earlier one's
    # residue compromised the shared tree — leaves this marker instead of a
    # .status/.out.json (see run_write_capable_angles). Checked first, ahead
    # of every other file, so a later --from-dir re-merge reports the same
    # UNPARSED(<cause>) rather than misreading stale or absent files.
    if skipped_path.is_file():
        cause = skipped_path.read_text().strip() or "skipped"
        return AngleResult(aid, angle["title"], "UNPARSED", cause=cause)

    # `expected_run_meta` is the run dir's own current provenance record —
    # `run_meta` itself for a live run's own collection, or run_dir/plan.json's
    # "_run" key for a `--from-dir` merge (None when that key is absent,
    # e.g. a hand-authored plan.json that was never produced by a live run —
    # nothing to compare against, so the check is skipped rather than
    # treating every angle as stale). When present, every angle's own
    # .meta.json (written by run_angle alongside its other artifacts — see
    # run_meta) must match it exactly: a reused `--dir` whose plan, base, or
    # angle-prompt template changed between two live runs, combined with
    # `--only` selecting just some angles, leaves an unselected angle's older
    # .status/.out.json sitting next to the *new* plan.json (main()'s own
    # broad clear on a detected change is the primary defense — see main() —
    # this is the backstop for whatever it misses: a hand-edited run dir, a
    # partial failure between the clear and the rewrite, ...). A missing or
    # mismatched meta is never trusted as any verdict, however well-formed
    # its .status/.out.json otherwise look — it is attributed to nothing,
    # not misattributed to the plan/base/template sitting in run_dir right
    # now.
    if expected_run_meta is not None:
        if not meta_path.is_file():
            return AngleResult(aid, angle["title"], "UNPARSED", cause="stale")
        try:
            meta = json.loads(meta_path.read_text())
        except (OSError, json.JSONDecodeError):
            return AngleResult(aid, angle["title"], "UNPARSED", cause="stale")
        if not isinstance(meta, dict) or any(
            meta.get(k) != expected_run_meta.get(k)
            for k in ("plan_hash", "base_resolved", "base_sha", "template_hash")
        ):
            return AngleResult(aid, angle["title"], "UNPARSED", cause="stale")

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

# Every control character below 0x20 except tab (0x09), plus DEL (0x7f).
# Tab is left alone — it renders as harmless, unambiguous whitespace. LF and
# CR are technically in range too, but escape_block_text always collapses
# them (to a visible two-character "\n") before this ever runs, so in
# practice this only ever matches the rest: NUL, ESC, BEL, and the like —
# invisible or terminal-active bytes that must never reach a rendered block
# raw (a NUL can truncate a naive reader, an ESC can drive a terminal).
_CONTROL_CHAR_RE = re.compile("[\x00-\x08\x0a-\x1f\x7f]")


def _escape_control_char(m):
    return f"\\x{ord(m.group(0)):02x}"


# Every character str.splitlines() treats as a line boundary that isn't
# \r or \n (already collapsed to a literal, visible "\n" above) or already
# caught by _CONTROL_CHAR_RE's ASCII range (\x0b, \x0c, \x1c-\x1e — matched
# there too, but replaced here first so they end up in this escape's
# consistent \uXXXX form rather than that one's \xNN): the Unicode NEL,
# Line Separator, and Paragraph Separator. None of the three is an ASCII
# control byte, so _CONTROL_CHAR_RE's 0x00-0x7f range never sees them — and
# a JSON string decodes any of them just fine embedded raw (json.loads has
# no reason to reject a valid, unescaped Unicode character), so a
# model-authored claim/summary can carry one straight through and inject a
# line str.splitlines() would treat as a boundary — a fake section heading,
# say — into what must render as one finding's fixed set of lines.
_LINE_BOUNDARY_RE = re.compile("[\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029]")


def _escape_line_boundary(m):
    # \xNN cannot represent \u2028/\u2029 (above 0xff) — \uXXXX covers the
    # whole set in one consistent form instead of switching formats
    # mid-set depending on each character's code point.
    return f"\\u{ord(m.group(0)):04x}"


def escape_block_text(s):
    """Collapse any literal CR/LF in `s` into a visible two-character `\\n`
    so a multiline path/claim/evidence/reproduction can never inject a bare
    continuation line into the compact block — each finding must render as
    exactly its `- [Pn] ...` line plus the `  evidence:`/`  reproduction:`
    lines that follow it, nothing else. Uses str.replace, not re.sub, so the
    literal backslash-n is never re-interpreted as an escape sequence. Every
    other character str.splitlines() would treat as a line boundary is
    escaped next (see _LINE_BOUNDARY_RE), as \\uXXXX, then every remaining
    control character (see _CONTROL_CHAR_RE) is escaped too, as \\xNN, so no
    other raw control byte or line-breaking Unicode character can reach the
    block either. merged.json is unaffected — JSON handles embedded control
    characters natively, so this only applies to the plain-text block."""
    collapsed = s.replace("\r\n", "\\n").replace("\r", "\\n").replace("\n", "\\n")
    collapsed = _LINE_BOUNDARY_RE.sub(_escape_line_boundary, collapsed)
    return _CONTROL_CHAR_RE.sub(_escape_control_char, collapsed)


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


# Every environment variable that can redirect git's own repository
# discovery away from the ordinary cwd-walks-up-to-.git search — scrubbed
# from the probe subprocess in dir_in_git_repo so a caller's ambient
# environment (a stray GIT_CEILING_DIRECTORIES from an outer script, a
# leftover GIT_DIR from a prior `git -C` invocation elsewhere in the same
# shell, ...) can't make a directory that is genuinely inside a checkout
# read back as "not a repository".
_GIT_DISCOVERY_ENV_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
)


def _ancestor_has_dotgit(path):
    """Walks `path` and its ancestors (no git involved at all) looking for a
    `.git` entry — a directory for an ordinary repo root, a file for a
    worktree or submodule. The second, independent signal dir_in_git_repo
    combines with the (env-scrubbed) git probe: this one can't be fooled by
    any GIT_* environment variable because it never runs git."""
    cur = Path(path).resolve()
    while True:
        if (cur / ".git").exists():
            return True
        parent = cur.parent
        if parent == cur:
            return False
        cur = parent


def _git_probe_inside_work_tree(path, scrub_env):
    """Runs `git rev-parse --is-inside-work-tree` in `path` once, either
    with every discovery-altering GIT_* variable (see
    _GIT_DISCOVERY_ENV_VARS) stripped from its environment (scrub_env=True)
    or with the ambient environment passed through untouched
    (scrub_env=False). Fails closed: only a probe that positively confirms
    "not a repo" — git runs and exits nonzero with the canonical "not a git
    repository (or any of the parent directories)" stderr — is trusted as
    such. Any other nonzero exit (a safe.directory rejection, a permissions
    surprise — each prints a different fatal: message that doesn't match
    that phrase) never actually answered the question, same as git not
    being runnable at all (missing from PATH, bad cwd, ...) — both are
    treated as "possibly inside a checkout"."""
    if scrub_env:
        env = {k: v for k, v in os.environ.items() if k not in _GIT_DISCOVERY_ENV_VARS}
    else:
        env = dict(os.environ)
    # The "not a git repository" match below is the literal English string
    # git prints — a localized ambient LANG/LC_ALL (a caller's shell, a CI
    # runner set to e.g. de_DE.UTF-8) would make git emit a translated
    # message instead, so the match would silently fail and a genuine
    # "outside any repo" answer would fail open to "possibly inside a
    # checkout". Pinned here, on a copy, so the caller's own environment is
    # never mutated.
    env["LC_ALL"] = "C"
    env["LANG"] = "C"
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=path, capture_output=True, text=True, env=env,
        )
    except OSError:
        return True
    if r.returncode == 0:
        return r.stdout.strip() == "true"
    return "not a git repository (or any of the parent directories)" not in r.stderr


def dir_in_git_repo(path):
    """Whether `path` sits inside a git working tree (any repo — not just
    the one adversarial-review would review, and no relation to whether
    `path` itself is version-controlled). Used only to decide where
    merged.json is safe to land. Fails closed and combines three
    independent signals with OR — any one saying "inside" wins:

    1. `_git_probe_inside_work_tree(path, scrub_env=True)` — every
       discovery-altering GIT_* variable stripped, so ambient env left over
       from some outer caller (a stray GIT_CEILING_DIRECTORIES, a leftover
       GIT_DIR from a prior `git -C` elsewhere in the same shell, ...) can't
       steer git's search away from the real answer for `path`'s own
       ordinary ancestry.
    2. `_git_probe_inside_work_tree(path, scrub_env=False)` — the same probe
       with the ambient environment left exactly as given. This is the only
       signal that can see a work tree defined *only* by GIT_DIR/
       GIT_WORK_TREE (a bare repo elsewhere, pointed at `path` by those two
       variables) — the scrub in (1) deliberately blinds itself to that
       case, and no `.git` entry exists anywhere in `path`'s own ancestry
       for (3) to find either, so without this second, unscrubbed probe a
       directory that genuinely is a live work tree right now would read
       back as "not a repository".
    3. _ancestor_has_dotgit(path) — a plain filesystem walk for a `.git`
       entry, immune to environment entirely.

    merged.json diverts to a temp file instead of risking a write into a
    checkout whenever any signal says (or fails closed toward) "inside"."""
    return (
        _git_probe_inside_work_tree(path, scrub_env=True)
        or _git_probe_inside_work_tree(path, scrub_env=False)
        or _ancestor_has_dotgit(path)
    )


def select_dir_outside_git_checkouts(purpose):
    """Picks the first of `tempfile.gettempdir()`, `/tmp`, `/var/tmp` that
    both exists and sits outside every git working tree (see
    dir_in_git_repo), for a caller that needs somewhere to write that must
    never land inside a checkout. `tempfile.gettempdir()` (which honors
    TMPDIR) can itself point inside a checkout — including the very one a
    caller is trying to stay out of — so each candidate is verified with
    dir_in_git_repo rather than trusted outright. `purpose` names, in the
    error message, what the directory was needed for. If every candidate is
    unusable (missing, or itself inside a checkout), this is an environment
    failure, not a silent fall-back into a checkout — it exits 1."""
    tried = []
    seen = set()
    for candidate_dir in (tempfile.gettempdir(), "/tmp", "/var/tmp"):
        if candidate_dir in seen:
            continue
        seen.add(candidate_dir)
        if not os.path.isdir(candidate_dir):
            tried.append(f"{candidate_dir} (missing)")
            continue
        if dir_in_git_repo(candidate_dir):
            tried.append(f"{candidate_dir} (inside a git checkout)")
            continue
        return candidate_dir

    env_error(
        f"cannot find a temp directory outside every git checkout to {purpose} — "
        f"tried {', '.join(tried)} (TMPDIR may be pointing inside a repository)"
    )


def resolve_merged_json_path(run_dir, from_dir_mode):
    """Where merged.json for this run should be written. In `--from-dir`
    mode `run_dir` may be a directory the caller doesn't own writing into —
    a fixtures tree, an example checked into some other repo — so if it
    sits inside a git working tree, merged.json is diverted to a temp file
    instead of dirtying that checkout; the report's MERGED= line (see
    build_report) says where it actually landed. The candidate directory is
    picked by select_dir_outside_git_checkouts (also used by
    make_throwaway_codex_home, for the same reason), which exits 1 if every
    candidate is unusable rather than silently writing into a checkout.
    Live runs never divert: `main` already refuses a run dir inside the
    repository under review, so the default <run_dir>/merged.json is always
    safe there."""
    if not (from_dir_mode and dir_in_git_repo(run_dir)):
        return run_dir / "merged.json"

    candidate_dir = select_dir_outside_git_checkouts("divert merged.json into")
    fd, path = tempfile.mkstemp(
        prefix="adversarial-review-merged.", suffix=".json", dir=candidate_dir,
    )
    os.close(fd)
    return Path(path)


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
    p.add_argument(
        "--print-base", action="store_true",
        help="resolve --base to the exact ref this run would diff against, print it, and exit 0 (no --plan needed)",
    )
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


# --- Interrupt handling (Ctrl-C / SIGTERM during a live run) -----------------
#
# Every reviewer Popen currently in flight — across the parallel read-only
# pool and the serial workspace-write phase — is tracked here so a Ctrl-C or
# SIGTERM can kill all of them, not just whichever one the shell happened to
# signal directly. Codex is started with start_new_session=True precisely so
# each one's whole process group, not just its own pid, can be reaped this
# way (see kill_process_group).
#
# The signal handler below must never block on a lock: it runs on the main
# thread, synchronously, wherever that thread's bytecode happened to be —
# possibly itself inside `with _LIVE_PROCS_LOCK` via _track_proc/_untrack_proc
# a worker thread called into, or inside a ThreadPoolExecutor internal lock —
# so taking a lock or calling executor.shutdown() (which takes one of its
# own) from here risks a self-deadlock. _LIVE_PROCS is therefore a plain
# list: worker paths (_track_proc/_untrack_proc) still serialize their own
# add/remove through _LIVE_PROCS_LOCK to avoid corrupting the list under
# concurrent workers, but the handler reads it directly, lock-free — a plain
# list's append/remove/read are each atomic enough under the GIL that a
# lock-free read is safe (worst case it misses an id added a moment after
# the signal, or races a same-moment removal; either way `kill_process_group`
# treats an already-gone process as a no-op).
_LIVE_PROCS_LOCK = threading.Lock()
_LIVE_PROCS = []

# Set once by main() (live-run mode only) right after make_throwaway_codex_home
# creates the run's throwaway CODEX_HOME — the directory _kill_all_and_exit
# below must also remove on an interrupt, since os._exit bypasses atexit
# handlers entirely (main() additionally registers an atexit cleanup for the
# ordinary sys.exit paths). Read-only outside of that one assignment; never
# locked, same as _LIVE_PROCS's own handler-side reads.
_THROWAWAY_CODEX_HOME = None

# One sentinel per Popen call currently between "returned" and "registered in
# _LIVE_PROCS" — appended immediately before Popen, removed immediately after
# _track_proc completes (see run_angle). Closes the same spawn/track race
# run_angle's own _CANCELLED checks narrow but cannot close alone: a signal
# landing in that exact window would otherwise let the handler's snapshot run
# before the new proc is registered, leaking it past os._exit. No lock, like
# _LIVE_PROCS's handler-side reads: only run_angle's own worker thread ever
# touches its own sentinel (append then remove, never inspected by identity
# from elsewhere), so a plain list's append/remove are atomic enough under
# the GIL; the handler only ever reads truthiness via _wait_for_in_flight.
_IN_FLIGHT = []

# Set only by the signal handler, read (never written) everywhere else — a
# bare global bool rather than a threading.Event, whose set() takes an
# internal lock the handler must not touch. Lets a main-thread path (e.g.
# main()'s future-submission loop) notice cancellation and stop scheduling
# more work without itself taking any lock.
_CANCELLED = False


def _track_proc(proc):
    with _LIVE_PROCS_LOCK:
        _LIVE_PROCS.append(proc)


def _untrack_proc(proc):
    with _LIVE_PROCS_LOCK:
        try:
            _LIVE_PROCS.remove(proc)
        except ValueError:
            pass


def _wait_for_in_flight(timeout_sec=2.0, poll_sec=0.01):
    """Busy-waits (no locks — see _IN_FLIGHT's own comment) until every
    in-flight Popen/_track_proc window has closed, or `timeout_sec` has
    passed, whichever comes first. Called by _kill_all_and_exit before it
    snapshots _LIVE_PROCS, so a signal landing mid-spawn doesn't race ahead
    of the new proc being registered. Bounded rather than unconditional: a
    worker thread wedged before reaching its own sentinel removal (stuck in
    Popen itself, e.g.) must not hang the exit forever."""
    deadline = time.monotonic() + timeout_sec
    while _IN_FLIGHT and time.monotonic() < deadline:
        time.sleep(poll_sec)


def _kill_all_and_exit(exit_fn=None):
    """The snapshot-and-kill half of _interrupt_and_exit, factored out so a
    test can drive it directly: waits out any open spawn/track window (see
    _wait_for_in_flight), kills every process group in a lock-free snapshot
    of _LIVE_PROCS, prints one line, and exits via `exit_fn` — defaulting to
    `os._exit` looked up at call time (not bound as a default argument) so a
    test can either pass its own `exit_fn` or monkeypatch `os._exit` and see
    it honored either way. Never takes a lock — see the _LIVE_PROCS comment
    above for why; the same applies here since this always runs on whatever
    thread called it, which for the real signal path is the main thread."""
    _wait_for_in_flight()
    procs = list(_LIVE_PROCS)
    for proc in procs:
        kill_process_group(proc)
    # os._exit below bypasses atexit entirely, so the run's throwaway
    # CODEX_HOME (holding a copy of the user's auth.json — see
    # make_throwaway_codex_home) would otherwise survive an interrupted run
    # forever instead of being cleaned up like every other exit path.
    if _THROWAWAY_CODEX_HOME is not None:
        shutil.rmtree(_THROWAWAY_CODEX_HOME, ignore_errors=True)
    print(f"{PROG}: interrupted — terminated all reviewer process groups", file=sys.stderr)
    sys.stderr.flush()
    (exit_fn or os._exit)(130)


def _interrupt_and_exit(signum=None, frame=None):
    """Installed directly (via signal.signal) as the handler for both SIGINT
    and SIGTERM, and also called from main()'s own `except KeyboardInterrupt`
    as a defensive backstop. A direct signal.signal handler — not Python's
    default SIGINT-raises-KeyboardInterrupt behavior, caught with a bare
    `except` — is what actually works here: cf.as_completed's wait is an
    unbounded pthread condition-variable wait that a signal merely flagged
    pending does not interrupt (only an actively installed handler does),
    and relying on the default handler also assumes SIGINT's disposition is
    still SIG_DFL by the time this process starts, which it is not in every
    embedding context (e.g. a backgrounded job under a non-interactive
    parent shell already set it to SIG_IGN) — signal.signal() always installs
    an active handler regardless of prior disposition. May also run for an
    angle's own subprocess.communicate() being interrupted directly (see
    run_angle's matching except BaseException, which kills that one angle's
    group immediately, before this function's sweep, so a SIGKILL escalation
    on the same group here is a harmless no-op rather than a race).

    Never takes a lock and never calls executor.shutdown() — see the
    _LIVE_PROCS comment above for why. Sets _CANCELLED first (so any
    main-thread path checking it, and any worker mid-Popen in run_angle,
    sees cancellation as early as possible), then delegates the actual
    wait/snapshot/kill/exit to _kill_all_and_exit. 130 is the conventional
    128+SIGINT code, used for SIGTERM here too since either means "the run
    is being cancelled", never "codex could not be spawned" (exit 3) or any
    other structured exit this tool defines. os._exit, not sys.exit,
    terminates immediately and correctly even from inside a signal handler
    on the main thread, without waiting on any worker thread still blocked
    in a subprocess call — which also means a not-yet-started future in the
    parallel-phase pool is never explicitly cancelled here: the whole
    process (every thread, every queued future with it) is gone by the time
    os._exit returns, so there is nothing left to cancel."""
    global _CANCELLED
    _CANCELLED = True
    _kill_all_and_exit()


# Every file collect_angle_result (or a human re-running --from-dir) would
# read for one angle. A reused --dir (an explicit --dir re-run of the same
# plan, or --only re-running just a few ids) must never let one of these
# survive from an earlier run — a stale .out.json or .residue.txt sitting
# next to a failed re-run would be misread as this run's own result.
ANGLE_ARTIFACT_SUFFIXES = (
    ".prompt.txt", ".out.json", ".log", ".status", ".residue.txt", ".skipped.txt", ".meta.json",
)


def clear_stale_artifacts(aid, run_dir):
    """Delete any leftover artifact files for angle `aid` in `run_dir` before
    it's launched again. `aid` is not always trustworthy: main()'s reused-
    `--dir` handling calls this for every id found in the run directory's
    OWN existing plan.json, read straight off disk without going through
    validate_plan's ANGLE_ID_RE check — a hand-edited or otherwise malformed
    plan.json can carry an id like "../../project/server", and naively
    unlinking `run_dir / f"{aid}{suffix}"` would then remove a file outside
    run_dir entirely. So this never builds a path from `aid` and unlinks it
    directly: it lists run_dir's own entries, keeps only regular files whose
    name is exactly `<aid><suffix>` for `suffix` one of
    ANGLE_ARTIFACT_SUFFIXES, confirms each survivor's resolved path is still
    inside run_dir, and unlinks only those. A hostile id fails the
    ANGLE_ID_RE check before any filename is even considered; the
    resolve-and-relative_to check below is the backstop in case that ever
    changes. Best-effort: a file gone by the time it's unlinked, or a
    directory that can no longer be listed, is not an error."""
    if not ANGLE_ID_RE.fullmatch(aid):
        return
    try:
        run_dir_resolved = run_dir.resolve()
        entries = list(run_dir_resolved.iterdir())
    except OSError:
        return
    names = {f"{aid}{suffix}" for suffix in ANGLE_ARTIFACT_SUFFIXES}
    for entry in entries:
        if entry.name not in names:
            continue
        try:
            resolved = entry.resolve()
            resolved.relative_to(run_dir_resolved)
        except (OSError, ValueError):
            continue
        if not resolved.is_file():
            continue
        try:
            resolved.unlink()
        except FileNotFoundError:
            pass


def _mark_interrupted(aid, run_dir):
    """Marks angle `aid` UNPARSED(interrupted) — written by run_angle itself
    when it notices _CANCELLED around its own Popen call, so this run's own
    collect_angle_result (or a later --from-dir re-merge of the same --dir)
    reports the same outcome, the same way _mark_skipped's dirty-tree/
    compromised markers do for angles that never ran at all."""
    (run_dir / f"{aid}.skipped.txt").write_text("interrupted\n")


def make_throwaway_codex_home():
    """Creates a fresh, empty CODEX_HOME containing only a copy of the real
    one's auth.json, and returns its Path.

    Security fix, not a convenience: `codex exec -C <root>` on a *trusted*
    checkout (`[projects."<root>"] trust_level = "trusted"` in the real
    CODEX_HOME's config.toml — set once a person accepts the interactive
    trust prompt for that path, in any unrelated session, at any time in the
    past) loads that checkout's own `.codex/config.toml` — hooks, MCP
    servers, exec-policy rules, model overrides — ahead of every angle's
    prompt. All of it is branch-controlled, same hazard class as the
    AGENTS.md-loading `project_doc_max_bytes=0` guards against just above.
    Verified empirically against codex-cli 0.145.0: a throwaway repo with a
    `.codex/config.toml` setting `model_reasoning_effort = "minimal"` left
    `codex exec`'s own header reading `reasoning effort: xhigh` (the
    ambient CODEX_HOME's own setting) while the project was untrusted, and
    `reasoning effort: minimal` — the repo-local value, loaded and applied —
    the moment a throwaway CODEX_HOME's config.toml marked the same path
    trusted; a CODEX_HOME holding only a copy of auth.json (no config.toml
    at all) authenticated and ran normally while leaving the header back at
    the built-in default, proving the project's own config was not loaded.
    `--ephemeral` (already passed for every angle) means no session state
    needs to survive between runs, so a brand new CODEX_HOME each run costs
    nothing beyond re-fetching the model catalog.

    Never touches the real CODEX_HOME/~/.codex — only reads its auth.json.
    Best-effort on the copy's permissions (chmod 600); a missing auth.json
    is not fatal here — some setups authenticate purely via an environment
    variable this process's own environ (inherited by every angle's Popen
    call) already carries, so the throwaway, otherwise-empty CODEX_HOME
    still closes off project-local config for them too.

    Created outside every git working tree, via the same
    select_dir_outside_git_checkouts used to divert merged.json — a TMPDIR
    pointed inside a checkout would otherwise put a copy of the real
    auth.json inside that checkout's working tree, where a careless
    workspace-write angle (or just `git status`) could see it; failing with
    an environment error is preferable to silently landing it in one. The
    resulting path is also always made absolute: Python's own
    tempfile.mkdtemp (3.9-3.11) can return a path exactly as relative as the
    `dir=` it was given, and this path is later placed into angle_env
    (CODEX_HOME) for a child process Popen'd with cwd=root, not this
    process's own cwd — a relative CODEX_HOME there would resolve against
    the wrong directory."""
    real_home = Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex"))
    candidate_dir = select_dir_outside_git_checkouts("create the throwaway CODEX_HOME in")
    throwaway = Path(
        tempfile.mkdtemp(prefix="adversarial-review-codex-home.", dir=candidate_dir)
    ).resolve()
    real_auth = real_home / "auth.json"
    if real_auth.is_file():
        dest_auth = throwaway / "auth.json"
        shutil.copyfile(real_auth, dest_auth)
        try:
            os.chmod(dest_auth, 0o600)
        except OSError:
            pass
    return throwaway


def run_angle(aid, angle, plan, base_resolved, template, run_dir, root, schema_path, timeout_sec, codex_home, run_meta):
    """Returns (error, spawned): error is None on a clean run, else a
    message; spawned is True once Popen has actually started the codex
    process, regardless of what happens afterward. A caller running
    workspace-write angles serially needs `spawned` to tell a real spawn
    failure (nothing to check — the tree was never touched) apart from a
    post-spawn failure (writing .status, the background-leak note) that
    still leaves a process that may have dirtied the tree — see
    run_write_capable_angles.

    `run_meta` is this run's provenance record — {"plan_hash", "base_resolved",
    "base_sha"}, the same dict stamped into run_dir/plan.json's "_run" key —
    written alongside the prompt into `<aid>.meta.json`, with the rendered
    prompt's own sha256 added, so a later `--from-dir` (this run's own
    immediate merge, or a separate invocation entirely) can tell this
    angle's .status/.out.json apart from a same-named leftover produced by a
    different plan or base sharing the same --dir (see collect_angle_result
    and main())."""
    spawned = False
    # Stale artifacts for `aid` are cleared by main(), synchronously, before
    # either phase (parallel or serial) schedules any angle — not here, so a
    # queued angle whose run_angle body never gets to run before an
    # interrupt still has its old outputs gone.
    prompt_text = render_prompt(template, plan, angle, base_resolved)
    (run_dir / f"{aid}.prompt.txt").write_text(prompt_text)
    meta = dict(run_meta)
    meta["prompt_sha256"] = hashlib.sha256(prompt_text.encode("utf-8")).hexdigest()
    (run_dir / f"{aid}.meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    out_path = run_dir / f"{aid}.out.json"
    log_path = run_dir / f"{aid}.log"
    # Every other environment variable passes through unchanged (an
    # OPENAI_API_KEY-based auth setup, proxy settings, ...) — only CODEX_HOME
    # is overridden, to the run's own throwaway one (see
    # make_throwaway_codex_home) so this angle can never see the real
    # CODEX_HOME's own config.toml, in particular any `[projects.<root>]
    # trust_level = "trusted"` entry that would let `-C root` below load
    # root's own repo-local .codex/config.toml.
    angle_env = dict(os.environ)
    angle_env["CODEX_HOME"] = str(codex_home)
    cmd = [
        CODEX_BIN, "exec", "--ephemeral",
        "-s", angle["execution"],
        "-C", root,
        "--output-schema", str(schema_path),
        "-o", str(out_path),
        "-c", f"model={CODEX_REVIEW_MODEL}",
        "-c", f"model_reasoning_effort={CODEX_REVIEW_EFFORT}",
        # `codex exec -C <root>` auto-loads AGENTS.md (root and every parent
        # up to the git root) as project instructions ahead of the angle
        # prompt below. The branch under review controls that file, so
        # without this it could instruct every angle to report CLEAN
        # regardless of the diff. project_doc_max_bytes=0 disables that
        # discovery — verified against codex-cli 0.145.0 with `codex debug
        # prompt-input`, which shows the "# AGENTS.md instructions for
        # <dir>" block disappear from the model-visible prompt at this
        # setting. The throwaway CODEX_HOME set below (see angle_env) closes
        # the remaining project-local surface this alone doesn't: a trusted
        # checkout's own .codex/config.toml (hooks, MCP servers, exec-policy
        # rules, model overrides).
        "-c", "project_doc_max_bytes=0",
        # The option terminator: a rendered prompt is arbitrary text a plan
        # or a custom --angle-prompt template controls, not this runner —
        # one that happens to start with "-" (a mandate quoting a CLI flag,
        # a markdown "---" rule) must never be parsed as another codex exec
        # option instead of the positional prompt argument.
        "--",
        prompt_text,
    ]
    try:
        with open(log_path, "wb") as logfh:
            # Closes the spawn/track race with the interrupt handler: a
            # signal landing between Popen() returning and _track_proc()
            # registering it would let the handler's lock-free sweep of
            # _LIVE_PROCS miss this process entirely, leaking it (and
            # anything it backgrounds) past this run's exit. The _IN_FLIGHT
            # sentinel (held open only across Popen+_track_proc) makes the
            # handler itself wait out that exact window before it ever
            # snapshots _LIVE_PROCS — see _wait_for_in_flight — so by the
            # time a kill sweep runs, this proc is guaranteed either fully
            # registered or never started. Checking _CANCELLED immediately
            # before Popen, and once more right after registering, is a
            # second, independent line of defense: if cancellation is seen
            # at either point, this angle kills its own new group itself
            # rather than trust a sweep, and reports the same outcome the
            # handler's own exit would have implied.
            if _CANCELLED:
                _mark_interrupted(aid, run_dir)
                return None, spawned
            # start_new_session makes this process its own process-group
            # leader, so a timeout can reap everything it spawned via
            # killpg — not just its own pid, which is all subprocess.run's
            # built-in timeout kill would reach.
            sentinel = object()
            _IN_FLIGHT.append(sentinel)
            try:
                proc = subprocess.Popen(
                    cmd, stdin=subprocess.DEVNULL, stdout=logfh, stderr=subprocess.STDOUT,
                    cwd=root, start_new_session=True, env=angle_env,
                )
                spawned = True
                _track_proc(proc)
            finally:
                # Removed even if Popen itself raised (OSError, caught
                # below) — a sentinel left behind on a failed spawn would
                # otherwise wedge every future _wait_for_in_flight for the
                # rest of the run, not just this angle's own window.
                _IN_FLIGHT.remove(sentinel)
            if _CANCELLED:
                kill_process_group(proc)
                _untrack_proc(proc)
                _mark_interrupted(aid, run_dir)
                return None, spawned
            try:
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
                except BaseException:
                    # Belt-and-suspenders: SIGINT/SIGTERM during the serial
                    # (workspace-write) phase are normally handled by
                    # main()'s own signal.signal handlers, which kill every
                    # _LIVE_PROCS-tracked group (this one included) and
                    # os._exit before ever returning control here — but if a
                    # KeyboardInterrupt/BaseException reaches this call some
                    # other way, kill this angle's own group immediately,
                    # before the finally below drops it from _LIVE_PROCS.
                    # Re-raised so the normal caller handling still runs.
                    kill_process_group(proc)
                    raise
            finally:
                _untrack_proc(proc)
        return None, spawned
    except OSError as e:
        return str(e), spawned


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


def run_write_capable_angles(serial_ids, angles_by_id, plan, base_resolved, template, run_dir, root, schema_path, timeout_sec, codex_home, run_meta):
    """Runs workspace-write angles one at a time against the shared checkout
    (never concurrently with each other or with a read-only angle — see
    partition_angles: isolating them in a git worktree was rejected because
    reviewers need the project's real environment — .venv, caches — which a
    worktree lacks).

    Requires a clean tree before the first one; if the tree is already dirty
    at that point, every write-capable angle is skipped without running, as
    UNPARSED(dirty-tree) — contract, not policy: a dirty tree means we can't
    attribute any residue that follows to a specific angle. After each angle
    whose codex process actually spawned (run_angle's `spawned` flag — a true
    spawn failure is the only case with nothing to check, since the tree was
    never touched), the tree is checked again: a non-empty `git status
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
        err, spawned = run_angle(
            aid, angles_by_id[aid], plan, base_resolved, template,
            run_dir, root, schema_path, timeout_sec, codex_home, run_meta,
        )
        if err is not None:
            spawn_failures.append((aid, err))
            # A true spawn failure (Popen itself never started the process)
            # never touched the tree, so there's nothing to check. Any error
            # after that — the .status write, the background-leak note —
            # leaves a codex process that may already have run against the
            # shared checkout, so the residue check below must still run,
            # exactly as it does after a normal finish.
            if not spawned:
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

    if args.print_base:
        # No plan, no codex, no signal handlers — this is a pure lookup a
        # planner runs (plan-prompt.md, SKILL.md step 0) to get the exact
        # ref this run would diff against, so planning and running can never
        # resolve `--base` two different ways.
        if not args.base:
            usage_error("--print-base requires --base")
        print(resolve_base(args.base, repo_root()))
        return 0

    # Both installed explicitly and unconditionally (harmless in --from-dir
    # mode, where no reviewer process is ever tracked). SIGTERM has no
    # Python-level default handler at all, so it needs this to get any
    # "kill every tracked group and exit 130" treatment instead of the OS's
    # silent default termination. SIGINT is normally caught by Python's own
    # default handler (which raises KeyboardInterrupt, caught around the
    # parallel/serial phases below) — but an explicit handler here is not
    # redundant: it also fires reliably while blocked inside
    # cf.as_completed()'s unbounded wait, which is built on a pthread
    # condition variable that a signal merely flagged-as-pending (the
    # KeyboardInterrupt-on-next-bytecode mechanism) does not interrupt, only
    # a real, actively-installed handler does. It also does not depend on
    # SIGINT's default disposition being SIG_DFL at process start, which it
    # is not in every embedding context (e.g. a backgrounded job under a
    # non-interactive parent shell) — signal.signal() always installs an
    # active handler regardless of what disposition it had before. See
    # _interrupt_and_exit.
    signal.signal(signal.SIGINT, _interrupt_and_exit)
    signal.signal(signal.SIGTERM, _interrupt_and_exit)

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
        # None (skip the check) when this plan.json carries no "_run" record
        # at all — a hand-authored plan.json (every static fixtures/*/plan.json
        # in this test suite included) was never produced by a live run and
        # has nothing to compare an angle's .meta.json against, so it is
        # merged exactly as before this check existed.
        expected_run_meta = plan.get("_run") if isinstance(plan.get("_run"), dict) else None
        # A per-angle .meta.json can only ever be compared field-for-field
        # against "_run" (see collect_angle_result) — it says nothing about
        # whether plan.json ITSELF was hand-edited after the run that
        # produced those .meta.json files, since editing the file in place
        # leaves "_run" (and so every angle's still-matching meta) untouched.
        # Recomputing plan.json's own canonical hash — with "_run" stripped
        # back out, the same shape compute_plan_hash saw before "_run" was
        # ever stamped in (see main()'s live-run branch) — and requiring it
        # to equal the recorded plan_hash catches exactly that: a plan
        # edited after the fact must never merge under its original,
        # no-longer-accurate verdict.
        plan_edited_since_run = (
            expected_run_meta is not None
            and compute_plan_hash({k: v for k, v in plan.items() if k != "_run"})
            != expected_run_meta.get("plan_hash")
        )
        if plan_edited_since_run:
            print(
                f"{PROG}: plan.json in {run_dir} has changed since this run directory "
                "was produced (recomputed hash does not match the recorded plan_hash) "
                "— every angle is reported UNPARSED(stale), not its earlier verdict",
                file=sys.stderr,
            )
            results_by_id = {
                aid: AngleResult(aid, angles_by_id[aid]["title"], "UNPARSED", cause="stale")
                for aid in angle_ids
            }
        else:
            results_by_id = {
                aid: collect_angle_result(angles_by_id[aid], run_dir, expected_run_meta)
                for aid in angle_ids
            }
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

        global CODEX_BIN
        resolved_codex_bin = shutil.which(CODEX_BIN)
        if resolved_codex_bin is None:
            env_error(f"codex CLI ('{CODEX_BIN}') not found on PATH")
        # shutil.which returns a relative CODEX_BIN (one containing a path
        # separator, e.g. "./relative/fake-codex") unchanged — it only
        # verifies such a path directly, it does not resolve it. Every
        # angle's Popen below runs with cwd=root (the repo top level), not
        # this process's own cwd, so a relative path here would be
        # re-resolved against the wrong directory and fail to spawn the
        # moment root differs from wherever this command was invoked (e.g.
        # a subdirectory). os.path.abspath, called now while the process's
        # cwd is still the invocation directory, makes it unambiguous.
        CODEX_BIN = os.path.abspath(resolved_codex_bin)

        # One throwaway CODEX_HOME for the whole run (every angle, parallel
        # and serial alike, shares it) — see make_throwaway_codex_home for
        # why. Registered for cleanup immediately, before any angle can
        # spawn: atexit covers every ordinary sys.exit path below (a usage
        # or environment error, a spawn-failure abort, the normal return),
        # and the global lets _kill_all_and_exit clean it up on an interrupt
        # too, since os._exit bypasses atexit.
        global _THROWAWAY_CODEX_HOME
        codex_home = make_throwaway_codex_home()
        _THROWAWAY_CODEX_HOME = codex_home
        atexit.register(shutil.rmtree, codex_home, ignore_errors=True)

        root = repo_root()
        base = args.base or plan.get("base")
        if not base:
            usage_error("plan has no 'base' and --base was not given")
        base_resolved = resolve_base(base, root)
        # This run's provenance record — stamped into run_dir/plan.json's
        # "_run" key and into every angle's own <aid>.meta.json (see
        # run_angle) — so a `--dir` reused later, whether by a second live
        # run or a separate `--from-dir` merge, can tell whether the plan,
        # the base, or the angle-prompt template has moved since an artifact
        # sitting in run_dir was produced. base_sha (not just
        # base_resolved's name) matters on its own: the same branch name can
        # advance between two runs that never touched --plan or --base at
        # all. template_hash is filled in below, once the template itself is
        # loaded — every comparison against this dict (the reused-`--dir`
        # broad clear, collect_angle_result's meta check) happens after that.
        run_meta = {
            "plan_hash": compute_plan_hash(plan),
            "base_resolved": base_resolved,
            "base_sha": resolve_base_sha(base_resolved, root),
        }

        diff_check = git(["diff", f"{base_resolved}...HEAD", "--name-only"], root)
        if diff_check.returncode != 0:
            env_error(f"git diff {base_resolved}...HEAD failed: {diff_check.stderr.strip()}")
        if not diff_check.stdout.strip():
            env_error(f"empty diff between {base_resolved} and HEAD — nothing to review")

        if args.jobs is not None and args.jobs < 1:
            usage_error("--jobs must be >= 1")
        if args.timeout < 1:
            usage_error("--timeout must be >= 1")

        # Every fallible input (plan and base are already validated above;
        # this is the last one) is resolved before run_dir is even computed,
        # let alone mutated — a reused --dir must never have its plan.json
        # overwritten or its merged.json cleared only to then abort on a bad
        # --angle-prompt, leaving the new plan paired with a previous run's
        # stale <angle>.status/<angle>.out.json (cleared only later, in the
        # per-angle loop below): a subsequent --from-dir would merge that
        # mismatched pair and could report a false verdict for a run that
        # never actually happened.
        template = load_angle_prompt_template(args.angle_prompt, script_dir)
        # A different --angle-prompt template gives every angle materially
        # different instructions even when the plan and base are byte-for-
        # byte unchanged — an angle's artifacts must count as stale exactly
        # as they would after a plan/base change (same run_meta-equality
        # check, both in the reused-`--dir` broad clear below and in
        # collect_angle_result's per-angle meta backstop), not survive under
        # a template that never actually produced them.
        run_meta["template_hash"] = hashlib.sha256(template.encode("utf-8")).hexdigest()
        schema_path = script_dir / "findings.schema.json"

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

        # A reused --dir whose plan or resolved base differs from the run
        # that last wrote to it must never let an *unselected* angle's
        # artifacts from that earlier run survive: --only only clears the
        # ids it selects (the loop below), so an angle left out of this run
        # would otherwise keep last time's .status/.out.json sitting next to
        # today's plan.json, and a later --from-dir would attribute that old
        # verdict to a plan it was never actually produced against
        # (collect_angle_result's own meta check is the backstop for
        # whatever this misses — see there). Compared via the same "_run"
        # record this run is about to stamp into plan.json itself, so a
        # plan whose bytes changed, or a base that resolved to a different
        # ref or has since moved to a different commit, both count as
        # "changed" — an unparsable or missing existing plan.json is treated
        # the same way, conservatively, since nothing in it can be trusted.
        old_plan_path = run_dir / "plan.json"
        if old_plan_path.is_file():
            try:
                old_doc = json.loads(old_plan_path.read_text())
            except (OSError, json.JSONDecodeError):
                old_doc = None
            old_ids = set()
            if isinstance(old_doc, dict) and isinstance(old_doc.get("angles"), list):
                old_ids = {
                    a.get("id") for a in old_doc["angles"]
                    if isinstance(a, dict) and isinstance(a.get("id"), str)
                }
            old_run_meta = old_doc.get("_run") if isinstance(old_doc, dict) else None
            if old_run_meta != run_meta:
                for stale_aid in old_ids | set(angle_ids_all):
                    clear_stale_artifacts(stale_aid, run_dir)

        # A reused --dir may carry a merged.json from an earlier invocation
        # — clear it before any angle launches, so an abort further down
        # (spawn failure) can never leave that previous verdict looking
        # like this run's own result.
        clear_merged_json(run_dir)
        plan_doc = dict(plan)
        plan_doc["_run"] = run_meta
        (run_dir / "plan.json").write_text(json.dumps(plan_doc, indent=2) + "\n")

        # Read-only angles don't write to the checkout, so they're safe to
        # race in the shared thread pool. workspace-write angles run against
        # the same shared checkout and must never race each other or a
        # read-only angle — see partition_angles and
        # run_write_capable_angles.
        parallel_ids, serial_ids = partition_angles(angle_ids, angles_by_id)

        # Every selected angle's stale artifacts (this same --dir's leftovers
        # from an earlier invocation) are cleared here, synchronously, before
        # either phase schedules any work — not lazily inside run_angle. A
        # reused --dir with --jobs 1 makes this observable: if a SIGINT lands
        # while angle 1 is still running, angles 2 and 3 sit queued and their
        # run_angle body never executes in this run at all, so only an
        # upfront clear (not run_angle's own) can guarantee their old
        # .out.json doesn't survive as this run's (mis)result.
        for aid in angle_ids:
            clear_stale_artifacts(aid, run_dir)

        spawn_failures = []
        # SIGINT/SIGTERM anywhere in here — blocked on a parallel angle in
        # cf.as_completed, or on the serial phase's own serial_future.result()
        # — is handled by the signal.signal handlers installed above; this
        # `except KeyboardInterrupt` is a defensive backstop, not the primary
        # path (both are an unbounded pthread condition-variable wait, which
        # a signal merely flagged pending — the mechanism behind the default
        # SIGINT-raises-KeyboardInterrupt handler — does not reliably
        # interrupt; only an actively installed handler like ours does,
        # which is why one is installed for SIGINT too, not just SIGTERM).
        # Deliberately no `finally: ex.shutdown(wait=True)` around either
        # executor block below — that would block waiting for a worker
        # thread that's stuck on the very process an interrupt exists to
        # kill. The non-interrupt path shuts each executor down inline
        # instead, after its work is already done.
        try:
            if parallel_ids:
                jobs = args.jobs or min(len(parallel_ids), 4)
                ex = cf.ThreadPoolExecutor(max_workers=jobs)
                # An explicit loop, not a dict comprehension: checking
                # _CANCELLED after each submit() lets this stop handing out
                # more work once cancellation is seen, rather than
                # unconditionally queuing every remaining angle. In practice
                # the signal handler's os._exit ends the whole process (this
                # loop included) before a real interrupt could ever be
                # observed here — this is a cheap, correct belt-and-suspenders
                # check, not the primary defense (that's run_angle's own
                # checks around its Popen call).
                future_to_id = {}
                for aid in parallel_ids:
                    future_to_id[ex.submit(
                        run_angle, aid, angles_by_id[aid], plan, base_resolved, template,
                        run_dir, root, schema_path, args.timeout, codex_home, run_meta,
                    )] = aid
                    if _CANCELLED:
                        break
                for fut in cf.as_completed(future_to_id):
                    # spawned is irrelevant here: read-only angles never
                    # write to the checkout, so there is no residue check
                    # to gate (contrast run_write_capable_angles).
                    err, _spawned = fut.result()
                    if err is not None:
                        spawn_failures.append((future_to_id[fut], err))
                ex.shutdown(wait=True)

            # Run on a dedicated single worker thread, never inline on the
            # main thread. signal.signal handlers always run on the main
            # thread, so if run_angle's Popen call happened here directly, a
            # SIGINT landing inside its own _IN_FLIGHT window (see that
            # comment) would preempt the very main-thread frame that was
            # about to register the process and clear the sentinel —
            # _wait_for_in_flight's wait could then only ever be satisfied
            # by timing out (2s), never by real progress, because the thing
            # it's waiting on is itself, one frame further down a stack it
            # can no longer return to until the handler does. Handing the
            # whole serial phase to its own worker (mirroring the parallel
            # phase's ThreadPoolExecutor) keeps every Popen for a
            # workspace-write angle off the main thread, so that wait is
            # always satisfied by the worker's own forward progress instead.
            # No `finally: shutdown(wait=True)` here either, for the same
            # reason the parallel block above has none: that would block
            # waiting on a worker stuck on the very process an interrupt
            # exists to kill. On the real interrupt path the signal
            # handler's os._exit ends the process before shutdown() below is
            # ever reached, exactly as for the parallel phase.
            serial_ex = cf.ThreadPoolExecutor(max_workers=1)
            serial_future = serial_ex.submit(
                run_write_capable_angles,
                serial_ids, angles_by_id, plan, base_resolved, template,
                run_dir, root, schema_path, args.timeout, codex_home, run_meta,
            )
            synthetic_results, serial_spawn_failures = serial_future.result()
            serial_ex.shutdown(wait=True)
            spawn_failures.extend(serial_spawn_failures)
        except KeyboardInterrupt:
            _interrupt_and_exit()

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
            else collect_angle_result(angles_by_id[aid], run_dir, run_meta)
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
