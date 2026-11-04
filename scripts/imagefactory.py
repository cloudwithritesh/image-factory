#!/usr/bin/env python3
"""
imagefactory: turns ImageRequest YAML files into Packer/Ansible inputs and a
GitLab child pipeline.

  imagefactory.py validate [REQUEST ...]   check requests against the schema and catalogs
  imagefactory.py render REQUEST           write build/<name>/ inputs for one request
  imagefactory.py plan                     choose which requests to build, render them,
                                           and write the CI fan-out:
                                             GitLab: build/child-pipeline.yml
                                             GitHub: build/matrix.json (+ $GITHUB_OUTPUT)

Works on GitHub Actions and GitLab CI; ci_env() maps each platform's
built-in variables to one set of names.

The catalogs (catalog/*.yaml) are the single source of truth for what can be
requested. The portal reads the same catalogs, so the UI and this validator
always agree.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
CATALOG_DIR = ROOT / "catalog"
REQUESTS_DIR = ROOT / "requests"
SCHEMA_FILE = ROOT / "schemas" / "image-request.schema.json"
ANSIBLE_FILES_DIR = ROOT / "ansible" / "files"
HARDENING_VARS_DIR = ROOT / "ansible" / "vars" / "hardening"

VM_TARGETS = {"aws", "azure"}
CONTAINER_TARGETS = {"docker"}

DEFAULTS = {
    "aws": {"instance_type": "t3.medium", "root_volume_gb": 20, "copy_regions": []},
    "azure": {"vm_size": "Standard_D2s_v5", "replication_regions": []},
    "scan": {"fail_on_severity": "critical", "only_fixed": True},
    "promotion": "auto",
}


def ci_env() -> dict[str, str]:
    """Platform-neutral view of the CI environment (GitHub Actions or GitLab CI)."""
    e = os.environ
    if e.get("GITHUB_ACTIONS") == "true":
        repo = e.get("GITHUB_REPOSITORY", "")
        server = e.get("GITHUB_SERVER_URL", "https://github.com")
        return {
            "platform": "github",
            "sha": e.get("GITHUB_SHA", "HEAD"),
            "before_sha": e.get("BEFORE_SHA", ""),  # set by the workflow from the event payload
            "run_number": e.get("GITHUB_RUN_NUMBER", "0"),
            "run_url": f"{server}/{repo}/actions/runs/{e.get('GITHUB_RUN_ID', '0')}",
            "event": e.get("GITHUB_EVENT_NAME", ""),
            "project_url": f"{server}/{repo}",
            "registry_image": e.get("REGISTRY_IMAGE") or f"ghcr.io/{repo.lower()}",
            "parent_pipeline_id": "",
        }
    if e.get("GITLAB_CI") == "true":
        return {
            "platform": "gitlab",
            "sha": e.get("CI_COMMIT_SHA", "HEAD"),
            "before_sha": e.get("CI_MERGE_REQUEST_DIFF_BASE_SHA") or e.get("CI_COMMIT_BEFORE_SHA", ""),
            "run_number": e.get("CI_PIPELINE_IID", "0"),
            "run_url": e.get("CI_PIPELINE_URL", "local"),
            "event": e.get("CI_PIPELINE_SOURCE", ""),
            "project_url": e.get("CI_PROJECT_URL", ""),
            "registry_image": e.get("REGISTRY_IMAGE") or e.get("CI_REGISTRY_IMAGE", ""),
            "parent_pipeline_id": e.get("CI_PIPELINE_ID", "0"),
        }
    return {
        "platform": "local",
        "sha": e.get("COMMIT_SHA", "HEAD"),
        "before_sha": e.get("BEFORE_SHA", ""),
        "run_number": e.get("RUN_NUMBER", "0"),
        "run_url": "local",
        "event": e.get("CI_EVENT", ""),
        "project_url": "",
        "registry_image": e.get("REGISTRY_IMAGE", "registry.example.com/image-factory"),
        "parent_pipeline_id": "0",
    }


class NoAliasDumper(yaml.SafeDumper):
    """Write plain YAML without &anchors, so the generated pipeline is easy to read."""

    def ignore_aliases(self, data: Any) -> bool:  # noqa: ARG002
        return True


def rel(path: Path) -> str:
    """Path relative to the repo root (Packer and Ansible run from there)."""
    path = path.resolve()
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


class RequestError(Exception):
    """The request is invalid. The message is shown to the requester as-is."""


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #
def load_yaml(path: Path) -> Any:
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def load_catalogs() -> dict[str, dict]:
    return {
        "os": load_yaml(CATALOG_DIR / "os.yaml") or {},
        "hardening": load_yaml(CATALOG_DIR / "hardening.yaml") or {},
        "software": load_yaml(CATALOG_DIR / "software.yaml") or {},
    }


def resolve_request_path(ref: str) -> Path:
    """Accept 'requests/x.yaml', 'x.yaml' or just 'x'."""
    candidates = [Path(ref), ROOT / ref, REQUESTS_DIR / ref, REQUESTS_DIR / f"{ref}.yaml"]
    for c in candidates:
        if c.is_file():
            return c.resolve()
    raise RequestError(f"request not found: {ref}")


# --------------------------------------------------------------------------- #
# Validation
# --------------------------------------------------------------------------- #
def validate_request(req: dict, catalogs: dict, source: str = "") -> list[str]:
    """Return a list of human-readable errors (empty list = valid)."""
    errors: list[str] = []
    schema = json.loads(SCHEMA_FILE.read_text(encoding="utf-8"))
    for err in sorted(Draft202012Validator(schema).iter_errors(req), key=lambda e: list(e.path)):
        loc = "/".join(str(p) for p in err.path) or "(root)"
        errors.append(f"{loc}: {err.message}")
    if errors:
        return errors  # don't cross-check a structurally broken request

    spec = req["spec"]
    os_key = spec["os"]
    os_entry = catalogs["os"].get(os_key)
    if not os_entry:
        return [f"spec/os: '{os_key}' is not in catalog/os.yaml (known: {sorted(catalogs['os'])})"]

    targets = set(spec["targets"])
    unsupported = targets - set(os_entry.get("targets", {}))
    if unsupported:
        errors.append(f"spec/targets: {os_key} has no base image for {sorted(unsupported)}")

    # Hardening profiles
    hard = catalogs["hardening"].get(os_key, {})
    for kind, kind_targets in (("vm", VM_TARGETS), ("container", CONTAINER_TARGETS)):
        if not targets & kind_targets:
            continue
        kind_cfg = hard.get(kind)
        if not kind_cfg:
            errors.append(f"hardening: catalog has no '{kind}' profiles for {os_key}")
            continue
        chosen = (spec.get("hardening") or {}).get(kind, kind_cfg["default"])
        profile = kind_cfg["profiles"].get(chosen)
        if not profile:
            errors.append(
                f"spec/hardening/{kind}: '{chosen}' is not a {kind} profile for {os_key} "
                f"(choose from {sorted(kind_cfg['profiles'])})"
            )
        elif profile.get("role", "none") != "none":
            for vf in (
                HARDENING_VARS_DIR / f"{profile['role']}.common.yml",
                HARDENING_VARS_DIR / profile.get("vars_file", ""),
            ):
                if not vf.is_file():
                    errors.append(f"catalog: profile '{chosen}' needs {vf.relative_to(ROOT)}, which is missing")

    # Software
    for key in spec.get("software", []):
        item = catalogs["software"].get(key)
        if not item:
            errors.append(f"spec/software: '{key}' is not in catalog/software.yaml")
            continue
        if os_key not in item.get("os", []):
            errors.append(f"spec/software: '{key}' is not approved for {os_key}")
        if not targets & set(item.get("targets", [])):
            errors.append(f"spec/software: '{key}' supports none of the requested targets {sorted(targets)}")
        if item.get("type") == "file" and not (ANSIBLE_FILES_DIR / item["src"]).is_file():
            errors.append(f"spec/software: '{key}' needs ansible/files/{item['src']}, which isn't in the repo")

    # The file name must match metadata.name so there's one request per image
    if source and Path(source).stem != req["metadata"]["name"]:
        errors.append(f"metadata/name '{req['metadata']['name']}' must match the file name '{Path(source).name}'")
    return errors


def load_valid_request(ref: str, catalogs: dict) -> tuple[Path, dict]:
    path = resolve_request_path(ref)
    req = load_yaml(path)
    if not isinstance(req, dict):
        raise RequestError(f"{path.name}: not a YAML mapping")
    errors = validate_request(req, catalogs, str(path))
    if errors:
        raise RequestError(f"{path.name} is invalid:\n  - " + "\n  - ".join(errors))
    return path, req


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #
def image_version() -> str:
    """Azure-gallery-compatible version: <year>.<month*100+day>.<pipeline iid>."""
    if os.environ.get("IMAGE_VERSION"):
        return os.environ["IMAGE_VERSION"]
    now = dt.datetime.now(dt.timezone.utc)
    iid = int(ci_env()["run_number"] or 0)
    return f"{now.year}.{now.month * 100 + now.day}.{iid}"


def merged(spec: dict, section: str) -> Any:
    default = DEFAULTS[section]
    if isinstance(default, dict):
        return {**default, **(spec.get(section) or {})}
    return spec.get(section, default)


def hardening_for(spec: dict, catalogs: dict, kind: str) -> tuple[str, dict]:
    kind_cfg = catalogs["hardening"][spec["os"]][kind]
    name = (spec.get("hardening") or {}).get(kind, kind_cfg["default"])
    return name, kind_cfg["profiles"][name]


def render(req: dict, catalogs: dict, out_root: Path, version: str) -> dict:
    meta, spec = req["metadata"], req["spec"]
    name, os_key = meta["name"], spec["os"]
    os_entry = catalogs["os"][os_key]
    targets = list(spec["targets"])
    out = out_root / name
    out.mkdir(parents=True, exist_ok=True)

    aws, azure, scan = merged(spec, "aws"), merged(spec, "azure"), merged(spec, "scan")
    software_items = [{"key": k, **catalogs["software"][k]} for k in spec.get("software", [])]
    env = ci_env()
    registry_image = env["registry_image"] or "registry.example.com/image-factory"

    pkrvars: dict[str, Any] = {
        "image_name": name,
        "image_version": version,
        "image_owner": meta["owner"],
        "image_description": meta.get("description", f"{os_entry['display_name']} golden image"),
        "os_key": os_key,
        "request_labels": meta.get("labels", {}),
        "git_sha": env["sha"],
        "pipeline_url": env["run_url"],
        "output_dir": rel(out / "output"),
    }

    for kind, kind_targets in (("vm", VM_TARGETS), ("container", CONTAINER_TARGETS)):
        if not set(targets) & kind_targets:
            continue
        profile_name, profile = hardening_for(spec, catalogs, kind)
        ansible_vars = {
            "image_name": name,
            "image_version": version,
            "os_key": os_key,
            "image_kind": kind,
            "software_items": software_items,
            "hardening_profile": profile_name,
            "hardening_role": profile.get("role", "none"),
            "hardening_vars_file": profile.get("vars_file", ""),
        }
        vars_path = out / f"ansible-{kind}.json"
        vars_path.write_text(json.dumps(ansible_vars, indent=2) + "\n", encoding="utf-8")
        pkrvars[f"ansible_{kind}_vars_file"] = rel(vars_path)
        pkrvars[f"ansible_{kind}_skip_tags"] = ",".join(profile.get("skip_tags", []))

    if "aws" in targets:
        t = os_entry["targets"]["aws"]
        pkrvars |= {
            "aws_source_ami_filter_name": t["source_ami_filter_name"],
            "aws_source_ami_owners": t["source_ami_owners"],
            "aws_ssh_username": t["ssh_username"],
            "aws_instance_type": aws["instance_type"],
            "aws_root_volume_gb": aws["root_volume_gb"],
            "aws_ami_copy_regions": aws["copy_regions"],
        }
    if "azure" in targets:
        t = os_entry["targets"]["azure"]
        pkrvars |= {
            "azure_image_publisher": t["image_publisher"],
            "azure_image_offer": t["image_offer"],
            "azure_image_sku": t["image_sku"],
            # One gallery image definition per image request (see packer-build.sh)
            "azure_gallery_image_definition": name,
            "azure_hyper_v_generation": t.get("hyper_v_generation", "V2"),
            "azure_os_type": "Windows" if os_entry["family"] == "windows" else "Linux",
            "azure_vm_size": azure["vm_size"],
            "azure_replication_regions": azure["replication_regions"],
        }
    if "docker" in targets:
        t = os_entry["targets"]["docker"]
        pkrvars |= {
            "docker_base_image": t["base_image"],
            "docker_repository": f"{registry_image}/images/{name}",
            "docker_source_url": env["project_url"],
        }

    (out / "variables.pkrvars.json").write_text(json.dumps(pkrvars, indent=2) + "\n", encoding="utf-8")

    plan = {
        "name": name,
        "version": version,
        "os": os_key,
        "family": os_entry["family"],
        "targets": targets,
        "fail_on_severity": scan["fail_on_severity"],
        "only_fixed": bool(scan["only_fixed"]),
        "promotion": merged(spec, "promotion"),
        "docker_repository": pkrvars.get("docker_repository", ""),
        "azure_gallery_image_definition": pkrvars.get("azure_gallery_image_definition", ""),
        "azure_hyper_v_generation": pkrvars.get("azure_hyper_v_generation", ""),
        "azure_os_type": pkrvars.get("azure_os_type", ""),
    }
    (out / "plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    return plan


# --------------------------------------------------------------------------- #
# Planning (which requests does this pipeline build?)
# --------------------------------------------------------------------------- #
def all_requests() -> list[str]:
    return sorted(str(p.relative_to(ROOT)) for p in REQUESTS_DIR.glob("*.yaml"))


def changed_requests() -> list[str]:
    env = ci_env()
    # MR/PR pipelines compare with the merge base; pushes with the previous
    # tip of the branch.
    sha, before = env["sha"], env["before_sha"]
    if not before or set(before) == {"0"}:
        # First push of a branch: GitLab gives no "before" commit. Compare
        # with the parent commit instead.
        before = f"{sha}~1"
    try:
        out = subprocess.run(
            ["git", "diff", "--name-only", "--diff-filter=AM", before, sha, "--", "requests/"],
            cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout
    except subprocess.CalledProcessError as exc:
        print(f"warning: git diff failed ({exc.stderr.strip()}); building nothing", file=sys.stderr)
        return []
    return sorted(line for line in out.splitlines() if line.endswith(".yaml"))


def select_requests() -> tuple[list[str], str]:
    explicit = os.environ.get("IMAGE_REQUEST", "").strip()
    if explicit:
        return [r.strip() for r in explicit.split(",") if r.strip()], "IMAGE_REQUEST variable"
    if ci_env()["event"] == "schedule" or os.environ.get("REBUILD_ALL", "").lower() == "true":
        return all_requests(), "scheduled rebuild of every request"
    return changed_requests(), "requests changed in this commit"


def job(extends: str, variables: dict, needs: list, **extra: Any) -> dict:
    return {"extends": extends, "variables": variables, "needs": needs, **extra}


def child_pipeline(plans: list[dict]) -> dict:
    parent = ci_env()["parent_pipeline_id"] or "0"
    pipeline: dict[str, Any] = {
        "include": [{"local": ".gitlab/ci/image-jobs.yml"}],
        "stages": ["build", "scan", "promote"],
        "variables": {"PARENT_PIPELINE_ID": parent},
    }
    if not plans:
        pipeline["nothing-to-build"] = {
            "stage": "build",
            "image": "busybox:latest",
            "script": ["echo 'No image requests selected for this pipeline.'"],
        }
        return pipeline

    plan_artifacts = {"pipeline": "$PARENT_PIPELINE_ID", "job": "plan"}
    for p in plans:
        common = {
            "IMAGE_NAME": p["name"],
            "IMAGE_VERSION": p["version"],
            "FAIL_ON_SEVERITY": p["fail_on_severity"],
            "ONLY_FIXED": str(p["only_fixed"]).lower(),
        }
        for target in p["targets"]:
            prefix = f"{p['name']}:{target}"
            vars_ = {**common, "TARGET": target}
            scan_tpl = ".scan-container" if target in CONTAINER_TARGETS else ".scan-vm"
            pipeline[f"{prefix}:build"] = job(f".build-{target}", vars_, [plan_artifacts])
            pipeline[f"{prefix}:scan"] = job(scan_tpl, vars_, [plan_artifacts, f"{prefix}:build"])
            promote = job(f".promote-{target}", vars_, [plan_artifacts, f"{prefix}:build", f"{prefix}:scan"])
            if p["promotion"] == "manual":
                promote["when"] = "manual"
            pipeline[f"{prefix}:promote"] = promote
    return pipeline


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def github_matrix(plans: list[dict]) -> list[dict]:
    """One entry per request and target, for strategy.matrix.include."""
    return [
        {
            "name": p["name"],
            "version": p["version"],
            "target": target,
            "fail_on_severity": p["fail_on_severity"],
            "only_fixed": str(p["only_fixed"]).lower(),
            # Approvals are GitHub environment protection rules. Manual
            # promotion uses a separate environment with required reviewers.
            "environment": f"images-{target}" + ("-approval" if p["promotion"] == "manual" else ""),
        }
        for p in plans
        for target in p["targets"]
    ]


def cmd_validate(args: argparse.Namespace) -> int:
    catalogs = load_catalogs()
    refs = args.requests or all_requests()
    failed = 0
    for ref in refs:
        try:
            path, _ = load_valid_request(ref, catalogs)
            print(f"ok      {path.relative_to(ROOT)}")
        except RequestError as exc:
            failed += 1
            print(f"INVALID {exc}", file=sys.stderr)
    return 1 if failed else 0


def cmd_render(args: argparse.Namespace) -> int:
    catalogs = load_catalogs()
    try:
        _, req = load_valid_request(args.request, catalogs)
    except RequestError as exc:
        print(exc, file=sys.stderr)
        return 1
    plan = render(req, catalogs, Path(args.out), image_version())
    print(json.dumps(plan, indent=2))
    return 0


def cmd_plan(args: argparse.Namespace) -> int:
    catalogs = load_catalogs()
    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)
    refs, reason = select_requests()
    print(f"Selecting requests by: {reason}")
    version = image_version()
    plans, errors = [], []
    for ref in refs:
        try:
            _, req = load_valid_request(ref, catalogs)
            plans.append(render(req, catalogs, out_root, version))
            print(f"  + {req['metadata']['name']} {version} -> {', '.join(req['spec']['targets'])}")
        except RequestError as exc:
            errors.append(str(exc))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    (out_root / "plan.json").write_text(json.dumps(plans, indent=2) + "\n", encoding="utf-8")
    with (out_root / "child-pipeline.yml").open("w", encoding="utf-8") as fh:
        yaml.dump(child_pipeline(plans), fh, Dumper=NoAliasDumper, sort_keys=False, width=200)
    matrix = github_matrix(plans)
    (out_root / "matrix.json").write_text(json.dumps(matrix, indent=2) + "\n", encoding="utf-8")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            fh.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
            fh.write(f"count={len(matrix)}\n")
    print(f"Planned {len(plans)} image(s), {len(matrix)} build job(s)")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate", help="validate requests (default: all)")
    v.add_argument("requests", nargs="*")
    v.set_defaults(func=cmd_validate)
    r = sub.add_parser("render", help="render one request")
    r.add_argument("request")
    r.add_argument("--out", default=str(ROOT / "build"))
    r.set_defaults(func=cmd_render)
    p = sub.add_parser("plan", help="select, render and write the child pipeline")
    p.add_argument("--out", default=str(ROOT / "build"))
    p.set_defaults(func=cmd_plan)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
