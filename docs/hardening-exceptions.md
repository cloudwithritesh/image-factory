# Hardening exceptions

Hardening roles, pinned in `ansible/requirements.yml`:

| OS | Role | Benchmark |
|---|---|---|
| Ubuntu 26.04 (VMs) | [ansible-lockdown/UBUNTU26-CIS](https://github.com/ansible-lockdown/UBUNTU26-CIS) **0.9.0** (first public release) | CIS Ubuntu Linux 26.04 LTS v1.0.0 |
| Ubuntu 24.04 | [ansible-lockdown/UBUNTU24-CIS](https://github.com/ansible-lockdown/UBUNTU24-CIS) **1.8.0** | CIS Ubuntu Linux 24.04 LTS v1.0.0 |
| RHEL 10, Rocky 10 | [ansible-lockdown/RHEL10-CIS](https://github.com/ansible-lockdown/RHEL10-CIS) **1.1.2** | CIS RHEL 10 |
| RHEL 9, Rocky 9 | [ansible-lockdown/RHEL9-CIS](https://github.com/ansible-lockdown/RHEL9-CIS) **2.4.2** | CIS RHEL 9 v2.0.0 |
| Amazon Linux 2023 | [ansible-lockdown/AMAZON2023-CIS](https://github.com/ansible-lockdown/AMAZON2023-CIS) **1.5.0** | CIS Amazon Linux 2023 |
| Windows Server 2025 | [ansible-lockdown/Windows-2025-CIS](https://github.com/ansible-lockdown/Windows-2025-CIS) **1.2.2** | CIS Windows Server 2025 (Member Server) |
| Windows Server 2022 | [ansible-lockdown/Windows-2022-CIS](https://github.com/ansible-lockdown/Windows-2022-CIS) **4.2.0** | CIS Windows Server 2022 (Member Server) |
| Fedora 44/45, SLES 15/16, Ubuntu 26.04 containers, all non-Ubuntu containers | `ansible/roles/baseline` (in this repo) | Factory baseline: the controls the benchmarks share (see below) |
| UBI 9/10 for OpenShift | `ansible/roles/openshift` (baseline + OpenShift conventions) | OpenShift image guidelines |

Each table lists every change from a role's defaults. It must match
`ansible/vars/hardening/`. Your security team should review it, and it
should be re-checked whenever a role version changes.

## Ubuntu 24.04 (UBUNTU24-CIS)

| Control / setting | Profile(s) | What we do | Why | Compensating control |
|---|---|---|---|---|
| Level selection | cis-l1, cis-l1-container | `--skip-tags level2-server`, `ubtu24cis_level_2: false` | Level 1 is the general-purpose baseline | Request `cis-l2` where needed |
| 5.2.4 Users must provide a password for privilege escalation | all | Rule disabled (`ubtu24cis_rule_5_2_4: false`) | Packer's build user has no password and the role's pre-check aborts. cloud-init re-adds `NOPASSWD` for the default user at every launch anyway. | Enforce per instance: disable the default user and use SSO/SSM/Bastion with named accounts, or remove `NOPASSWD` with your config management after launch. |
| 4.2.x ufw outbound ports | VM profiles | Allowed out: 53/tcp+udp, 67/udp, 80/tcp, 123/udp, 443/tcp; Azure also 32526/tcp | DNS, DHCP renewal, package mirrors and metadata, NTP, HTTPS; Azure guest agent to WireServer | Change `factory_ufw_out_ports_*` if workloads need more |
| 1.4.1 Boot loader password | all | Not set (`ubtu24cis_set_boot_pass: false`, the role default) | Needs a site-specific secret | Set a hash from a secret store if required |
| Audit (goss) | all | `setup_audit: false`, `run_audit: false` | Keeps audit tooling out of the image | Run the audit in a separate pipeline step (phase 2) |
| Reboot during role | all | `skip_reboot: true` | The image reboots at first launch | — |
| EC2-incompatible tasks | aws | `system_is_ec2: true` | Role-provided switch for EC2 (GRUB, reboot) | — |
| Container mode | cis-l1-container | `system_is_container: true` and the role's `vars/is_container.yml` | Kernel, boot loader, firewall, auditd, AIDE, AppArmor and time sync controls don't apply inside containers. In this mode the role also skips most of section 5 (SSH, sudo, PAM, password ageing) by design. | Host and runtime hardening (Kubernetes PSA, seccomp, read-only rootfs, non-root user) |
| Container extras (found in test builds) | cis-l1-container | Off: 1.6.1 dynamic-MOTD PAM edit, 2.1.22, 2.3.1.1, 2.3.3.x, 2.4.1.1, 3.3.x, all 6.1.x | No sshd PAM file, no systemd, no daemons (cron, chrony), `/proc/sys` read-only, logs go to stdout. The role's `is_container.yml` doesn't cover these. | Host/node hardening and the container runtime's logging |

## Ubuntu 26.04 (UBUNTU26-CIS 0.9.0)

0.9.0 is the role's first public release (the CIS benchmark itself is
v1.0.0). We use it, as agreed, with the same build-safe overrides as Ubuntu
24.04; re-review this section when the role reaches 1.x.

| Control / setting | Profile(s) | What we do | Why |
|---|---|---|---|
| Level selection | cis-l1 | `--skip-tags level2-server`, `ubtu26cis_level_2: false` | Level 1 baseline |
| 5.2.4 Password for privilege escalation | all | `ubtu26cis_rule_5_2_4: false` | As for Ubuntu 24.04 |
| ufw outbound ports | all | Same allow-list as Ubuntu 24.04 (+32526/tcp on Azure) | Same reasons |
| Boot loader password, audit, reboot | all | Not set / off / skipped | As for Ubuntu 24.04 |
| Containers | ubuntu-2604 containers | CIS role not used; `baseline-container` instead | The 24.04 role needed many container exclusions found by test builds; the 26.04 role hasn't been through that yet |

## RHEL 10 and Rocky 10 (RHEL10-CIS 1.1.2)

Same overrides as RHEL 9 below, with the `rhel10cis_` prefix: Level 2
skipped for cis-l1, 5.2.4 off, `sshd_allowusers` empty, firewalld, no
boot loader password, crypto policy DEFAULT, no audit, no reboot; RHEL-family
containers use `baseline-container`.

## Windows Server 2025 (Windows-2025-CIS 1.2.2)

Same approach as Windows Server 2022 below (`win25cis_` prefix,
`memberserver`, `win_skip_for_test: true`). The 2025 role's skip list has
two more controls, both domain-member related: **2.2.3** (network logon
rights) and **2.2.22** (deny network logon). Apply all 13 with GPO or Intune
after deployment.

## RHEL 9 and Rocky 9 (RHEL9-CIS)

| Control / setting | Profile(s) | What we do | Why | Compensating control |
|---|---|---|---|---|
| Level selection | cis-l1 | `--skip-tags level2-server`, `rhel9cis_level_2: false` | Level 1 baseline | Request `cis-l2` |
| 5.2.4 Password for privilege escalation | all | `rhel9cis_rule_5_2_4: false` | Same as Ubuntu: passwordless build user; the role's pre-check aborts | Per instance, as for Ubuntu |
| 5.1.7 sshd `AllowUsers` | all | `rhel9cis_sshd_allowusers: ""` (not set) | The role defaults it to the build user, who is deleted before capture and isn't the login user of later VMs | SSH keys only, NSG/security group rules, named accounts per instance |
| Boot loader password | all | Not set | Site-specific secret | Set a hash from a secret store |
| Crypto policy | all | `DEFAULT` (role default) | `FUTURE` breaks some cloud agents and clients | Raise per workload |
| Audit (goss), reboot | all | `setup_audit/run_audit: false`, `skip_reboot: true` | As for Ubuntu | — |
| Containers | all RHEL-family containers | CIS role not used; `baseline-container` instead | The CIS role targets full systems; most controls don't apply in containers | Host/runtime hardening |

## Amazon Linux 2023 (AMAZON2023-CIS)

| Control / setting | Profile(s) | What we do | Why |
|---|---|---|---|
| Level selection | cis-l1 | `--skip-tags level2-server`, `amzn2023cis_level_2: false` | Level 1 baseline |
| sshd `AllowUsers` | all | `amzn2023cis_sshd_allowusers: ""` | Same reason as RHEL 9 |
| Audit, reboot | all | off / skipped | As for Ubuntu |

## Windows Server 2022 (Windows-2022-CIS)

| Control / setting | Profile(s) | What we do | Why | Compensating control |
|---|---|---|---|---|
| Level selection | cis-l1 | `win22cis_level_2: false` | Level 1 baseline | Request `cis-l2` |
| Role | all | `win22cis_system_role: memberserver` | Images are member servers, not DCs | — |
| 2.2.26, 2.2.27 deny network / RDP logon for local accounts | all | Skipped (`win_skip_for_test: true`) | Would cut off WinRM (Packer and Ansible log on as a local admin) mid-build | Apply by GPO/Intune after domain join |
| 2.3.1.3 Rename administrator | all | Skipped | Breaks the build account and EC2Launch/Azure agent password reset | GPO/LAPS after deployment |
| 9.3.4 Public profile firewall rules | all | Skipped | Breaks the reboot during the build | GPO after deployment |
| 18.10.89.x, 18.10.90.1 WinRM client/service auth, remote shell | all | Skipped | Packer and Ansible need WinRM until sysprep | GPO after deployment; sysprep removes the build listener on AWS |
| Reboot | all | `skip_reboot: true` | Packer restarts the VM after Ansible | — |

## Factory baseline (Fedora, SLES, containers)

No maintained open-source CIS role exists for Fedora or SLES 15/16, and the CIS
roles target full systems rather than containers. The `baseline` role applies
the controls every benchmark shares:

| Control | VMs | Containers |
|---|---|---|
| Login banner (`/etc/issue`, `/etc/issue.net`, `/etc/motd`) | ✓ | ✓ |
| umask 027 for login shells | ✓ | ✓ |
| Core dumps off (limits, systemd-coredump, `fs.suid_dumpable=0`) | ✓ | limits only |
| `/etc/passwd`, `/etc/group` 0644 root | ✓ | ✓ |
| SSH: no root login, no passwords, no X11, `MaxAuthTries 4`, idle timeout, banner | ✓ | — |
| Kernel network settings (no redirects/source routing, martians logged, SYN cookies, ASLR) | ✓ | — (host owns them) |
| Unused filesystem modules blocked (cramfs, freevxfs, hfs, hfsplus, jffs2) | ✓ | — |
| setuid/setgid bits removed from all files | — | ✓ |

`udf` and `squashfs` stay enabled: Azure provisioning media and snaps need
them. For full CIS on SLES, use SUSE's CIS-hardened marketplace images or
OpenSCAP (`scap-security-guide`) in a later phase.

## UBI 9 / UBI 10 for OpenShift

`openshift` = container baseline + user `default` (UID 1001) in group 0,
group-writable `/opt/app-root` and `/opt/app-root/src`, image `USER 1001`
and `WORKDIR /opt/app-root/src`. OpenShift runs containers with a random
UID in group 0, so group permissions are what matter.

## Known side effects

- **AIDE** is initialised during hardening. The cleanup step changes a few
  files after that (package caches, logs, machine-id), so the first AIDE
  check on an instance reports those changes. Re-initialise AIDE at first
  boot if this is noisy.
- **CIS SSH settings** (ciphers, MACs, KEX, `MaxAuthTries 4`) apply to
  instances. Old SSH clients may fail to connect.
- **Python 3 stays in container images**, because Ansible needs it to
  provision them. On SLES, Python 3.11 is added (the system 3.6 is too old
  for ansible-core).
- **Baseline containers have no setuid binaries**, so `su`, `sudo`,
  `passwd` and `ping` (where setuid) don't work inside them. That's the
  point; build images that need them with profile `none` and an exception.
