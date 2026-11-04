#!/bin/sh
# Prepare a Linux build target for Ansible. Runs as root (Packer), first
# provisioner of every Linux build.
#   VMs:        wait for cloud-init, then make sure a supported Python exists
#   containers: install Python (minimal base images ship without it)
#
# Inputs: PKG_FAMILY (debian | redhat | suse), IMAGE_KIND (vm | container)
# POSIX sh on purpose: minimal images may not have bash.
set -eu

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s [bootstrap] %s\n' "$(ts)" "$*"; }

: "${PKG_FAMILY:?PKG_FAMILY is required}"
: "${IMAGE_KIND:?IMAGE_KIND is required}"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091  # present on every supported base image
  . /etc/os-release
  log "target: ${PRETTY_NAME:-unknown} (family ${PKG_FAMILY}, ${IMAGE_KIND}, $(uname -m))"
fi

if [ "$IMAGE_KIND" = vm ] && command -v cloud-init > /dev/null 2>&1; then
  log "waiting for cloud-init to finish"
  # exit code 2 = finished with recoverable errors; still fine to continue
  rc=0; cloud-init status --wait > /dev/null || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || { log "cloud-init failed (rc=$rc)"; cloud-init status --long || true; exit "$rc"; }
  log "cloud-init done (rc=$rc)"
fi

retry() {
  # Package mirrors are the most common transient failure; retry 3 times.
  n=1
  until "$@"; do
    [ "$n" -ge 3 ] && { log "giving up after $n attempts: $*"; return 1; }
    log "attempt $n failed, retrying in $((n * 10))s: $*"
    sleep $((n * 10)); n=$((n + 1))
  done
}

case "$PKG_FAMILY" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    if [ "$IMAGE_KIND" = container ]; then
      retry apt-get update
      retry apt-get install -y --no-install-recommends python3 python3-apt ca-certificates
    fi
    ;;
  redhat)
    if command -v dnf > /dev/null 2>&1; then pm=dnf; else pm=microdnf; fi
    pkgs="python3"
    # Fedora 41+ uses dnf5; Ansible's dnf5 module needs its Python bindings.
    if [ "$pm" = dnf ] && dnf --version 2> /dev/null | grep -q '^dnf5'; then
      pkgs="$pkgs python3-libdnf5"
    fi
    if [ "$IMAGE_KIND" = container ] || ! command -v python3 > /dev/null 2>&1; then
      # shellcheck disable=SC2086  # $pkgs is a word list
      retry "$pm" -y install $pkgs
    fi
    ;;
  suse)
    # The system python3 (3.6) is too old for ansible-core; 3.11 is in the
    # base module of SLES 15 SP7 and in the BCI repository.
    retry zypper --non-interactive --gpg-auto-import-keys refresh
    retry zypper --non-interactive install --no-recommends python311
    ;;
  *)
    log "unknown PKG_FAMILY: $PKG_FAMILY"; exit 1 ;;
esac

log "python: $(command -v python3.11 || command -v python3 || echo missing)"
log "bootstrap complete"
