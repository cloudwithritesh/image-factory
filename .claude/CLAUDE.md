# Image factory: guide for Claude (and new team members)

Read this before changing the repo. It is the short version of
`docs/architecture.md`, `docs/workflow.md` and `docs/instructions.md`, plus
the conventions and traps that aren't obvious from the code. Lessons from
past failures are in @issues.md; read the relevant section before touching
that area, and add an entry when you fix something new.

## What this is

A golden-image factory and self-service portal, all driven by pull requests:

- **Image requests** (`requests/<name>.yaml`) → Packer + Ansible build for
  AWS, Azure and Docker → SBOM (Syft) → vulnerability gate (Grype) →
  promotion (Azure gallery `latest`, GHCR tags, AWS SSM).
- **VM requests** (`vms/<name>.yaml`) → Terraform, one state per VM, from
  the latest *approved* image (Linux only for now).
- **Portals** (GitHub Pages; Backstage locally) never write to `main`: they
  open a PR on a short-lived branch that a code owner approves.
- Live: GitHub Actions + Azure (`southeastasia`) + GHCR. AWS (`ap-southeast-1`)
  is implemented end to end (AMIs + EC2) and goes live when
  `scripts/bootstrap/deploy-github-aws.sh` has run and its PR is merged.
  GitLab is implemented but not switched on.
- **OS policy:** the catalog offers each vendor's latest stable major
  release and the previous one (`release: latest | previous`). When a new
  major ships, add it as latest, demote the old one, retire N-2.

## Map

| Path | What |
|---|---|
| `catalog/os.yaml` | every OS: vendor, `family` (linux/windows → `packer/<family>`), `pkg_family` (debian/redhat/suse/windows), `status`, base image per target |
| `catalog/hardening.yaml` | profiles per OS and kind (vm/container) → role + vars file + skip tags |
| `catalog/software.yaml` | approved software: `package` (apt/dnf/zypper), `url`, `file`, `choco` |
| `catalog/vm.yaml` | VM sizes, regions, environments, which clouds are enabled |
| `scripts/imagefactory.py` | validate / render / plan; the single source of request rules |
| `scripts/portal/` | `process_request.py` (form → YAML, all validation), `standards.py` (branch/title rules), `open_pr.sh`, `start_pr_checks.sh`, `render.py` (portal data + Backstage templates), `test_portal.py` |
| `scripts/ci/` | `log.sh` (logging), `lib.sh` (cloud login, helpers), `packer-build.sh`, `packer-validate.sh`, `scan.sh`, `promote.sh`, `triage.py` |
| `scripts/linux/bootstrap.sh`, `scripts/vm/`, `scripts/container/`, `scripts/windows/` | run *on the build target* |
| `packer/linux`, `packer/windows` | one template per OS family; build block named after the family |
| `ansible/image.yml`, `ansible/windows.yml` | provisioning; roles `base`, `software`, `baseline`, `openshift`; CIS roles from `requirements.yml` |
| `terraform/factory/azure` | gallery, build RG, VM landing zone, Entra app + federated credentials |
| `terraform/vm/azure`, `terraform/vm/aws` | one VM / one EC2 instance (same request fields) |
| `terraform/factory/aws` | OIDC roles (packer, vm-provision), KMS, build VPC, workload VPC, instance profile |
| `.github/workflows/` | `image-factory`, `portal-request`, `pr-standards`, `vm-provision`, `portal-pages`, `branch-cleanup`, `base-images` |

## Commands

```bash
python3 scripts/imagefactory.py validate                  # all requests
python3 scripts/imagefactory.py render requests/<x>.yaml  # build/<x>/ inputs
python3 scripts/portal/test_portal.py                     # portal + every-OS render tests
python3 scripts/portal/validate_all.py
python3 scripts/portal/render.py backstage                # regenerate templates (commit them!)
python3 scripts/portal/render.py backstage --check
python3 scripts/ci/check_base_images.py                   # needs az/aws logins
yamllint -c .yamllint.yml .
shellcheck scripts/ci/*.sh scripts/vm/*.sh scripts/linux/*.sh scripts/container/*.sh scripts/bootstrap/*.sh scripts/portal/*.sh
actionlint .github/workflows/*.yml
cd ansible && ansible-galaxy role install -r requirements.yml -p .galaxy/roles \
  && ansible-playbook image.yml --syntax-check -i localhost, \
  && ansible-playbook windows.yml --syntax-check -i localhost, \
  && ansible-lint --offline image.yml windows.yml roles/
```

