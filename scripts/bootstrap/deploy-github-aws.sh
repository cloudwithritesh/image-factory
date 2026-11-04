#!/usr/bin/env bash
# =============================================================================
# Deploy the AWS side of the image factory, from your own machine. It uses
# the logins you already have (aws and gh), so no credentials are copied
# anywhere: GitHub Actions reach AWS through OIDC afterwards.
#
#   1. checks tools and logins
#   2. creates the S3 bucket for Terraform state (versioned, encrypted, private)
#   3. terraform apply terraform/factory/aws (shows the plan, asks first):
#      GitHub OIDC trust, Packer build role, AMI KMS key, build VPC,
#      workload VPC, vm-provision role, instance profile
#   4. stores the outputs as GitHub Actions repository variables
#   5. creates the promotion environments images-aws(-approval)
#   6. opens a PR that turns AWS on in catalog/vm.yaml (and, if you agree,
#      adds aws to requests/ubuntu-2404-base.yaml so the first AMI builds
#      when the PR is merged)
#
# Usage (from the repo root, on an up-to-date main):
#   scripts/bootstrap/deploy-github-aws.sh
#
# Optional overrides (environment variables):
#   AWS_PROFILE            which AWS CLI profile to use (default: your default)
#   AWS_REGION             default: ap-southeast-1
#   GITHUB_OWNER           default: the account gh is logged in as
#   REPO_NAME              default: image-factory
#   WORKLOAD_NAT_GATEWAY   true | false (default true; ~USD 35/month, gives
#                          private instances outbound internet for patching)
#   FIRST_AMI=0            don't add aws to requests/ubuntu-2404-base.yaml
#
# Safe to re-run: every step checks what already exists.
# Works with macOS's bash 3.2.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
REPO_NAME="${REPO_NAME:-image-factory}"
WORKLOAD_NAT_GATEWAY="${WORKLOAD_NAT_GATEWAY:-true}"
STATE_KEY="image-factory/aws.tfstate"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()    { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
step "1/6  Checking tools and logins"
missing=""
for tool in git gh aws terraform jq python3; do
  command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
done
if [[ -n "$missing" ]]; then
  die "missing:${missing}
    macOS: brew install git gh awscli jq python hashicorp/tap/terraform"
fi
tf_version="$(terraform version -json | jq -r .terraform_version)"
case "$tf_version" in
  0.*|1.[0-9].*) die "Terraform ${tf_version} is too old; need >= 1.10 for S3 state locking (brew upgrade hashicorp/tap/terraform)" ;;
esac
ok "git, gh, aws, terraform ${tf_version}, jq, python3"

gh auth status > /dev/null 2>&1 || die "GitHub CLI isn't logged in. Run: gh auth login"
GH_LOGIN="$(gh api user -q .login)"
GH_USER_ID="$(gh api user -q .id)"
GH_PLAN="$(gh api user -q '.plan.name // "unknown"')"
GITHUB_OWNER="${GITHUB_OWNER:-$GH_LOGIN}"
REPO="${GITHUB_OWNER}/${REPO_NAME}"
gh repo view "$REPO" > /dev/null 2>&1 || die "${REPO} not found. Run deploy-github-azure.sh first, or set GITHUB_OWNER/REPO_NAME."
GH_REPO_ID="$(gh api "repos/${REPO}" -q .id)"
GH_OWNER_ID="$(gh api "repos/${REPO}" -q .owner.id)"
ok "GitHub: ${GH_LOGIN}, repo ${REPO} (id ${GH_REPO_ID}, owner id ${GH_OWNER_ID})"

identity="$(aws sts get-caller-identity --output json 2> /dev/null)" \
  || die "AWS CLI isn't logged in. Run: aws configure sso   (or aws sso login / aws configure)"
AWS_ACCOUNT_ID="$(jq -r .Account <<< "$identity")"
AWS_ARN="$(jq -r .Arn <<< "$identity")"
ok "AWS: ${AWS_ARN}"

STATE_BUCKET="image-factory-tfstate-${AWS_ACCOUNT_ID}-${AWS_REGION}"

# An account has at most one GitHub OIDC provider; reuse it if it exists.
GITHUB_OIDC_ARN="$(aws iam list-open-id-connect-providers --query \
  "OpenIDConnectProviderList[?ends_with(Arn, 'oidc-provider/token.actions.githubusercontent.com')].Arn | [0]" \
  --output text 2> /dev/null || true)"
