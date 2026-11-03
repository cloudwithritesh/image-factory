#!/bin/sh
# Shrink and tidy the container image before Packer commits it.
set -eu
export DEBIAN_FRONTEND=noninteractive

apt-get -y autoremove --purge
apt-get -y clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
       /var/log/apt/* /var/log/dpkg.log /var/log/*.log \
       /tmp/* /var/tmp/* /root/.cache /root/.ansible
echo ">> container cleanup complete"
