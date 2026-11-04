#!/usr/bin/env bash
# =============================================================================
# Apply the repository settings behind docs/standards.md:
#   - squash merge only, using the PR title (one conventional commit per PR)
#   - delete head branches on merge (short-lived branches)
#   - ruleset on main: PR required, 1 approval incl. code owners, the
#     pr-standards check required, linear history, no force-push or deletion.
#     Repo admins may bypass approvals on their own PRs.
#   - GitHub Actions may create pull requests (portal fallback without an App)
#   - GitHub Pages served by the portal-pages workflow
#
# Usage: scripts/bootstrap/configure-github-repo.sh [owner/repo]
# Needs: gh logged in as a repo admin. Safe to re-run.
# =============================================================================
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }

echo "Configuring ${REPO}"

gh api -X PATCH "repos/${REPO}" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true -F has_issues=true > /dev/null
ok "squash merge only (PR title), branches deleted on merge"

gh api -X PUT "repos/${REPO}/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true > /dev/null
ok "workflows: read-only token by default, allowed to open PRs"

ruleset="$(cat <<'JSON'
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "pr-standards" } ]
      }
    }
  ]
}
JSON
)"
existing="$(gh api "repos/${REPO}/rulesets" -q '.[] | select(.name=="main-protection") | .id' 2> /dev/null || true)"
if [[ -n "$existing" ]]; then
  gh api -X PUT "repos/${REPO}/rulesets/${existing}" --input - <<< "$ruleset" > /dev/null
else
  gh api -X POST "repos/${REPO}/rulesets" --input - <<< "$ruleset" > /dev/null
fi
ok "ruleset main-protection (PR + 1 approval + pr-standards; admins can bypass on own PRs)"

if gh api "repos/${REPO}/pages" > /dev/null 2>&1; then
  gh api -X PUT "repos/${REPO}/pages" -f build_type=workflow > /dev/null
else
  gh api -X POST "repos/${REPO}/pages" -f build_type=workflow > /dev/null \
    || warn "couldn't enable Pages (private repos need a paid plan)"
fi
pages_url="$(gh api "repos/${REPO}/pages" -q .html_url 2> /dev/null || true)"
ok "GitHub Pages from the portal-pages workflow ${pages_url:+(${pages_url})}"

echo
echo "Optional (recommended): a GitHub App for the portal bot, so portal PRs run"
echo "the normal PR checks and show as <app>[bot]. See portal/README.md."
