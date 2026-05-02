# Infrastructure Documentation — news-feed-infra

> Last updated: 2026-04-18

This document covers every component of the `news-feed-infra` repo: what was
built, why, how to use it, and what to watch out for.

---

## Table of Contents

1. [Repository layout](#1-repository-layout)
2. [Terragrunt architecture](#2-terragrunt-architecture)
3. [Remote state & bootstrap project](#3-remote-state--bootstrap-project)
4. [Dev environment — Terragrunt units](#4-dev-environment--terragrunt-units)
5. [Devcontainer toolchain](#5-devcontainer-toolchain)
6. [Helm charts — application (omnifeed)](#6-helm-charts--application-omnifeed)
7. [Helm charts — platform tools](#7-helm-charts--platform-tools)
8. [CI/CD — GitHub Actions for Terraform](#8-cicd--github-actions-for-terraform)
9. [Secrets management](#9-secrets-management)
10. [Applying the stack end-to-end](#10-applying-the-stack-end-to-end)
11. [Conventions & best practices followed](#11-conventions--best-practices-followed)

---

## 1. Repository layout

```
news-feed-infra/
├── .devcontainer/               Dev container (Docker + VS Code config)
│   ├── Dockerfile               Multi-arch, all CLI tools installed
│   └── devcontainer.json        Extensions, mounts, post-create hook
├── .github/                     CI workflows
│   └── workflows/
│       └── update-atlantis.yml
├── .pre-commit-config.yaml      Pre-commit hooks config
├── atlantis.yaml                Atlantis config (scaffold)
├── LEARNING.md                  Decision log with rationale
├── README.md                    Bootstrap instructions
├── docs/
│   └── INFRASTRUCTURE.md        ← this file
├── helm/
│   ├── omnifeed/                Umbrella Helm chart for the app
│   └── platform/                Platform tool Helm values
└── live/
    ├── environments/
    │   ├── root.hcl             Shared provider + GCS backend config
    │   ├── common.yaml          Org-wide settings
    │   ├── dev/                 Dev environment
    │   │   ├── env.yaml         Dev-specific knobs
    │   │   ├── project/         GCP project (project-factory)
    │   │   ├── networking/
    │   │   │   ├── vpc/         VPC + subnet + secondary ranges
    │   │   │   └── cloud-nat/   Cloud Router + NAT
    │   │   └── gke-cluster/     Private zonal GKE cluster
    │   └── prod/                Prod environment (env.yaml only for now)
    │       └── env.yaml
    └── modules/                 Local TF modules (empty — using community modules)
```

## 2. Terragrunt architecture

### Core concept: one unit = one state file

Each folder containing a `terragrunt.hcl` is a "unit." Each unit maps to
exactly one Terraform state file in the GCS remote backend. This gives us:

- **Small blast radius** — a bad `apply` only affects one unit.
- **Fast plans** — Terraform only reads state for the resources in that unit.
- **Clear ownership** — each folder is self-contained and reviewable.

### Configuration inheritance

```
root.hcl              ← provider "google", remote_state { gcs }, shared inputs
  ├── common.yaml     ← org_id, billing, region, app_name
  └── env.yaml        ← per-env: folder_id, node count, machine type, zone
```

Every child unit does `include "root" { path = find_in_parent_folders("root.hcl") }`
to inherit the provider, GCS backend, and merged YAML inputs. This means you
never repeat provider or backend config.

### Dependencies between units

Units are wired with `dependency` blocks:

```
project → networking/vpc → networking/cloud-nat → gke-cluster
```

When you run `terragrunt run-all apply` in `dev/`, Terragrunt resolves the
dependency graph and applies units in the correct order. Each downstream unit
reads outputs from its upstream via `dependency.X.outputs.Y`.

`mock_outputs` allow `plan` to work even when upstream units haven't been
applied yet — useful for CI dry-runs.

### expose = true

Adding `expose = true` to an `include` block makes the included file's
`locals` accessible in the child via `include.<name>.locals.*`. Without it,
the child can't reference locals defined in the parent. Both approaches
(expose vs re-reading YAML) work — expose is DRY-er, re-reading is more
self-contained.

## 3. Remote state & bootstrap project

### Bootstrap project

| Setting | Value |
|---|---|
| Project ID | `bootstrap-terragrunt-gcs-01` |
| Org ID | `828057377450` |
| GCS bucket | `news-app-infra-terragrunt-state` |
| Bucket location | `EU` |
| Versioning | Enabled |

This project exists solely to host the Terraform state bucket. It was created
manually via `gcloud` (see `README.md` for the exact commands). The state
bucket has versioning enabled so you can recover from accidental state
corruption.

### State path convention

Each unit's state is stored at:

```
gs://news-app-infra-terragrunt-state/<path_relative_to_root>/terraform.tfstate
```

For example: `dev/networking/vpc/terraform.tfstate`.

## 4. Dev environment — Terragrunt units

### 4.1 dev/project

| Field | Value |
|---|---|
| Module | `terraform-google-project-factory@v18.2.0` |
| Project name | `news-feed-omnifeed` |
| Folder | `795926127355` (dev folder under org) |
| auto_create_network | `false` (we build our own VPC) |

**APIs enabled at project level** (to avoid race conditions downstream):
cloudresourcemanager, cloudbilling, iam, iamcredentials, serviceusage,
compute, container (GKE), servicenetworking, dns, logging, monitoring,
artifactregistry, secretmanager.

**Key decision:** APIs are enabled here, not scattered across downstream
units. This prevents the common failure where a module tries to call an API
before it's enabled.

### 4.2 dev/networking/vpc

| Field | Value |
|---|---|
| Module | `terraform-google-network@v18.0.0` |
| VPC name | `omnifeed-dev-vpc` |
| Subnet | `omnifeed-dev-gke-subnet` in `europe-west1` |
| Primary CIDR (nodes) | `10.10.0.0/20` (4,096 IPs) |
| Secondary "pods" | `10.20.0.0/14` (262k IPs) |
| Secondary "services" | `10.30.0.0/20` (4,096 IPs) |
| Private Google Access | Enabled |
| VPC Flow Logs | Enabled, 10% sampling |
| Routing mode | GLOBAL |
| auto_create_subnetworks | `false` (custom mode) |

**Why these CIDRs:** GKE allocates one IP per pod from the secondary range.
A /14 gives 262k pod IPs — more than enough and costs nothing. The /20 node
range supports up to 4,096 node VMs. The /20 services range supports 4,096
ClusterIP services.

### 4.3 dev/networking/cloud-nat

| Field | Value |
|---|---|
| Module | `terraform-google-cloud-nat@v7.0.0` |
| NAT name | `omnifeed-dev-nat` |
| Router name | `omnifeed-dev-router` |
| Scope | ALL_SUBNETWORKS_ALL_IP_RANGES |
| Logging | ERRORS_ONLY |

**Why Cloud NAT:** private GKE nodes have no public IPs. Without NAT, they
can't pull container images, run apt, or call external APIs. Cloud NAT
provides outbound-only internet access — nothing can initiate inbound
connections to the nodes.

### 4.4 dev/gke-cluster

| Field | Value |
|---|---|
| Module | `terraform-google-kubernetes-engine//modules/private-cluster@v44.0.0` |
| Cluster name | `omnifeed-dev-cluster` |
| Type | Zonal (europe-west1-b) |
| Private nodes | Yes (no public IPs) |
| Private endpoint | No (API is public, restricted by authorized networks) |
| Control plane CIDR | `172.16.0.0/28` |
| Authorized networks | User's public IP (from env.yaml) |
| Node pool | "general": e2-standard-2, preemptible, autoscaling 1–3 |
| Disk | pd-standard, 50 GB |
| Features | Workload Identity, HPA, HTTP LB, Network Policy (Calico) |
| Release channel | REGULAR |
| Maintenance window | Weekdays 03:00–07:00 UTC |
| deletion_protection | false (dev only) |

**Why private-cluster submodule:** makes the private-node intent explicit.
The root module supports it too, but the submodule enforces the right defaults.
For prod, upgrade to `safer-cluster` (adds Binary Auth, Shielded GKE, etc.).

**Why zonal:** one control plane replica instead of three = cheaper. Acceptable
for dev; use regional for prod.

**Why preemptible nodes:** ~60-80% cheaper. Pods must tolerate restarts
(Deployments with replicas ≥ 2 handle this). Set `preemptible = false` for
workloads that can't restart.

**Autoscaling:** min 1, max 3 nodes. The Cluster Autoscaler watches for
pending pods and adds/removes nodes automatically. Starts at min_count.

## 5. Devcontainer toolchain

The `.devcontainer/Dockerfile` builds a multi-arch Ubuntu 24.04 image with:

| Tool | Version | Purpose |
|---|---|---|
| Google Cloud CLI | apt-latest | `gcloud` commands, auth |
| kubectl | apt-latest | Kubernetes CLI |
| gke-gcloud-auth-plugin | apt-latest | Modern GKE auth (replaces deprecated built-in) |
| Terraform | apt-latest | IaC engine |
| Terragrunt | v0.99.2 | Terraform wrapper (DRY config, dependencies) |
| terraform-docs | v0.21.0 | Auto-generate module documentation |
| k9s | v0.32.7 | Terminal UI for Kubernetes |
| Helm | v3.16.3 | Kubernetes package manager |
| Kustomize | v5.5.0 | Template-free manifest patching |
| Oh My Zsh | latest | Shell with plugins |

**Multi-arch support:** All Go binaries use Docker's `TARGETARCH` build arg
to download native ARM64 binaries on Apple Silicon Macs. This avoids the Go
runtime `lfstack.push` crash that occurs when running amd64 binaries under
QEMU emulation.

**Environment variable:** `USE_GKE_GCLOUD_AUTH_PLUGIN=True` is set globally
so kubectl uses the new plugin-based authentication.

**Kubectl aliases** (via .zshrc):

| Alias | Command |
|---|---|
| `k` | `kubectl` |
| `kgp` | `kubectl get pods` |
| `kgs` | `kubectl get svc` |
| `kgd` | `kubectl get deployments` |
| `kgn` | `kubectl get nodes` |
| `kga` | `kubectl get all` |
| `kns <ns>` | `kubectl config set-context --current --namespace <ns>` |
| `kl` / `klf` | `kubectl logs` / `kubectl logs -f` |
| `kex` | `kubectl exec -it` |
| `kaf` / `kdf` | `kubectl apply -f` / `kubectl delete -f` |
| `hls` | `helm list -A` |

**VS Code extensions:** Terraform, Terragrunt, HCL, Python, Markdown lint,
Kubernetes tools, YAML (with K8s schema validation).

## 6. Helm charts — application (omnifeed)

### Structure

```
helm/omnifeed/                     Umbrella chart
├── Chart.yaml                     Declares Bitnami dependencies
├── values.yaml                    Default config
├── values-dev.yaml                Dev overrides (smaller resources)
├── .helmignore
├── templates/
│   ├── _helpers.tpl               Shared labels
│   ├── postgres-initdb-configmap.yaml  init.sql as ConfigMap
│   └── secrets.yaml               Documentation + kubectl commands
└── charts/
    ├── api-gateway/               Go REST API
    │   └── templates/
    │       ├── deployment.yaml    Deployment + health checks
    │       └── service.yaml       ClusterIP Service
    ├── frontend/                  React/Vite → nginx
    │   └── templates/
    │       ├── deployment.yaml
    │       └── service.yaml
    ├── worker-fetcher/            Python GNews fetcher
    │   └── templates/
    │       └── deployment.yaml    No Service (background worker)
    └── worker-summarizer/         Python LLM summarizer
        └── templates/
            └── deployment.yaml    No Service (background worker)
```

### Bitnami dependencies (in-cluster for dev)

| Chart | Version | In-cluster DNS name |
|---|---|---|
| postgresql | 16.4.1 | `omnifeed-postgresql:5432` |
| redis | 20.6.2 | `omnifeed-redis-master:6379` |
| rabbitmq | 15.1.2 | `omnifeed-rabbitmq:5672` |

These are enabled via `condition: <name>.enabled` in Chart.yaml. For prod,
set `enabled: false` and point env vars at managed GCP services instead.

### Service connectivity

```
                    ┌──────────────┐
    Internet ──────►│   frontend   │ (nginx, port 80)
                    └──────┬───────┘
                           │ /api/*
                    ┌──────▼───────┐
                    │ api-gateway  │ (Go, port 8080)
                    └──┬───────┬───┘
                       │       │
              ┌────────▼─┐  ┌──▼──────┐
              │ postgres  │  │  redis  │
              └────────▲──┘  └──▲──────┘
                       │       │
              ┌────────┴───────┴──┐
              │ worker-summarizer │ (Python)
              └────────▲──────────┘
                       │ RabbitMQ
              ┌────────┴──────────┐
              │  worker-fetcher   │ (Python)
              └───────────────────┘
                       │
                  GNews API
```

### Secrets (not in git)

Three K8s Secrets must be created manually before `helm install`:

- `omnifeed-api-gateway-secrets` — DATABASE_URL, REDIS_ADDR, NEWS_API_KEY
- `omnifeed-worker-fetcher-secrets` — NEWS_API_KEY, RABBITMQ_HOST
- `omnifeed-worker-summarizer-secrets` — POSTGRES_URL, REDIS_HOST, REDIS_PORT,
  RABBITMQ_HOST, GEMINI_API_KEY

See `templates/secrets.yaml` for the exact `kubectl create secret` commands.

### Image placeholders

All image fields are set to `<IMAGE>` in values.yaml. Replace with your
actual registry paths (e.g. `europe-west1-docker.pkg.dev/project/repo/api-gateway`)
once you've built and pushed the images.

## 7. Helm charts — platform tools

Full installation guide, configuration, and usage docs are in
[`helm/platform/README.md`](../helm/platform/README.md).

| Tool | Chart | Namespace | Purpose |
|---|---|---|---|
| Prometheus + Grafana | `kube-prometheus-stack` | `monitoring` | Cluster monitoring, alerting, dashboards |
| EFK Stack | `elasticsearch` + `fluent-bit` + `kibana` | `logging` | Centralized log collection, search, visualization |
| ArgoCD | `argo-cd` | `argocd` | GitOps — auto-deploy from git on push |
| Atlantis | `atlantis` | `atlantis` | Terraform/Terragrunt PR automation |

### How these tools fit together

```
Developer pushes code
       │
       ├─── Terraform/HCL changes ──► Atlantis plans + applies infra
       │
       └─── App/Helm changes ──► ArgoCD syncs to cluster
                                        │
                                        ▼
                                  Prometheus scrapes metrics
                                        │
                                        ▼
                                  Grafana dashboards
```

### Quick access (port-forward)

| Tool | Command | URL |
|---|---|---|
| Grafana | `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` | http://localhost:3000 |
| Prometheus | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090` | http://localhost:9090 |
| ArgoCD | `kubectl -n argocd port-forward svc/argocd-server 8443:443` | https://localhost:8443 |
| Atlantis | `kubectl -n atlantis port-forward svc/atlantis 4141:80` | http://localhost:4141 |

## 8. CI/CD — GitHub Actions for Terraform

Full setup guide, Workload Identity Federation instructions, and troubleshooting
are in [`docs/CI-CD.md`](CI-CD.md).

### Summary

| Workflow | File | Trigger | What it does |
|---|---|---|---|
| **Terragrunt Plan** | `.github/workflows/terragrunt-plan.yml` | PR opened/updated | Plans changed units, posts output as PR comment |
| **Terragrunt Apply** | `.github/workflows/terragrunt-apply.yml` | Push to `main` | Applies changed units in dependency order |

### PR workflow

```
Create branch → Edit terragrunt files → Push → Open PR
     │
     ▼
GitHub Actions runs `terragrunt plan` for each changed unit
     │
     ▼
Plan output appears as PR comment (✅ or ❌)
     │
     ▼
Reviewer reads plan, approves → Merge to main
     │
     ▼
GitHub Actions runs `terragrunt apply` automatically
```

### Authentication: Workload Identity Federation

No JSON key files. GitHub Actions exchanges a short-lived OIDC token with GCP.
Setup requires:

1. A GCP service account (`github-actions@...`)
2. A Workload Identity Pool + OIDC Provider
3. IAM binding scoped to your specific GitHub repo

See `docs/CI-CD.md` section 3 for the exact `gcloud` commands.

### Setup checklist

- [ ] Run the WIF setup commands from `docs/CI-CD.md`
- [ ] Update `GCP_WORKLOAD_IDENTITY_PROVIDER` in both workflow files with your project number
- [ ] Update `GCP_SERVICE_ACCOUNT` in both workflow files
- [ ] Enable branch protection on `main` (require PR + status checks)
- [ ] Set Actions permissions: "Read and write" + allow PR comments

## 9. Secrets management

**Current approach (dev):** manual `kubectl create secret generic` commands.
Good enough for dev, not acceptable for prod.

**Recommended prod approach:** External Secrets Operator (ESO) + GCP Secret
Manager. ESO runs in-cluster and syncs secrets from Secret Manager into K8s
Secrets automatically. The Terraform infra repo would manage the Secret
Manager secrets; ESO would pull them into the cluster.

## 10. Applying the stack end-to-end

### Prerequisites

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project bootstrap-terragrunt-gcs-01
```

### Step-by-step

```bash
# 1. Terraform/Terragrunt — create GCP resources
cd live/environments/dev

# Apply in order (or use run-all):
cd project         && terragrunt apply
cd ../networking/vpc && terragrunt apply
cd ../cloud-nat    && terragrunt apply
cd ../../gke-cluster && terragrunt apply

# 2. Get kubectl credentials
gcloud container clusters get-credentials omnifeed-dev-cluster \
  --zone europe-west1-b \
  --project $(cd ../project && terragrunt output -raw project_id)

# 3. Install platform tools (see helm/platform/ docs)
# 4. Create app secrets (see section 8)
# 5. Deploy app
cd news-feed-infra/helm/omnifeed
helm dependency update
helm install omnifeed . -f values-dev.yaml -n omnifeed --create-namespace
```

## 11. Conventions & best practices followed

1. **One terragrunt unit per resource group** — small blast radius, clear state boundaries.
2. **Community modules over custom** — `terraform-google-modules/*` are maintained by Google, battle-tested. We pin by git ref.
3. **Environment-first directory structure** — `dev/networking/vpc` not `networking/dev/vpc`.
4. **APIs enabled at project level** — avoids race conditions in downstream modules.
5. **Private GKE nodes** — no public IPs on nodes; egress via Cloud NAT only.
6. **Preemptible nodes for dev** — 60-80% cost savings; regional + non-preemptible for prod.
7. **Autoscaling over fixed node count** — pay for what you use.
8. **Secrets never in git** — K8s Secrets created imperatively; prod will use External Secrets Operator.
9. **Multi-arch devcontainer** — native ARM64 binaries on Apple Silicon to avoid QEMU crashes.
10. **Helm umbrella chart** — single `helm install` deploys the entire app stack.
11. **Bitnami subcharts for dev** — in-cluster stateful services; swap for managed services in prod.
12. **Mock outputs on dependencies** — allows `terragrunt plan` before upstream is applied.
13. **Workload Identity** — pods authenticate to GCP via K8s ServiceAccount binding, no JSON keys.
14. **Network Policy enabled** — Calico enforces pod-to-pod communication rules.
