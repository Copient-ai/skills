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
import shutil
import subprocess
import sys
import tempfile
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
        "{{DIFF_COMMAND}}": f"git diff {base_resolved}...HEAD",
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


def collect_angle_result(angle, run_dir):
    aid = angle["id"]
    status_path = run_dir / f"{aid}.status"
    out_path = run_dir / f"{aid}.out.json"

    exit_code = None
    if status_path.is_file():
        text = status_path.read_text().strip()
        try:
            exit_code = int(text)
        except ValueError:
            exit_code = None  # malformed status file — fall through to the JSON check

    if exit_code == 124:
        return AngleResult(aid, angle["title"], "UNPARSED", cause="timeout")
    if exit_code not in (None, 0):
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

    findings = data["findings"]
    # Trust the findings array over the self-reported verdict text: a model
    # that mislabels verdict="CLEAN" while still listing findings must not
    # have those findings silently dropped.
    if findings:
        return AngleResult(aid, angle["title"], "FINDINGS", summary=data["summary"], findings=findings)
    if data["verdict"] == "BLOCKED":
        return AngleResult(aid, angle["title"], "BLOCKED", summary=data["summary"])
    return AngleResult(aid, angle["title"], "CLEAN", summary=data["summary"])


# --- Merge + dedup -------------------------------------------------------------

def dedup_key(f):
    claim_norm = re.sub(r"\s+", " ", f["claim"].strip().lower())[:60]
    return (f["path"], f["line"], claim_norm)


def merge_findings(results):
    merged = {}
    order = []
    for r in results:
        if r.kind != "FINDINGS":
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

def build_report(angle_ids, results_by_id, merged_findings, run_dir):
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
            lines.append(f"{aid}: {r.summary}")

    if merged_findings:
        lines.append("--- FINDINGS ---")
        for f in merged_findings:
            lines.append(
                f"- [{f['severity']}] {f['path']}:{f['line']} — {f['claim']}  "
                f"[angles: {','.join(f['angles'])}]"
            )
            lines.append(f"  evidence: {f['evidence']}")
            lines.append(f"  reproduction: {f['reproduction']}")

    counts = {
        "angles": len(angle_ids),
        "ran": ran,
        "blocked": blocked_n,
        "unparsed": unparsed_n,
        "blocking": blocking,
        "nits": nits,
    }
    return "\n".join(lines), rc, banner, counts


def write_merged_json(run_dir, angle_ids, results_by_id, merged_findings, banner, counts):
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
    (run_dir / "merged.json").write_text(json.dumps(doc, indent=2) + "\n")


# --- CLI -----------------------------------------------------------------------

def build_arg_parser():
    p = argparse.ArgumentParser(prog=PROG, add_help=True)
    p.add_argument("--plan", help="plan JSON file (required unless --from-dir)")
    p.add_argument("--base", help="override the plan's base branch")
    p.add_argument("--jobs", type=int, help="angles run in parallel (default: min(#angles, 4))")
    p.add_argument("--timeout", type=int, default=900, help="per-angle codex timeout, seconds")
    p.add_argument("--dir", help="run directory (default: a fresh mktemp -d)")
    p.add_argument("--only", help="comma-separated angle ids to restrict to")
    p.add_argument("--angle-prompt", help="prompt template file")
    p.add_argument("--from-dir", help="skip codex; merge from an existing run dir")
    p.add_argument("--version", action="store_true", help="print the version and exit")
    return p


def run_angle(aid, angle, plan, base_resolved, template, run_dir, root, schema_path, timeout_sec):
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
            proc = subprocess.run(
                cmd, stdin=subprocess.DEVNULL, stdout=logfh, stderr=subprocess.STDOUT,
                cwd=root, timeout=timeout_sec,
            )
        (run_dir / f"{aid}.status").write_text(f"{proc.returncode}\n")
        return None
    except subprocess.TimeoutExpired:
        (run_dir / f"{aid}.status").write_text("124\n")
        return None
    except OSError as e:
        return str(e)


def main(argv=None):
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    if args.version:
        print(f"adversarial_review.py {VERSION}")
        return 0

    script_dir = Path(__file__).resolve().parent

    if args.from_dir:
        run_dir = Path(args.from_dir)
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
        plan_path = Path(args.plan)
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
        jobs = args.jobs or min(len(angle_ids), 4)

        if args.dir:
            run_dir = Path(args.dir)
            run_dir.mkdir(parents=True, exist_ok=True)
        else:
            run_dir = Path(tempfile.mkdtemp(prefix="adversarial-review.", dir=os.environ.get("TMPDIR", "/tmp")))
        (run_dir / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")

        template = load_angle_prompt_template(args.angle_prompt, script_dir)
        schema_path = script_dir / "findings.schema.json"

        spawn_failures = []
        with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
            future_to_id = {
                ex.submit(
                    run_angle, aid, angles_by_id[aid], plan, base_resolved, template,
                    run_dir, root, schema_path, args.timeout,
                ): aid
                for aid in angle_ids
            }
            for fut in cf.as_completed(future_to_id):
                err = fut.result()
                if err is not None:
                    spawn_failures.append((future_to_id[fut], err))

        if spawn_failures:
            for aid, err in spawn_failures:
                print(f"{PROG}: codex failed to start for angle '{aid}': {err}", file=sys.stderr)
            codex_error(
                "codex could not be invoked for one or more angles — aborting without a "
                "merged report (a review that never started is not the same as one that "
                "ran and timed out or errored, which is instead folded into a per-angle "
                "UNPARSED result)"
            )

        results_by_id = {aid: collect_angle_result(angles_by_id[aid], run_dir) for aid in angle_ids}

    merged_findings = merge_findings([results_by_id[aid] for aid in angle_ids])
    report, rc, banner, counts = build_report(angle_ids, results_by_id, merged_findings, run_dir)
    write_merged_json(run_dir, angle_ids, results_by_id, merged_findings, banner, counts)
    print(report)
    return rc


if __name__ == "__main__":
    sys.exit(main())
