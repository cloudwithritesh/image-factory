#!/usr/bin/env bash
# Run `packer validate` for every request rendered by `imagefactory.py plan`,
# limited to the targets each request asks for.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/ci/lib.sh
source scripts/ci/lib.sh

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

packer init packer/linux

count="$(jq 'length' "$PLAN")"
if [[ "$count" -eq 0 ]]; then
  log "No requests selected; validating the template syntax only"
  packer validate -syntax-only packer/linux
  exit 0
fi

for name in $(jq -r '.[].name' "$PLAN"); do
  only="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .targets[]' "$PLAN" \
    | while read -r t; do printf 'linux.%s,' "$(source_for_target "$t")"; done)"
  log "packer validate: $name (${only%,})"
  packer validate -only="${only%,}" -var-file="build/${name}/variables.pkrvars.json" packer/linux
done