[[ "$GITHUB_OIDC_ARN" == "None" ]] && GITHUB_OIDC_ARN=""

echo
bold "About to deploy:"
cat <<EOF
    AWS account          ${AWS_ACCOUNT_ID} (${AWS_ARN})
    Region               ${AWS_REGION}
    Terraform state      s3://${STATE_BUCKET}/${STATE_KEY}
    GitHub OIDC provider ${GITHUB_OIDC_ARN:-will be created}
    Creates in AWS       IAM roles image-factory-packer, image-factory-vm-provision,
                         image-factory-instance (all trusted to ${REPO} only, no keys),
                         KMS key alias/image-factory-ami, build VPC 10.250.0.0/20,
                         workload VPC 10.70.0.0/16 (NAT gateway: ${WORKLOAD_NAT_GATEWAY})
    GitHub               repository variables for AWS, environments images-aws(-approval),
                         a PR that turns AWS on in the portal
EOF
read -r -p "Continue? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || die "cancelled"

# -----------------------------------------------------------------------------
step "2/6  Terraform state bucket"
if aws s3api head-bucket --bucket "$STATE_BUCKET" > /dev/null 2>&1; then
  ok "s3://${STATE_BUCKET} exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$STATE_BUCKET" > /dev/null
  else
    aws s3api create-bucket --bucket "$STATE_BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" > /dev/null
  fi
  ok "created s3://${STATE_BUCKET}"
fi
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-policy --bucket "$STATE_BUCKET" --policy "$(jq -nc --arg b "$STATE_BUCKET" '{
  Version: "2012-10-17",
  Statement: [{Sid: "TlsOnly", Effect: "Deny", Principal: "*", Action: "s3:*",
    Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"],
    Condition: {Bool: {"aws:SecureTransport": "false"}}}]}')"
aws s3api put-bucket-tagging --bucket "$STATE_BUCKET" \
  --tagging 'TagSet=[{Key=Component,Value=image-factory},{Key=ManagedBy,Value=bootstrap}]'
ok "versioning, encryption, public access block, TLS-only policy"

# -----------------------------------------------------------------------------
step "3/6  Terraform: AWS foundation"
tf_args=(
  -var="aws_region=${AWS_REGION}"
  -var="github_repository=${REPO}"
  -var="github_repository_id=${GH_REPO_ID}"
  -var="github_owner_id=${GH_OWNER_ID}"
  -var="tf_state_bucket=${STATE_BUCKET}"
  -var="workload_nat_gateway=${WORKLOAD_NAT_GATEWAY}"
)
if [[ -n "$GITHUB_OIDC_ARN" ]]; then
  tf_args+=(-var="create_github_oidc_provider=false" -var="github_oidc_provider_arn=${GITHUB_OIDC_ARN}")
fi
(
  cd terraform/factory/aws
  terraform init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=${STATE_KEY}" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true"
  terraform apply -input=false "${tf_args[@]}"
)
CI_VARS="$(terraform -chdir=terraform/factory/aws output -json ci_variables)"
ok "AWS foundation applied"

# -----------------------------------------------------------------------------
step "4/6  GitHub Actions repository variables"
CI_VARS="$(jq -c --arg b "$STATE_BUCKET" '. + {TF_STATE_AWS_BUCKET: $b}' <<< "$CI_VARS")"
echo "$CI_VARS" | jq -r 'to_entries[] | select(.value != null and .value != "") | "\(.key)\t\(.value)"' |
  while IFS="$(printf '\t')" read -r key value; do
    gh variable set "$key" --repo "$REPO" --body "$value"
    ok "$key"
  done

# -----------------------------------------------------------------------------
step "5/6  Promotion environments"
use_envs="$(gh variable get PROMOTION_ENVIRONMENTS --repo "$REPO" 2> /dev/null || echo true)"
if [[ "$use_envs" == "false" ]]; then
  warn "PROMOTION_ENVIRONMENTS=false (GitHub Free + private repo): no environments to create"
else
  gh api -X PUT "repos/${REPO}/environments/images-aws" > /dev/null && ok "images-aws"
  if gh api -X PUT "repos/${REPO}/environments/images-aws-approval" --input - > /dev/null 2>&1 \
       <<< "{\"reviewers\":[{\"type\":\"User\",\"id\":${GH_USER_ID}}]}"; then
    ok "images-aws-approval (required reviewer: ${GH_LOGIN})"
  else
    gh api -X PUT "repos/${REPO}/environments/images-aws-approval" > /dev/null
    warn "images-aws-approval created, but your plan (${GH_PLAN}) doesn't allow required reviewers here"
  fi
