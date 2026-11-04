#!/usr/bin/env python3
"""
Repository naming standards: one definition used by the request processor
(to create names) and by the pr-standards check (to enforce them).

  Branches        portal/<kind>/<name>-<YYYYMMDD>-<id>     created by the portal
                  <type>/<slug>                            created by people
  Commits, PRs    <type>(<scope>): <subject>               Conventional Commits

  python3 scripts/portal/standards.py check --branch B --title T [--commits-file F]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys

TYPES = ("feat", "fix", "chore", "docs", "ci", "refactor", "test", "perf", "build", "revert")
PORTAL_KINDS = ("image", "vm")

BRANCH_RE = re.compile(
    r"^(?:"
    r"portal/(?:image|vm)/[a-z0-9][a-z0-9-]{1,60}-\d{8}-[a-z0-9]{2,12}"  # portal-generated
    r"|(?:" + "|".join(TYPES) + r")/[a-z0-9][a-z0-9._-]{1,60}"          # human branches
    r"|dependabot/.+|renovate/.+"                                         # dependency bots
    r")$"
)
TITLE_RE = re.compile(r"^(?:" + "|".join(TYPES) + r")(?:\([a-z0-9][a-z0-9-]*\))?!?: \S.{0,71}$")
MERGE_RE = re.compile(r"^(Merge (branch|pull request|remote-tracking branch) |Revert \")")

BOT_IDENTITIES = {
    # Commit identity used for portal changes, per token type
    "app": "image-factory-bot",  # GitHub App (recommended); email set from the app's user id
    "actions": ("github-actions[bot]", "41898282+github-actions[bot]@users.noreply.github.com"),
}


def portal_branch(kind: str, name: str, ref: str, today: dt.date | None = None) -> str:
    """portal/<kind>/<name>-<YYYYMMDD>-<ref>; ref is the issue number or run id."""
    if kind not in PORTAL_KINDS:
        raise ValueError(f"unknown kind {kind}")
    day = (today or dt.datetime.now(dt.timezone.utc).date()).strftime("%Y%m%d")
    ref = re.sub(r"[^a-z0-9]", "", ref.lower())[:12] or "x"
    branch = f"portal/{kind}/{name}-{day}-{ref}"
    assert BRANCH_RE.match(branch), branch
    return branch


def title(kind: str, action: str, name: str, extra: str = "") -> str:
    """Conventional Commit subject for a portal change."""
    verbs = {
        ("image", "add"): ("feat", f"add image {name}"),
        ("image", "update"): ("chore", f"update image {name}"),
        ("vm", "add"): ("feat", f"create vm {name}{extra}"),
        ("vm", "update"): ("chore", f"update vm {name}{extra}"),
        ("vm", "remove"): ("chore", f"decommission vm {name}"),
    }
    ctype, subject = verbs[(kind, action)]
    text = f"{ctype}({kind}): {subject}"
    assert TITLE_RE.match(text), text
    return text


def check(branch: str, pr_title: str, commits: list[str]) -> list[str]:
    errors = []
    if not BRANCH_RE.match(branch):
        errors.append(
            f"branch '{branch}' doesn't follow the standard. Use <type>/<short-name> "
            f"with type one of {', '.join(TYPES)} (e.g. feat/add-rhel9), or create the "
            "change through the portal."
        )
    if not TITLE_RE.match(pr_title):
        errors.append(
            f"PR title '{pr_title}' isn't a Conventional Commit. Use '<type>(<scope>): <subject>', "
            "e.g. 'feat(image): add rhel-9 base image' (subject up to 72 characters)."
        )
    for subject in commits:
        if MERGE_RE.match(subject):
            continue
        if not TITLE_RE.match(subject):
            errors.append(f"commit '{subject}' isn't a Conventional Commit")
    return errors


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--branch", required=True)
    c.add_argument("--title", required=True)
    c.add_argument("--commits-file", help="JSON list of commit subjects")
    args = ap.parse_args(argv)

    commits: list[str] = []
    if args.commits_file:
        with open(args.commits_file, encoding="utf-8") as fh:
            commits = json.load(fh)
    errors = check(args.branch, args.title, commits)
    if errors:
        print("Naming standards not met (see docs/standards.md):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"ok: branch '{args.branch}', title '{args.title}', {len(commits)} commit(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
