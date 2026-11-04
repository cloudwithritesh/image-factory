#!/usr/bin/env python3
"""
Turn a portal submission into a validated request file plus everything
needed for a standard branch, commit and pull request.

Inputs (the GitHub event file, never shell-interpolated):
  issues.opened       GitHub Pages portal: the issue body carries the form as JSON
  workflow_dispatch   Backstage: inputs.kind, inputs.payload (form JSON), inputs.requested_by

Writes requests/<name>.yaml (images) or vms/<name>.yaml (VMs) and a JSON
result describing the branch, commit and PR. The portal forms are flat on
purpose; this script owns the mapping to the request documents, so every
front end (Pages, Backstage, a future Entra-ID portal) behaves the same.

  python3 scripts/portal/process_request.py --event "$GITHUB_EVENT_PATH" --out result.json
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))  # scripts/
sys.path.insert(0, str(HERE))  # scripts/portal/

import imagefactory as ifc  # noqa: E402
import standards  # noqa: E402

VM_DIR = ROOT / "vms"
VM_SCHEMA = ROOT / "schemas" / "vm-request.schema.json"
VM_CATALOG = ROOT / "catalog" / "vm.yaml"
MARKER = "<!-- portal-request:v1 -->"
TRUSTED_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
SOURCES = {"pages": "GitHub Pages portal", "backstage": "Backstage", "cli": "command line"}


class RequestError(Exception):
    """Shown to the requester (issue comment / workflow summary)."""


class IndentedDumper(yaml.SafeDumper):
    """Lists indented under their key, as .yamllint.yml requires; no anchors."""

    def ignore_aliases(self, data):  # noqa: ARG002
        return True

    def increase_indent(self, flow=False, indentless=False):  # noqa: ARG002
        return super().increase_indent(flow, False)


# --------------------------------------------------------------------------- #
# Reading the submission
# --------------------------------------------------------------------------- #
def extract_form(body: str) -> dict:
    if MARKER not in body:
        raise RequestError("this issue wasn't created by the portal (missing marker)")
    m = re.search(r"```(?:json|yaml)?\s*\n(.*?)\n```", body, re.DOTALL)
    if not m:
        raise RequestError("no request block found in the issue")
    try:
        form = yaml.safe_load(m.group(1))  # JSON is valid YAML
    except yaml.YAMLError as exc:
        raise RequestError(f"the request block isn't valid JSON/YAML: {exc}") from exc
    if not isinstance(form, dict):
        raise RequestError("the request block must be an object")
    return form


def read_submission(event_path: Path) -> dict:
    event = json.loads(event_path.read_text(encoding="utf-8"))
    run_id = os.environ.get("GITHUB_RUN_ID", "0")
    actor = os.environ.get("GITHUB_ACTOR", "unknown")

    if "issue" in event:
        issue = event["issue"]
        if issue.get("author_association") not in TRUSTED_ASSOCIATIONS:
            raise RequestError("only repository owners, members and collaborators can submit requests")
        form = extract_form(issue.get("body") or "")
        return {
            "form": form,
            "kind": form.get("kind"),
            "requested_by": issue["user"]["login"],
            "submitted_by": issue["user"]["login"],
            "source": "pages",
            "ref": f"i{issue['number']}",
            "ref_text": f"issue #{issue['number']}",
            "issue_number": issue["number"],
        }

    inputs = event.get("inputs") or {}
    try:
        form = json.loads(inputs.get("payload") or "{}")
    except json.JSONDecodeError as exc:
        raise RequestError(f"payload isn't valid JSON: {exc}") from exc
    if not isinstance(form, dict):
        raise RequestError("payload must be a JSON object")
    requested_by = (inputs.get("requested_by") or actor).strip()
    # Backstage passes an entity ref (user:default/<name>); keep the name
    requested_by = re.sub(r"^user:(?:[a-z0-9-]+/)?", "", requested_by)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@/:-]{0,99}", requested_by):
        raise RequestError("requested_by contains unexpected characters")
    source = inputs.get("source") or "backstage"
    if source not in SOURCES:
        raise RequestError(f"unknown source '{source}'")
    return {
        "form": form,
        "kind": inputs.get("kind") or form.get("kind"),
        "requested_by": requested_by,
        "submitted_by": actor,
        "source": source,
        "ref": f"r{run_id[-8:]}",
        "ref_text": f"workflow run {run_id}",
        "issue_number": None,
    }


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def text(form: dict, key: str, default: Any = None) -> Any:
    value = form.get(key, default)
    if isinstance(value, str):
        value = value.strip()
        if key == "owner":  # Backstage OwnerPicker returns group:default/<team>
            value = re.sub(r"^(?:group|user):(?:[a-z0-9-]+/)?", "", value)
        return value if value else default
    return value


def as_list(value: Any) -> list:
    if value is None or value == "":
        return []
    if isinstance(value, str):
        return [v.strip() for v in value.split(",") if v.strip()]
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    raise RequestError(f"expected a list, got {type(value).__name__}")


def as_bool(value: Any, default: bool) -> bool:
    if value is None or value == "":
        return default
    if isinstance(value, bool):
        return value
    return str(value).lower() in ("true", "yes", "1", "on")


def load_yaml_file(path: Path) -> dict | None:
    if not path.is_file():
        return None
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return data if isinstance(data, dict) else None


def prune(d: dict) -> dict:
    """Drop empty values so the written file stays tidy."""
    out = {}
    for k, v in d.items():
        if isinstance(v, dict):
            v = prune(v)
        if v in (None, "", [], {}):
            continue
        out[k] = v
    return out


# --------------------------------------------------------------------------- #
# Image requests
# --------------------------------------------------------------------------- #
def build_image_request(form: dict, requested_by: str, existing: dict | None) -> dict:
    name = text(form, "name")
    if not name:
        raise RequestError("image name is required")
    doc = copy.deepcopy(existing) if existing else {
        "apiVersion": "imagefactory/v1", "kind": "ImageRequest", "metadata": {}, "spec": {},
    }
    meta, spec = doc.setdefault("metadata", {}), doc.setdefault("spec", {})

    meta["name"] = name
    meta["owner"] = text(form, "owner", meta.get("owner"))
    meta["description"] = text(form, "description", meta.get("description"))
    meta["requested_by"] = requested_by

    spec["os"] = text(form, "os", spec.get("os"))
    targets = as_list(form.get("targets")) or spec.get("targets", [])
    spec["targets"] = targets

    hardening = dict(spec.get("hardening") or {})
    if text(form, "hardening_vm"):
        hardening["vm"] = text(form, "hardening_vm")
    if text(form, "hardening_container"):
        hardening["container"] = text(form, "hardening_container")
    if not set(targets) & ifc.VM_TARGETS:
        hardening.pop("vm", None)
    if not set(targets) & ifc.CONTAINER_TARGETS:
        hardening.pop("container", None)
    spec["hardening"] = hardening

    if "software" in form:
        spec["software"] = as_list(form.get("software"))

    if text(form, "azure_vm_size"):
        spec.setdefault("azure", {})["vm_size"] = text(form, "azure_vm_size")
    if text(form, "aws_instance_type"):
        spec.setdefault("aws", {})["instance_type"] = text(form, "aws_instance_type")

    scan = dict(spec.get("scan") or {})
    if text(form, "fail_on_severity"):
        scan["fail_on_severity"] = text(form, "fail_on_severity")
    if "only_fixed" in form:
        scan["only_fixed"] = as_bool(form.get("only_fixed"), True)
    spec["scan"] = scan

    if text(form, "promotion"):
        spec["promotion"] = text(form, "promotion")
    return prune(doc)


def enabled_targets() -> list[str]:
    """Image targets this platform can build: enabled clouds (catalog/vm.yaml) + docker."""
    catalog = yaml.safe_load(VM_CATALOG.read_text(encoding="utf-8"))
    return [c for c, cfg in catalog["clouds"].items() if cfg.get("enabled")] + ["docker"]


def validate_image(doc: dict, path: Path) -> None:
    errors = ifc.validate_request(doc, ifc.load_catalogs(), str(path))
    allowed = enabled_targets()
    for target in (doc.get("spec") or {}).get("targets", []):
        if target not in allowed:
            errors.append(f"spec/targets: '{target}' isn't set up on this platform yet (enabled: {', '.join(allowed)})")
    if errors:
        raise RequestError("the image request is invalid:\n- " + "\n- ".join(errors))


# --------------------------------------------------------------------------- #
# VM requests
# --------------------------------------------------------------------------- #
def approved_images() -> dict[str, list[str]]:
    """Image name -> targets, for every request file in requests/."""
    images = {}
    for path in sorted(ifc.REQUESTS_DIR.glob("*.yaml")):
        data = load_yaml_file(path) or {}
        name = (data.get("metadata") or {}).get("name")
        if name:
            images[name] = list((data.get("spec") or {}).get("targets", []))
    return images


def build_vm_request(form: dict, requested_by: str, existing: dict | None) -> dict:
    catalog = yaml.safe_load(VM_CATALOG.read_text(encoding="utf-8"))
    name = text(form, "name")
    if not name:
        raise RequestError("VM name is required")
    doc = copy.deepcopy(existing) if existing else {
        "apiVersion": "imagefactory/v1", "kind": "VirtualMachine", "metadata": {}, "spec": {},
    }
    meta, spec = doc.setdefault("metadata", {}), doc.setdefault("spec", {})
    meta["name"] = name
    meta["owner"] = text(form, "owner", meta.get("owner"))
    meta["environment"] = text(form, "environment", meta.get("environment"))
    meta["description"] = text(form, "description", meta.get("description"))
    meta["requested_by"] = requested_by

    spec["cloud"] = text(form, "cloud", spec.get("cloud", "azure"))
    spec["image"] = text(form, "image", spec.get("image"))
    spec["image_version"] = text(form, "image_version", spec.get("image_version", "latest"))
    spec["size"] = text(form, "size", spec.get("size"))
    spec["region"] = text(form, "region", spec.get("region"))
    disk = form.get("os_disk_gb", spec.get("os_disk_gb", catalog["os_disk_gb"]["default"]))
    try:
        spec["os_disk_gb"] = int(disk)
    except (TypeError, ValueError) as exc:
        raise RequestError("os_disk_gb must be a number") from exc
    spec["admin_username"] = text(form, "admin_username", spec.get("admin_username", catalog["admin_username_default"]))
    spec["ssh_public_key"] = text(form, "ssh_public_key", spec.get("ssh_public_key"))
    spec["public_ip"] = as_bool(form.get("public_ip"), spec.get("public_ip", False))
    if spec["public_ip"]:
        spec["allowed_ssh_cidr"] = text(form, "allowed_ssh_cidr", spec.get("allowed_ssh_cidr"))
    else:
        spec.pop("allowed_ssh_cidr", None)
    spec["state"] = text(form, "state", spec.get("state", "present"))
    return prune(doc)


def validate_vm(doc: dict, path: Path) -> None:
    errors = []
    schema = json.loads(VM_SCHEMA.read_text(encoding="utf-8"))
    friendly = {
        "name": "must be 3-15 characters: lowercase letters, digits and hyphens, starting with a letter",
        "ssh_public_key": "isn't a valid SSH public key (paste the whole line from ~/.ssh/id_ed25519.pub)",
        "allowed_ssh_cidr": "must be an IPv4 range like 203.0.113.0/24",
        "admin_username": "must be 3-32 characters: lowercase letters, digits, - and _",
        "image_version": "must be 'latest' or a version like 2026.1103.42",
    }
    for err in sorted(Draft202012Validator(schema).iter_errors(doc), key=lambda e: list(e.path)):
        loc = "/".join(str(p) for p in err.path) or "(root)"
        field = str(err.path[-1]) if err.path else ""
        message = friendly.get(field, err.message) if err.validator == "pattern" else err.message
        errors.append(f"{loc}: {message}")
    if not errors:
        catalog = yaml.safe_load(VM_CATALOG.read_text(encoding="utf-8"))
        meta, spec = doc["metadata"], doc["spec"]
        cloud = catalog["clouds"].get(spec["cloud"], {})
        if not cloud.get("enabled"):
            errors.append(f"cloud '{spec['cloud']}' isn't enabled yet (catalog/vm.yaml)")
        if spec["region"] not in cloud.get("regions", []):
            errors.append(f"region '{spec['region']}' isn't allowed for {spec['cloud']} (choose from {cloud.get('regions')})")
        if spec["size"] not in cloud.get("sizes", {}):
            errors.append(f"size '{spec['size']}' isn't defined (choose from {sorted(cloud.get('sizes', {}))})")
        if meta["environment"] not in catalog["environments"]:
            errors.append(f"environment '{meta['environment']}' isn't allowed (choose from {catalog['environments']})")
        images = approved_images()
        if spec["image"] not in images:
            errors.append(f"image '{spec['image']}' isn't an approved image (choose from {sorted(images)})")
        elif spec["cloud"] not in images[spec["image"]]:
            errors.append(f"image '{spec['image']}' isn't built for {spec['cloud']}")
        lo, hi = catalog["os_disk_gb"]["min"], catalog["os_disk_gb"]["max"]
        if not lo <= spec.get("os_disk_gb", lo) <= hi:
            errors.append(f"os_disk_gb must be between {lo} and {hi}")
        if spec.get("public_ip"):
            net = ipaddress.ip_network(spec["allowed_ssh_cidr"], strict=False)
            if net.prefixlen < 16:
                errors.append("allowed_ssh_cidr is too broad; use a /16 or narrower (your office or VPN range)")
        if path.stem != meta["name"]:
            errors.append("file name must match metadata.name")
    if errors:
        raise RequestError("the VM request is invalid:\n- " + "\n- ".join(errors))


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
def dump_yaml(doc: dict, sub: dict) -> str:
    header = (
        "# Managed through the image factory portal.\n"
        f"# Last change: requested by @{sub['requested_by']} via {SOURCES[sub['source']]} "
        f"({sub['ref_text']}) on {dt.datetime.now(dt.timezone.utc):%Y-%m-%d}.\n"
    )
    return header + yaml.dump(doc, Dumper=IndentedDumper, sort_keys=False, width=120, allow_unicode=True)


def strip_header(content: str) -> str:
    return "\n".join(line for line in content.splitlines() if not line.startswith("# ")).strip()


def pr_body(kind: str, action: str, name: str, rel_path: str, content: str, sub: dict, targets: list[str]) -> str:
    who = f"@{sub['requested_by']}"
    if sub["submitted_by"] != sub["requested_by"]:
        who += f" (submitted by @{sub['submitted_by']})"
    if kind == "image":
        heading = f"Image request: `{name}`"
        nxt = [
            "The PR checks validate the request against the catalogs and naming standards.",
            f"After approval and merge, the image pipeline builds **{', '.join(targets)}**, "
            "hardens it, generates the SBOM, scans it and promotes it.",
        ]
        checklist = [
            "Software and hardening choices are appropriate for this image",
            "Targets and promotion mode (auto/manual) are correct",
            "The owner team is correct",
        ]
    else:
        heading = f"VM request: `{name}`"
        nxt = [
            "The PR checks validate the request against the VM catalog.",
            "After approval and merge, the vm-provision workflow "
            + ("**decommissions** this VM." if action == "remove" else "creates or updates the VM with Terraform."),
        ]
        checklist = [
            "Size and environment are justified",
            "The SSH key belongs to the requester",
            "Public IP (if any) is restricted to a known range",
        ]
    lines = [
        f"## {heading}",
        "",
        "| | |",
        "|---|---|",
        f"| Action | **{action}** |",
        f"| Requested by | {who} |",
        f"| Source | {SOURCES[sub['source']]} ({sub['ref_text']}) |",
        f"| File | `{rel_path}` |",
        "",
        "### Request",
        "",
        "```yaml",
        strip_header(content),
        "```",
        "",
        "### What happens next",
        "",
        *[f"- {n}" for n in nxt],
        "",
        "### Reviewer checklist",
        "",
        *[f"- [ ] {c}" for c in checklist],
        "",
        "_Created by the image factory portal. The branch is deleted automatically when the PR is merged or closed._",
    ]
    if sub.get("issue_number"):
        lines += ["", f"Closes #{sub['issue_number']}"]
    return "\n".join(lines) + "\n"


NAME_RULES = {
    "image": re.compile(r"^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$"),
    "vm": re.compile(r"^[a-z][a-z0-9-]{1,13}[a-z0-9]$"),
}


def process(sub: dict) -> dict:
    kind = sub["kind"]
    form = sub["form"]
    if kind in NAME_RULES:
        # Checked before the name is used in any path
        name = text(form, "name") or ""
        if not NAME_RULES[kind].fullmatch(name):
            raise RequestError(
                f"invalid {kind} name '{name}': use lowercase letters, digits and hyphens"
                + (" (3-15 characters, starting with a letter)" if kind == "vm" else " (3-50 characters)")
            )
    if kind == "image":
        name = text(form, "name") or ""
        path = ifc.REQUESTS_DIR / f"{name}.yaml"
        existing = load_yaml_file(path)
        doc = build_image_request(form, sub["requested_by"], existing)
        validate_image(doc, path)
        action = "update" if existing else "add"
        extra, targets = "", doc["spec"]["targets"]
    elif kind == "vm":
        name = text(form, "name") or ""
        path = VM_DIR / f"{name}.yaml"
        existing = load_yaml_file(path)
        doc = build_vm_request(form, sub["requested_by"], existing)
        validate_vm(doc, path)
        if doc["spec"].get("state") == "absent":
            if not existing:
                raise RequestError(f"VM '{name}' doesn't exist, so it can't be decommissioned")
            action = "remove"
        else:
            action = "update" if existing else "add"
        extra, targets = f" on {doc['spec']['cloud']}", [doc["spec"]["cloud"]]
    else:
        raise RequestError(f"unknown request kind '{kind}' (expected image or vm)")

    if existing:
        comparable = prune(copy.deepcopy(existing))
        new_cmp = copy.deepcopy(doc)
        comparable.get("metadata", {}).pop("requested_by", None)
        new_cmp.get("metadata", {}).pop("requested_by", None)
        if comparable == new_cmp:
            raise RequestError(f"no changes: {path.relative_to(ROOT)} already matches this request")

    content = dump_yaml(doc, sub)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    rel = str(path.relative_to(ROOT))

    title = standards.title(kind, action, name, extra)
    branch = standards.portal_branch(kind, name, sub["ref"])
    trailers = [
        f"Requested-by: @{sub['requested_by']}",
        f"Request-source: {sub['source']}",
        f"Request-ref: {sub['ref_text']}",
    ]
    commit_message = f"{title}\n\nPortal request for {rel}.\n\n" + "\n".join(trailers) + "\n"
    return {
        "kind": kind,
        "name": name,
        "action": action,
        "path": rel,
        "branch": branch,
        "title": title,
        "commit_message": commit_message,
        "body": pr_body(kind, action, name, rel, content, sub, targets),
        "labels": ["portal", f"{kind}-request"],
        "requested_by": sub["requested_by"],
        "source": sub["source"],
        "issue_number": sub.get("issue_number"),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--event", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args(argv)
    try:
        result = process(read_submission(args.event))
        result["ok"] = True
    except RequestError as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:  # noqa: BLE001 - always leave a result for the issue reply
        result = {"ok": False, "error": f"internal error ({type(exc).__name__}: {exc}); the platform team has been notified via the failed run"}
    if not result["ok"]:
        try:  # still report the issue number so the workflow can comment
            event = json.loads(args.event.read_text(encoding="utf-8"))
            result["issue_number"] = (event.get("issue") or {}).get("number")
        except (OSError, ValueError):
            pass
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if not result["ok"]:
        print(f"Request rejected: {result['error']}", file=sys.stderr)
        return 1
    print(f"{result['action']} {result['path']} -> {result['branch']}")
    print(result["title"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
