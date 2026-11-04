#!/usr/bin/env python3
"""Validate every image request and VM request in the repo (used by PR checks)."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import imagefactory as ifc  # noqa: E402
import process_request as pr  # noqa: E402


def main() -> int:
    failed = 0
    if ifc.cmd_validate(type("Args", (), {"requests": []})()) != 0:
        failed += 1
    for path in sorted(pr.VM_DIR.glob("*.yaml")):
        try:
            doc = pr.load_yaml_file(path)
            if doc is None:
                raise pr.RequestError("not a YAML mapping")
            pr.validate_vm(doc, path)
            print(f"ok      {path.relative_to(pr.ROOT)}")
        except pr.RequestError as exc:
            failed += 1
            print(f"INVALID {path.relative_to(pr.ROOT)}: {exc}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
