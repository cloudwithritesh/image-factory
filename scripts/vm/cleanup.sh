#!/usr/bin/env bash
# Generalise the VM so each instance launched from the image starts clean.
# Runs as root and is the last provisioner. On Azure it ends with
# waagent -deprovision+user, which also deletes the build user.
set -euo pipefail

: "${PACKER_SOURCE_TYPE:?PACKER_SOURCE_TYPE is required}"
export DEBIAN_FRONTEND=noninteractive

echo ">> package caches"
apt-get -y autoremove --purge
apt-get -y clean
rm -rf /var/lib/apt/lists/*

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
cloud-init clean --logs --seed

case "$PACKER_SOURCE_TYPE" in
  amazon-ebs)
    # cloud-init injects the instance's key pair at launch
    rm -f /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys
    ;;
  azure-arm)
    sync
    /usr/sbin/waagent -force -deprovision+user
    export HISTSIZE=0
    ;;
esac

sync
echo ">> cleanup complete"
