#!/usr/bin/env bash
# Wire a local Backstage app to the image factory.
#
#   portal/backstage/setup.sh <path-to-backstage-app>
#
# Create the app first (once):  npx @backstage/create-app@latest
# See portal/README.md for the full walkthrough.
set -euo pipefail

APP="${1:?usage: setup.sh <path-to-backstage-app>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -f "${APP}/app-config.yaml" ]] || { echo "No Backstage app at ${APP} (app-config.yaml missing)"; exit 1; }

if [[ -f "${APP}/app-config.local.yaml" ]] && ! grep -q "Image Factory Portal" "${APP}/app-config.local.yaml"; then
  cp "${APP}/app-config.local.yaml" "${APP}/app-config.local.yaml.bak"
  echo "Backed up your existing app-config.local.yaml to app-config.local.yaml.bak"
fi
cp "${HERE}/app-config.image-factory.yaml" "${APP}/app-config.local.yaml"
echo "Installed ${APP}/app-config.local.yaml"

# GitHub sign-in needs the provider module in the backend
backend_index="${APP}/packages/backend/src/index.ts"
if [[ -f "$backend_index" ]] && ! grep -q "auth-backend-module-github-provider" "$backend_index"; then
  ( cd "${APP}" && yarn --cwd packages/backend add @backstage/plugin-auth-backend-module-github-provider )
  sed -i.bak "/plugin-auth-backend-module-guest-provider/a\\
backend.add(import('@backstage/plugin-auth-backend-module-github-provider'));
" "$backend_index" && rm -f "${backend_index}.bak"
  echo "Added the GitHub auth provider to the backend"
fi

cat <<'EOF'

Next:
  export GITHUB_TOKEN="$(gh auth token)"
  export AUTH_GITHUB_CLIENT_ID=<from your GitHub OAuth App>
  export AUTH_GITHUB_CLIENT_SECRET=<from your GitHub OAuth App>
  cd <your app> && yarn start

Then open http://localhost:3000/create and pick
  "Request or change a golden image" or "Create, change or decommission a VM".
To show a "Sign in with GitHub" button, follow "Sign-in page" in portal/README.md.
EOF
