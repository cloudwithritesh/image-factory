#!/usr/bin/env bash
# Create the short-lived branch, the standard commit and the pull request
# for a processed portal request (the JSON written by process_request.py).
#
#   scripts/portal/open_pr.sh result.json
#
# Env: GH_TOKEN (GitHub App token, or GITHUB_TOKEN), GITHUB_REPOSITORY,
#      GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL (bot identity)
set -euo pipefail
RESULT="${1:?usage: open_pr.sh result.json}"

jqr() { jq -r "$1" "$RESULT"; }
branch="$(jqr .branch)"
path="$(jqr .path)"
title="$(jqr .title)"
: "${GIT_AUTHOR_NAME:?}" "${GIT_AUTHOR_EMAIL:?}" "${GITHUB_REPOSITORY:?}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

body_file="$(mktemp)"
msg_file="$(mktemp)"
jqr .body > "$body_file"
jqr .commit_message > "$msg_file"

# Labels are created on first use so the repo needs no setup
gh label create portal --color 5319e7 --description "Created by the self-service portal" > /dev/null 2>&1 || true
gh label create image-request --color 0e8a16 --description "Golden image request" > /dev/null 2>&1 || true
gh label create vm-request --color 1d76db --description "VM request" > /dev/null 2>&1 || true

git switch -c "$branch"
git add -- "$path"
git commit --quiet --file "$msg_file"
git push --quiet --set-upstream origin "$branch"

label_args=()
while read -r label; do label_args+=(--label "$label"); done < <(jq -r '.labels[]' "$RESULT")

pr_url="$(gh pr create --base main --head "$branch" --title "$title" --body-file "$body_file" "${label_args[@]}")"
echo "$pr_url"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "pr_url=${pr_url}"
    echo "branch=${branch}"
    echo "sha=$(git rev-parse HEAD)"
  } >> "$GITHUB_OUTPUT"
fi
