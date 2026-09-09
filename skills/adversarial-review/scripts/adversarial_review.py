#!/usr/bin/env python3
"""Run one `codex exec` per adversarial "angle" from a plan file, then merge
schema-enforced JSON findings into one compact, parseable block. Does the
real work for adversarial-review.sh, a thin dispatcher; see that file's
header, or run `python3 adversarial_review.py --help`. Stdlib only.

Exit codes (same contract as the .sh wrapper): 0 ok (CLEAN or FINDINGS);
1 environment (bad path, no git repo, unresolvable base, empty diff, ...);
2 usage (bad flags, invalid plan JSON, unknown --only id); 3 codex could not
be spawned for one or more angles, aborting without a merged report (never
conflated with an angle that ran and timed out or errored, which folds into
a per-angle UNPARSED instead); 4 unparsed-never-clean (any angle UNPARSED or
BLOCKED); 130 interrupted (Ctrl-C / SIGTERM).
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

# Bump alongside adversarial-review.sh's ADVERSARIAL_REVIEW_VERSION — the two
# must always match (the test suite checks this).
VERSION = "1.2.0"
PROG = "adversarial-review"

CODEX_REVIEW_MODEL = os.environ.get("CODEX_REVIEW_MODEL", "gpt-5.6-sol")
CODEX_REVIEW_EFFORT = os.environ.get("CODEX_REVIEW_EFFORT", "xhigh")
CODEX_BIN = os.environ.get("CODEX_BIN", "codex")

SEVERITIES = ("P0", "P1", "P2", "P3")
BLOCKING_SEVERITIES = ("P0", "P1")
SEVERITY_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
EXECUTIONS = ("read-only", "workspace-write")
ANGLE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
MAX_ANGLES = 6  # sane plan-size cap; SKILL.md documents 3-6 angles per plan.
TOP_REQUIRED = {"angle", "verdict", "summary", "findings"}
FINDING_REQUIRED = {"severity", "path", "line", "claim", "evidence", "reproduction"}
# Per-angle artifacts a live run writes; cleared before relaunching an angle
# into a reused --dir.
ANGLE_ARTIFACT_SUFFIXES = (".prompt.txt", ".out.json", ".log", ".status")


def _exit(code, msg):
    print(f"{PROG}: {msg}", file=sys.stderr)
    sys.exit(code)


def usage_error(msg):
    _exit(2, msg)


def env_error(msg):
    _exit(1, msg)


def codex_error(msg):
    _exit(3, msg)


# --- Plan loading + validation ------------------------------------------------

def load_plan(path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as e:
        env_error(f"cannot read plan file {path}: {e}")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        usage_error(f"invalid JSON in plan file {path}: {e}")
    validate_plan(data, path)
    return data


def _require_nonempty_str(val, label, source):
    if not isinstance(val, str) or not val.strip():
        usage_error(f"plan {source}: {label} must be a non-empty string")


def _require_str_list(val, label, source):
    if val is not None and not (isinstance(val, list) and all(isinstance(x, str) for x in val)):
        usage_error(f"plan {source}: {label} must be a list of strings")


def validate_plan(data, source):
    if not isinstance(data, dict):
        usage_error(f"plan {source} must be a JSON object")
    if data.get("version") != 1:
        usage_error(f"unsupported plan version {data.get('version')!r} in {source} (expected 1)")
    _require_nonempty_str(data.get("promise"), "'promise'", source)
    base = data.get("base")
    if base is not None:
        _require_nonempty_str(base, "'base'", source)
    _require_str_list(data.get("contracts"), "'contracts'", source)
    _require_str_list(data.get("invariants"), "'invariants'", source)
    angles = data.get("angles")
    if not isinstance(angles, list) or not angles:
        usage_error(f"plan {source} must have a non-empty 'angles' array")
    if len(angles) > MAX_ANGLES:
        usage_error(f"plan {source} has {len(angles)} angles, more than the max of {MAX_ANGLES}")
    seen_ids = set()
    for a in angles:
        if not isinstance(a, dict):
            usage_error(f"plan {source}: each angle must be an object")
        aid = a.get("id")
        # fullmatch, not match: re's `$` matches before a trailing newline too.
        if not isinstance(aid, str) or not ANGLE_ID_RE.fullmatch(aid):
            usage_error(f"plan {source}: invalid angle id {aid!r} (must match ^[a-z0-9][a-z0-9-]*$)")
        if aid in seen_ids:
            usage_error(f"plan {source}: duplicate angle id '{aid}'")
        seen_ids.add(aid)
        for req_field in ("title", "mandate", "evidence"):
            _require_nonempty_str(a.get(req_field), f"angle '{aid}' field '{req_field}'", source)
        # Advisory only: this run's actual sandbox mode is decided once, for
        # every selected angle, by --allow-writes (see main()) — kept here
        # so a plan still records which angles need one, for the operator's
        # own later `--only <id> --allow-writes` re-run.
        execu = a.get("execution")
        if execu not in EXECUTIONS:
            usage_error(
                f"plan {source}: angle '{aid}' has invalid execution {execu!r} "
                f"(expected one of {', '.join(EXECUTIONS)})"
            )
        _require_str_list(a.get("files"), f"angle '{aid}' field 'files'", source)


def parse_only(only_arg, known_ids):
    """Subset of known_ids named by --only, in plan order; None means every angle."""
    if only_arg is None:
        return None
    requested = [x.strip() for x in only_arg.split(",") if x.strip()]
    if not requested:
        usage_error("--only given but no angle ids parsed from it")
    unknown = [x for x in requested if x not in known_ids]
    if unknown:
        usage_error(f"--only names unknown angle id(s): {', '.join(unknown)} (known: {', '.join(known_ids)})")
    wanted = set(requested)
    return [aid for aid in known_ids if aid in wanted]


# --- git helpers ---------------------------------------------------------------

def git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def repo_root():
    r = git(["rev-parse", "--show-toplevel"], cwd=os.getcwd())
    if r.returncode != 0:
        env_error("not inside a git repository (git rev-parse --show-toplevel failed)")
    return r.stdout.strip()


def git_verify(ref, cwd):
    return git(["rev-parse", "--verify", "--quiet", ref], cwd=cwd).returncode == 0


def resolve_base(base, cwd):
    """Resolves `base` to a fully-qualified ref, remote-first (refs/remotes/<r>/<b>,
    else refs/heads/<b>), so a bare "origin/main" never resolves to a same-named
    local branch instead of the real remote-tracking ref."""
    remotes_r = git(["remote"], cwd=cwd)
    remotes = [l for l in remotes_r.stdout.splitlines() if l.strip()] if remotes_r.returncode == 0 else []
    ordered_remotes = [r for r in remotes if r == "origin"] + [r for r in remotes if r != "origin"]

    if "/" in base:
        remote_prefix, _, rest = base.partition("/")
        if remote_prefix in remotes and rest:
            # An explicit "<remote>/<branch>" form against a real remote is
            # never allowed to fall through to an unrelated ref of the same name.
            qualified = f"refs/remotes/{remote_prefix}/{rest}"
            if git_verify(qualified, cwd):
                return qualified
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


# --- Prompt rendering ------------------------------------------------------------

def bulleted(items, empty):
    items = [str(i).strip() for i in (items or []) if str(i).strip()]
    return "\n".join(f"- {i}" for i in items) if items else empty


def load_angle_prompt_template(path_arg, script_dir):
    candidate = Path(path_arg) if path_arg else script_dir.parent / "angle-prompt.md"
    if not candidate.is_file():
        env_error(f"no angle prompt template found: {candidate}")
    return candidate.read_text(encoding="utf-8")


PLACEHOLDER_RE = re.compile(r"\{\{(\w+)\}\}")

# {{EXECUTION}}'s text, keyed by this RUN's actual sandbox mode (--allow-writes
# or not) — one mode for every angle in an invocation, not a per-angle field.
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


def render_prompt(template, plan, angle, base_resolved, execution_mode):
    values = {
        "BASE": base_resolved,
        "BASE_SHELL": shlex.quote(base_resolved),
        "PROMISE": plan.get("promise", ""),
        "CONTRACTS": bulleted(plan.get("contracts"), "(none)"),
        "INVARIANTS": bulleted(plan.get("invariants"), "(none)"),
        "ANGLE_ID": angle["id"],
        "ANGLE_TITLE": angle["title"],
        "MANDATE": angle["mandate"],
        "EVIDENCE": angle["evidence"],
        "FILES": bulleted(angle.get("files"), "(all changed files)"),
        "EXECUTION": _EXECUTION_INSTRUCTIONS[execution_mode],
        "DIFF_COMMAND": f"git diff {shlex.quote(base_resolved)}...HEAD",
    }
    # One pass over the original template, never over substituted output, so
    # a mandate containing a literal "{{MANDATE}}" isn't replaced twice.
    return PLACEHOLDER_RE.sub(lambda m: values.get(m.group(1), m.group(0)), template)


# --- Findings schema validation (no external jsonschema dependency) ------------

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
        for key in ("path", "claim", "evidence", "reproduction"):
            if not isinstance(f[key], str) or not f[key].strip():
                return False, f"findings[{i}].{key} must be a non-empty string"
    # verdict="FINDINGS" with an empty array is self-contradictory: never
    # trust it as CLEAN, or as FINDINGS with nothing to show.
    if data["verdict"] == "FINDINGS" and not findings:
        return False, "'verdict' is FINDINGS but 'findings' is empty"
    return True, ""


# --- Per-angle result collection -----------------------------------------------

@dataclass
class AngleResult:
    id: str
    title: str
    kind: str  # CLEAN | FINDINGS | BLOCKED | UNPARSED
    cause: str = ""  # set only when kind == UNPARSED
    summary: str = ""
    findings: list = field(default_factory=list)


# Case-insensitive substrings the provider's content filter is known to emit
# when it refuses an angle's prompt outright, so a refusal (reword and
# retry) is distinguished from an ordinary crash.
REFUSAL_MARKERS = (
    "flagged for possible cybersecurity risk",
    "content was flagged",
    "trusted access for cyber",
)


def log_refused(log_path):
    if not log_path.is_file():
        return False
    text = log_path.read_text(encoding="utf-8", errors="replace").lower()
    return any(marker in text for marker in REFUSAL_MARKERS)


def collect_angle_result(angle, run_dir):
    aid = angle["id"]
    status_path = run_dir / f"{aid}.status"
    out_path = run_dir / f"{aid}.out.json"
    log_path = run_dir / f"{aid}.log"

    # out.json is trusted only once its own run reports exit 0.
    if not status_path.is_file():
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nostatus")
    try:
        exit_code = int(status_path.read_text(encoding="utf-8").strip())
    except (OSError, UnicodeDecodeError, ValueError):
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nostatus")

    if exit_code == 124:
        return AngleResult(aid, angle["title"], "UNPARSED", cause="timeout")
    if exit_code != 0:
        cause = "refused" if log_refused(log_path) else f"exit{exit_code}"
        return AngleResult(aid, angle["title"], "UNPARSED", cause=cause)

    if not out_path.is_file():
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nojson")
    try:
        data = json.loads(out_path.read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return AngleResult(aid, angle["title"], "UNPARSED", cause="nojson")

    ok, _err = validate_findings_json(data)
    if not ok:
        return AngleResult(aid, angle["title"], "UNPARSED", cause="schema")
    if data["angle"] != aid:  # a stale file, or the model answering the wrong mandate
        return AngleResult(aid, angle["title"], "UNPARSED", cause="mistagged")

    findings = data["findings"]
    # BLOCKED outranks a nonempty findings array: incomplete is never clean.
    if data["verdict"] == "BLOCKED":
        return AngleResult(aid, angle["title"], "BLOCKED", summary=data["summary"], findings=findings)
    # Trust the findings array over a self-reported verdict text.
    if findings:
        return AngleResult(aid, angle["title"], "FINDINGS", summary=data["summary"], findings=findings)
    return AngleResult(aid, angle["title"], "CLEAN", summary=data["summary"])


# --- Merge + dedup ---------------------------------------------------------------

def dedup_key(f):
    # Full normalized claim, not a prefix: two findings sharing a prefix but
    # diverging later are different findings.
    claim_norm = re.sub(r"\s+", " ", f["claim"].strip().lower())
    return (f["path"], f["line"], claim_norm)


def merge_findings(results):
    merged = {}
    order = []
    for r in results:
        if not r.findings:  # merge by presence, not by kind (see BLOCKED above)
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
                entry.update(
                    severity=f["severity"], path=f["path"], line=f["line"],
                    claim=f["claim"], evidence=f["evidence"], reproduction=f["reproduction"],
                )

    findings = [merged[k] for k in order]
    for f in findings:
        f["angles"] = sorted(f["angles"])

    def sort_key(f):
        return (0 if f["severity"] in BLOCKING_SEVERITIES else 1, f["path"], f["line"], SEVERITY_RANK[f["severity"]])

    findings.sort(key=sort_key)
    return findings


# --- Report rendering --------------------------------------------------------------

def escape_block_text(s):
    """Collapses CR/LF to a literal two-char "\\n" so a multiline field can't inject a fake block line."""
    return s.replace("\r\n", "\\n").replace("\r", "\\n").replace("\n", "\\n")


