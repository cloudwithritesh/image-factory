# Issues and lessons learned

One entry per problem we hit: symptom, cause, fix, and the rule that
prevents it coming back. Newest first within each area. Add an entry (and,
for runtime failures, a signature in `scripts/ci/triage.py`) whenever you
fix something that took more than a few minutes to understand.

## GitHub and pull requests

### Portal PR checks waited for "Approve and run"
- **Symptom:** PR #5 (opened by `github-actions[bot]`) showed `lint` and
  `plan` waiting for approval; only the self-posted `pr-standards` status
  was green.
- **Cause:** GitHub doesn't run `pull_request` workflows for PRs created
  with `GITHUB_TOKEN` without a manual approval.
- **Fix:** `start_pr_checks.sh` dispatches `pr-standards` (new
  `workflow_dispatch` with a `pr` input) and `image-factory` on the PR
  branch; dispatch from `GITHUB_TOKEN` is allowed and the check runs land on
  the head commit. A GitHub App avoids it entirely.
- **Rule:** required checks must be produced by real runs, never by posting
  a status with the same name.

### Admins could merge without review
- **Symptom:** "Squash and merge" was enabled on unapproved PRs for the repo admin.
- **Cause:** the ruleset had `bypass_actors: [RepositoryRole 5 (admin), pull_request]`.
- **Fix:** `bypass_actors: []`; required checks now `pr-standards`, `lint`, `plan`.
  `ALLOW_ADMIN_BYPASS=true` exists for emergencies.
- **Rule:** a sole maintainer can't approve their own PRs; plan for a second
  code owner before removing bypass. Merge PRs that change protection
  *before* applying the stricter ruleset.

### `gh pr create` failed from the Claude session
- **Cause:** GraphQL blocked by the egress proxy.
- **Fix:** REST: `gh api repos/$R/pulls -f title= -f head= -f base=main -f body=`.
  `open_pr.sh` now uses REST too.

### shellcheck passed locally, failed on the runner (SC2015)
- **Cause:** the runner's shellcheck is newer and flags `a && b || c`.
- **Fix:** use `if ...; then ...; fi` in `configure-github-repo.sh` and `branch-cleanup.yml`.
- **Rule:** never use `&& ||` as if/else in scripts.

### `lint` passed, but `plan` failed on a fresh repo
- **Cause:** repository variables (`PKR_VAR_azure_*`) weren't set yet, so
  `packer validate` failed on empty required values.
- **Fix:** `packer-validate.sh` fills placeholders when variables are missing.

### Bootstrap step 8 didn't start the first build
- **Symptom:** no `workflow_dispatch` run of `image-factory` after the deploy script.
- **Status:** dispatch needs the workflow on the default branch and an
  allowed token; start it by hand: Actions → image-factory → Run workflow →
  `requests/ubuntu-2404-base.yaml`.

## AWS

### Least privilege for EC2 self-service
- **Decision:** separate role `image-factory-vm-provision` (trusts `main`
  only) from the Packer role; mutating EC2 calls require
  `ManagedBy=image-factory`, which the module sets with `default_tags`.
- **Watch for:** `UnauthorizedOperation` on a new resource type the module
  starts using; add the action in `terraform/factory/aws/vm.tf` (triage
  signature `aws-iam`).

### Ubuntu 26.04 needs x86-64-v3 CPUs
- Canonical builds 26.04 AMD64 images for x86-64-v3 (Haswell+). All offered
  sizes qualify; don't add pre-Haswell families (m3, c3, some t2 hosts) for 26.04.

## Azure and OIDC

### AADSTS700213: no matching federated identity record
- **Cause:** repos created after 2026-07-15 send immutable subjects
  (`repo:<owner>@<owner_id>/<repo>@<repo_id>:...`); the credentials used
  `repo:<owner>/<repo>:...`.
- **Fix:** Terraform variables `github_owner_id` / `github_repository_id`;
  the deploy script looks them up with `gh api`.
- **Rule:** look up IDs, never hard-code subjects by name.

### Subnet NSG blocked SSH to public-IP VMs
- **Cause:** Azure evaluates subnet *and* NIC NSGs; the subnet NSG denied
  what the per-VM NSG allowed.
- **Fix:** no NSG on `snet-workloads`; one NSG per VM NIC.

### A new `latest` image would have rebuilt running VMs
- **Fix:** resolve the image once into `terraform_data` with
  `triggers_replace=[image, image_version]` and `ignore_changes=[input]`.
- **Rule:** VMs change image only when the request changes.

### Removing the old shared image definition would have destroyed it
- **Fix:** `removed { from = azurerm_shared_image.os  lifecycle { destroy = false } }`
  when moving to one definition per request.

## Catalog

### "Preview" read as "unstable OS"
- **Symptom:** the user asked why OSes were preview-only and wanted stable
  latest versions.
- **Cause:** "preview" was our label for "not yet built through the
  pipeline", not about the OS. Several entries were also one major behind.
- **Fix:** `release: latest | previous` (N and N-1 of each vendor); the
  weekly `base-images` workflow proves the base images resolve.
- **Rule:** labels in the portal describe the OS release, never our
  internal confidence; track pipeline maturity in docs and issues.