`packer validate` and `terraform validate` need HashiCorp downloads; if
those are blocked where you run, format-check HCL with `tofu fmt` on `.tf`
copies and parse with `python-hcl2`, and let CI validate for real.

Testing Ansible without a cloud: extract an Ubuntu rootfs (debootstrap) and
run `ansible-playbook image.yml -c community.general.chroot -i <rootfs>,`
with `-e packer_source_type=docker` and the rendered `ansible-container.json`.
Never run VM-kind tasks in a chroot (sysctl/modprobe would change the host).

## Conventions

- **Branches:** `<type>/<slug>` for people (`feat/multi-os`), portal:
  `portal/<image|vm>/<name>-<YYYYMMDD>-<ref>` (`i<issue>` or `r<run>`).
- **Titles and commits:** Conventional Commits, `type(scope): subject`,
  ≤ 72 chars after the type. Squash merge uses the PR title.
- **Merging:** 1 code-owner approval, required checks `pr-standards`,
  `lint`, `plan`; no bypass. Authors can't approve their own PRs.
- **Catalog first:** anything a user can choose lives in `catalog/`; code
  reads it, the portal renders it. After any catalog or request change run
  `render.py backstage` and commit the templates, or `lint` fails.
- **Every hardening deviation** goes in both `ansible/vars/hardening/` and
  `docs/hardening-exceptions.md`.
- **Pin everything:** tool versions in `ci/versions.env` (checksum-verified
  downloads), Python in `ci/requirements-core.txt`, roles by tag, Packer
  plugins by `~>`.
- **Logging:** shell scripts source `scripts/ci/lib.sh` (which sources
  `log.sh`), set `FACTORY_LOG_COMPONENT`, call `log_trap_errors`, wrap real
  work in `run_step`, and write tool output to `$FACTORY_LOG_DIR`. Python
  uses `factorylog.get_logger()`. stdout is for data, logs go to stderr.
  Add a `triage.py` signature for every new failure class you fix.
- **Writing style for docs and messages:** plain, short sentences; tables
  for reference; no marketing words.

## Security rules (non-negotiable)

- No cloud secrets anywhere: OIDC only (GitHub → Entra ID / AWS IAM).
  Never ask the user to paste credentials; have them run scripts with their
  own `gh` / `az` logins (`scripts/bootstrap/`).
- Untrusted input (issue bodies, dispatch payloads) is read from the event
  file, never interpolated into shell; names are pattern-checked before use
  in paths; issues are accepted only from OWNER/MEMBER/COLLABORATOR.
- Build VMs accept SSH/WinRM only from the runner's IP. Workload VMs are
  private unless a narrow CIDR is requested.
- Images reach `latest` only after the scan gate; VMs refuse unapproved
  versions (Terraform postcondition on `Status=approved`).
- This repo is **public**: debug logs and artifacts are readable by anyone
  with a GitHub account. Debug artifacts are kept 7 days.

## Environment facts

- Repo `cloudwithritesh/image-factory` (ID 1444290366, owner ID 207864571).
  Created after 2026-07-15 → OIDC subjects use the immutable form
  `repo:cloudwithritesh@207864571/image-factory@1444290366:...`.
- Azure: subscription `rhegdecloud-mvp-subscription`, region
  `southeastasia`, gallery `sig_image_factory`, RGs
  `rg-image-factory-{gallery,build,vms,tfstate}`.
- AWS: region `ap-southeast-1`; state bucket `image-factory-tfstate-<account>-<region>`;
  roles `image-factory-packer` (builds, main + `images-aws*`) and
  `image-factory-vm-provision` (main only, may only touch `ManagedBy=image-factory`).
- Image versions: `YYYY.(MM*100+DD).<run number>`.

## When working from a Claude session

- GitHub GraphQL may be blocked by the egress proxy: use REST
  (`gh api repos/<r>/pulls -f title=... -f head=... -f base=main -f body=...`)
  instead of `gh pr create` / `gh pr view`.
- Repository settings, variables and dispatch endpoints may return 403 from
  the session; give the user the command to run locally instead
  (e.g. `scripts/bootstrap/configure-github-repo.sh`).
- When editing files with regexes or `sed`, re-read the lines you changed;
  a substitution once clobbered `TITLE_RE` in `standards.py`.
