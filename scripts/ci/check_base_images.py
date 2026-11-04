#!/usr/bin/env python3
"""
Check that every base image in catalog/os.yaml exists and report what it
currently resolves to, so a renamed SKU or a changed AMI naming scheme is
caught before an image build fails.

  python3 scripts/ci/check_base_images.py [--clouds azure,aws] [--location southeastasia] [--region ap-southeast-1]

Uses the az and aws CLIs with whatever login they have (OIDC in CI, your
own login locally). Clouds without a login are skipped with a warning.
Docker bases are not checked here (the plan job's packer validate and the
build pull them). Exit code 1 when any checked image is missing.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from factorylog import fields, get_logger  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
log = get_logger("check-base-images")


def run(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return p.returncode, (p.stdout if p.returncode == 0 else p.stderr).strip()


def logged_in(cloud: str) -> bool:
    if cloud == "azure":
        return bool(shutil.which("az")) and run(["az", "account", "show", "-o", "none"])[0] == 0
    return bool(shutil.which("aws")) and run(["aws", "sts", "get-caller-identity"])[0] == 0


def check_azure(t: dict, location: str) -> tuple[bool, str]:
    rc, out = run(["az", "vm", "image", "list", "--all", "-l", location, "-o", "json",
                   "--publisher", t["image_publisher"], "--offer", t["image_offer"], "--sku", t["image_sku"]])
    if rc != 0:
        return False, out.splitlines()[-1] if out else "az failed"
    exact = [i for i in json.loads(out) if i["sku"].lower() == t["image_sku"].lower()
             and i["offer"].lower() == t["image_offer"].lower()]
    if not exact:
        return False, "no image versions"
    newest = sorted(exact, key=lambda i: [int(x) if x.isdigit() else 0 for x in i["version"].split(".")])[-1]
    return True, newest["urn"]


def check_aws(t: dict, region: str) -> tuple[bool, str]:
    rc, out = run(["aws", "ec2", "describe-images", "--region", region, "--owners", *t["source_ami_owners"],
                   "--filters", f"Name=name,Values={t['source_ami_filter_name']}",
                   "Name=architecture,Values=x86_64", "Name=state,Values=available",
                   "--query", "sort_by(Images, &CreationDate)[-1].[ImageId,Name,CreationDate]", "--output", "json"])
    if rc != 0:
        return False, out.splitlines()[-1] if out else "aws failed"
    found = json.loads(out)
    if not found:
        return False, "no AMI matches the filter"
    return True, f"{found[0]} {found[1]} ({found[2][:10]})"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clouds", default="azure,aws")
    ap.add_argument("--location", default=os.environ.get("PKR_VAR_azure_gallery_location") or "southeastasia")
    ap.add_argument("--region", default=os.environ.get("PKR_VAR_aws_region") or "ap-southeast-1")
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    args = ap.parse_args(argv)

    catalog = yaml.safe_load((ROOT / "catalog" / "os.yaml").read_text(encoding="utf-8"))
    clouds = [c for c in args.clouds.split(",") if c]
    active = {c: logged_in(c) for c in clouds}
    for c, ok in active.items():
        if not ok:
            log.warning(f"no {c} login; skipping {c} base images")

    rows, failed = [], 0
    for key, entry in catalog.items():
        for cloud in clouds:
            t = entry.get("targets", {}).get(cloud)
            if not t or not active[cloud]:
                continue
            ok, detail = check_azure(t, args.location) if cloud == "azure" else check_aws(t, args.region)
            failed += not ok
            rows.append((key, cloud, "ok" if ok else "MISSING", detail))
            (log.info if ok else log.error)(f"{key} / {cloud}: {detail}",
                                            extra=fields(event="base_image", os=key, cloud=cloud, ok=ok))
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write("### Base images\n\n| OS | Cloud | Status | Resolves to |\n|---|---|---|---|\n")
            fh.writelines(f"| {k} | {c} | {s} | `{d}` |\n" for k, c, s, d in rows)
    print(json.dumps([{"os": k, "cloud": c, "status": s, "image": d} for k, c, s, d in rows], indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
