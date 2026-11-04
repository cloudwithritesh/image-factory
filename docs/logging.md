# Logging and troubleshooting

Every step of the factory writes logs you can use to find out what failed
and why, without re-running anything. This page explains what is logged,
where it goes, how to turn on more detail, and how to read it.

## What is logged

| Stage | Logs | Where |
|---|---|---|
| Portal request (`portal-request`) | request received / accepted / rejected, branch, PR, check dispatch | `logs-portal-request-<run>` artifact, issue comment, run summary |
| PR checks (`pr-standards`, `lint`, `plan`) | rule that failed; plan decisions per image (`plan_select`, `plan_image`) | job log, `plan` artifact (`build/logs/`) |
| Image build (`build <image> / <target>`) | `packer.log`, `ansible.log`, `grype.log`, `events.jsonl`, `run-context.json`, optional `packer-debug.log` | `output-<image>-<target>` artifact, folder `logs/` |
| Promotion | `events.jsonl`, `run-context.json` | `logs-promote-<image>-<target>` artifact |
| VM provisioning (`vm-provision`, Azure and AWS) | `terraform-init.log`, `terraform-apply.log` / `-destroy.log`, optional `terraform-debug.log` | `logs-vm-<name>` artifact |
| Base image check (`base-images`, weekly) | one line per OS and cloud with what it resolves to | run summary, `logs-base-images-<run>` artifact |
| Inside the image | `/etc/image-factory/build-info.json` (Linux), `C:\ProgramData\image-factory\build-info.json` (Windows): image, version, target, hardening profile, software, installed hotfixes | the image itself |

Artifacts are kept 90 days (30 for portal and plan logs, 7 for debug runs).
Failed jobs upload their logs too.

## Log format

Scripts log through one library (`scripts/ci/log.sh` for shell,
`scripts/factorylog.py` for Python), so every message looks the same:

```
2026-11-04T03:44:38Z INFO  [packer-build] step finished: packer build (1834s) event=step_end step="packer build" rc=0 duration_s=1834
2026-11-04T03:44:38Z ERROR [scan] vulnerability gate failed (findings at or above 'critical')...
```

and is also written as one JSON object per line to `events.jsonl`:

```json
{"ts":"2026-11-04T03:44:38Z","level":"error","component":"packer-build","msg":"step failed: packer build (exit 1 after 912s)",
 "correlation_id":"gh-19034412345-1","run_id":"19034412345","job":"build","image":"rhel9-base","version":"2026.1104.12",
 "target":"azure","request_ref":"i42","event":"step_end","step":"packer build","rc":"1","duration_s":"912"}
```

Warnings and errors also appear as annotations at the top of the run page.

### Correlation: following one request end to end

| Field | Meaning | Set by |
|---|---|---|
| `request_ref` | portal request: `i<issue>` (GitHub Pages) or `r<run>` (Backstage) | portal-request; read back from the commit's `Request-ref:` trailer by build and VM jobs |
| `correlation_id` | `gh-<run id>-<attempt>` of the workflow run | every job |
| `image`, `version`, `target` | which build | build, scan, promote |

To trace issue #42: search the Actions runs for the PR that closed it, then
filter `events.jsonl` from the build artifacts with
`jq 'select(.request_ref == "i42")'`.

### Steps and timing

`run_step` wraps every significant command and logs `step_start` and
`step_end` events with the exit code and duration. To see where a build
spent its time:

```bash
jq -r 'select(.event == "step_end") | "\(.duration_s)s\t\(.rc)\t\(.step)"' events.jsonl | sort -n
```

`run-context.json` records the runner, commit, actor, trigger and the
versions of Packer, Terraform, Ansible, Syft, Grype and the cloud CLIs.

## More detail (debug mode)

| How | Effect |
|---|---|
| Run `image-factory` or `vm-provision` manually with **debug = true** | that run only |
| Re-run a job with **Enable debug logging** (GitHub) | that attempt (`RUNNER_DEBUG=1`) |
| Repository variable `FACTORY_LOG_LEVEL=debug` | every run until removed |

Debug mode adds `log_debug` messages, Packer's internal log
(`PACKER_LOG=1` → `packer-debug.log`), Ansible verbosity 2, and
`TF_LOG=DEBUG` (`terraform-debug.log`). Those files can contain
infrastructure details (IP addresses, resource IDs, API requests). Packer
and Terraform redact values marked sensitive, but this repository is
public, so debug artifacts are kept for 7 days only. Turn debug off again
when you're done.

## Failure triage

