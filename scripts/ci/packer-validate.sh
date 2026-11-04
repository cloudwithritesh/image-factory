#!/usr/bin/env bash
# Run `packer validate` for every request rendered by `imagefactory.py plan`,
# limited to the targets each request asks for.
set -euo pipefail
cd "$(dirname "$0")/../.."
export FACTORY_LOG_COMPONENT=packer-validate
# shellcheck source=scripts/ci/lib.sh
source scripts/ci/lib.sh
log_trap_errors

PLAN=build/plan.json
[[ -f "$PLAN" ]] || die "$PLAN not found; run scripts/imagefactory.py plan first"

# Platform settings come from CI variables. When they're missing (before
# setup, or on PRs from forks), validate with placeholders so the template
# logic is still checked. Real values are always used for builds.
missing=()
placeholder() {
  local name="PKR_VAR_$1"
  if [[ -z "${!name:-}" ]]; then
    export "${name}=$2"
    missing+=("$1")
  fi
}
placeholder azure_subscription_id 00000000-0000-0000-0000-000000000000
placeholder azure_build_resource_group rg-validate-build
placeholder azure_gallery_resource_group rg-validate-gallery
placeholder azure_gallery_name sig_validate
if [[ ${#missing[@]} -gt 0 ]]; then
  log "CI variables not set (${missing[*]}); validating with placeholders"
fi

# Every template is always syntax-checked, whatever the plan contains
for template in packer/*/; do
  template="${template%/}"
  run_step "packer init ${template}" packer init "$template"
  run_step "packer validate -syntax-only ${template}" packer validate -syntax-only "$template"
done

count="$(jq 'length' "$PLAN")"
if [[ "$count" -eq 0 ]]; then
  log_info "no requests selected; templates syntax-checked only"
  exit 0
fi

for name in $(jq -r '.[].name' "$PLAN"); do
  family="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .family // "linux"' "$PLAN")"
  only="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .targets[]' "$PLAN" \
    | while read -r t; do printf '%s.%s,' "$family" "$(source_for_target "$t" "$family")"; done)"
  run_step "packer validate ${name} (${only%,})" \
    packer validate -only="${only%,}" -var-file="build/${name}/variables.pkrvars.json" "packer/${family}"
done