def build_report(angle_ids, results_by_id, merged_findings, run_dir):
    unparsed_n = sum(1 for aid in angle_ids if results_by_id[aid].kind == "UNPARSED")
    blocked_n = sum(1 for aid in angle_ids if results_by_id[aid].kind == "BLOCKED")
    ran = len(angle_ids) - unparsed_n
    blocking = sum(1 for f in merged_findings if f["severity"] in BLOCKING_SEVERITIES)
    nits = len(merged_findings) - blocking

    # Never clean on any UNPARSED/BLOCKED angle, even if the rest came back CLEAN.
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
        "--- ANGLES ---",
    ]
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
            path, claim = escape_block_text(f["path"]), escape_block_text(f["claim"])
            evidence, reproduction = escape_block_text(f["evidence"]), escape_block_text(f["reproduction"])
            lines.append(f"- [{f['severity']}] {path}:{f['line']} — {claim}  [angles: {','.join(f['angles'])}]")
            lines.append(f"  evidence: {evidence}")
            lines.append(f"  reproduction: {reproduction}")

    counts = {
        "angles": len(angle_ids), "ran": ran, "blocked": blocked_n,
        "unparsed": unparsed_n, "blocking": blocking, "nits": nits,
    }
    return "\n".join(lines), rc, banner, counts


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
    merged_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


