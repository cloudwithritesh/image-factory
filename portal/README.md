# Self-service portal

Two front ends, one process. Both turn a form into a **pull request on a
short-lived branch**, following [docs/standards.md](../docs/standards.md):

```
GitHub Pages form ──► issue (as you) ──┐
                                       ├─► portal-request workflow ──► validate ──► branch + commit + PR
Backstage template ──► workflow_dispatch ┘        (scripts/portal/process_request.py)
                                                                   │
                     review + squash merge ◄───────────────────────┘
                                │
              image pipeline builds │ vm-provision applies Terraform
```

| | GitHub Pages portal | Backstage (local) |
|---|---|---|
| URL | https://cloudwithritesh.github.io/image-factory/ | http://localhost:3000/create |
| Sign-in | your GitHub session (submits an issue as you) | GitHub OAuth (Entra ID later) |
| Hosting | free, static, always on | runs on your machine for now |
| Forms generated from | `catalog/*.yaml`, `requests/`, `vms/` (`render.py pages`) | same (`render.py backstage`) |

Who can submit: on a public repo anyone can open an issue, but the processor
only acts on issues from the repo **owner, members and collaborators**.
Other issues are ignored.

## What each form creates

| Form | File | Branch | Commit / PR title |
|---|---|---|---|
| New golden image | `requests/<name>.yaml` | `portal/image/<name>-<date>-<ref>` | `feat(image): add image <name>` |
| Change an image | `requests/<name>.yaml` | same pattern | `chore(image): update image <name>` |
| New VM | `vms/<name>.yaml` | `portal/vm/<name>-<date>-<ref>` | `feat(vm): create vm <name> on <cloud>` |
| Change a VM | `vms/<name>.yaml` | same pattern | `chore(vm): update vm <name> on <cloud>` |
| Decommission | `vms/<name>.yaml` (`state: absent`) | same pattern | `chore(vm): decommission vm <name>` |

After merge: image requests are built by the `image-factory` workflow; VM
requests are applied by `vm-provision` (Terraform, one state per VM).

---

## One-time setup

### 1. Repository settings
```bash
scripts/bootstrap/configure-github-repo.sh cloudwithritesh/image-factory
```
This sets squash-only merges with the PR title, auto-delete of branches, a
ruleset on `main` (PR + 1 approval + `pr-standards` check), permission for
Actions to open PRs, and GitHub Pages.

### 2. VM landing zone
Re-run `scripts/bootstrap/deploy-github-azure.sh`. It now also creates the
VM resource group, VNet and subnet, gives the pipeline identity access to
them and to the Terraform state, and sets the `VM_*` and `TF_STATE_*`
repository variables.

### 3. Portal bot: GitHub App (recommended)
Without an App, PRs are opened with the workflow's `GITHUB_TOKEN`. GitHub
doesn't run other workflows for those PRs, so the processor records the
`pr-standards` check itself, but `lint` and `plan` don't run on portal PRs.
With an App, everything runs normally and commits show as `<app>[bot]`.

1. GitHub → Settings → Developer settings → GitHub Apps → **New GitHub App**
   - Name: `image-factory-bot` (or similar), Homepage: the repo URL, Webhook: off
   - Repository permissions: **Contents** read & write, **Pull requests** read & write,
     **Issues** read & write, **Commit statuses** read & write, Metadata read
2. Generate a private key and **install** the App on `image-factory` only.
3. Store it:
   ```bash
   gh variable set PORTAL_APP_ID --repo cloudwithritesh/image-factory --body <app id>
   gh secret set PORTAL_APP_PRIVATE_KEY --repo cloudwithritesh/image-factory < image-factory-bot.private-key.pem
   ```

---

## GitHub Pages portal

Deployed by `.github/workflows/portal-pages.yml` on every change to the
catalogs, requests, VMs or the page itself.

Local preview:
```bash
python3 scripts/portal/render.py pages --out portal/pages   # writes portal/pages/data/catalog.json
cd portal/pages && python3 -m http.server 8000                 # http://localhost:8000
```

---

## Backstage (local)

### 1. Create the app (once)
Needs Node.js 20 or 22 and Yarn.
```bash
cd ~/my_work
npx @backstage/create-app@latest      # name it image-factory-portal
```

### 2. GitHub OAuth App for sign-in
GitHub → Settings → Developer settings → OAuth Apps → **New OAuth App**:
- Homepage URL: `http://localhost:3000`
- Authorization callback URL: `http://localhost:7007/api/auth/github/handler/frame`

### 3. Connect it to the image factory
```bash
~/my_work/image-factory/portal/backstage/setup.sh ~/my_work/image-factory-portal
export GITHUB_TOKEN="$(gh auth token)"               # needs repo + workflow scopes
export AUTH_GITHUB_CLIENT_ID=<client id>
export AUTH_GITHUB_CLIENT_SECRET=<client secret>
cd ~/my_work/image-factory-portal && yarn start
```
`setup.sh` installs `app-config.local.yaml` (GitHub integration, GitHub
auth, and the catalog location `portal/backstage/catalog-info.yaml`) and adds
the GitHub auth module to the backend.

### 4. Sign-in page
Open `packages/app/src/App.tsx` and see which style it uses.

**New frontend system** (`createApp({ features: [...] })`):
```tsx
import { SignInPageBlueprint } from '@backstage/plugin-app-react';
import { SignInPage } from '@backstage/core-components';
import { createFrontendModule } from '@backstage/frontend-plugin-api';
import { githubAuthApiRef } from '@backstage/core-plugin-api';

const signInPage = SignInPageBlueprint.make({
  params: {
    loader: async () => props => (
      <SignInPage {...props} provider={{
        id: 'github-auth-provider', title: 'GitHub',
        message: 'Sign in using GitHub', apiRef: githubAuthApiRef,
      }} />
    ),
  },
});

export default createApp({
  features: [/* existing features */, createFrontendModule({ pluginId: 'app', extensions: [signInPage] })],
});
```

**Legacy** (`const app = createApp({ apis, ... })`): add
```tsx
components: {
  SignInPage: props => (
    <SignInPage {...props} auto provider={{
      id: 'github-auth-provider', title: 'GitHub',
      message: 'Sign in using GitHub', apiRef: githubAuthApiRef,
    }} />
  ),
},
```

Sign-in matches your GitHub username to a User entity, so everyone who signs
in needs one in `portal/backstage/org.yaml` (`cloudwithritesh` is already there).

### 5. Use it
http://localhost:3000/create has two templates:
- **Request or change a golden image** (owner: platform-engineering)
- **Create, change or decommission a VM**

Each one runs the `portal-request` workflow and links to the PR.

### Moving to Entra ID later
Swap the `github` provider in `app-config.local.yaml` for the commented
`microsoft` block, import users and groups with the Microsoft Graph org
provider, and use `microsoftAuthApiRef` on the sign-in page. The templates
and the PR process don't change. `requested_by` becomes the Entra user's
entity name.

## Keeping the forms in sync
The forms are generated, never edited by hand:
```bash
python3 scripts/portal/render.py backstage      # after changing catalog/*.yaml or requests/
```
The `lint` job fails if the committed Backstage templates are stale, and the
Pages site is rebuilt automatically on merge.
