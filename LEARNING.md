# Learning log — news-feed-infra

A running record of the infra decisions, why we made them, and how to apply
them. Keep this file up to date as the project grows — future-you will thank
present-you.

## 1. Repo layout (the "live / modules" split)

```
live/
  environments/
    root.hcl              shared provider + GCS backend
    common.yaml           org/billing/region/app name
    dev/
      env.yaml            env-specific knobs (folder id, node count, …)
      project/            creates the GCP project
      networking/
        vpc/              VPC + subnet + secondary ranges
        cloud-nat/        Router + NAT for private-node egress
      gke-cluster/        GKE (still to build)
    prod/
      env.yaml
      …                   same layout as dev
  modules/                local Terraform modules (optional wrappers)
```

Best practice:

- **One unit = one `terragrunt.hcl` folder = one Terraform state file.** Small
  blast radius, faster plans, clear ownership.
- **Group by environment first, resource second.** `dev/networking/vpc` is
  easier to reason about than `networking/dev/vpc`.
- `live/` holds *deployed* config. `modules/` is reserved for local Terraform
  modules you author yourself. Since we're using Google's community modules
  directly via `terraform { source = "git::…" }`, `modules/` can stay empty
  until you have logic that genuinely repeats across environments.

## 2. The dependency graph for dev

```
project → networking/vpc → networking/cloud-nat → gke-cluster
```

Terragrunt applies these in order because each downstream unit has a
`dependency` block pointing at the upstream one. You can:

- Apply just one unit: `cd live/environments/dev/networking/vpc && terragrunt apply`
- Apply everything in dev: `cd live/environments/dev && terragrunt run-all apply`

`run-all` plans everything in parallel and only runs `apply` in the right order
based on `dependency` edges. Use it with care in prod (one bad plan will be
applied everywhere at once).

## 3. Decisions and trade-offs

### Networking

| Decision | Value | Why |
|---|---|---|
| VPC mode | custom (not auto-create) | explicit CIDRs, no surprise default firewall rules |
| Routing mode | GLOBAL | keeps the door open for multi-region later |
| Subnet CIDR (nodes) | 10.10.0.0/20 | 4k IPs — plenty for dev |
| Secondary range pods | 10.20.0.0/14 | GKE needs 1 IP per pod; oversize is free |
| Secondary range services | 10.30.0.0/20 | ClusterIP Services |
| Private Google Access | on | nodes reach GCP APIs without public IPs |
| VPC flow logs | on, 10% sample | cheap debugging signal |
| Cloud NAT | yes, 1 per region | egress for private nodes |
| NAT log filter | ERRORS_ONLY | keeps log cost tiny |

### GKE cluster privacy (what we'll build next)

Three options, briefly:

1. **Public cluster** — nodes + control plane on the internet. Don't.
2. **Private nodes, public endpoint + authorized networks** ← dev choice.
   Nodes are private (safe), control plane has a public endpoint locked to
   your IP allow-list. You can `kubectl` from your laptop.
3. **Fully private cluster** — both nodes and control plane private. Needs a
   bastion/VPN/IAP tunnel. Best posture for prod; more moving parts.

Plan: dev uses option 2. Prod will use option 3. The community
`terraform-google-modules/kubernetes-engine` module can flip between them via
`enable_private_endpoint`, so the upgrade path is one variable.

### Project factory

- We enable APIs at the project level (not scattered across units) so that
  downstream units never race on an API that isn't ready yet.
- `auto_create_network = false` — we build our own VPC.
- **TODO:** once you're ready to add prod, rename the project input to
  `name = "news-feed-${environment}"` so `news-feed-dev` and `news-feed-prod`
  don't collide. This will destroy+recreate the current dev project, so do it
  deliberately (empty dev first).

## 4. GKE cluster decisions

### Module choice: private-cluster submodule

The community repo `terraform-google-modules/kubernetes-engine` ships several
submodules:

- **Root module** — full-featured but you configure privacy yourself.
- **`//modules/private-cluster`** ← what we use for dev. Turns on private node
  defaults and adds the `master_ipv4_cidr_block` input.
- **`//modules/safer-cluster`** — very opinionated: enables Binary Authorization,
  intranode visibility, Shielded GKE nodes, etc. Ideal for prod, but requires
  org-policy preconditions.

### Zonal vs regional

| | Zonal | Regional |
|---|---|---|
| Control plane replicas | 1 | 3 |
| Cost | ~same node cost, cheaper control plane | 3× control-plane footprint |
| Zone outage | cluster unreachable | survives 1 zone failure |
| **Dev** | **✓** | overkill |
| **Prod** | ✗ | **✓** |

### Node pool design

