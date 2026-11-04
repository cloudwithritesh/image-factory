#!/usr/bin/env python3
"""
Generate the portal front ends from the catalogs, so the forms always offer
exactly what the request processor accepts.

  python3 scripts/portal/render.py pages --out <dir>   data/catalog.json for the GitHub Pages portal
  python3 scripts/portal/render.py backstage           portal/backstage/templates/*/template.yaml
  python3 scripts/portal/render.py backstage --check   fail if the committed templates are stale (CI)

The repository (owner/name) comes from --repo, $GITHUB_REPOSITORY or the
git remote.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import imagefactory as ifc  # noqa: E402
import process_request as pr  # noqa: E402

BACKSTAGE_DIR = ROOT / "portal" / "backstage" / "templates"
SEVERITIES = ["negligible", "low", "medium", "high", "critical"]


class Dumper(yaml.SafeDumper):
    """No anchors, and lists indented under their key (matches .yamllint.yml)."""

    def ignore_aliases(self, data):  # noqa: ARG002
        return True

    def increase_indent(self, flow=False, indentless=False):  # noqa: ARG002
        return super().increase_indent(flow, False)


def detect_repo(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    try:
        url = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.strip()
        m = re.search(r"github\.com[:/]([^/]+/[^/.]+)", url)
        if m:
            return m.group(1)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return "OWNER/image-factory"


def collect(repo: str) -> dict:
    catalogs = ifc.load_catalogs()
    vm_catalog = yaml.safe_load(pr.VM_CATALOG.read_text(encoding="utf-8"))
    images = {}
    for path in sorted(ifc.REQUESTS_DIR.glob("*.yaml")):
        doc = pr.load_yaml_file(path) or {}
        meta, spec = doc.get("metadata", {}), doc.get("spec", {})
        if meta.get("name"):
            images[meta["name"]] = {
                "owner": meta.get("owner", ""),
                "description": meta.get("description", ""),
                "os": spec.get("os", ""),
                "targets": spec.get("targets", []),
                "hardening": spec.get("hardening", {}),
                "software": spec.get("software", []),
                "promotion": spec.get("promotion", "auto"),
                "fail_on_severity": (spec.get("scan") or {}).get("fail_on_severity", "critical"),
            }
    vms = {}
    for path in sorted(pr.VM_DIR.glob("*.yaml")):
        doc = pr.load_yaml_file(path) or {}
        meta, spec = doc.get("metadata", {}), doc.get("spec", {})
        if meta.get("name"):
            vms[meta["name"]] = {
                "owner": meta.get("owner", ""), "environment": meta.get("environment", ""),
                "cloud": spec.get("cloud", ""), "image": spec.get("image", ""),
                "size": spec.get("size", ""), "state": spec.get("state", "present"),
            }
    owner, name = repo.split("/", 1)
    return {
        "repo": {"owner": owner, "name": name, "full_name": repo, "url": f"https://github.com/{repo}"},
        "os": {k: {"display_name": v["display_name"], "family": v["family"], "targets": sorted(v["targets"])}
               for k, v in catalogs["os"].items()},
        "hardening": catalogs["hardening"],
        "software": {k: {"description": v.get("description", k), "type": v["type"],
                         "os": v.get("os", []), "targets": v.get("targets", [])}
                     for k, v in catalogs["software"].items()},
        "images": images,
        "vms": vms,
        "vm_catalog": vm_catalog,
        "enabled_targets": pr.enabled_targets(),
        "severities": SEVERITIES,
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


# --------------------------------------------------------------------------- #
# Backstage templates
# --------------------------------------------------------------------------- #
def dispatch_step(repo: str, kind: str) -> dict:
    owner, name = repo.split("/", 1)
    return {
        "id": "request",
        "name": "Open a pull request",
        "action": "github:actions:dispatch",
        "input": {
            "repoUrl": f"github.com?owner={owner}&repo={name}",
            "workflowId": "portal-request.yml",
            "branchOrTagName": "main",
            "workflowInputs": {
                "kind": kind,
                "payload": "${{ parameters | dump }}",
                "requested_by": "${{ user.entity.metadata.name if user.entity else 'guest' }}",
                "source": "backstage",
            },
        },
    }


def output_links(repo: str, kind: str) -> dict:
    url = f"https://github.com/{repo}"
    return {"links": [
        {"title": "Your request's pull request", "icon": "github",
         "url": f"{url}/pulls?q=is%3Apr+label%3A{kind}-request+sort%3Acreated-desc"},
        {"title": "Request processing runs", "icon": "dashboard",
         "url": f"{url}/actions/workflows/portal-request.yml"},
    ]}


def image_template(data: dict) -> dict:
    repo = data["repo"]["full_name"]
    vm_profiles = sorted({p for os_cfg in data["hardening"].values() for p in os_cfg.get("vm", {}).get("profiles", {})})
    ct_profiles = sorted({p for os_cfg in data["hardening"].values() for p in os_cfg.get("container", {}).get("profiles", {})})
    software = sorted(data["software"])
    return {
        "apiVersion": "scaffolder.backstage.io/v1beta3",
        "kind": "Template",
        "metadata": {
            "name": "golden-image-request",
            "title": "Request or change a golden image",
            "description": "Ask the image factory for a new golden image, or change an existing one "
                           "(use its name). Creates a pull request for review.",
            "tags": ["image-factory", "golden-image", "packer"],
            "annotations": {"backstage.io/source-location": f"url:https://github.com/{repo}/tree/main/"},
        },
        "spec": {
            "owner": "group:default/platform-engineering",
            "type": "golden-image",
            "parameters": [
                {
                    "title": "Image",
                    "required": ["name", "owner", "os", "targets"],
                    "properties": {
                        "name": {"title": "Image name", "type": "string",
                                 "pattern": "^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$",
                                 "ui:help": "Lowercase, digits and hyphens. Existing images: "
                                            + (", ".join(sorted(data["images"])) or "none yet")
                                            + ". Use an existing name to change that image."},
                        "owner": {"title": "Owning team", "type": "string", "ui:field": "OwnerPicker",
                                  "ui:options": {"catalogFilter": {"kind": "Group"}, "allowArbitraryValues": True}},
                        "description": {"title": "Description", "type": "string", "maxLength": 250},
                        "os": {"title": "Operating system", "type": "string",
                               "enum": sorted(data["os"]),
                               "enumNames": [data["os"][k]["display_name"] for k in sorted(data["os"])]},
                        "targets": {"title": "Targets", "type": "array", "uniqueItems": True, "minItems": 1,
                                    "items": {"type": "string", "enum": data["enabled_targets"]},
                                    "ui:widget": "checkboxes"},
                    },
                },
                {
                    "title": "Hardening and software",
                    "properties": {
                        "hardening_vm": {"title": "VM hardening profile", "type": "string", "enum": vm_profiles,
                                         "ui:help": "Leave empty for the OS default (CIS Level 1)."},
                        "hardening_container": {"title": "Container hardening profile", "type": "string",
                                                "enum": ct_profiles},
                        "software": {"title": "Approved software", "type": "array", "uniqueItems": True,
                                     "items": {"type": "string", "enum": software,
                                               "enumNames": [f"{k}: {data['software'][k]['description']}" for k in software]},
                                     "ui:widget": "checkboxes"},
                    },
                },
                {
                    "title": "Release",
                    "properties": {
                        "promotion": {"title": "Promotion", "type": "string", "enum": ["auto", "manual"],
                                      "enumNames": ["Automatic after the scan passes", "Manual approval"],
                                      "default": "auto"},
                        "fail_on_severity": {"title": "Block images with vulnerabilities at or above",
                                             "type": "string", "enum": SEVERITIES, "default": "critical"},
                    },
                },
            ],
            "steps": [dispatch_step(repo, "image")],
            "output": output_links(repo, "image"),
        },
    }


def vm_template(data: dict) -> dict:
    repo = data["repo"]["full_name"]
    cat = data["vm_catalog"]
    clouds = sorted(k for k, v in cat["clouds"].items() if v.get("enabled"))
    images = sorted(n for n, i in data["images"].items() if set(i["targets"]) & set(clouds)) or ["none-yet"]
    regions = sorted({r for c in clouds for r in cat["clouds"][c]["regions"]})
    sizes = ["small", "medium", "large"]
    size_names = [f"{s} ({', '.join(cat['clouds'][c]['sizes'][s] for c in clouds)})" for s in sizes]
    return {
        "apiVersion": "scaffolder.backstage.io/v1beta3",
        "kind": "Template",
        "metadata": {
            "name": "vm-request",
            "title": "Create, change or decommission a VM",
            "description": "Get a VM built from an approved golden image. Creates a pull request; "
                           "the VM is provisioned when it's approved and merged.",
            "tags": ["image-factory", "vm", "self-service"],
        },
        "spec": {
            "owner": "group:default/platform-engineering",
            "type": "vm",
            "parameters": [
                {
                    "title": "VM",
                    "required": ["name", "owner", "environment", "state"],
                    "properties": {
                        "state": {"title": "Action", "type": "string", "enum": ["present", "absent"],
                                  "enumNames": ["Create or update", "Decommission"], "default": "present"},
                        "name": {"title": "VM name", "type": "string", "pattern": "^[a-z][a-z0-9-]{1,13}[a-z0-9]$",
                                 "ui:help": "3-15 characters. Existing VMs: "
                                            + (", ".join(sorted(data["vms"])) or "none yet")},
                        "owner": {"title": "Owning team", "type": "string", "ui:field": "OwnerPicker",
                                  "ui:options": {"catalogFilter": {"kind": "Group"}, "allowArbitraryValues": True}},
                        "environment": {"title": "Environment", "type": "string", "enum": cat["environments"]},
                        "description": {"title": "Purpose", "type": "string", "maxLength": 250},
                    },
                },
                {
                    "title": "Image and size",
                    "properties": {
                        "cloud": {"title": "Cloud", "type": "string", "enum": clouds, "default": clouds[0] if clouds else ""},
                        "image": {"title": "Golden image", "type": "string", "enum": images},
                        "image_version": {"title": "Image version", "type": "string", "default": "latest",
                                          "ui:help": "latest = newest promoted version"},
                        "size": {"title": "Size", "type": "string", "enum": sizes, "enumNames": size_names,
                                 "default": "small"},
                        "region": {"title": "Region", "type": "string", "enum": regions,
                                   "default": regions[0] if regions else ""},
                        "os_disk_gb": {"title": "OS disk (GB)", "type": "integer",
                                       "minimum": cat["os_disk_gb"]["min"], "maximum": cat["os_disk_gb"]["max"],
                                       "default": cat["os_disk_gb"]["default"]},
                    },
                },
                {
                    "title": "Access",
                    "properties": {
                        "admin_username": {"title": "Admin user", "type": "string",
                                           "default": cat["admin_username_default"]},
                        "ssh_public_key": {"title": "SSH public key", "type": "string", "ui:widget": "textarea",
                                           "ui:help": "Paste the whole line from ~/.ssh/id_ed25519.pub"},
                        "public_ip": {"title": "Public IP", "type": "boolean", "default": False},
                        "allowed_ssh_cidr": {"title": "Allowed SSH range (with public IP)", "type": "string",
                                             "ui:help": "Your office or VPN range, e.g. 203.0.113.0/24"},
                    },
                },
            ],
            "steps": [dispatch_step(repo, "vm")],
            "output": output_links(repo, "vm"),
        },
    }


def backstage_files(data: dict) -> dict[Path, str]:
    header = ("# GENERATED by scripts/portal/render.py from catalog/*.yaml and requests/.\n"
              "# Don't edit; change the catalogs and run: python3 scripts/portal/render.py backstage\n")
    files = {}
    for sub, tpl in (("image-request", image_template(data)), ("vm-request", vm_template(data))):
        files[BACKSTAGE_DIR / sub / "template.yaml"] = header + yaml.dump(
            tpl, Dumper=Dumper, sort_keys=False, width=120, allow_unicode=True)
    return files


# --------------------------------------------------------------------------- #
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pages")
    p.add_argument("--out", type=Path, default=ROOT / "portal" / "pages")
    b = sub.add_parser("backstage")
    b.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    data = collect(detect_repo(args.repo))
    if args.cmd == "pages":
        out = args.out / "data"
        out.mkdir(parents=True, exist_ok=True)
        (out / "catalog.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {out / 'catalog.json'} ({len(data['images'])} images, {len(data['vms'])} VMs)")
        return 0

    stale = []
    for path, content in backstage_files(data).items():
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if args.check:
            if current != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            print(f"wrote {path.relative_to(ROOT)}")
    if stale:
        print("Backstage templates are out of date; run: python3 scripts/portal/render.py backstage\n  "
              + "\n  ".join(stale), file=sys.stderr)
        return 1
    if args.check:
        print("Backstage templates are up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
