#!/usr/bin/env bash
# =============================================================================
# One-time deploy of the image factory to GitHub + Azure, run from your own
# machine. It uses the logins you already have (gh and az), so no credentials
# are copied anywhere.
#
#   1. checks tools and logins
#   2. creates the GitHub repository (private by default)
#   3. creates Azure storage for Terraform state
#   4. terraform apply terraform/factory/azure (shows the plan, asks first)
#   5. stores the Terraform outputs as GitHub Actions repository variables
#   6. creates the promotion environments
#   7. pushes the code
#   8. starts the first image build
#
# Usage (from the repo root):
#   scripts/bootstrap/deploy-github-azure.sh
#
# Optional overrides (environment variables):
#   AZURE_SUBSCRIPTION_ID   default: your current az default subscription
#   AZURE_LOCATION          default: southeastasia
#   GITHUB_OWNER            default: the account gh is logged in as
#   REPO_NAME               default: image-factory
#   REPO_VISIBILITY         private | public (default: private)
#   SKIP_FIRST_BUILD=1      don't start the first build
#
# Safe to re-run: every step checks what already exists.
# Works with macOS's bash 3.2.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

AZURE_LOCATION="${AZURE_LOCATION:-southeastasia}"
REPO_NAME="${REPO_NAME:-image-factory}"
REPO_VISIBILITY="${REPO_VISIBILITY:-private}"
STATE_RG="rg-image-factory-tfstate"
STATE_CONTAINER="tfstate"
STATE_KEY="image-factory/azure.tfstate"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()    { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
step "1/8  Checking tools and logins"
missing=""
for tool in git gh az terraform jq; do
  command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
done
if [[ -n "$missing" ]]; then
  die "missing:${missing}
    macOS: brew install git gh azure-cli jq hashicorp/tap/terraform"
fi
ok "git, gh, az, terraform, jq found"

tf_version="$(terraform version -json | jq -r .terraform_version)"
case "$tf_version" in
  0.*|1.[0-5].*) die "Terraform ${tf_version} is too old; need >= 1.6 (brew upgrade hashicorp/tap/terraform)" ;;
esac
ok "terraform ${tf_version}"

gh auth status > /dev/null 2>&1 || die "GitHub CLI isn't logged in. Run: gh auth login"
# Pushing .github/workflows needs the 'workflow' scope on OAuth tokens.
scopes="$(gh api -i user 2> /dev/null | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' | tr -d '\r')"
if [[ -n "$scopes" && "$scopes" != *workflow* ]]; then
  warn "your gh token lacks the 'workflow' scope; requesting it now"
  gh auth refresh -h github.com -s workflow
fi
GH_LOGIN="$(gh api user -q .login)"
GH_USER_ID="$(gh api user -q .id)"
GH_PLAN="$(gh api user -q '.plan.name // "unknown"')"
GITHUB_OWNER="${GITHUB_OWNER:-$GH_LOGIN}"
REPO="${GITHUB_OWNER}/${REPO_NAME}"
ok "GitHub: logged in as ${GH_LOGIN} (plan: ${GH_PLAN})"

az account show > /dev/null 2>&1 || die "Azure CLI isn't logged in. Run: az login"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
AZ_SUB_NAME="$(az account show --query name -o tsv)"
AZ_TENANT="$(az account show --query tenantId -o tsv)"
ok "Azure: ${AZ_SUB_NAME} (${AZURE_SUBSCRIPTION_ID})"

# Deterministic, globally unique storage account name for this subscription
STATE_SA="stimgfac$(printf '%s' "$AZURE_SUBSCRIPTION_ID" | shasum -a 256 | cut -c1-12)"

echo
bold "About to deploy:"
cat <<EOF
    GitHub repo          ${REPO} (${REPO_VISIBILITY})
    Azure subscription   ${AZ_SUB_NAME}
    Azure tenant         ${AZ_TENANT}
    Region               ${AZURE_LOCATION}
    Terraform state      ${STATE_RG} / ${STATE_SA} / ${STATE_CONTAINER}
    Creates in Azure     rg-image-factory-gallery, rg-image-factory-build,
                         Compute Gallery sig_image_factory, Entra app image-factory-ci
                         (federated credentials for ${REPO}, no secrets)
EOF
read -r -p "Continue? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || die "cancelled"

# -----------------------------------------------------------------------------
step "2/8  GitHub repository"
if gh repo view "$REPO" > /dev/null 2>&1; then
  ok "${REPO} already exists"
else
  gh repo create "$REPO" "--${REPO_VISIBILITY}" \
    --description "Golden image factory: Packer + Ansible + Terraform, AWS/Azure/Docker, CIS hardening, SBOM"
  ok "created ${REPO}"
fi

# Numeric IDs for GitHub's immutable OIDC subject format (repos created
# after 2026-07-15 use it by default).
GH_REPO_ID="$(gh api "repos/${REPO}" -q .id)"
GH_OWNER_ID="$(gh api "repos/${REPO}" -q .owner.id)"
ok "repo id ${GH_REPO_ID}, owner id ${GH_OWNER_ID}"

# -----------------------------------------------------------------------------
step "3/8  Terraform state storage"
az group create --name "$STATE_RG" --location "$AZURE_LOCATION" \
  --tags Component=image-factory ManagedBy=bootstrap -o none
if ! az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" > /dev/null 2>&1; then
  az storage account create --name "$STATE_SA" --resource-group "$STATE_RG" \
    --location "$AZURE_LOCATION" --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --allow-blob-public-access false --https-only true \
    --tags Component=image-factory ManagedBy=bootstrap -o none
