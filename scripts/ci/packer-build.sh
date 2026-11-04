#!/usr/bin/env bash
# Build one target of one image request with Packer.
# Inputs: IMAGE_NAME, TARGET (aws | azure | docker), and build/<image>/ from the plan job.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/ci/lib.sh
source scripts/ci/lib.sh

require_env IMAGE_NAME TARGET
VARS_FILE="build/${IMAGE_NAME}/variables.pkrvars.json"
[[ -f "$VARS_FILE" ]] || die "$VARS_FILE not found (artifacts from the plan job are missing)"
SOURCE="$(source_for_target "$TARGET")"

case "$TARGET" in
  aws)
    aws_login
    ;;
  azure)
    azure_login
    ensure_gallery_image_definition "$VARS_FILE"
    # Only this runner may SSH to the temporary build VM.
    runner_ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
    export PKR_VAR_azure_allowed_inbound_ip_addresses="[\"${runner_ip}\"]"
    log "Build VM SSH restricted to runner IP ${runner_ip}"
    ;;
  docker)
    registry_env
    export PKR_VAR_docker_registry="$REGISTRY"
    export PKR_VAR_docker_registry_username="$REGISTRY_USER"
    export PKR_VAR_docker_registry_password="$REGISTRY_PASSWORD"
    mkdir -p "${PACKER_TMP_DIR:-.packer-tmp}"
    ;;
esac

log "Building ${IMAGE_NAME} ${IMAGE_VERSION:-} for ${TARGET} (${SOURCE})"
packer init packer/linux
packer build \
  -only="linux.${SOURCE}" \
  -var-file="$VARS_FILE" \
  -color=false \
  -timestamp-ui \
  packer/linux

log "Artifacts:"
jq '.builds[] | {name, artifact_id}' "build/${IMAGE_NAME}/output/manifest.json"
