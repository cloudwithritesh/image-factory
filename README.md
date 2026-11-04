# Image Factory

Automated golden images for **AWS**, **Azure** and **Docker** from one
repository: Packer, Ansible, Terraform, CIS hardening, an SBOM and a
vulnerability gate on every image.

The pipeline runs on **GitHub Actions** today. A **GitLab CI** pipeline that
uses the same scripts is in the repo too, so moving later doesn't require a
rewrite (see [Moving to GitLab](#moving-to-gitlab-later)).

```
request YAML ─► validate ─► Packer build (AWS │ Azure │ Docker) ─► SBOM ─► Grype gate ─► promote ─► catalog
     ▲                       patch → install software → CIS harden → generalise
     └── self-service portal (Backstage, phase 3) opens a PR with the request
```

Status: **phases 1 and 3–4**: Ubuntu 24.04 golden images (Azure + Docker live, AWS ready), plus a
self-service portal (GitHub Pages + local Backstage) where DevOps request images and end users
request VMs. Every request becomes a reviewed pull request ([portal/README.md](portal/README.md)).

| Portal | Where |
|---|---|
| GitHub Pages | https://cloudwithritesh.github.io/image-factory/ |
| Backstage (local) | http://localhost:3000/create after [setup](portal/README.md#backstage-local) |
| Standards | [docs/standards.md](docs/standards.md): branches, commits, PRs |

## How it works

1. **A request** (`requests/<name>.yaml`) says which OS, targets, hardening
   profile and software an image needs. The portal writes these files, or
   you can write one by hand.
2. **Catalogs** (`catalog/*.yaml`) list what can be requested: base images,
   hardening profiles per OS, and approved software. `scripts/imagefactory.py`
   checks every request against the JSON schema and the catalogs.
3. **Plan** renders each selected request into Packer variables and
   Ansible variables under `build/<name>/`, runs `packer validate`, and
   fans out one job per request and target (a GitHub matrix, or a GitLab
   child pipeline).
4. **Build**: one Packer template (`packer/linux`) with three sources. They
   all get the same Ansible provisioning: patch, install software, apply the
   CIS profile, write `/etc/image-factory/build-info.json`.
   - AWS: an encrypted AMI (customer-managed KMS key), tagged `Status=candidate`.
   - Azure: a Compute Gallery version with `excludeFromLatest=true`, in an image
     definition named after the request (created on first build).
   - Docker: pushed as `:candidate-<version>` (GHCR on GitHub, the GitLab registry on GitLab).
5. **SBOM**: on VMs, Syft runs on the build VM after hardening (CycloneDX
   and SPDX JSON) and Packer downloads the files. For Docker, Syft scans the
   pushed image in CI.
6. **Scan gate**: Grype scans the SBOM and fails at `fail_on_severity`
   (default `critical`, only vulnerabilities that have a fix). A failed image
   stays a candidate and is never promoted.
7. **Promote** (straight away, or after approval when a request sets
   `promotion: manual`):
   - AWS: tag `Status=approved`, share with accounts/org, set SSM
     `/image-factory/<name>/latest` and `/versions/<version>`.
   - Azure: include the version in `latest`, tag it approved.
   - Docker: add the `<version>` and `latest` tags.
   - All targets: SBOMs, the scan report and a catalog record (JSON) are
     stored with the version: a **GitHub release** `<name>-<version>`, or
     the **GitLab generic package** `<name>/<version>`.

Version format is `YYYY.(MM*100+DD).<run number>`, e.g. `2026.1103.42`.
That is valid semver, which Azure galleries require, and it is the same for
every target in one run.

## Repository layout

```
catalog/              os.yaml, hardening.yaml, software.yaml, vm.yaml (what can be requested)
schemas/              JSON schemas for image and VM requests
requests/             one YAML per image (written by the portal or by hand)
vms/                  one YAML per end-user VM (written by the portal)
portal/               GitHub Pages portal, Backstage templates + setup
packer/linux/         one build, sources: amazon-ebs, azure-arm, docker
ansible/              image.yml playbook, roles (base, software), hardening vars
scripts/              imagefactory.py (validate/render/plan), CI scripts, VM/container scripts
.github/workflows/    GitHub Actions pipeline (active)
.github/actions/      setup-tools: pinned, checksum-verified Packer, Syft, Grype, crane
.gitlab-ci.yml        GitLab pipeline (for later), plus .gitlab/ci/ job templates
ci/                   versions.env (tool pins), GitLab toolbox Dockerfile, Python requirements
terraform/factory/    one-time AWS and Azure foundations (OIDC trust, network, gallery, KMS, VM landing zone)
terraform/vm/azure/   one end-user VM from the latest promoted image (used by vm-provision)
docs/                 hardening exceptions
```

## Quick deploy: GitHub + Azure

On a machine where `gh` and `az` are already logged in:

```bash
scripts/bootstrap/deploy-github-azure.sh
```

The script creates the repo, the Terraform state storage and the Azure
foundation (it shows the plan and asks first), sets the repository
variables and environments, pushes the code, and starts the first build.
It's safe to re-run. The manual steps below explain what it does, and cover AWS.

## Set up on GitHub (once)

### 1. Repository
- Create the repo (e.g. `my-org/image-factory`) and push this code.
- Protect `main`: require PRs and the `lint` and `plan` checks.
- Settings → Actions → General → Workflow permissions: leave it read-only.
  The workflow asks for the extra permissions it needs per job.

### 2. Terraform state
State lives in your clouds, not in the CI platform, so it isn't affected if
you switch CI later. Create an S3 bucket and an Azure storage container for
state (or use what you already have).

### 3. AWS foundation
```bash
cd terraform/factory/aws
cp terraform.tfvars.example terraform.tfvars    # github_repository, consumer accounts
terraform init -backend-config="bucket=<state-bucket>" \
               -backend-config="key=image-factory/aws.tfstate" \
               -backend-config="region=ap-southeast-1" \
               -backend-config="use_lockfile=true"
terraform apply
terraform output ci_variables
```
If the account already has a GitHub OIDC provider, set
`create_github_oidc_provider = false` and `github_oidc_provider_arn`.

### 4. Azure foundation
```bash
cd terraform/factory/azure
cp terraform.tfvars.example terraform.tfvars    # subscription_id, github_repository
terraform init -backend-config="resource_group_name=<rg>" \
               -backend-config="storage_account_name=<account>" \
               -backend-config="container_name=tfstate" \
               -backend-config="key=image-factory/azure.tfstate"
terraform apply
terraform output ci_variables
```
You need permission to create Entra ID app registrations.

### 5. Repository variables
Settings → Secrets and variables → Actions → **Variables**: add every key
from both `ci_variables` outputs.

| Variable | Source |
|---|---|
| `AWS_BUILD_ROLE_ARN`, `PKR_VAR_aws_region`, `PKR_VAR_aws_subnet_id`, `PKR_VAR_aws_kms_key_id`, `CATALOG_SSM_PREFIX`, `AWS_SHARE_ACCOUNT_IDS` | AWS output |
| `AWS_SHARE_ORG_ARN` (optional) | your AWS Organization ARN, to share AMIs org-wide |
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `PKR_VAR_azure_subscription_id`, `PKR_VAR_azure_build_resource_group`, `PKR_VAR_azure_gallery_resource_group`, `PKR_VAR_azure_gallery_name`, `PKR_VAR_azure_gallery_location` | Azure output |

None of these are secrets. Cloud access uses OIDC, and the trust accepts
only this repo's `main` branch and its `images-*` environments. GHCR uses
the workflow's own `GITHUB_TOKEN`.

### 6. Environments (approvals)
The first promotion creates the environments automatically. To require
sign-off, open Settings → Environments and add **required reviewers** to
`images-aws-approval`, `images-azure-approval` and
`images-docker-approval`. Requests with `promotion: manual` use these
environments; `promotion: auto` uses `images-<target>`, which has no
reviewers.

### 7. GHCR package visibility
Docker images are pushed to `ghcr.io/<owner>/<repo>/images/<name>`. They are
linked to the repo through the `org.opencontainers.image.source` label and
inherit its access. Make a package public or grant teams access in the
package settings.

## Day-to-day use

| I want to… | Do this |
|---|---|
| Add or change an image | Portal → **Golden image** (or add `requests/<name>.yaml` on a `feat/…` branch). Merging the PR builds it. |
| Get a VM | Portal → **Virtual machine**. Merging the PR runs `vm-provision`; the run summary shows the IP. |
| Rebuild one image | Actions → image-factory → Run workflow, with `image_request=requests/<name>.yaml`. The portal makes the same call through the `workflow_dispatch` API. |
| Rebuild everything | The monthly schedule does this, or run the workflow with `rebuild_all`. |
| Add approved software | Add an entry to `catalog/software.yaml` (`apt`, `url` with a checksum, or `file`). |
| Use the image in Terraform | AWS: `data "aws_ssm_parameter" "ami" { name = "/image-factory/<name>/latest" }`. Azure: the gallery image definition ID without a version (resolves to latest). Docker: `ghcr.io/<owner>/<repo>/images/<name>:<version>`. |
| Find an image's SBOM | The release `<name>-<version>`, or the `SbomUrl` tag on the AMI or gallery version. |
| Build locally | `make build TARGET=docker` (needs a Docker daemon and the tools pinned in `ci/versions.env`). |

## Hardening

Profiles are listed in `catalog/hardening.yaml`. VMs get `cis-l1` by
default, with `cis-l2` and `none` as options. Containers get
`cis-l1-container` by default. Every change from the CIS role's defaults is
listed in [docs/hardening-exceptions.md](docs/hardening-exceptions.md).

## Moving to GitLab later

Everything that does the work (`scripts/`, `packer/`, `ansible/`, `catalog/`,
`terraform/`) is the same on both platforms. Only the thin pipeline files
differ:

| | GitHub Actions | GitLab CI |
|---|---|---|
| Pipeline | `.github/workflows/image-factory.yml` | `.gitlab-ci.yml` + `.gitlab/ci/image-jobs.yml` |
| Fan-out | job matrix | dynamic child pipeline |
| Tools | `setup-tools` action reads `ci/versions.env` | toolbox image from `ci/Dockerfile` |
| Cloud login | `configure-aws-credentials`, `azure/login` | ID tokens, exchanged in `scripts/ci/lib.sh` |
| Registry | GHCR | GitLab container registry |
| SBOM / catalog storage | GitHub releases | GitLab generic packages |
| Approvals | environments `images-*-approval` | protected environments `images/*` |

To move:
1. Push the repo to GitLab and protect `main`.
2. Re-apply both Terraform modules with `gitlab_project_path` set. Keep
   `github_repository` set during the transition, so both platforms are
   trusted at once. Clear it once the move is done.
3. Copy the same variables into GitLab CI/CD variables (the names are identical).
4. Run a pipeline with `BUILD_TOOLBOX=true` once, to build the toolbox image.
5. Point the portal at GitLab's pipeline trigger API instead of `workflow_dispatch`.

Images, SSM parameters and gallery versions don't move: they're already in
your clouds. Docker images and SBOMs from the GitHub period stay in
GHCR and GitHub releases. Mirror them with `crane copy` if you want everything
in one place.

## Known caveats (phase 1)

- **Build VM access**: hosted runners (GitHub or GitLab.com) connect to build
  VMs over a public IP, limited to the runner's IP. For private-only builds,
  use self-hosted runners inside the build VPC/VNet; no template changes
  are needed.
- **GitHub immutable OIDC subjects**: repos created after 2026-07-15 get
  tokens with `repo:<owner>@<owner_id>/<repo>@<repo_id>:...` subjects. Set
  `github_owner_id` and `github_repository_id` in Terraform; the deploy
  script does this for you.
- **GitHub environments and OIDC**: a job that runs in an environment gets a
  different OIDC subject (`repo:<owner>/<repo>:environment:<name>`).
  Terraform trusts exactly the `images-*` environment names. If you rename
  them, update Terraform too. Org-level custom OIDC subject templates also
  change the subject.
- **Manual promotion of failed builds**: the matrix still opens an approval
  request for a target whose build failed. The job then skips with a
  warning, because promotion needs the scan's pass marker.
- **Docker on GitLab.com runners** uses docker-in-docker. `PACKER_TMP_DIR` is
  set inside the shared builds volume. GitHub runners have a local Docker
  daemon, so this doesn't apply there.
- **Copies to other AWS regions** need a KMS key in each region
  (`PKR_VAR_aws_region_kms_key_ids`).
- **Cross-account SSM**: consumers in other accounts can't read the factory
  account's SSM parameters by default. Share them with AWS RAM (advanced
  tier) or replicate them, which is planned for phase 4.

## Roadmap

1. ✅ Factory core: Ubuntu 24.04 on AWS, Azure and Docker; CIS L1/L2; SBOM; Grype gate; promotion; GitHub and GitLab pipelines
2. More operating systems: RHEL 9 / Rocky 9, Amazon Linux 2023, Windows Server 2022 (WinRM, sysprep, CIS GPO role)
3. ✅ Self-service portal: GitHub Pages + Backstage forms → standard PRs (image requests)
4. ✅ VM self-service on Azure (Terraform per VM, latest promoted image); AWS EC2 module next
5. Entra ID sign-in for Backstage, and hosting it (Azure Container Apps)
