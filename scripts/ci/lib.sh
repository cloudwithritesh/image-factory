#!/usr/bin/env bash
# Shared helpers for the CI scripts. Source this file; don't run it.
#
# The scripts run unchanged on GitHub Actions and GitLab CI. Platform
# differences are handled here:
#   cloud login      GitLab: exchange the ID token here
#                    GitHub: the workflow logs in first (aws-actions, azure/login)
#   registry         REGISTRY / REGISTRY_USER / REGISTRY_PASSWORD (GitHub: GHCR),
#                    falling back to GitLab's CI_REGISTRY* variables
#   artifact store   GitHub: a release per image version
#                    GitLab: the generic package registry

log() { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "required variable $name is not set (see README: CI variables)"
  done
}

ci_platform() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then echo github
  elif [[ "${GITLAB_CI:-}" == "true" ]]; then echo gitlab
  else echo local
  fi
}

# Container registry credentials, whichever platform we're on
registry_env() {
  export REGISTRY="${REGISTRY:-${CI_REGISTRY:-}}"
  export REGISTRY_USER="${REGISTRY_USER:-${CI_REGISTRY_USER:-}}"
  export REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-${CI_REGISTRY_PASSWORD:-}}"
  require_env REGISTRY REGISTRY_USER REGISTRY_PASSWORD
}

# Packer source name for a target
source_for_target() {
  case "$1" in
    aws)    echo "amazon-ebs.linux" ;;
    azure)  echo "azure-arm.linux" ;;
    docker) echo "docker.linux" ;;
    *) die "unknown target: $1" ;;
  esac
}

# AWS credentials. On GitLab, exchange the ID token (the SDKs in Packer and
# the AWS CLI refresh from the token file). On GitHub, the workflow has
# already run aws-actions/configure-aws-credentials.
aws_login() {
  require_env PKR_VAR_aws_region
  export AWS_REGION="$PKR_VAR_aws_region"
  export AWS_DEFAULT_REGION="$PKR_VAR_aws_region"
  if [[ -n "${AWS_ID_TOKEN:-}" ]]; then
    require_env AWS_BUILD_ROLE_ARN
    local token_file
    token_file="$(mktemp)"
    printf '%s' "$AWS_ID_TOKEN" > "$token_file"
    export AWS_ROLE_ARN="$AWS_BUILD_ROLE_ARN"
    export AWS_WEB_IDENTITY_TOKEN_FILE="$token_file"
    export AWS_ROLE_SESSION_NAME="ci-${CI_PROJECT_ID:-local}-${CI_JOB_ID:-0}"
  fi
  local arn
  arn="$(aws sts get-caller-identity --query Arn --output text)" \
    || die "no AWS credentials (GitLab: AWS_ID_TOKEN; GitHub: configure-aws-credentials step)"
  log "AWS identity: ${arn}"
}

# Azure login with workload identity federation (GitLab), or reuse the
# session created by azure/login (GitHub).
azure_login() {
  require_env PKR_VAR_azure_subscription_id
  if [[ -n "${AZURE_ID_TOKEN:-}" ]]; then
    require_env AZURE_CLIENT_ID AZURE_TENANT_ID
    az login --service-principal \
      --username "$AZURE_CLIENT_ID" \
      --tenant "$AZURE_TENANT_ID" \
      --federated-token "$AZURE_ID_TOKEN" \
      --allow-no-subscriptions --output none
  fi
  az account set --subscription "$PKR_VAR_azure_subscription_id" \
    || die "no Azure session (GitLab: AZURE_ID_TOKEN; GitHub: azure/login step)"
  log "Azure subscription: $(az account show --query name --output tsv)"
}

# Store a file with the image version and print its download URL.
#   GitHub: asset on release "<image>-<version>" (created on first upload)
#   GitLab: generic package "<image>", version "<version>"
upload_package_file() {
  local file="$1" name url tag
  require_env IMAGE_NAME IMAGE_VERSION
  name="$(basename "$file")"
  case "$(ci_platform)" in
    github)
      require_env GH_TOKEN GITHUB_REPOSITORY GITHUB_SHA
      tag="${IMAGE_NAME}-${IMAGE_VERSION}"
      # Several promote jobs may race to create the release; losing is fine.
      gh release view "$tag" > /dev/null 2>&1 \
        || gh release create "$tag" --target "$GITHUB_SHA" \
             --title "${IMAGE_NAME} ${IMAGE_VERSION}" \
             --notes "Golden image ${IMAGE_NAME} ${IMAGE_VERSION}: SBOMs, scan reports and catalog records." \
             > /dev/null 2>&1 \
        || true
      gh release upload "$tag" "$file" --clobber > /dev/null
      echo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/releases/download/${tag}/${name}"
      ;;
    gitlab)
      require_env CI_API_V4_URL CI_PROJECT_ID CI_JOB_TOKEN
      url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/${IMAGE_NAME}/${IMAGE_VERSION}/${name}"
      curl --fail-with-body --silent --show-error \
        --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
        --upload-file "$file" "$url" > /dev/null
      echo "$url"
      ;;
    *)
      echo "file://$(realpath "$file")"
      ;;
  esac
}

# One gallery image definition per image request, created on first build.
# Identifier: publisher ImageFactory / offer <os key> / sku <image name>.
ensure_gallery_image_definition() {
  local vars_file="$1" definition os_key os_type generation
  require_env PKR_VAR_azure_gallery_resource_group PKR_VAR_azure_gallery_name
  definition="$(jq -r '.azure_gallery_image_definition' "$vars_file")"
  os_key="$(jq -r '.os_key' "$vars_file")"
  os_type="$(jq -r '.azure_os_type // "Linux"' "$vars_file")"
  generation="$(jq -r '.azure_hyper_v_generation // "V2"' "$vars_file")"
  if az sig image-definition show \
       --resource-group "$PKR_VAR_azure_gallery_resource_group" \
       --gallery-name "$PKR_VAR_azure_gallery_name" \
       --gallery-image-definition "$definition" > /dev/null 2>&1; then
    log "Gallery image definition ${definition} exists"
    return
  fi
  log "Creating gallery image definition ${definition} (${os_type}, ${generation})"
  az sig image-definition create \
    --resource-group "$PKR_VAR_azure_gallery_resource_group" \
    --gallery-name "$PKR_VAR_azure_gallery_name" \
    --gallery-image-definition "$definition" \
    --publisher ImageFactory --offer "$os_key" --sku "$definition" \
    --os-type "$os_type" --os-state Generalized --hyper-v-generation "$generation" \
    --description "Golden image ${definition} (image factory)" \
    --tags ManagedBy=image-factory OsKey="$os_key" --output none
}
