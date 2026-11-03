# Hardening exceptions

Hardening uses [ansible-lockdown/UBUNTU24-CIS](https://github.com/ansible-lockdown/UBUNTU24-CIS)
**1.8.0** (CIS Ubuntu Linux 24.04 LTS Benchmark **v1.0.0**), pinned in
`ansible/requirements.yml`.

The table lists every change from the role's defaults. It must match
`ansible/vars/hardening/`. Your security team should review it, and it
should be re-checked whenever the role version changes.

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

## Known side effects

- **AIDE** is initialised during hardening. The cleanup step changes a few
  files after that (package caches, logs, machine-id), so the first AIDE
  check on an instance reports those changes. Re-initialise AIDE at first
  boot if this is noisy.
- **CIS SSH settings** (ciphers, MACs, KEX, `MaxAuthTries 4`) apply to
  instances. Old SSH clients may fail to connect.
- **Python 3 stays in container images**, because Ansible needs it to
  provision them.