- **remove_default_node_pool = true**: the default pool is inflexible (can't
  resize to 0, can't change machine type). Always create a dedicated pool.
- **preemptible = true** (dev only): ~60-80% savings. Pods must tolerate
  restarts (Deployments with `replicas ≥ 2` handle this naturally).
- **GKE_METADATA**: enables the GKE Metadata Server on nodes, which is
  required for Workload Identity.

### Authorized networks

`master_authorized_networks` is a list of CIDRs allowed to reach the k8s
API. You set your public IP in `env.yaml` → `master_authorized_cidr`.
Find it with `curl -s https://icanhazip.com`.

### Control plane peering range

`master_ipv4_cidr_block = "172.16.0.0/28"` — GKE creates a separate VPC
for the control plane and peers it to your VPC. This /28 must not overlap
with any CIDR in your VPC. Convention: use the 172.16.x.x space.

### Workload Identity

The recommended way for pods to authenticate to GCP. Each Kubernetes
ServiceAccount can be bound to a GCP service account — no JSON key files
in Secrets. The cluster exposes an OIDC issuer; GCP trusts it.

Set `identity_namespace = "<project_id>.svc.id.goog"` on the cluster,
then annotate your K8s ServiceAccount:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
  annotations:
    iam.gke.io/gcp-service-account: my-app@<project_id>.iam.gserviceaccount.com
```

And grant the binding on the GCP side:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  my-app@<project_id>.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:<project_id>.svc.id.goog[<namespace>/my-app]"
```

## 5. How to apply the dev stack (first time)

```bash
# Authenticate once per machine.
gcloud auth application-default login
gcloud auth application-default set-quota-project bootstrap-terragrunt-gcs-01

# !! BEFORE APPLYING: set your public IP in dev/env.yaml !!
# Run: curl -s https://icanhazip.com
# Then edit live/environments/dev/env.yaml:
#   master_authorized_cidr: "YOUR_IP/32"

# 1. Project (already applied, but safe to re-run)
cd live/environments/dev/project
terragrunt plan
terragrunt apply

# 2. VPC
cd ../networking/vpc
terragrunt plan
terragrunt apply

# 3. Cloud NAT
cd ../cloud-nat
terragrunt plan
terragrunt apply

# 4. GKE cluster (~10 min to create)
cd ../../gke-cluster
terragrunt plan          # read this carefully
terragrunt apply

# 5. Get kubectl credentials
gcloud container clusters get-credentials omnifeed-dev-cluster \
  --zone europe-west1-b \
  --project $(cd ../project && terragrunt output -raw project_id)
kubectl get nodes        # should show 2 preemptible nodes
```

Or the one-shot equivalent (use only when you trust the plan):

```bash
cd live/environments/dev
terragrunt run-all plan
terragrunt run-all apply
```

## 6. How to connect kubectl after the cluster is up

```bash
# Install gke-gcloud-auth-plugin if you haven't:
gcloud components install gke-gcloud-auth-plugin

# Fetch credentials:
gcloud container clusters get-credentials omnifeed-dev-cluster \
  --zone europe-west1-b \
  --project <your-project-id>

# Verify:
kubectl cluster-info
kubectl get nodes
```

If `kubectl` times out, your current public IP may have changed.
Update `master_authorized_cidr` in `env.yaml` and re-apply the cluster.

## 7. What to do before every apply

1. `terragrunt hclfmt` at the repo root — keeps formatting consistent.
2. `terragrunt plan` (per-unit) — read the diff; never trust `run-all plan`
   alone for anything risky.
3. Scan the plan for `destroy` / `replace` operations on stateful resources
   (projects, databases, clusters). Those are the ones that bite.
4. Commit the .terraform.lock.hcl files that Terragrunt generates — they pin
   provider versions across collaborators.

## 8. Next steps queue

- [ ] Build `live/environments/dev/gke-cluster/terragrunt.hcl` against
      `terraform-google-modules/kubernetes-engine` (safer-cluster variant) with
      private nodes + public authorized endpoint.
- [ ] Decide on authorized networks (your home IP, CI ranges).
- [ ] Add a local `modules/` wrapper for GKE once you're repeating yourself
      between dev and prod.
- [ ] Add pre-commit hooks: `terraform_fmt`, `terragrunt_fmt`,
      `terraform_validate`, `terraform_docs`.
- [ ] Add a CI workflow (GitHub Actions) that runs `terragrunt run-all plan`
      against PRs and `apply` on merges to main (or switch to Atlantis —
      you've already got an `atlantis.yaml` scaffold).
- [ ] Mirror everything into `live/environments/prod/…` once dev is stable.
- [ ] Fix typo: rename `live/modules/databse` → `database` (skipped for now
      per your choice — do this before any module lands in it).
