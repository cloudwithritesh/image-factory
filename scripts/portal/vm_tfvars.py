#!/usr/bin/env python3
"""
Turn vms/<name>.yaml into Terraform variables for terraform/vm/<cloud>.

  python3 scripts/portal/vm_tfvars.py vms/web-01.yaml --out terraform/vm/azure/request.auto.tfvars.json

Prints "state=<present|absent>" and "cloud=<cloud>" lines (for $GITHUB_OUTPUT).
The request is validated again first, so a hand-edited file can't skip the rules.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import process_request as pr  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("request", type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args(argv)

    path = args.request.resolve()
    doc = pr.load_yaml_file(path)
    if doc is None:
        print(f"{args.request}: not found or not a YAML mapping", file=sys.stderr)
        return 1
    try:
        pr.validate_vm(doc, path)
    except pr.RequestError as exc:
        print(exc, file=sys.stderr)
        return 1

    catalog = yaml.safe_load(pr.VM_CATALOG.read_text(encoding="utf-8"))
    meta, spec = doc["metadata"], doc["spec"]
    tfvars = {
        "name": meta["name"],
        "owner": meta["owner"],
        "environment": meta["environment"],
        "requested_by": meta.get("requested_by", "unknown"),
        "image": spec["image"],
        "image_version": spec.get("image_version", "latest"),
        "vm_size": catalog["clouds"][spec["cloud"]]["sizes"][spec["size"]],
        "region": spec["region"],
        "os_disk_gb": spec.get("os_disk_gb", catalog["os_disk_gb"]["default"]),
        "admin_username": spec.get("admin_username", pr.admin_default(catalog, spec["cloud"])),
        "ssh_public_key": spec["ssh_public_key"],
        "public_ip": bool(spec.get("public_ip", False)),
        "allowed_ssh_cidr": spec.get("allowed_ssh_cidr", ""),
    }
    args.out.write_text(json.dumps(tfvars, indent=2) + "\n", encoding="utf-8")
    print(f"state={spec.get('state', 'present')}")
    print(f"cloud={spec['cloud']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
