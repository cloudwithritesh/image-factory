#!/usr/bin/env python3
"""
Tests for the portal request processor and naming standards.
Runs against a throwaway copy of the repo, so nothing here is modified.

  python3 scripts/portal/test_portal.py
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import standards  # noqa: E402

KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@example"
MARKER = "<!-- portal-request:v1 -->"
FIXTURE_IMAGE = """apiVersion: imagefactory/v1
kind: ImageRequest
metadata:
  name: ubuntu-2404-base
  owner: platform-engineering
  requested_by: ritesh
spec:
  os: ubuntu-2404
  targets:
    - azure
    - docker
  hardening:
    vm: cis-l1
    container: cis-l1-container
  software:
    - ca-certificates
    - curl
  scan:
    fail_on_severity: critical
    only_fixed: true
  promotion: auto
"""


class Repo:
    """A disposable copy of the repository."""

    def __init__(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="portal-test-"))
        self.root = self.tmp / "repo"
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns(".git", "build", ".galaxy", "node_modules"))
        # Deterministic inventory: one known image, no VMs, whatever the repo holds
        for folder in ("requests", "vms"):
            shutil.rmtree(self.root / folder, ignore_errors=True)
            (self.root / folder).mkdir()
        (self.root / "requests/ubuntu-2404-base.yaml").write_text(FIXTURE_IMAGE)

    def run(self, event: dict) -> dict:
        ev, out = self.tmp / "event.json", self.tmp / "out.json"
        ev.write_text(json.dumps(event))
        env = {**os.environ, "GITHUB_RUN_ID": "123456789", "GITHUB_ACTOR": "tester"}
        subprocess.run([sys.executable, str(self.root / "scripts/portal/process_request.py"),
                        "--event", str(ev), "--out", str(out)], env=env, capture_output=True, check=False)
        return json.loads(out.read_text())

    def close(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


def issue(form: dict, association: str = "OWNER", number: int = 7) -> dict:
    body = f"Portal request\n\n{MARKER}\n\n```json\n{json.dumps(form)}\n```\n"
    return {"issue": {"number": number, "body": body, "user": {"login": "alice"}, "author_association": association}}


def dispatch(kind: str, form: dict, who: str = "user:default/bob") -> dict:
    return {"inputs": {"kind": kind, "payload": json.dumps(form), "requested_by": who, "source": "backstage"}}


VM = {"name": "web-01", "owner": "group:default/web-team", "environment": "dev", "cloud": "azure",
      "image": "ubuntu-2404-base", "size": "small", "region": "southeastasia", "ssh_public_key": KEY}


class Standards(unittest.TestCase):
    def test_branch_rules(self):
        ok = ["portal/image/ubuntu-2404-base-20261104-i42", "portal/vm/web-01-20261104-r87654321",
              "feat/rhel9-support", "fix/azure-ufw-port", "dependabot/pip/x"]
        bad = ["main", "ritesh-patch-1", "feature/x", "portal/image/x", "feat/Upper"]
        for b in ok:
            self.assertEqual(standards.check(b, "feat(image): add image x", []), [], b)
        for b in bad:
            self.assertTrue(standards.check(b, "feat(image): add image x", []), b)

    def test_titles_and_commits(self):
        self.assertEqual(standards.check("feat/xy", "chore(vm): decommission vm web-01", ["fix: y", "Merge branch 'main'"]), [])
        self.assertTrue(standards.check("feat/xy", "Update stuff", []))
        self.assertTrue(standards.check("feat/xy", "feat: ok", ["wip"]))


class Formatting(unittest.TestCase):
    def test_written_yaml_passes_yamllint_style(self):
        repo = Repo()
        try:
            r = repo.run(dispatch("vm", VM))
            self.assertTrue(r["ok"], r)
            text = (repo.root / "vms/web-01.yaml").read_text()
            r = repo.run(issue({"kind": "image", "name": "ubuntu-2404-base", "software": ["curl", "jq"]}))
            self.assertTrue(r["ok"], r)
            image = (repo.root / "requests/ubuntu-2404-base.yaml").read_text()
            # lists are indented under their key (yamllint default "indentation" rule)
            self.assertIn("  targets:\n    - azure", image)
            self.assertNotIn("\n  - ", text)
        finally:
            repo.close()


class Processor(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()

    def tearDown(self):
        self.repo.close()

    def test_image_update_from_pages(self):
        r = self.repo.run(issue({"kind": "image", "name": "ubuntu-2404-base", "os": "ubuntu-2404",
                                 "targets": ["azure", "docker"], "software": ["curl"], "promotion": "manual"}))
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["action"], "update")
        self.assertEqual(r["title"], "chore(image): update image ubuntu-2404-base")
        self.assertRegex(r["branch"], r"^portal/image/ubuntu-2404-base-\d{8}-i7$")
        self.assertIn("Requested-by: @alice", r["commit_message"])
        self.assertIn("Closes #7", r["body"])
        self.assertEqual(r["labels"], ["portal", "image-request"])
        self.assertEqual(standards.check(r["branch"], r["title"], [r["title"]]), [])

    def test_new_image(self):
        r = self.repo.run(issue({"kind": "image", "name": "ubuntu-2404-web", "owner": "web", "os": "ubuntu-2404",
                                 "targets": ["azure"], "software": ["curl", "node-exporter"]}))
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["title"], "feat(image): add image ubuntu-2404-web")
        self.assertTrue((self.repo.root / "requests/ubuntu-2404-web.yaml").is_file())

    def test_rejections(self):
        cases = [
            (issue({"kind": "image", "name": "x-y-z"}, association="NONE"), "owners, members and collaborators"),
            (issue({"kind": "image", "name": "../../etc/passwd"}), "invalid image name"),
            (issue({"kind": "image", "name": "abc", "owner": "web", "os": "ubuntu-2404", "targets": ["aws"]}), "isn't set up"),
            (issue({"kind": "image", "name": "abc", "owner": "web", "os": "ubuntu-2404", "targets": ["docker"],
                    "software": ["monitoring-basics"]}), "supports none of the requested targets"),
            (issue({"kind": "image", "name": "ubuntu-2404-base"}), "no changes"),
            ({"issue": {"number": 1, "body": "hello", "user": {"login": "a"}, "author_association": "OWNER"}}, "missing marker"),
            (dispatch("vm", {**VM, "public_ip": True, "allowed_ssh_cidr": "0.0.0.0/0"}), "too broad"),
            (dispatch("vm", {**VM, "ssh_public_key": "-----BEGIN OPENSSH PRIVATE KEY-----"}), "valid SSH public key"),
            (dispatch("vm", {**VM, "cloud": "aws", "region": "ap-southeast-1"}), "isn't enabled"),
            (dispatch("vm", {**VM, "name": "web-99", "state": "absent"}), "doesn't exist"),
            (dispatch("other", {}), "unknown request kind"),
        ]
        for event, expected in cases:
            r = self.repo.run(event)
            self.assertFalse(r["ok"], (event, r))
            self.assertIn(expected, r["error"], r["error"])

    def test_vm_lifecycle_from_backstage(self):
        r = self.repo.run(dispatch("vm", VM))
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["title"], "feat(vm): create vm web-01 on azure")
        self.assertEqual(r["requested_by"], "bob")  # user:default/ prefix removed
        self.assertRegex(r["branch"], r"^portal/vm/web-01-\d{8}-r23456789$")
        text = (self.repo.root / "vms/web-01.yaml").read_text()
        self.assertIn("owner: web-team", text)  # group:default/ prefix removed

        r = self.repo.run(dispatch("vm", {"name": "web-01", "size": "medium"}))
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["title"], "chore(vm): update vm web-01 on azure")

        r = self.repo.run(dispatch("vm", {"name": "web-01", "state": "absent"}))
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["title"], "chore(vm): decommission vm web-01")
        self.assertIn("**decommissions**", r["body"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