When a build or VM job fails, `scripts/ci/triage.py` scans the logs for
known failure signatures and puts the likely cause and the fix in the run
summary, together with the last 40 log lines. The sections below are the
signatures it knows; add a signature (and a line in `.claude/issues.md`)
whenever you fix a new kind of failure.

### azure-oidc
`AADSTS700213` / `AADSTS70021`: the federated credential doesn't match the
run's subject. Repositories created after 2026-07-15 use the immutable
subject `repo:<owner>@<owner id>/<repo>@<repo id>:...`. Re-run
`scripts/bootstrap/deploy-github-azure.sh`, which looks the IDs up.

### azure-rbac
`AuthorizationFailed`: the CI identity lacks a role. The deploy script
grants Contributor on the build and VM resource groups and gallery access.
Windows builds also need permission to create a temporary Key Vault in the
build resource group (Contributor covers it) and the `Microsoft.KeyVault`
resource provider registered.

### aws-oidc
`Not authorized to perform sts:AssumeRoleWithWebIdentity`: the IAM role's
trust policy doesn't match the run. Builds run on `main` and promote in the
`images-aws(-approval)` environments; VM changes run on `main`. Re-run
`scripts/bootstrap/deploy-github-aws.sh` (it passes the repo's immutable IDs).

### aws-iam
`UnauthorizedOperation` / `AccessDenied`: the role lacks an action. The
message names it. Builds use `image-factory-packer` (`terraform/factory/aws/main.tf`),
VMs use `image-factory-vm-provision` (`vm.tf`). The VM role may only change
resources tagged `ManagedBy=image-factory`.

### aws-capacity
`InsufficientInstanceCapacity` / `VcpuLimitExceeded`: no capacity or quota
for the instance type. Pick another size or raise the quota.

### azure-quota
`QuotaExceeded` / `SkuNotAvailable`: not enough vCPU quota for the size, or
the size isn't offered in the region. Use a smaller size in the request's
`azure.vm_size`, or request quota.

### marketplace-terms
Some marketplace images need their terms accepted once: Azure
`az vm image terms accept --urn <publisher>:<offer>:<sku>:latest`; AWS
`OptInRequired` means subscribing to the product in the AWS Marketplace
console. The catalog uses vendors' public images, which need neither.

### winrm
`Timeout waiting for WinRM`: the Windows build VM didn't answer on 5986.
Check that the runner-IP rule was applied (the build log prints the IP),
and that the image finished first boot; raise `winrm_timeout` for large
sizes.

### ssh
`Timeout waiting for SSH` / `handshake failed`: usually the runner-IP rule,
or a hardening control that changed sshd before Packer finished. Look at the
last Ansible task in `ansible.log`.

### ansible-unreachable
The connection dropped mid-run: a reboot or an SSH/WinRM control. The task
before `UNREACHABLE!` in `ansible.log` is the culprit; add an exception in
`ansible/vars/hardening/` and `docs/hardening-exceptions.md`.

### ansible-failed
Search `ansible.log` for `fatal:`. The task name shows the role (`base`,
`software`, a CIS role). Reproduce locally against a container or chroot
(see `.claude/CLAUDE.md`).

### packages
A package name doesn't exist for this OS. Set `packages_by_family` for the
item in `catalog/software.yaml`.

### network
DNS or TLS timeouts to mirrors: usually transient, re-run the job. If it
repeats, check egress rules for the build subnet and proxies.

### scan-gate
Grype found vulnerabilities at or above the request's `fail_on_severity`.
The report is `scan/<image>-<version>-<target>.grype.json` in the output
artifact. Rebuild when fixes ship (the monthly rebuild does this), or
change the threshold with an approved exception.

### rate-limit
Docker Hub / GHCR rate limits: point `docker.base_image` in
`catalog/os.yaml` at a pull-through cache.

### packer-template
Template error: render and validate locally:
`python3 scripts/imagefactory.py render <request> && packer validate -var-file=build/<name>/variables.pkrvars.json packer/<family>`.

### tf-lock
The VM's Terraform state is locked by another run. Wait for it; if a run
died, `terraform force-unlock <lock id>` after confirming nothing is running.

## Where to look first

1. The run summary (triage table and log tail).
2. Annotations at the top of the run page.
3. The artifact's `logs/` folder: `packer.log` → `ansible.log` → `events.jsonl`.
4. For portal requests: the issue comment and `logs-portal-request-<run>`.

## Retention and central logging

GitHub artifacts are the log store today. For longer retention or a SIEM,
ship `events.jsonl` (already JSON lines) to Azure Monitor / Log Analytics,
Splunk or Elastic from a workflow step at the end of each job; the fields
above map one-to-one to columns.
