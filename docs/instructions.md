# Instructions

Setup and day-to-day operation of the Image Factory, by role. How it
works: [architecture.md](architecture.md) · step-by-step flows:
[workflow.md](workflow.md).

| I am… | Start at |
|---|---|
| the platform admin setting it up | [1. One-time setup](#1-one-time-setup) |
| a DevOps engineer who needs an image | [2. Golden images](#2-golden-images-devops) |
| an end user who needs a VM | [3. Virtual machines](#3-virtual-machines-end-users) |
| a reviewer | [4. Reviewing requests](#4-reviewing-requests) |
| maintaining the platform | [5. Maintenance](#5-maintenance) |
| stuck | [6. Troubleshooting](#6-troubleshooting) |

---

## 1. One-time setup

### 1.1 Prerequisites (on your machine)

| Tool | Install (macOS) | Check |
|---|---|---|
| git, jq | `brew install git jq` | |
| GitHub CLI | `brew install gh` | `gh auth status` (logged in; the script adds the `workflow` scope) |
| Azure CLI | `brew install azure-cli` | `az account show` (logged in) |
| Terraform ≥ 1.7 | `brew install hashicorp/tap/terraform` | `terraform version` |

You need: admin on the GitHub repo, Owner (or Contributor + User Access
Administrator) on the Azure subscription, and permission to create Entra
ID app registrations.

### 1.2 Deploy (run again after every platform change)

```bash
cd ~/my_work/image-factory
git switch main && git pull
./scripts/bootstrap/deploy-github-azure.sh
```

It asks twice: once to confirm the summary, once (`yes`) at Terraform's
plan. It's safe to re-run. What it does:

| Step | Result |
|---|---|
| 1 | Checks tools and logins; finds your GitHub user and the repo's immutable IDs |
| 2 | Creates the repo if missing |
| 3 | Terraform state storage `rg-image-factory-tfstate` / `stimgfac<hash>` (versioned) |
| 4 | `terraform apply` of `terraform/factory/azure`: gallery, build RG, VM landing zone, Entra app + federated credentials, role assignments |
| 5 | Repository variables from the Terraform outputs (+ `TF_STATE_*`) |
| 6 | Promotion environments; then `configure-github-repo.sh`: squash-only, auto-delete branches, ruleset on `main`, Actions may open PRs, GitHub Pages + first deployment |
| 7 | Pushes code on the first run; afterwards opens a `chore/bootstrap-…` PR for any files it changed (e.g. the provider lock file) |
| 8 | Starts a build of `requests/ubuntu-2404-base.yaml` |

Options: `AZURE_SUBSCRIPTION_ID=… AZURE_LOCATION=… REPO_NAME=… SKIP_FIRST_BUILD=1`.

### 1.3 Portal bot: GitHub App (recommended)

Without it, portal PRs only get the `pr-standards` status (posted by the
processor), because GitHub doesn't run workflows for PRs opened by
`GITHUB_TOKEN`.

1. GitHub → Settings → Developer settings → GitHub Apps → **New GitHub App**:
   name `image-factory-bot`, homepage = repo URL, **Webhook off**.
   Repository permissions: Contents RW, Pull requests RW, Issues RW,
   Commit statuses RW, Metadata R.
2. **Generate a private key**, then **Install App** on `image-factory` only.
3. ```bash
   gh variable set PORTAL_APP_ID --repo cloudwithritesh/image-factory --body <app id>
   gh secret set PORTAL_APP_PRIVATE_KEY --repo cloudwithritesh/image-factory < ~/Downloads/image-factory-bot.*.private-key.pem
   ```

### 1.4 Backstage (optional, local)

```bash
cd ~/my_work && npx @backstage/create-app@latest          # name: image-factory-portal
# GitHub OAuth App: homepage http://localhost:3000,
#   callback http://localhost:7007/api/auth/github/handler/frame
~/my_work/image-factory/portal/backstage/setup.sh ~/my_work/image-factory-portal
export GITHUB_TOKEN="$(gh auth token)" AUTH_GITHUB_CLIENT_ID=… AUTH_GITHUB_CLIENT_SECRET=…
cd ~/my_work/image-factory-portal && yarn start           # http://localhost:3000/create
```
Add the GitHub sign-in page as described in
[portal/README.md](../portal/README.md#4-sign-in-page). Everyone who signs
in needs a User entity in `portal/backstage/org.yaml`.

### 1.5 Verify the setup

| Check | Expected |
|---|---|
| Actions → image-factory (latest run) | lint, plan, build (azure, docker), promote: green |
| `az sig image-version list -g rg-image-factory-gallery -r sig_image_factory -i ubuntu-2404-base --query "[].{v:name, latest:!publishingProfile.excludeFromLatest, status:tags.Status}" -o table` | a version with `latest: True`, `status: approved` |
| Releases | `ubuntu-2404-base-<version>` with `.cdx.json`, `.spdx.json`, `.grype.json`, `catalog-*.json` |
| https://cloudwithritesh.github.io/image-factory/ | portal loads, image dropdown shows `ubuntu-2404-base` |
| Settings → Rules → Rulesets | `main-protection` active |

---

## 2. Golden images (DevOps)

### 2.1 Request a new image
1. Open the portal → **Golden image**. Keep "Start from: New image".
2. Name (lowercase, 3–50 characters), owning team, OS, targets (only clouds
   that are set up can be ticked).
3. Pick hardening profiles (defaults are CIS Level 1) and approved software.
   Items that don't fit the chosen targets are greyed out.
4. Promotion: **Automatic** (after the scan passes) or **Manual approval**.
   Threshold: block vulnerabilities at or above (default `critical`).
5. **Submit request**. GitHub opens; click **Submit new issue**.
6. Within a minute the bot comments with the PR link. After merge the image
   builds; follow it under Actions → image-factory.

### 2.2 Change an image
Portal → **Golden image** → **Start from: <existing image>**. The form loads
the current settings; change what you need and submit. The result is
`chore(image): update image <name>`.

### 2.3 Rebuild without changes (pick up patches)
Actions → **image-factory** → Run workflow → `image_request:
requests/<name>.yaml`. Every image is also rebuilt monthly.

### 2.4 Use an image
| Target | Reference |
|---|---|
| Azure (Terraform) | `data "azurerm_shared_image_version" "img" { name = "latest", image_name = "<name>", gallery_name = "sig_image_factory", resource_group_name = "rg-image-factory-gallery" }` |
| Azure (CLI) | `az sig image-version show -g rg-image-factory-gallery -r sig_image_factory -i <name> -e latest` |
| Docker | `FROM ghcr.io/cloudwithritesh/image-factory/images/<name>:<version>` (or `@sha256:` from the catalog record) |
| What's inside | release `<name>-<version>` (SBOM), or `/etc/image-factory/build-info.json` on the machine |

### 2.5 Add approved software (platform team)
Add an entry to `catalog/software.yaml` on a `feat/…` branch:
```yaml
nginx:
  description: NGINX web server
  type: apt                 # apt | url (checksum required) | file (from ansible/files/)
  packages: [nginx]
  os: [ubuntu-2404]
  targets: [aws, azure, docker]
```
Open a PR titled e.g. `feat(catalog): add nginx`. After merge the portal
offers it automatically. Run `python3 scripts/portal/render.py backstage` and
commit the result, or the `lint` freshness check fails.

### 2.6 Add a hardening profile or OS (platform team)
- Profile: add it under the OS in `catalog/hardening.yaml` and create its
  vars file in `ansible/vars/hardening/`. Record any deviations in
  `docs/hardening-exceptions.md`.
- OS: add `catalog/os.yaml` (base image per target), `catalog/hardening.yaml`
  (profiles), the hardening role in `ansible/requirements.yml`, and allow it
  in the relevant `catalog/software.yaml` entries. RHEL/Rocky, Amazon Linux
  2023 and Windows are on the roadmap.

---

## 3. Virtual machines (end users)

### 3.1 Get a VM
1. Have an SSH key: `ssh-keygen -t ed25519`, then copy `~/.ssh/id_ed25519.pub`
   (the **.pub** file; never the private key).
2. Portal → **Virtual machine** → **Create or update**.
3. Name (3–15 characters, starts with a letter), owning team, environment,
   purpose.
4. Cloud, golden image, size (small / medium / large), region, disk.
   Image version `latest` = newest approved image.
5. Access: admin user and SSH public key. **Public IP** only if you must
   reach it from outside the VNet; then give your office or VPN range
   (/16 or narrower).
6. **Submit request** → **Submit new issue** → wait for the PR link.
7. After approval and merge: Actions → **vm-provision** → your VM's job →
   the summary shows the IP and the `ssh` command.

### 3.2 Change a VM
Type the existing VM name in the portal: its current settings load. Change
what you need (e.g. size) and submit (`chore(vm): update vm …`). Changing
the **image** or a pinned **image version** rebuilds the VM, which
replaces the OS disk. The admin user and SSH key are also fixed at creation;
changing them rebuilds the VM too. Size and disk growth are applied in place
(a resize restarts the VM).

### 3.3 Decommission a VM
Portal → **Virtual machine** → **Decommission** → name → submit. After merge
the VM, its disk, NIC, NSG and public IP are destroyed. Don't delete the
file from `vms/` by hand: that doesn't remove the VM.

### 3.4 Connect
```bash
ssh <admin_user>@<private-or-public-ip>
```
Private-only VMs are reachable from inside the workload VNet
(`vnet-image-factory-workloads`), e.g. via a jump host, VPN or Azure Bastion.

---

## 4. Reviewing requests

Portal PRs carry labels `portal` + `image-request` / `vm-request` and a
checklist. Check:

| Request | Look for |
|---|---|
| Image | right OS and targets; hardening not `none` outside labs; software justified; promotion mode; owner team |
| VM | size and environment justified; SSH key belongs to the requester; public IP only with a narrow range; image is the intended one |
| Any | `pr-standards` green; the YAML diff matches the description; `Requested-by` is who you expect |

Approve, then **Squash and merge**. The branch is deleted automatically. To
reject, close the PR; the `branch-cleanup` workflow deletes the branch.

---

## 5. Maintenance

| Task | How |
|---|---|
| Upgrade tools (Packer, Syft, Grype, crane, Terraform) | edit `ci/versions.env` (and the ARGs in `ci/Dockerfile` for GitLab); PR `chore(ci): bump …` |
| Upgrade the CIS role | bump `ansible/requirements.yml`, read the role's changelog, adjust `ansible/vars/hardening/`, rebuild an image on the branch via `image_request` before merging |
| Change VM sizes, regions, environments | `catalog/vm.yaml`; regenerate Backstage templates |
| Enable AWS | deploy `terraform/factory/aws`, set its outputs as repository variables, set `clouds.aws.enabled: true`, add `aws` to image targets |
| Add reviewers or teams | `.github/CODEOWNERS`; Backstage teams in `portal/backstage/org.yaml` |
| Rotate secrets | nothing to rotate: OIDC everywhere. If you use the GitHub App, rotate its private key in the App settings and `gh secret set` again |
| Clean old image versions | `az sig image-version delete …` for versions no VM pins (check VM tags `ImageVersion`) |
| Run the checks locally | `make lint`, `make portal-test`, `make portal` (preview on :8000) |

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AADSTS700213: No matching federated identity record` | OIDC subject doesn't match the federated credentials (e.g. repo IDs missing, renamed environment) | re-run the deploy script (it passes the repo's immutable IDs); environment names must be `images-<target>[-approval]` |
| Bot comment: "only repository owners, members and collaborators…" | requester has no repo access | add them as a collaborator, or let a member submit |
| Bot comment: "isn't set up on this platform yet" | target cloud disabled in `catalog/vm.yaml` | enable the cloud or untick it |
| Bot comment: "no changes" | the request matches the current file | change something, or use Run workflow to rebuild |
| `pr-standards` fails | branch or title doesn't follow [standards.md](standards.md) | rename the branch (`feat/…`) / edit the PR title to `type(scope): subject` |
| `lint` fails: "Backstage templates are out of date" | catalog or requests changed by hand | `python3 scripts/portal/render.py backstage` and commit |
| Build fails in the CIS role | a control conflicts with the build environment | override it in `ansible/vars/hardening/`, document it in `hardening-exceptions.md` |
| Scan gate fails | fixed vulnerabilities at or above the threshold | rebuild later (patched packages), or adjust `fail_on_severity` in the request after review |
| VM apply: "isn't approved (it hasn't passed the vulnerability gate)" | pinned `image_version` is a candidate | use `latest` or a promoted version |
| Public-IP VM unreachable | wrong source range | update the VM with the correct `allowed_ssh_cidr` |
| portal-pages: "Ensure GitHub Pages has been enabled" | Pages not turned on | run `scripts/bootstrap/configure-github-repo.sh` |
| configure script: "couldn't create the ruleset" | private repo on GitHub Free | make the repo public or use a paid plan |
| Portal shows old options | Pages not redeployed | Actions → portal-pages → Run workflow |

---

## 7. Later: Entra ID and GitLab

- **Entra ID for Backstage:** swap the `github` auth provider for the
  commented `microsoft` block in `portal/backstage/app-config.image-factory.yaml`,
  import users and groups with the Microsoft Graph org provider, and use
  `microsoftAuthApiRef` on the sign-in page. Templates and the PR process
  stay the same.
- **GitLab:** follow "Moving to GitLab later" in the [README](../README.md).
  Terraform can trust GitHub and GitLab at the same time during the move.
