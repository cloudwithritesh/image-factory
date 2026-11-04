#!/usr/bin/env bash
# Promote a scanned candidate image so consumers can find and use it:
#   1. store the SBOMs and scan report (GitHub release / GitLab package registry)
#   2. aws:    tag the AMI approved, share it, update the SSM catalog parameters
#      azure:  include the gallery version in "latest", tag it approved
#      docker: add the <version> and latest tags to the candidate image
#   3. upload a catalog record (JSON) that the portal reads
set -euo pipefail
cd "$(dirname "$0")/../.."
export FACTORY_LOG_DIR="build/${IMAGE_NAME:?IMAGE_NAME is required}/promote-logs"
export FACTORY_LOG_COMPONENT=promote
# shellcheck source=scripts/ci/lib.sh
source scripts/ci/lib.sh
log_trap_errors
write_run_context

require_env IMAGE_NAME IMAGE_VERSION TARGET
OUT="build/${IMAGE_NAME}/output"
PLAN="build/${IMAGE_NAME}/plan.json"
SSM_PREFIX="${CATALOG_SSM_PREFIX:-/image-factory}"

[[ -f "${OUT}/scan/PASSED-${TARGET}" ]] \
  || die "no passing scan for ${IMAGE_NAME} ${IMAGE_VERSION} on ${TARGET}; refusing to promote"

# ---- 1. SBOM and scan report -----------------------------------------------
case "$TARGET" in
  aws)    sbom_key="amazon-ebs" ;;
  azure)  sbom_key="azure-arm" ;;
  docker) sbom_key="docker" ;;
esac
sbom_url="$(upload_package_file "${OUT}/sbom/${IMAGE_NAME}-${IMAGE_VERSION}-${sbom_key}.cdx.json")"
upload_package_file "${OUT}/sbom/${IMAGE_NAME}-${IMAGE_VERSION}-${sbom_key}.spdx.json" > /dev/null
scan_url="$(upload_package_file "${OUT}/scan/${IMAGE_NAME}-${IMAGE_VERSION}-${TARGET}.grype.json")"
log "SBOM stored at ${sbom_url}"

artifacts='[]'

# ---- 2. Target-specific promotion -----------------------------------------
case "$TARGET" in
  aws)
    aws_login
    # artifact_id looks like "ap-southeast-1:ami-0abc,eu-west-1:ami-0def"
    artifact_id="$(jq -r '[.builds[] | select(.builder_type == "amazon-ebs")] | last | .artifact_id' "${OUT}/manifest.json")"
    IFS=',' read -ra pairs <<< "$artifact_id"
    for pair in "${pairs[@]}"; do
      region="${pair%%:*}"; ami="${pair#*:}"
      log "Promoting ${ami} in ${region}"
      aws ec2 create-tags --region "$region" --resources "$ami" --tags \
        Key=Status,Value=approved Key=SbomUrl,Value="$sbom_url"

      if [[ -n "${AWS_SHARE_ORG_ARN:-}" ]]; then
        aws ec2 modify-image-attribute --region "$region" --image-id "$ami" \
          --launch-permission "Add=[{OrganizationArn=${AWS_SHARE_ORG_ARN}}]"
      fi
      for account in ${AWS_SHARE_ACCOUNT_IDS//,/ }; do
        aws ec2 modify-image-attribute --region "$region" --image-id "$ami" \
          --launch-permission "Add=[{UserId=${account}}]"
      done

      aws ssm put-parameter --region "$region" --overwrite \
        --name "${SSM_PREFIX}/${IMAGE_NAME}/latest" \
        --type String --data-type aws:ec2:image --value "$ami" > /dev/null
      aws ssm put-parameter --region "$region" \
        --name "${SSM_PREFIX}/${IMAGE_NAME}/versions/${IMAGE_VERSION}" \
        --type String --data-type aws:ec2:image --value "$ami" > /dev/null
      artifacts="$(jq -c --arg r "$region" --arg a "$ami" \
        --arg p "${SSM_PREFIX}/${IMAGE_NAME}/latest" \
        '. + [{region: $r, ami_id: $a, ssm_parameter: $p}]' <<< "$artifacts")"
    done
    ;;

  azure)
    azure_login
    require_env PKR_VAR_azure_gallery_resource_group PKR_VAR_azure_gallery_name
    definition="$(jq -r '.azure_gallery_image_definition' "$PLAN")"
    log "Promoting gallery version ${definition}/${IMAGE_VERSION}"
    version_id="$(az sig image-version update \
      --resource-group "$PKR_VAR_azure_gallery_resource_group" \
      --gallery-name "$PKR_VAR_azure_gallery_name" \
      --gallery-image-definition "$definition" \
      --gallery-image-version "$IMAGE_VERSION" \
      --set publishingProfile.excludeFromLatest=false tags.Status=approved tags.SbomUrl="$sbom_url" \
      --query id --output tsv)"
    artifacts="$(jq -c --arg id "$version_id" --arg d "$definition" \
      '[{gallery_image_version_id: $id, image_definition: $d}]' <<< "$artifacts")"
    ;;

  docker)
    registry_env
    repo="$(jq -r '.docker_repository' "$PLAN")"
    crane auth login "$REGISTRY" -u "$REGISTRY_USER" -p "$REGISTRY_PASSWORD"
    log "Tagging ${repo}:candidate-${IMAGE_VERSION} as ${IMAGE_VERSION} and latest"
    crane tag "${repo}:candidate-${IMAGE_VERSION}" "$IMAGE_VERSION"
    crane tag "${repo}:candidate-${IMAGE_VERSION}" latest
    digest="$(crane digest "${repo}:${IMAGE_VERSION}")"
    artifacts="$(jq -c --arg ref "${repo}:${IMAGE_VERSION}" --arg d "$digest" \
      '[{image: $ref, digest: $d, pinned: ($ref | split(":")[0]) + "@" + $d}]' <<< "$artifacts")"
    ;;
esac

# ---- 3. Catalog record -----------------------------------------------------
record="${OUT}/catalog-${TARGET}.json"
jq -n \
  --arg name "$IMAGE_NAME" --arg version "$IMAGE_VERSION" --arg target "$TARGET" \
  --arg sbom "$sbom_url" --arg scan "$scan_url" \
  --arg pipeline "$(jq -r '.pipeline_url' "build/${IMAGE_NAME}/variables.pkrvars.json")" \
  --arg sha "${GITHUB_SHA:-${CI_COMMIT_SHA:-local}}" \
  --argjson artifacts "$artifacts" \
  --argjson findings "$(cat "${OUT}/scan/summary-${TARGET}.json")" \
  --argjson plan "$(cat "$PLAN")" \
  '{
     image: $name, version: $version, target: $target, status: "approved",
     os: $plan.os, artifacts: $artifacts,
     sbom_url: $sbom, scan_report_url: $scan, findings: $findings,
     promoted_at: (now | todate), pipeline: $pipeline, git_sha: $sha
   }' > "$record"
upload_package_file "$record" > /dev/null
log "Catalog record:"
cat "$record"
