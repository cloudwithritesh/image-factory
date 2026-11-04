# Branch, commit and pull request standards

Every change reaches `main` through a pull request from a **short-lived
branch**. The `pr-standards` check enforces these rules (the source of truth
is `scripts/portal/standards.py`), and `main` is protected so it can't be
bypassed.

## Branches

| Created by | Pattern | Example |
|---|---|---|
| Portal (Pages or Backstage) | `portal/<image\|vm>/<name>-<YYYYMMDD>-<ref>` | `portal/image/ubuntu-2404-base-20261104-i42` |
| People | `<type>/<short-name>` | `feat/rhel9-support`, `fix/azure-ufw-port` |

- `<ref>` is `i<issue number>` (Pages portal) or `r<run id>` (Backstage), so
  every request can be traced.
- Branches are deleted automatically when the PR is merged, and when a
  portal PR is closed without merging (`branch-cleanup` workflow).
- Don't reuse branches. One request = one branch = one PR.

## Commit messages and PR titles

[Conventional Commits](https://www.conventionalcommits.org/):
`<type>(<scope>): <subject>`, with the subject in lowercase imperative and at
most about 70 characters.

| Type | Use for |
|---|---|
| `feat` | new image, new VM, new capability |
| `fix` | bug fix |
| `chore` | updates to existing images/VMs, maintenance, version bumps |
| `docs`, `ci`, `refactor`, `test`, `perf`, `build`, `revert` | as usual |

Scopes in use: `image`, `vm`, `portal`, `packer`, `ansible`, `terraform`,
`pipeline`, `docs`.

Portal commits follow fixed templates:

| Request | Commit / PR title |
|---|---|
| New image | `feat(image): add image <name>` |
| Change an image | `chore(image): update image <name>` |
| New VM | `feat(vm): create vm <name> on <cloud>` |
| Change a VM | `chore(vm): update vm <name> on <cloud>` |
| Decommission a VM | `chore(vm): decommission vm <name>` |

and carry trailers that record who asked and where from:

```
Requested-by: @cloudwithritesh
Request-source: pages            # pages | backstage | cli
Request-ref: i42                  # or: r<last 8 digits of the run id>
```

## Commit identity

- Portal changes are committed by the portal bot: the GitHub App
  (`<app-name>[bot]`, recommended) or `github-actions[bot]`. The requester is
  in the `Requested-by` trailer and in the PR.
- People commit as themselves, using their GitHub noreply email.

## Merging

- **Squash merge only.** The squash commit uses the PR title, so `main`'s
  history is one conventional commit per PR.
- At least **one approving review from a code owner**, and nobody can
  bypass it, admins included: the **Squash and merge** button stays
  disabled until the PR is approved and the required checks pass.
  - Portal PRs are authored by the bot, so a code owner approves them.
  - GitHub never lets authors approve their own PR, so a PR you open
    yourself needs another reviewer. Add a second code owner in
    `.github/CODEOWNERS`. (Emergency only:
    `ALLOW_ADMIN_BYPASS=true scripts/bootstrap/configure-github-repo.sh`
    restores admin bypass; re-run without it afterwards.)
- **Required checks: `pr-standards`, `lint`, `plan`**, on every PR. They
  start automatically, without "Approve and run":
  - people's PRs run them on `pull_request`;
  - portal PRs opened with `GITHUB_TOKEN` get them via `workflow_dispatch`
    on the PR branch (`scripts/portal/start_pr_checks.sh`); with the
    GitHub App they run on `pull_request` like any other PR;
  - forks only need approval for first-time contributors who are new to
    GitHub.