# --- CLI ---------------------------------------------------------------------------

def build_arg_parser():
    p = argparse.ArgumentParser(prog=PROG, add_help=True)
    p.add_argument("--plan", help="plan JSON file (required unless --from-dir)")
    p.add_argument("--base", help="override the plan's base branch")
    p.add_argument("--jobs", type=int, help="angles run in parallel (default: min(#angles, 4), or 1 under --allow-writes)")
    p.add_argument("--timeout", type=int, default=900, help="per-angle codex timeout, seconds")
    p.add_argument("--dir", help="run directory (default: a fresh mktemp -d)")
    p.add_argument("--only", help="comma-separated angle ids to restrict to")
    p.add_argument("--angle-prompt", help="prompt template file (default: <skill-dir>/angle-prompt.md)")
    p.add_argument("--from-dir", help="skip codex; merge from an existing run dir")
    p.add_argument("--allow-writes", action="store_true", help="run every angle with -s workspace-write, not read-only")
    p.add_argument("--version", action="store_true", help="print the version and exit")
    p.add_argument("--print-base", action="store_true", help="resolve --base, print it, and exit (no --plan/codex needed)")
    return p


def run_angle(aid, angle, plan, base_resolved, template, execution_mode, run_dir, root, schema_path, timeout_sec):
    """Runs one ephemeral `codex exec`. Returns an error string only on a
    spawn failure (exit 3); a nonzero exit or timeout instead lands in
    <aid>.status for collect_angle_result to fold into UNPARSED."""
    prompt_text = render_prompt(template, plan, angle, base_resolved, execution_mode)
    (run_dir / f"{aid}.prompt.txt").write_text(prompt_text, encoding="utf-8")
    out_path = run_dir / f"{aid}.out.json"
    log_path = run_dir / f"{aid}.log"
    cmd = [
        CODEX_BIN, "exec", "--ephemeral", "--strict-config",
        "-s", execution_mode,
        "-C", root,
        "--output-schema", str(schema_path),
        "-o", str(out_path),
        "-c", f"model={CODEX_REVIEW_MODEL}",
        "-c", f"model_reasoning_effort={CODEX_REVIEW_EFFORT}",
        # Independence of judgment, not security (we review our own branches):
        # keeps an angle from being swayed by the branch's own AGENTS.md/skills.
        "-c", "project_doc_max_bytes=0",
        "-c", "skills.include_instructions=false",
        "--",  # everything after this is the positional prompt, never a flag
        prompt_text,
    ]
    try:
        with open(log_path, "wb") as logfh:
            proc = subprocess.run(
                cmd, stdin=subprocess.DEVNULL, stdout=logfh, stderr=subprocess.STDOUT,
                cwd=root, env=os.environ, timeout=timeout_sec,
            )
        (run_dir / f"{aid}.status").write_text(f"{proc.returncode}\n", encoding="utf-8")
        return None
    except subprocess.TimeoutExpired:
        (run_dir / f"{aid}.status").write_text("124\n", encoding="utf-8")
        return None
    except OSError as e:
        return str(e)


