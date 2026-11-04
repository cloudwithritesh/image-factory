#!/usr/bin/env bash
# Generalise the VM so each instance launched from the image starts clean.
# Runs as root and is the last provisioner. On Azure it ends with
# waagent -deprovision+user, which also deletes the build user.
set -euo pipefail

: "${PACKER_SOURCE_TYPE:?PACKER_SOURCE_TYPE is required}"
PKG_FAMILY="${PKG_FAMILY:-debian}"

echo ">> package caches (${PKG_FAMILY})"
case "$PKG_FAMILY" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get -y autoremove --purge
    apt-get -y clean
    rm -rf /var/lib/apt/lists/*
    ;;
  redhat)
    dnf -y autoremove || true
    dnf -y clean all
    rm -rf /var/cache/dnf
    # RHEL PAYG images register with the cloud's RHUI at boot; nothing to unregister.
    ;;
  suse)
    zypper --non-interactive clean --all
    # PAYG instances re-register with the SUSE public cloud update
    # infrastructure on first boot; drop the build VM's registration.
    if command -v registercloudguest > /dev/null 2>&1; then registercloudguest --clean || true; fi
    ;;
esac

echo ">> SBOM working files"
rm -rf /tmp/sbom

echo ">> logs and shell history"
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
find /var/log -type f -exec truncate -s 0 {} +
rm -f /root/.bash_history /home/*/.bash_history
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true

echo ">> machine identity (regenerated on first boot)"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*

echo ">> cloud-init state"
if command -v cloud-init > /dev/null 2>&1; then cloud-init clean --logs --seed; fi

case "$PACKER_SOURCE_TYPE" in
  amazon-ebs)
    # cloud-init injects the instance's key pair at launch
    rm -f /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys
    ;;
  azure-arm)
    sync
    waagent_bin="$(command -v waagent || echo /usr/sbin/waagent)"
    "$waagent_bin" -force -deprovision+user
    export HISTSIZE=0
    ;;
esac

sync
echo ">> cleanup complete"