### AMI name filters matched the wrong product variants
- **Cause:** `suse-sles-15-sp7-v*-hvm-ssd-x86_64` also matches
  `...-v<date>-ecs-hvm-ssd...` (and app/BYOS variants on SLES 16).
- **Fix:** `v????????` (exactly the 8-digit date).
- **Rule:** after changing a filter, run `check_base_images.py` and read
  the AMI *name* it resolves to, not just "found".

### SLES 16 has a new Python, SLES 15 an old one
- **Fix:** bootstrap installs `python311` only on SLES 15
  (`ansible_python: /usr/bin/python3.11`); SLES 16 uses its python3 (3.13).

## Hardening (Ansible / CIS)

### CIS container profile failed on many controls
- **Cause:** containers have no systemd, sshd PAM file, cron/chrony,
  writable `/proc/sys`; the role's `is_container.yml` doesn't cover all.
- **Fix:** reproduced in a debootstrap chroot (`community.general.chroot`)
  with a UID 1000 `ubuntu` user like the Docker image; disabled 1.6.1
  dynamic-MOTD, 2.1.22, 2.3.1.1, 2.3.3.x, 2.4.1.1, 3.3.x, 6.1.x for
  containers. Result 84 ok / 0 failed.
- **Rule:** test hardening changes in a chroot before CI; document every
  exclusion in `docs/hardening-exceptions.md`.

### Password-for-sudo rule aborts the CIS roles
- **Cause:** Packer's build user has no password; UBUNTU24-CIS and
  RHEL9-CIS pre-checks abort when rule 5.2.4 is on.
- **Fix:** `*_rule_5_2_4: false` with the compensating control documented.

### CIS `AllowUsers` would lock out VMs launched from the image
- **Cause:** RHEL9-CIS and AMAZON2023-CIS default `sshd_allowusers` to the
  *build* user, which is deleted (Azure) or isn't the login user later.
- **Fix:** set `*_sshd_allowusers: ""`.
- **Rule:** check every role default that captures build-time facts
  (`ansible_facts['user_id']`, `SUDO_USER`).

### Packer WinRM defaulted to Basic auth while the AWS listener disabled it
- **Found by:** automated review on PR #6, before any build.
- **Fix:** `winrm_use_ntlm = true` on both Windows sources, matching Ansible's
  `ansible_winrm_transport=ntlm`.
- **Rule:** the communicator, the listener set-up and Ansible must agree on
  transport and auth.

### Windows CIS controls cut off WinRM mid-build
- **Cause:** 2.2.26/2.2.27 (deny network logon for local accounts),
  18.10.89.x/18.10.90.1 (WinRM auth/remote shell), 2.3.1.3, 9.3.4.
- **Fix:** keep the role's `win_skip_for_test: true`; apply those by GPO/Intune.

### SLES python too old for ansible-core
- **Cause:** SLES 15 system python3 is 3.6; ansible-core 2.21 needs ≥ 3.9 on targets.
- **Fix:** bootstrap installs `python311`; `ansible_python: /usr/bin/python3.11`
  in `catalog/os.yaml` is passed to Ansible.

### Fedora's dnf5 needs extra Python bindings
- **Fix:** bootstrap installs `python3-libdnf5` when `dnf --version` reports dnf5.

## Portal processor

### Processor crashed on short issue numbers (`i7`)
- **Cause:** branch ref regex required ≥ 3 characters.
- **Fix:** `{2,12}`; plus a catch-all so every failure still produces a
  result file and an issue comment.

### "No changes" false positive
- **Cause:** compared the pruned new document with the unpruned existing file.
- **Fix:** prune both before comparing.

### YAML written by the processor failed yamllint
- **Fix:** `IndentedDumper` (lists indented under their key).

### Backstage templates went stale
- **Fix:** `open_pr.sh` regenerates and stages them; `lint` runs `render.py backstage --check`.

## Concurrency

### Requests merged close together were silently dropped
- **Cause:** a shared concurrency group keeps only one *pending* run.
- **Fix:** one group per submission (portal), per VM (vm-provision, job
  level), per run on `main` (image-factory).
- **Rule:** use shared groups only where "latest wins" is really correct.

## Working environment (Claude sessions)

### HashiCorp, Docker Hub and the Go proxy are blocked in the sandbox
- **Workaround:** `tofu fmt` on `.tf` copies of HCL, `python-hcl2` parsing,
  actionlint/shellcheck locally; CI does the real `packer validate` and
  `terraform validate`. GitHub release downloads work.

### Disk filled while copying a chroot
- **Cause:** copied a rootfs with `/proc` still bind-mounted.
- **Fix:** unmount first; keep a tar snapshot and extract fresh copies.

### Files committed to the user's folder were stale
- **Cause:** committing under an existing name kept the old content.
- **Fix:** use new file names; extract with `tar --overwrite`.

### A `sed` edit clobbered a regex line
- **Fix:** do multi-character edits with a small Python script that
  asserts the old text occurs exactly once; re-read changed lines.

### Azure marketplace lookups
- The Azure MCP `marketplace` tool lists offers (e.g. `suse.sles-15-sp7`),
  not image SKUs/URNs; `compute` can't list images. Confirm URNs from vendor
  docs or `az vm image list` on the user's machine.
