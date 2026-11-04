#!/usr/bin/env bash
# Vulnerability gate. Scans the SBOM with Grype and fails the job when
# findings reach FAIL_ON_SEVERITY.
#   VM targets:  SBOM was produced on the build VM by Packer
#   docker:      SBOM is produced here from the pushed candidate image
set -euo pipefail
cd "$(dirname "$0")/../.."
export FACTORY_LOG_DIR="build/${IMAGE_NAME:?IMAGE_NAME is required}/output/logs"
export FACTORY_LOG_COMPONENT=scan
# shellcheck source=scripts/ci/lib.sh
source scripts/ci/lib.sh
log_trap_errors

require_env IMAGE_NAME IMAGE_VERSION TARGET FAIL_ON_SEVERITY
OUT="build/${IMAGE_NAME}/output"
SBOM_DIR="${OUT}/sbom"
mkdir -p "$SBOM_DIR" "${OUT}/scan"

case "$TARGET" in
  docker)
    registry_env
    repo="$(jq -r '.docker_repository' "build/${IMAGE_NAME}/plan.json")"
    image_ref="${repo}:candidate-${IMAGE_VERSION}"
    export SYFT_REGISTRY_AUTH_AUTHORITY="$REGISTRY"
    export SYFT_REGISTRY_AUTH_USERNAME="$REGISTRY_USER"
    export SYFT_REGISTRY_AUTH_PASSWORD="$REGISTRY_PASSWORD"
    log "Generating SBOM for ${image_ref}"
    syft scan "registry:${image_ref}" \
      --source-name "$IMAGE_NAME" --source-version "$IMAGE_VERSION" \
      -o "cyclonedx-json=${SBOM_DIR}/${IMAGE_NAME}-${IMAGE_VERSION}-docker.cdx.json" \
      -o "spdx-json=${SBOM_DIR}/${IMAGE_NAME}-${IMAGE_VERSION}-docker.spdx.json"
    sbom="${SBOM_DIR}/${IMAGE_NAME}-${IMAGE_VERSION}-docker.cdx.json"
    ;;
  aws) sbom="${SBOM_DIR}/${IMAGE_NAME}-${IMAGE_VERSION}-amazon-ebs.cdx.json" ;;
  azure) sbom="${SBOM_DIR}/${IMAGE_NAME}-${IMAGE_VERSION}-azure-arm.cdx.json" ;;
  *) die "unknown target $TARGET" ;;
esac
[[ -s "$sbom" ]] || die "SBOM not found: $sbom"
log "SBOM: $sbom ($(jq '.components | length' "$sbom") components)"

grype_args=(--fail-on "$FAIL_ON_SEVERITY")
[[ "${ONLY_FIXED:-true}" == "true" ]] && grype_args+=(--only-fixed)

report="${OUT}/scan/${IMAGE_NAME}-${IMAGE_VERSION}-${TARGET}.grype.json"
log "Scanning (fail on: ${FAIL_ON_SEVERITY}, only fixed: ${ONLY_FIXED:-true})"
set +e
grype "sbom:${sbom}" "${grype_args[@]}" -o table -o "json=${report}" 2>&1 | tee "${FACTORY_LOG_DIR}/grype.log"
rc=${PIPESTATUS[0]}
set -e

# Summary for the job log and the catalog record
jq '[.matches[].vulnerability.severity] | group_by(.) | map({(.[0]): length}) | add // {}' \
  "$report" > "${OUT}/scan/summary-${TARGET}.json"
log_info "findings by severity: $(cat "${OUT}/scan/summary-${TARGET}.json")" event=scan_result rc="$rc"

[[ $rc -eq 0 ]] || die "vulnerability gate failed (findings at or above '${FAIL_ON_SEVERITY}'). The image stays a candidate and is not promoted."
# Promotion refuses to run without this marker.
date -u +%Y-%m-%dT%H:%M:%SZ > "${OUT}/scan/PASSED-${TARGET}"
log "Vulnerability gate passed"
