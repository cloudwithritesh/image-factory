#!/usr/bin/env bash
# Build one target of one image request with Packer.
# Inputs: IMAGE_NAME, TARGET (aws | azure | docker), and build/<image>/ from the plan job.
#
# Logs (build/<image>/output/logs/, uploaded with the output artifact):
#   packer.log         full Packer console output (what you see in the job log)
#   ansible.log        Ansible output for the provisioning stage
#   packer-debug.log   Packer internals, only when FACTORY_LOG_LEVEL=debug
#   events.jsonl       structured step events (scripts/ci/log.sh)
set -euo pipefail
cd "$(dirname "$0")/../.."
export FACTORY_LOG_DIR="build/${IMAGE_NAME:?IMAGE_NAME is required}/output/logs"
export FACTORY_LOG_COMPONENT=packer-build
# shellcheck source=scripts/ci/lib.sh
source scripts/ci/lib.sh
log_trap_errors

require_env IMAGE_NAME TARGET
VARS_FILE="build/${IMAGE_NAME}/variables.pkrvars.json"
[[ -f "$VARS_FILE" ]] || die "$VARS_FILE not found (artifacts from the plan job are missing)"
FAMILY="$(image_family "$IMAGE_NAME")"
TEMPLATE="packer/${FAMILY}"
SOURCE="$(source_for_target "$TARGET" "$FAMILY")"
write_run_context

# Ansible writes its own log; Packer's internal debug log only on request
# (it's verbose and can include infrastructure details).
export ANSIBLE_LOG_PATH="${PWD}/${FACTORY_LOG_DIR}/ansible.log"
if factory_debug_enabled; then
  export PACKER_LOG=1 PACKER_LOG_PATH="${FACTORY_LOG_DIR}/packer-debug.log"
  export ANSIBLE_VERBOSITY=2
  log_warn "debug logging is on: packer-debug.log may contain infrastructure details; artifact retention is short"
fi

case "$TARGET" in
  aws)
    run_step "cloud login (aws)" aws_login
    ;;
  azure)
    run_step "cloud login (azure)" azure_login
    run_step "gallery image definition" ensure_gallery_image_definition "$VARS_FILE"
    # Only this runner may reach the temporary build VM (SSH 22 / WinRM 5986).
    runner_ip="$(curl -fsS --retry 3 https://checkip.amazonaws.com | tr -d '[:space:]')"
    export PKR_VAR_azure_allowed_inbound_ip_addresses="[\"${runner_ip}\"]"
    log_info "build VM access restricted to the runner IP" runner_ip="$runner_ip"
    ;;
  docker)
    registry_env
    export PKR_VAR_docker_registry="$REGISTRY"
    export PKR_VAR_docker_registry_username="$REGISTRY_USER"
    export PKR_VAR_docker_registry_password="$REGISTRY_PASSWORD"
    mkdir -p "${PACKER_TMP_DIR:-.packer-tmp}"
    ;;
esac

log_info "building ${IMAGE_NAME} ${IMAGE_VERSION:-} for ${TARGET}" template="$TEMPLATE" source="$SOURCE" \
  os="$(jq -r .os "build/${IMAGE_NAME}/plan.json")"
run_step "packer init" packer init "$TEMPLATE"

packer_build() {
  # Console output is kept in packer.log as well (pipefail keeps the exit code)
  packer build \
    -only="${FAMILY}.${SOURCE}" \
    -var-file="$VARS_FILE" \
    -color=false \
    -timestamp-ui \
    "$TEMPLATE" 2>&1 | tee "${FACTORY_LOG_DIR}/packer.log"
}

if ! run_step "packer build" packer_build; then
  python3 scripts/ci/triage.py "${FACTORY_LOG_DIR}/packer.log" "${ANSIBLE_LOG_PATH}" \
    --title "Build failed: ${IMAGE_NAME} / ${TARGET}" || true
  die "packer build failed for ${IMAGE_NAME} (${TARGET}); logs: ${FACTORY_LOG_DIR}/"
fi

log_info "artifacts: $(jq -c '[.builds[] | {name, artifact_id}]' "build/${IMAGE_NAME}/output/manifest.json")" event=artifact
