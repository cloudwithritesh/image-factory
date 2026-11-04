#!/bin/sh
# Shrink and tidy the container image before Packer commits it.
# Input: PKG_FAMILY (debian | redhat | suse)
set -eu
: "${PKG_FAMILY:?PKG_FAMILY is required}"

case "$PKG_FAMILY" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get -y autoremove --purge
    apt-get -y clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/log/apt/* /var/log/dpkg.log
    ;;
  redhat)
    if command -v dnf > /dev/null 2>&1; then dnf -y clean all; else microdnf clean all; fi
    rm -rf /var/cache/dnf /var/cache/yum /var/log/dnf* /var/log/yum.log /var/log/hawkey.log
    ;;
  suse)
    zypper --non-interactive clean --all
    rm -rf /var/log/zypper.log /var/log/zypp
    ;;
esac
rm -rf /var/log/*.log /tmp/* /var/tmp/* /root/.cache /root/.ansible
echo ">> container cleanup complete (${PKG_FAMILY})"