fi
az storage account blob-service-properties update --account-name "$STATE_SA" \
  --resource-group "$STATE_RG" --enable-versioning true -o none
STATE_KEY_VALUE="$(az storage account keys list --account-name "$STATE_SA" \
  --resource-group "$STATE_RG" --query '[0].value' -o tsv)"
az storage container create --name "$STATE_CONTAINER" --account-name "$STATE_SA" \
  --account-key "$STATE_KEY_VALUE" -o none
unset STATE_KEY_VALUE
ok "state in ${STATE_SA}/${STATE_CONTAINER} (blob versioning on)"

# -----------------------------------------------------------------------------
step "4/8  Terraform: Azure foundation"
(
  cd terraform/factory/azure
  terraform init -input=false -reconfigure \
    -backend-config="subscription_id=${AZURE_SUBSCRIPTION_ID}" \
    -backend-config="resource_group_name=${STATE_RG}" \
    -backend-config="storage_account_name=${STATE_SA}" \
    -backend-config="container_name=${STATE_CONTAINER}" \
    -backend-config="key=${STATE_KEY}"
  terraform apply -input=false \
    -var="subscription_id=${AZURE_SUBSCRIPTION_ID}" \
    -var="location=${AZURE_LOCATION}" \
    -var="github_repository=${REPO}" \
    -var="github_repository_id=${GH_REPO_ID}" \
    -var="github_owner_id=${GH_OWNER_ID}"
)
CI_VARS="$(terraform -chdir=terraform/factory/azure output -json ci_variables)"
ok "Azure foundation applied"

# -----------------------------------------------------------------------------
step "5/8  GitHub Actions repository variables"
echo "$CI_VARS" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' |
  while IFS="$(printf '\t')" read -r key value; do
    gh variable set "$key" --repo "$REPO" --body "$value"
    ok "$key"
  done

# -----------------------------------------------------------------------------
step "6/8  Promotion environments"
# Free-plan private repos can't use environments. Fall back to promoting
# without them; the OIDC trust for the main branch still applies.
use_envs=true
if [[ "$REPO_VISIBILITY" == "private" && "$GH_PLAN" == "free" ]]; then
  use_envs=false
fi
if $use_envs; then
  for env in images-azure images-docker; do
    gh api -X PUT "repos/${REPO}/environments/${env}" > /dev/null && ok "$env"
  done
  for env in images-azure-approval images-docker-approval; do
    if gh api -X PUT "repos/${REPO}/environments/${env}" --input - > /dev/null 2>&1 \
         <<< "{\"reviewers\":[{\"type\":\"User\",\"id\":${GH_USER_ID}}]}"; then
      ok "${env} (required reviewer: ${GH_LOGIN})"
    else
      gh api -X PUT "repos/${REPO}/environments/${env}" > /dev/null
      warn "${env} created, but your plan doesn't allow required reviewers on this repo"
    fi
  done
  gh variable set PROMOTION_ENVIRONMENTS --repo "$REPO" --body "true"
else
  gh variable set PROMOTION_ENVIRONMENTS --repo "$REPO" --body "false"
  warn "GitHub Free + private repo: no environments, so promotion: manual isn't available."
  warn "Images promote automatically after passing the scan."
fi

# -----------------------------------------------------------------------------
step "7/8  Push the code"
gh auth setup-git > /dev/null 2>&1 || true
remote_url="https://github.com/${REPO}.git"
if [[ ! -d .git ]]; then
  git init -q -b main
fi
if git remote get-url origin > /dev/null 2>&1; then
  git remote set-url origin "$remote_url"
else
  git remote add origin "$remote_url"
fi
# If the repo already has commits (README/LICENSE from GitHub, or an earlier
# push), build on top of them so the push is a fast-forward.
if git ls-remote --exit-code --heads origin main > /dev/null 2>&1; then
  git fetch -q origin main
  if ! git rev-parse --verify -q HEAD > /dev/null; then
    git reset -q origin/main # adopt remote history, keep local files
  fi
fi
if git rev-parse --verify -q HEAD > /dev/null; then
  git checkout -q -B main
fi
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git -c user.name="${GIT_AUTHOR_NAME:-$GH_LOGIN}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-${GH_USER_ID}+${GH_LOGIN}@users.noreply.github.com}" \
      commit -q -m "Image factory phase 1: Packer/Ansible/Terraform, GitHub Actions + GitLab CI"
  ok "committed"
fi
git push -u origin main
ok "pushed to ${remote_url}"

# -----------------------------------------------------------------------------
step "8/8  First image build"
if [[ "${SKIP_FIRST_BUILD:-0}" == "1" ]]; then
  warn "skipped (SKIP_FIRST_BUILD=1)"
else
  # GitHub needs a moment to register a newly pushed workflow
  for attempt in 1 2 3 4 5 6; do
    if gh workflow run image-factory.yml --repo "$REPO" --ref main \
         -f image_request=requests/ubuntu-2404-base.yaml > /dev/null 2>&1; then
      ok "started: ubuntu-2404-base (azure + docker)"
      break
    fi
    [[ $attempt -eq 6 ]] && warn "couldn't start it; run it from the Actions tab"
    sleep 10
  done
fi

echo
bold "Done."
echo "    Actions:   https://github.com/${REPO}/actions"
echo "    Gallery:   az sig image-version list -g rg-image-factory-gallery -r sig_image_factory -i ubuntu-2404 -o table"
echo "    Packages:  https://github.com/${GITHUB_OWNER}?tab=packages"
