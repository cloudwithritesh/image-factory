#!/usr/bin/env python3
"""
Point at the likely cause of a failed step.

  triage.py LOG_FILE [LOG_FILE ...] [--summary FILE]

Scans the logs for known failure signatures and prints the matching hints
(newest match first), with a link to docs/logging.md. With --summary (or
$GITHUB_STEP_SUMMARY) it also writes a Markdown section with the hints and
the last lines of the log, so the cause is visible on the run page without
opening the raw log.

Add a signature when you fix a new class of failure (and a line in
.claude/issues.md).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# Absolute link on CI (the run summary can't resolve repo-relative paths)
DOC = (f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/blob/main/docs/logging.md"
       if os.environ.get("GITHUB_REPOSITORY") else "docs/logging.md")

# (regex, short cause, what to do, doc anchor)
SIGNATURES: list[tuple[str, str, str, str]] = [
    (r"AADSTS700213|AADSTS70021|No matching federated identity record",
     "Azure OIDC: the federated credential doesn't match this run",
     ("Check the subject (repo/environment/branch) in terraform/factory/azure; repos created after "
      "2026-07-15 use the immutable owner@id/repo@id format."), "azure-oidc"),
    (r"AuthorizationFailed|does not have authorization to perform action",
     "Azure RBAC: the CI identity lacks a role on a resource",
     "Re-run the deploy script (it grants the roles) or add the missing role assignment.", "azure-rbac"),
    (r"QuotaExceeded|exceeding approved .* quota|OperationNotAllowed.*quota",
     "Azure vCPU quota exceeded for the VM size or region",
     "Request a quota increase or pick a smaller size (azure.vm_size in the request).", "azure-quota"),
    (r"SkuNotAvailable|not available in location",
     "VM size not offered in this region",
     "Choose a size listed by `az vm list-skus -l <region>`.", "azure-quota"),
    (r"MarketplacePurchaseEligibilityFailed|ResourcePurchaseValidationFailed|accept the legal terms",
     "Marketplace image needs its terms accepted",
     "Run `az vm image terms accept --urn <publisher:offer:sku:latest>` once per subscription.", "marketplace-terms"),
    (r"Timeout waiting for WinRM|winrm.*(timeout|connection refused)|WinRMTransportError",
     "Packer couldn't reach the Windows build VM over WinRM",
     "Check the runner IP rule (allowed_inbound_ip_addresses), the 5986 listener and winrm_timeout.", "winrm"),
    (r"Timeout waiting for SSH|ssh: handshake failed|Permission denied \(publickey",
     "Packer couldn't reach the build VM over SSH",
     "Usually the runner-IP NSG rule or a hardening step that changed sshd mid-build.", "ssh"),
    (r"UNREACHABLE!",
     "Ansible lost the connection to the build target",
     "Often a reboot or an SSH/WinRM hardening control; see the task just before in ansible.log.", "ansible-unreachable"),
    (r"FAILED! =>|fatal: \[",
     "An Ansible task failed",
     "Open ansible.log in the logs artifact and search for 'fatal:'; the task name says which role.", "ansible-failed"),
    (r"No package .* available|Unable to find a match|nothing provides|E: Unable to locate package|No provider of",
     "A package isn't in the OS repositories",
     "Fix the package name for this OS family in catalog/software.yaml (packages_by_family).", "packages"),
    (r"Could not resolve host|Temporary failure in name resolution|Connection timed out|TLS handshake timeout",
     "Network error reaching a mirror or download",
     "Usually transient: re-run the job. If it repeats, check proxies/firewall rules for the build VM.", "network"),
    (r"vulnerability gate failed",
     "Grype found vulnerabilities at or above the gate",
     ("Read the scan report in the output artifact; rebuild when fixes ship or raise fail_on_severity "
      "with an approved exception."), "scan-gate"),
    (r"toomanyrequests|rate limit",
     "Registry rate limit (Docker Hub, GHCR)",
     "Use a pull-through cache/mirror for base images (catalog/os.yaml).", "rate-limit"),
    (r"Error: Failed to prepare build|Unsupported argument|An argument named .* is not expected",
     "Packer template error",
     "Run `packer validate` locally with the rendered variables (see docs/instructions.md).", "packer-template"),
    (r"Error acquiring the state lock|state blob is already locked",
     "Terraform state is locked by another run",
     "Wait for the other run; if it died, `terraform force-unlock <id>` after checking no run is active.", "tf-lock"),
]


def scan(paths: list[Path]) -> tuple[list[tuple[str, str, str, str]], str]:
    hits: list[tuple[str, str, str, str]] = []
    tail = ""
    for path in paths:
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        tail = "\n".join(lines[-40:])
        for rx, cause, fix, anchor in SIGNATURES:
            for line in reversed(lines):
                if re.search(rx, line, re.IGNORECASE):
                    hit = (cause, fix, anchor, line.strip()[:300])
                    if all(h[0] != cause for h in hits):
                        hits.append(hit)
                    break
    return hits, tail


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="+", type=Path)
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    ap.add_argument("--title", default="Failure triage")
    args = ap.parse_args(argv)

    hits, tail = scan(args.logs)
    if not hits:
        print("triage: no known failure signature found; read the log tail below.", file=sys.stderr)
    for cause, fix, anchor, line in hits:
        print(f"triage: {cause}\n  fix:  {fix}\n  docs: {DOC}#{anchor}\n  log:  {line}", file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::error title=Likely cause::{cause}. {fix}")

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(f"### {args.title}\n\n")
            if hits:
                fh.write("| Likely cause | What to do |\n|---|---|\n")
                for cause, fix, anchor, _ in hits:
                    fh.write(f"| {cause} | {fix} ([details]({DOC}#{anchor})) |\n")
            else:
                fh.write("No known failure signature matched. Download the `logs-*` artifact for the full logs.\n")
            fh.write("\n<details><summary>Last 40 log lines</summary>\n\n```\n" + tail + "\n```\n</details>\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
