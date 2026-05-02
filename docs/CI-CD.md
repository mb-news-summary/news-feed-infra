# CI/CD for Terraform — GitHub Actions + Workload Identity Federation

> Last updated: 2026-04-18

This document covers the full CI/CD setup for running `terragrunt plan` on PRs
and `terragrunt apply` on merge, authenticated securely via Workload Identity
Federation (no JSON key files).

---

## Table of Contents

1. [How it works](#1-how-it-works)
2. [Workflow overview](#2-workflow-overview)
3. [Setting up Workload Identity Federation](#3-setting-up-workload-identity-federation)
4. [GitHub repository configuration](#4-github-repository-configuration)
5. [Workflow files explained](#5-workflow-files-explained)
6. [Adding prod (or new environments)](#6-adding-prod-or-new-environments)
7. [Safety controls](#7-safety-controls)
8. [Troubleshooting](#8-troubleshooting)
9. [Why GitHub Actions instead of Atlantis](#9-why-github-actions-instead-of-atlantis)

---

## 1. How it works

```
Developer creates a branch
         │
         ▼
Push changes to live/**
         │
         ▼
Open a Pull Request
         │
         ▼
┌─────────────────────────────────────────────────────┐
│  GitHub Actions: terragrunt-plan.yml                │
│                                                     │
│  1. Detect which terragrunt units changed           │
│  2. Authenticate to GCP via Workload Identity (WIF) │
│  3. Run `terragrunt plan` for each changed unit     │
│  4. Post plan output as a PR comment                │
└─────────────────────────────────────────────────────┘
         │
         ▼
Reviewer reads the plan in the PR
         │
         ▼
Approve + Merge to main
         │
         ▼
┌─────────────────────────────────────────────────────┐
│  GitHub Actions: terragrunt-apply.yml               │
│                                                     │
│  1. Detect which units changed                      │
│  2. Authenticate to GCP via WIF                     │
│  3. Apply units in dependency order                 │
│     project → vpc → cloud-nat → gke-cluster         │
└─────────────────────────────────────────────────────┘
         │
         ▼
Infrastructure is live ✓
```

## 2. Workflow overview

| Workflow | Trigger | What it does | File |
|---|---|---|---|
| **Terragrunt Plan** | PR opened/updated against `main` | Plans changed units, posts PR comment | `.github/workflows/terragrunt-plan.yml` |
| **Terragrunt Apply** | Push to `main` (after merge) | Applies changed units in order | `.github/workflows/terragrunt-apply.yml` |

Both workflows only trigger when files under `live/` change. Helm chart or
documentation changes don't trigger infrastructure plans.

## 3. Setting up Workload Identity Federation

Workload Identity Federation (WIF) lets GitHub Actions authenticate to GCP
without service account JSON keys. Instead, GitHub's OIDC token is exchanged
for a short-lived GCP access token. This is the **best practice** — no secrets
to rotate, no keys to leak.

### Architecture

```
GitHub Actions Runner
  │
  │ 1. Requests OIDC token from GitHub
  ▼
GitHub OIDC Provider (https://token.actions.githubusercontent.com)
  │
  │ 2. Issues JWT with repo/branch claims
  ▼
GCP Workload Identity Pool + Provider
  │
  │ 3. Validates JWT, maps to GCP Service Account
  ▼
GCP Service Account (github-actions@...) → has IAM roles to manage resources
```

### Step-by-step setup

Run these commands once. They create the WIF pool, provider, and service account.

```bash
# ── Variables (adjust to your setup) ──
export PROJECT_ID="bootstrap-terragrunt-gcs-01"
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
export GITHUB_ORG="your-org"                    # ← CHANGE THIS
export GITHUB_REPO="news-feed-infra"
export SA_NAME="github-actions"
export POOL_NAME="github-pool"
export PROVIDER_NAME="github-provider"

# ── 1. Enable required APIs ──
gcloud services enable iamcredentials.googleapis.com \
  --project=$PROJECT_ID
gcloud services enable sts.googleapis.com \
  --project=$PROJECT_ID

# ── 2. Create the service account for GitHub Actions ──
gcloud iam service-accounts create $SA_NAME \
  --display-name="GitHub Actions CI/CD" \
  --project=$PROJECT_ID

# ── 3. Grant IAM roles to the service account ──
# It needs permissions to manage resources in the dev project.
# "roles/editor" is broad — tighten in prod.
DEV_PROJECT_ID=$(cd live/environments/dev/project && terragrunt output -raw project_id)

# On the dev project (where resources live):
gcloud projects add-iam-policy-binding $DEV_PROJECT_ID \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/editor"

# On the bootstrap project (where the state bucket lives):
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

# Container admin for GKE:
gcloud projects add-iam-policy-binding $DEV_PROJECT_ID \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/container.admin"

# ── 4. Create the Workload Identity Pool ──
gcloud iam workload-identity-pools create $POOL_NAME \
  --location="global" \
  --display-name="GitHub Actions Pool" \
  --project=$PROJECT_ID

# ── 5. Create the OIDC Provider (trusts GitHub's token issuer) ──
gcloud iam workload-identity-pools providers create-oidc $PROVIDER_NAME \
  --location="global" \
  --workload-identity-pool=$POOL_NAME \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository == '${GITHUB_ORG}/${GITHUB_REPO}'" \
  --project=$PROJECT_ID

# ── 6. Allow the WIF pool to impersonate the service account ──
gcloud iam service-accounts add-iam-policy-binding \
  "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}" \
  --project=$PROJECT_ID

# ── 7. Get the full provider resource name (you need this in the workflow) ──
echo ""
echo "════════════════════════════════════════════════════════"
echo "  WIF setup complete! Update your GitHub Actions env:"
echo "════════════════════════════════════════════════════════"
echo ""
echo "GCP_WORKLOAD_IDENTITY_PROVIDER:"
echo "  projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"
echo ""
echo "GCP_SERVICE_ACCOUNT:"
echo "  ${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
echo ""
```

### Update the workflow files

After running the commands above, update these values in both workflow files:

```yaml
env:
  GCP_PROJECT_ID: "bootstrap-terragrunt-gcs-01"
  GCP_WORKLOAD_IDENTITY_PROVIDER: "projects/123456789/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
  GCP_SERVICE_ACCOUNT: "github-actions@bootstrap-terragrunt-gcs-01.iam.gserviceaccount.com"
```

Replace `123456789` with your actual project number (printed by the script).

### Security of WIF

WIF is strictly scoped:

- **attribute_condition** restricts the pool to your specific repo. No other
  GitHub repo can authenticate, even if they know the pool name.
- **Tokens are short-lived** (~1 hour) and can't be extracted.
- **No JSON keys** — nothing to rotate, nothing to leak in git.
- **Audit trail** — all authentications appear in Cloud Audit Logs.

## 4. GitHub repository configuration

### Required repository settings

1. **Branch protection on `main`:**
   - Go to Settings → Branches → Add rule for `main`.
   - Enable "Require a pull request before merging".
   - Enable "Require status checks to pass" → add "Plan" as required.
   - Enable "Require review from Code Owners" (optional but recommended).

2. **Actions permissions:**
   - Go to Settings → Actions → General.
   - Under "Workflow permissions", select "Read and write permissions".
   - Check "Allow GitHub Actions to create and approve pull requests".

### Optional: GitHub Environment for apply protection

For extra safety, create a GitHub Environment with required reviewers
so that `apply` requires human approval even after merge:

1. Go to Settings → Environments → New environment → name it `production`.
2. Add required reviewers (yourself or your team).
3. Uncomment `environment: production` in `terragrunt-apply.yml`.

This adds a manual approval gate: after merge, the apply workflow pauses
and waits for a reviewer to click "Approve" in the Actions UI.

## 5. Workflow files explained

### terragrunt-plan.yml

**Trigger:** PR opened or updated against `main`, only when `live/` files change.

**What it does:**

1. **detect-changes job:** diffs the PR against `main`, finds which directories
   contain a `terragrunt.hcl` that was affected. If `common.yaml` or `root.hcl`
   changed, plans ALL units (since they affect everything).

2. **plan job (matrix):** runs in parallel for each changed unit. Each matrix
   leg:
   - Authenticates to GCP via WIF.
   - Installs Terraform + Terragrunt.
   - Runs `terragrunt init` + `terragrunt plan`.
   - Posts the plan output as a PR comment (updates the same comment on
     subsequent pushes).

**PR comment format:**

```
### ✅ Terragrunt Plan: `live/environments/dev/networking/vpc`

<details>
<summary>Click to expand plan output</summary>

  Terraform will perform the following actions:
    + google_compute_network.network
    + google_compute_subnetwork.subnetwork
  Plan: 2 to add, 0 to change, 0 to destroy.

</details>

Exit code: 0
Triggered by: @marian
```

### terragrunt-apply.yml

**Trigger:** push to `main` (happens automatically after PR merge).

**What it does:**

1. Diffs `HEAD~1` to find changed units.
2. If global config changed → `terragrunt run-all apply` (applies everything
   in dependency order).
3. Otherwise → applies individual units in hardcoded dependency order:
   `project → vpc → cloud-nat → gke-cluster`.

**Concurrency:** only one apply runs at a time (`cancel-in-progress: false`).
This prevents concurrent state modifications that could corrupt state.

## 6. Adding prod (or new environments)

When you add `live/environments/prod/`, update the apply workflow's
`ORDERED_UNITS` array:

```yaml
ORDERED_UNITS=(
  "live/environments/dev/project"
  "live/environments/dev/networking/vpc"
  "live/environments/dev/networking/cloud-nat"
  "live/environments/dev/gke-cluster"
  "live/environments/prod/project"
  "live/environments/prod/networking/vpc"
  "live/environments/prod/networking/cloud-nat"
  "live/environments/prod/gke-cluster"
)
```

The plan workflow needs no changes — it automatically detects any directory
with a `terragrunt.hcl`.

For prod, strongly consider using a GitHub Environment with required reviewers
so that prod applies require explicit human approval.

## 7. Safety controls

| Control | Status | How it helps |
|---|---|---|
| **Plan on PR** | ✅ Enabled | See what will change before approving |
| **Apply on merge only** | ✅ Enabled | No apply without code review |
| **Concurrency lock** | ✅ Enabled | Prevents parallel applies |
| **Branch protection** | ⚠️ Set up manually | Require PR + status checks for `main` |
| **Environment approval** | ⚠️ Optional | Manual gate before apply runs |
| **WIF (no JSON keys)** | ✅ Enabled | Short-lived tokens, repo-scoped, auditable |
| **Plan output in PR** | ✅ Enabled | Reviewer sees exact diff |
| **Global config detection** | ✅ Enabled | Plans all units when root config changes |

## 8. Troubleshooting

### "Error: No matching credentials found" (WIF)

The WIF provider can't validate the GitHub OIDC token. Check:

1. The `attribute_condition` in the provider matches your repo exactly:
   `assertion.repository == 'mb-news-summary/news-feed-infra'`
2. The `GCP_WORKLOAD_IDENTITY_PROVIDER` value in the workflow uses the correct
   project **number** (not project ID).
3. The service account IAM binding uses the correct principal set.

Debug with:

```bash
gcloud iam workload-identity-pools providers describe $PROVIDER_NAME \
  --location=global \
  --workload-identity-pool=$POOL_NAME \
  --project=$PROJECT_ID
```

### "Permission denied" on plan/apply

The service account is missing IAM roles. Check:

```bash
gcloud projects get-iam-policy $DEV_PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
```

Common missing roles: `roles/storage.objectAdmin` on the state bucket project,
`roles/container.admin` on the dev project.

### Plan succeeds but apply fails with "state locked"

Another apply is running concurrently. The `concurrency` block in the apply
workflow should prevent this, but if a manual `terragrunt apply` is running
from your laptop at the same time, it will conflict.

Fix: wait for the other apply to finish, or (carefully):

```bash
cd live/environments/dev/project
terragrunt force-unlock <LOCK_ID>
```

### No PR comment appears

Check that the workflow has `pull-requests: write` permission and that the
repo's Actions settings allow "Read and write permissions."

### Plan runs for ALL units when only one file changed

This happens when `common.yaml` or `root.hcl` was modified — the workflow
intentionally plans everything because those files affect all units. This
is correct behavior.

## 9. Why GitHub Actions instead of Atlantis

Both approaches give you "plan on PR, apply on merge." Here's why we chose
GitHub Actions for this project:

| Factor | GitHub Actions | In-cluster Atlantis |
|---|---|---|
| **Network** | No exposure needed | Needs public endpoint for webhooks |
| **Maintenance** | Zero (GitHub-hosted) | Must maintain pod, updates, storage |
| **Auth** | WIF (native) | SA key or WIF + K8s SA binding |
| **PR comments** | GitHub Script action | Built-in |
| **Cost** | Free for public repos, 2000 min/mo for private | Compute cost for the pod |
| **Interactive** | One-way (push-based) | Two-way (`atlantis apply` comment) |
| **Lock management** | Via concurrency groups | Built-in workspace locks |

The main thing Atlantis offers that GH Actions doesn't: the ability to type
`atlantis apply` as a PR comment and have it apply *before* merge. With GH
Actions, apply only happens after merge. For most teams, post-merge apply
is actually safer (forces code review before any infrastructure change).

You can always switch to Atlantis later — the `atlantis.yaml` in the repo root
has a pre-configured (but commented-out) config ready to go.