fi

# -----------------------------------------------------------------------------
step "6/6  Turn AWS on in the portal (pull request)"
if awk '/^  aws:/{f=1; next} f && /^  [a-z]/{f=0} f && /^    enabled: true/{found=1} END{exit !found}' catalog/vm.yaml; then
  ok "AWS is already enabled in catalog/vm.yaml"
  exit 0
fi
gh auth setup-git > /dev/null 2>&1 || true
git fetch -q origin main
branch="chore/enable-aws-$(date -u +%Y%m%d-%H%M)"
git switch -q -c "$branch" origin/main

# Enable the cloud (the only "enabled: false" under clouds.aws)
python3 - <<'PY'
import re
from pathlib import Path
p = Path("catalog/vm.yaml")
s = p.read_text()
s2 = re.sub(r"(\n  aws:\n(?:    #[^\n]*\n)*)    enabled: false", r"\1    enabled: true", s, count=1)
assert s2 != s, "couldn't find clouds.aws.enabled in catalog/vm.yaml"
p.write_text(s2)
PY
ok "catalog/vm.yaml: clouds.aws.enabled = true"

title="chore(platform): enable aws"
if [[ "${FIRST_AMI:-1}" == "1" ]] && [[ -f requests/ubuntu-2404-base.yaml ]] \
   && ! grep -qE '^  targets:.*aws' requests/ubuntu-2404-base.yaml; then
  python3 - <<'PY'
import re
from pathlib import Path
p = Path("requests/ubuntu-2404-base.yaml")
s = p.read_text()
s2 = re.sub(r"^(  targets: \[)([^\]]*)\]", lambda m: f"{m.group(1)}aws, {m.group(2)}]", s, count=1, flags=re.M)
if s2 == s:  # block-style list
    s2 = re.sub(r"^(  targets:\n)", r"\1    - aws\n", s, count=1, flags=re.M)
p.write_text(s2)
PY
  ok "requests/ubuntu-2404-base.yaml: aws added (the first AMI builds after merge)"
  title="chore(platform): enable aws and build ubuntu-2404-base ami"
fi

# The Backstage templates list the enabled clouds; regenerate them in a
# throwaway virtualenv so the PR's lint check passes.
venv="$(mktemp -d)/venv"
python3 -m venv "$venv"
"$venv/bin/pip" install -q pyyaml==6.0.3 jsonschema==4.26.0
"$venv/bin/python" scripts/portal/render.py backstage > /dev/null
rm -rf "$(dirname "$venv")"
ok "Backstage templates regenerated"

git add catalog/vm.yaml requests/ portal/backstage/templates
git -c user.name="$GH_LOGIN" -c user.email="${GH_USER_ID}+${GH_LOGIN}@users.noreply.github.com" \
  commit -q -m "$title" -m "AWS foundation deployed by scripts/bootstrap/deploy-github-aws.sh (account ${AWS_ACCOUNT_ID}, ${AWS_REGION})."
git push -q -u origin "$branch"
pr_url="$(gh pr create --repo "$REPO" --base main --head "$branch" --title "$title" --body "$(cat <<EOF
Turns AWS on now that the foundation is deployed (account \`${AWS_ACCOUNT_ID}\`, region \`${AWS_REGION}\`).

- \`catalog/vm.yaml\`: \`clouds.aws.enabled: true\`. The portal offers AWS as an image target and EC2 for VMs.
- Repository variables for AWS were set by the script (\`AWS_BUILD_ROLE_ARN\`, \`PKR_VAR_aws_*\`, \`VM_AWS_*\`, \`TF_STATE_AWS_BUCKET\`).
- If \`requests/ubuntu-2404-base.yaml\` changed: the first AMI builds, is scanned and promoted after merge.

Opened by \`scripts/bootstrap/deploy-github-aws.sh\`.
EOF
)")"
git switch -q main 2> /dev/null || true
ok "opened ${pr_url}"

echo
bold "Done."
echo "    Review and merge: ${pr_url}"
echo "    Then:  Actions → image-factory (AMI build), and the portal offers AWS."
echo "    AMIs:  aws ec2 describe-images --owners self --filters Name=tag:BuiltBy,Values=image-factory --query 'Images[].[Name,ImageId]' --output table"
