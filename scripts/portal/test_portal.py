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
        env = {**os.environ, "GITHUB_RUN_ID": "123456789", "GITHUB_ACTOR": "tester",
               "FACTORY_LOG_DIR": str(self.tmp / "logs")}
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


class MultiOS(unittest.TestCase):
    """Every catalog OS can be requested through the portal and rendered."""

    def setUp(self):
        self.repo = Repo()
        sys.path.insert(0, str(self.repo.root / "scripts"))
        import yaml  # noqa: PLC0415
        self.os = yaml.safe_load((self.repo.root / "catalog/os.yaml").read_text())
        self.software = yaml.safe_load((self.repo.root / "catalog/software.yaml").read_text())

    def tearDown(self):
        self.repo.close()

    def test_every_os_builds_on_enabled_targets(self):
        enabled = {"azure", "docker"}  # catalog/vm.yaml: AWS not enabled yet
        for n, (key, entry) in enumerate(self.os.items()):
            targets = sorted(set(entry["targets"]) & enabled)
            if not targets:
                continue
            software = [k for k, v in self.software.items()
                        if key in v["os"] and set(v["targets"]) & set(targets) and v["type"] != "file"]
            name = f"img-{key}"[:50]
            r = self.repo.run(issue({"kind": "image", "name": name, "owner": "platform", "os": key,
                                     "targets": targets, "software": software}, number=100 + n))
            self.assertTrue(r["ok"], (key, r))
            out = subprocess.run([sys.executable, str(self.repo.root / "scripts/imagefactory.py"), "render", name,
                                  "--out", str(self.repo.tmp / "build")], capture_output=True, text=True, check=False,
                                 env={**os.environ, "FACTORY_LOG_DIR": str(self.repo.tmp / "logs")})
            self.assertEqual(out.returncode, 0, (key, out.stderr))
            plan = json.loads(out.stdout)
            self.assertEqual(plan["packer_template"], f"packer/{entry['family']}")
            self.assertEqual(plan["pkg_family"], entry["pkg_family"])

    def test_os_specific_rejections(self):
        cases = [
            ({"os": "windows-2022", "targets": ["docker"]}, "no base image for ['docker']"),
            ({"os": "windows-2022", "targets": ["azure"], "software": ["curl"]}, "not approved for windows-2022"),
            ({"os": "rhel-9", "targets": ["azure"], "software": ["7zip"]}, "not approved for rhel-9"),
            ({"os": "rocky-9", "targets": ["azure"]}, "no base image for ['azure']"),
            ({"os": "ubi9-openshift", "targets": ["docker"], "hardening_container": "cis-l1-container"},
             "not a container profile"),
        ]
        for n, (form, expected) in enumerate(cases):
            r = self.repo.run(issue({"kind": "image", "name": f"neg-{n}x", "owner": "platform", **form}, number=200 + n))
            self.assertFalse(r["ok"], (form, r))
            self.assertIn(expected, r["error"], r["error"])

    def test_windows_image_not_offered_for_vms(self):
        r = self.repo.run(issue({"kind": "image", "name": "win-base", "owner": "platform", "os": "windows-2022",
                                 "targets": ["azure"]}, number=300))
        self.assertTrue(r["ok"], r)
        r = self.repo.run(dispatch("vm", {**VM, "image": "win-base"}))
        self.assertFalse(r["ok"], r)
        self.assertIn("Linux only", r["error"])


class Aws(unittest.TestCase):
    """EC2 self-service once AWS is enabled in catalog/vm.yaml."""

    def setUp(self):
        self.repo = Repo()
        vm_cat = self.repo.root / "catalog/vm.yaml"
        text = vm_cat.read_text()
        head, tail = text.split("\n  aws:\n", 1)
        vm_cat.write_text(head + "\n  aws:\n" + tail.replace("    enabled: false", "    enabled: true", 1))

    def tearDown(self):
        self.repo.close()

    def test_ec2_request_and_tfvars(self):
        r = self.repo.run(issue({"kind": "image", "name": "ubuntu-2404-base", "owner": "platform",
                                 "os": "ubuntu-2404", "targets": ["aws", "azure", "docker"]}, number=400))
        self.assertTrue(r["ok"], r)
        r = self.repo.run(dispatch("vm", {**VM, "name": "api-01", "cloud": "aws", "region": "ap-southeast-1",
                                          "size": "medium"}))
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["title"], "feat(vm): create vm api-01 on aws")
        out = self.repo.tmp / "tfvars.json"
        p = subprocess.run([sys.executable, str(self.repo.root / "scripts/portal/vm_tfvars.py"),
                            str(self.repo.root / "vms/api-01.yaml"), "--out", str(out)],
                           capture_output=True, text=True, check=False,
                           env={**os.environ, "FACTORY_LOG_DIR": str(self.repo.tmp / "logs")})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("cloud=aws", p.stdout)
        tfvars = json.loads(out.read_text())
        self.assertEqual(tfvars["vm_size"], "t3.medium")
        self.assertEqual(tfvars["admin_username"], "cloudadmin")
        self.assertEqual(set(tfvars), {"name", "owner", "environment", "requested_by", "image", "image_version",
                                       "vm_size", "region", "os_disk_gb", "admin_username", "ssh_public_key",
                                       "public_ip", "allowed_ssh_cidr"})

    def test_ec2_needs_an_aws_image(self):
        r = self.repo.run(dispatch("vm", {**VM, "name": "api-02", "cloud": "aws", "region": "ap-southeast-1"}))
        self.assertFalse(r["ok"], r)
        self.assertIn("isn't built for aws", r["error"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
