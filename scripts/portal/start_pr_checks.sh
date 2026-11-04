#!/usr/bin/env bash
# Start the required PR checks for a pull request opened with GITHUB_TOKEN.
#
# GitHub doesn't run pull_request workflows for PRs created by
# GITHUB_TOKEN (it asks for "Approve and run" instead). workflow_dispatch
# from GITHUB_TOKEN is allowed, so this starts the same workflows on the PR
# branch. Their jobs (pr-standards, lint, plan) report check runs on the
# branch's head commit, which is the PR's head commit, so the required
# checks are satisfied without anyone approving a run.
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, BRANCH, PR_URL, KIND, REQUEST_PATH
set -euo pipefail
export FACTORY_LOG_COMPONENT=start-pr-checks
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/ci/log.sh
source scripts/ci/log.sh
: "${BRANCH:?}" "${PR_URL:?}" "${GITHUB_REPOSITORY:?}"
pr="${PR_URL##*/}"

dispatch() {
  local workflow="$1"
  shift
  gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" --ref "$BRANCH" "$@"
}

die_soft=0
run_step "dispatch pr-standards (PR #${pr})" dispatch pr-standards.yml -f pr="$pr" || die_soft=1
if [[ "${KIND:-}" == "image" && -n "${REQUEST_PATH:-}" ]]; then
  # Plan exactly the request this PR changes (validates it with packer validate)
  run_step "dispatch image-factory lint+plan (${REQUEST_PATH})" dispatch image-factory.yml -f image_request="$REQUEST_PATH" \
    || die_soft=1
else
  run_step "dispatch image-factory lint+plan" dispatch image-factory.yml || die_soft=1
fi

if [[ "$die_soft" == "1" ]]; then
  log_error "couldn't start every PR check; a maintainer can start them from the Actions tab (Run workflow on ${BRANCH})"
  exit 1
fi
log_info "PR checks started on ${BRANCH}; they appear on ${PR_URL} in a few seconds" pr="$pr" branch="$BRANCH"
