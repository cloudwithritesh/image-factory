#!/usr/bin/env bash
# Generate the SBOM on the build VM with Syft (CycloneDX + SPDX JSON).
# Runs as root via Packer. The binary is checksum-verified, used once and
# then removed, so it doesn't ship in the image.
set -euo pipefail

: "${SYFT_VERSION:?SYFT_VERSION is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

TOOL_DIR=/usr/local/lib/sbom-tool
OUT_DIR=/tmp/sbom
BASE_URL="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}"
TARBALL="syft_${SYFT_VERSION}_linux_${ARCH}.tar.gz"

rm -rf "$TOOL_DIR" "$OUT_DIR"
mkdir -p "$TOOL_DIR" "$OUT_DIR"
cd "$TOOL_DIR"

curl -fsSLO "${BASE_URL}/${TARBALL}"
curl -fsSLO "${BASE_URL}/syft_${SYFT_VERSION}_checksums.txt"
grep " ${TARBALL}\$" "syft_${SYFT_VERSION}_checksums.txt" | sha256sum -c -
tar -xzf "$TARBALL" syft

# Scan the root filesystem, skipping pseudo filesystems and the tool itself.
./syft scan dir:/ \
  --source-name "$IMAGE_NAME" \
  --source-version "$IMAGE_VERSION" \
  --exclude './proc/**' \
  --exclude './sys/**' \
  --exclude './dev/**' \
  --exclude './run/**' \
  --exclude './tmp/**' \
  --exclude './var/tmp/**' \
  --exclude './usr/local/lib/sbom-tool/**' \
  -o "cyclonedx-json=${OUT_DIR}/sbom.cdx.json" \
  -o "spdx-json=${OUT_DIR}/sbom.spdx.json"

# Packer downloads these files as the SSH user, not as root.
chown -R "${SUDO_USER:-root}" "$OUT_DIR"
chmod 0644 "$OUT_DIR"/*.json

cd /
rm -rf "$TOOL_DIR"
echo "SBOM written: $(du -h "${OUT_DIR}/sbom.cdx.json" | cut -f1) CycloneDX, $(du -h "${OUT_DIR}/sbom.spdx.json" | cut -f1) SPDX"
