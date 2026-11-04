#!/usr/bin/env bash
# =============================================================================
# Apply the repository settings behind docs/standards.md:
#   - squash merge only, using the PR title (one conventional commit per PR)
#   - delete head branches on merge (short-lived branches)
#   - ruleset on main: PR required, 1 approving review incl. code owners,
#     required checks pr-standards + lint + plan, linear history, no
#     force-push or deletion. Nobody bypasses it, admins included: the
#     "Squash and merge" button stays disabled until a reviewer approves
#     and the checks pass. (GitHub never lets authors approve their own PR,
#     so a sole maintainer needs a second reviewer for PRs they open.)
#   - PR workflows from collaborators' branches run without approval; only
#     first-time contributors from forks who are new to GitHub need it
#   - GitHub Actions may create pull requests (portal fallback without an App)
#   - GitHub Pages served by the portal-pages workflow
#
# Usage: scripts/bootstrap/configure-github-repo.sh [owner/repo]
#   ALLOW_ADMIN_BYPASS=true  emergency only: lets repo admins merge without
#                            approval again (re-run without it to undo)
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

# can_approve_pull_request_reviews also allows workflows to open PRs. A
# workflow can't approve a PR that counts towards the ruleset anyway (its
# reviews come from github-actions[bot], which is not a code owner).
gh api -X PUT "repos/${REPO}/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true > /dev/null
ok "workflows: read-only token by default, allowed to open PRs"

# PR checks run without "Approve and run" for anyone with write access
# (their branches are in this repo). Forks: only accounts that are new to
# GitHub need approval, the least restrictive setting GitHub offers; fork
# runs get a read-only token and no secrets either way.
if gh api -X PUT "repos/${REPO}/actions/permissions/fork-pr-contributor-approval" \
  -f approval_policy=first_time_contributors_new_to_github > /dev/null 2>&1; then
  ok "fork PR workflows: approval only for first-time contributors new to GitHub"
else
  warn "couldn't set the fork PR approval policy (older GHES?); set it under Settings > Actions > General"
fi

ruleset="$(cat <<'JSON'
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
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
        "required_status_checks": [
          { "context": "pr-standards" },
          { "context": "lint" },
          { "context": "plan" }
        ]
      }
    }
  ]
}
JSON
)"
if [[ "${ALLOW_ADMIN_BYPASS:-false}" == "true" ]]; then
  ruleset="$(jq '.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}]' <<< "$ruleset")"
  warn "ALLOW_ADMIN_BYPASS=true: repo admins can merge their own PRs without approval"
fi
existing="$(gh api "repos/${REPO}/rulesets" -q '.[] | select(.name=="main-protection") | .id' 2> /dev/null || true)"
if [[ -n "$existing" ]]; then
  method=PUT; path="repos/${REPO}/rulesets/${existing}"
else
  method=POST; path="repos/${REPO}/rulesets"
fi
if gh api -X "$method" "$path" --input - <<< "$ruleset" > /dev/null 2>&1; then
  ok "ruleset main-protection (1 approval + code owner; checks pr-standards, lint, plan; no bypass)"
else
  # Rulesets need a public repo or a paid plan (Pro/Team/Enterprise)
  warn "couldn't create the ruleset (private repo on GitHub Free?). The pr-standards check"
  warn "still runs on every PR, but main isn't protected: make the repo public or upgrade."
fi

if gh api "repos/${REPO}/pages" > /dev/null 2>&1; then
  gh api -X PUT "repos/${REPO}/pages" -f build_type=workflow > /dev/null
else
  gh api -X POST "repos/${REPO}/pages" -f build_type=workflow > /dev/null \
    || warn "couldn't enable Pages (private repos need a paid plan)"
fi
pages_url="$(gh api "repos/${REPO}/pages" -q .html_url 2> /dev/null || true)"
ok "GitHub Pages from the portal-pages workflow ${pages_url:+(${pages_url})}"
if [[ -n "$pages_url" ]]; then
  if gh workflow run portal-pages.yml --repo "$REPO" --ref main > /dev/null 2>&1; then
    ok "started a portal-pages deployment"
  fi
fi

echo
echo "Optional (recommended): a GitHub App for the portal bot, so portal PRs run"
echo "the normal PR checks and show as <app>[bot]. See portal/README.md."