def _load_selected_plan(plan_path, only_arg):
    plan = load_plan(plan_path)
    angle_ids_all = [a["id"] for a in plan["angles"]]
    angles_by_id = {a["id"]: a for a in plan["angles"]}
    angle_ids = parse_only(only_arg, angle_ids_all) or angle_ids_all
    return plan, angles_by_id, angle_ids


def main(argv=None):
    args = build_arg_parser().parse_args(argv)

    if args.version:
        print(f"adversarial_review.py {VERSION}")
        return 0

    if args.print_base:
        # No plan, no codex: a pure lookup so planning and running always
        # resolve --base the same way.
        if not args.base:
            usage_error("--print-base requires --base")
        print(resolve_base(args.base, repo_root()))
        return 0

    if args.from_dir:
        run_dir = Path(args.from_dir).resolve()
        if not run_dir.is_dir():
            env_error(f"no such run directory: {run_dir}")
        plan_path = run_dir / "plan.json"
        if not plan_path.is_file():
            env_error(f"no plan.json in run directory: {plan_path}")
        plan, angles_by_id, angle_ids = _load_selected_plan(plan_path, args.only)
        results_by_id = {aid: collect_angle_result(angles_by_id[aid], run_dir) for aid in angle_ids}
    else:
        if not args.plan:
            usage_error("--plan FILE is required unless --from-dir is given")
        plan_path = Path(args.plan).resolve()
        if not plan_path.is_file():
            env_error(f"no such plan file: {plan_path}")
        plan, angles_by_id, angle_ids = _load_selected_plan(plan_path, args.only)

        global CODEX_BIN
        resolved_codex_bin = shutil.which(CODEX_BIN)
        if resolved_codex_bin is None:
            env_error(f"codex CLI ('{CODEX_BIN}') not found on PATH")
        # Angles run with cwd=root, which can differ from this process's own
        # cwd, so a relative CODEX_BIN must be made absolute now.
        CODEX_BIN = os.path.abspath(resolved_codex_bin)

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

        script_dir = Path(__file__).resolve().parent
        template = load_angle_prompt_template(args.angle_prompt, script_dir)
        schema_path = script_dir / "findings.schema.json"
        execution_mode = "workspace-write" if args.allow_writes else "read-only"

        if args.dir:
            run_dir = Path(args.dir).resolve()
        else:
            run_dir = Path(tempfile.mkdtemp(prefix="adversarial-review.", dir=os.environ.get("TMPDIR", "/tmp"))).resolve()

        # A run directory inside the repo would dirty the tree under review.
        if run_dir.is_relative_to(Path(root).resolve()):
            if not args.dir:
                shutil.rmtree(run_dir, ignore_errors=True)
            usage_error(
                f"run directory {run_dir} is inside the repository root {root} — "
                "the run directory must live outside the repository"
            )
        if args.dir:
            run_dir.mkdir(parents=True, exist_ok=True)

        # A reused --dir's leftovers for these angles must not survive as
        # this run's own result.
        for aid in angle_ids:
            for suffix in ANGLE_ARTIFACT_SUFFIXES:
                (run_dir / f"{aid}{suffix}").unlink(missing_ok=True)
        (run_dir / "merged.json").unlink(missing_ok=True)
        (run_dir / "plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")

        spawn_failures = []
        results_by_id = {}
        # workspace-write angles share one checkout — default to one at a
        # time so two reproductions never race each other; an explicit
        # --jobs still overrides, on the operator's own head.
        default_jobs = 1 if args.allow_writes else min(len(angle_ids), 4)
        jobs = args.jobs or default_jobs
        # No `with`: on KeyboardInterrupt we shut down without waiting so an
        # already-queued (not yet started) angle never launches a codex
        # process after the operator has asked to stop.
        ex = cf.ThreadPoolExecutor(max_workers=jobs)
        try:
            future_to_id = {
                ex.submit(
                    run_angle, aid, angles_by_id[aid], plan, base_resolved,
                    template, execution_mode, run_dir, root, schema_path, args.timeout,
                ): aid
                for aid in angle_ids
            }
            for fut in cf.as_completed(future_to_id):
                aid = future_to_id[fut]
                err = fut.result()
                if err is not None:
                    spawn_failures.append((aid, err))
                else:
                    results_by_id[aid] = collect_angle_result(angles_by_id[aid], run_dir)
            ex.shutdown(wait=True)
        except KeyboardInterrupt:
            ex.shutdown(wait=False, cancel_futures=True)
            print(f"{PROG}: interrupted", file=sys.stderr)
            sys.exit(130)

        if spawn_failures:
            for aid, err in spawn_failures:
                print(f"{PROG}: codex failed to start for angle '{aid}': {err}", file=sys.stderr)
            codex_error("codex could not be invoked for one or more angles — aborting without a merged report")

        if args.allow_writes:
            print(f"{PROG}: warning: ran with --allow-writes — angles may have modified the working tree", file=sys.stderr)
            status = git(["status", "--porcelain"], root).stdout
            print(status if status else "(clean)", file=sys.stderr)

    merged_findings = merge_findings([results_by_id[aid] for aid in angle_ids])
    merged_path = run_dir / "merged.json"
    report, rc, banner, counts = build_report(angle_ids, results_by_id, merged_findings, run_dir)
    write_merged_json(merged_path, angle_ids, results_by_id, merged_findings, banner, counts)
    print(report)
    return rc


if __name__ == "__main__":
    sys.exit(main())
