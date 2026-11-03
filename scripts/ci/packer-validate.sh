#!/usr/bin/env bash
# Run `packer validate` for every request rendered by `imagefactory.py plan`,
# limited to the targets each request asks for.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/ci/lib.sh
source scripts/ci/lib.sh

PLAN=build/plan.json
[[ -f "$PLAN" ]] || die "$PLAN not found; run scripts/imagefactory.py plan first"

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
