# Platform Tools — Installation & Usage Guide

This directory contains Helm values files for the cluster-level platform tools.
These are **separate from the omnifeed app chart** — they're cluster-wide
infrastructure that every app benefits from.

```
helm/platform/
├── monitoring/      Prometheus + Grafana + Alertmanager (kube-prometheus-stack)
├── efk/             Elasticsearch + Fluent Bit + Kibana (centralized logging)
├── argocd/          Argo CD — GitOps continuous delivery
├── atlantis/        Atlantis — Terraform/Terragrunt PR automation
└── README.md        ← this file
```

---

## Prerequisites

Before installing any platform tool, make sure:

```bash
# 1. You're connected to the cluster
kubectl cluster-info

# 2. Helm repos are added
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add elastic https://helm.elastic.co
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add runatlantis https://runatlantis.github.io/helm-charts
helm repo update
```

---

## 1. Monitoring (Prometheus + Grafana)

### What it does

- **Prometheus** scrapes metrics from the cluster, nodes, pods, and your app.
- **Grafana** provides dashboards to visualize those metrics.
- **Alertmanager** sends alerts when things go wrong (Slack, email, PagerDuty).
- **Node Exporter** exposes hardware/OS metrics from each node.
- **kube-state-metrics** exposes Kubernetes object metrics (pods, deployments, etc).

All five come bundled in one chart: `kube-prometheus-stack`.

### Install

```bash
kubectl create namespace monitoring

helm install monitoring prometheus-community/kube-prometheus-stack \
  -f helm/platform/monitoring/values-dev.yaml \
  -n monitoring
```

### Access Grafana

```bash
# Port-forward Grafana to your laptop
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

Open [http://localhost:3000](http://localhost:3000):
- Username: `admin`
- Password: `omnifeed-dev-grafana`

### Built-in dashboards

kube-prometheus-stack ships with ~20 dashboards out of the box:

| Dashboard | What it shows |
|---|---|
| Kubernetes / Compute Resources / Cluster | Overall CPU/memory usage |
| Kubernetes / Compute Resources / Namespace (Pods) | Per-pod resource usage |
| Kubernetes / Networking / Cluster | Network traffic between pods |
| Node Exporter / Nodes | Disk, CPU, memory per node |
| CoreDNS | DNS query rates and errors |

### Access Prometheus directly

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Open [http://localhost:9090](http://localhost:9090) to run PromQL queries.

### Useful PromQL queries for your app

```promql
# API gateway request rate (if you add Prometheus metrics to the Go app)
rate(http_requests_total{app="api-gateway"}[5m])

# Pod restarts (catches crash loops)
increase(kube_pod_container_status_restarts_total{namespace="omnifeed"}[1h])

# Memory usage by pod
container_memory_working_set_bytes{namespace="omnifeed"} / 1024 / 1024

# Node CPU utilization
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

### Adding custom dashboards

Create a ConfigMap with `grafana_dashboard: "1"` label:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-custom-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    { ... Grafana dashboard JSON ... }
```

Grafana's sidecar will auto-discover and load it.

### Upgrade / Uninstall

```bash
# Upgrade with new values
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -f helm/platform/monitoring/values-dev.yaml -n monitoring

# Uninstall (CRDs persist — delete them manually if needed)
helm uninstall monitoring -n monitoring
```

---

## 2. EFK Stack — Centralized Logging

### What it does

The EFK stack collects, stores, and visualizes logs from every container in
the cluster:

- **Fluent Bit** runs as a DaemonSet (one pod per node). It tails container
  logs from `/var/log/containers/`, enriches them with Kubernetes metadata
  (pod name, namespace, labels), and ships them to Elasticsearch.
- **Elasticsearch** stores and indexes the logs. You can search across millions
  of log lines in milliseconds.
- **Kibana** is the web UI — search logs, build dashboards, set up alerts.

```
Every Node                    Logging Namespace
┌──────────────┐
│  Pod A logs  │──┐
│  Pod B logs  │──┼──► Fluent Bit ──► Elasticsearch ──► Kibana (UI)
│  Pod C logs  │──┘    (DaemonSet)     (StatefulSet)     (Deployment)
└──────────────┘
```

### Why Fluent Bit over Fluentd?

Fluent Bit is ~10x lighter (~15MB RAM vs ~150MB), written in C, and
purpose-built for log forwarding. Fluentd is more flexible for complex
routing, but Fluent Bit covers 95% of use cases. You can always swap in
Fluentd later if you need advanced processing — the Elasticsearch/Kibana
parts stay the same.

### Install

The EFK stack uses 3 separate Helm charts. Install them in this order
(Elasticsearch must be up before Fluent Bit and Kibana can connect):

```bash
kubectl create namespace logging

# 1. Elasticsearch (takes ~2-3 minutes to become ready)
helm install elasticsearch elastic/elasticsearch \
  -f helm/platform/efk/elasticsearch-values-dev.yaml \
  -n logging

# Wait for ES to be ready
kubectl -n logging rollout status statefulset/elasticsearch-master --timeout=300s

# 2. Kibana (connects to ES on startup)
helm install kibana elastic/kibana \
  -f helm/platform/efk/kibana-values-dev.yaml \
  -n logging

# 3. Fluent Bit (starts shipping logs to ES immediately)
helm install fluent-bit fluent/fluent-bit \
  -f helm/platform/efk/fluent-bit-values-dev.yaml \
  -n logging
```

### Access Kibana

```bash
kubectl -n logging port-forward svc/kibana-kibana 5601:5601
```

Open [http://localhost:5601](http://localhost:5601).

### First-time Kibana setup

1. Go to **Management → Stack Management → Index Patterns**.
2. Create an index pattern: `fluent-bit-*`
3. Select `@timestamp` as the time field.
4. Go to **Discover** — you should see logs flowing in.

### Useful Kibana queries (KQL)

```
# All logs from the omnifeed namespace
kubernetes.namespace_name: "omnifeed"

# API gateway errors
kubernetes.labels.app: "api-gateway" AND log_processed.level: "error"

# Worker-fetcher logs in the last hour
kubernetes.labels.app: "worker-fetcher"

# All pod crash/restart events
kubernetes.container_name: * AND stream: "stderr"

# Search for a specific error message
log_processed: "connection refused"
```

### How logs are structured

Fluent Bit enriches each log line with Kubernetes metadata. A typical
document in Elasticsearch looks like:

```json
{
  "@timestamp": "2026-04-18T14:30:00.000Z",
  "kubernetes": {
    "namespace_name": "omnifeed",
    "pod_name": "omnifeed-api-gateway-5d8f9b7c4-x2k9p",
    "container_name": "api-gateway",
    "labels": {
      "app": "api-gateway",
      "app.kubernetes.io/part-of": "omnifeed"
    },
    "host": "gke-omnifeed-dev-general-abc123"
  },
  "log_processed": {
    "level": "info",
    "msg": "GET /api/health 200 1.2ms"
  },
  "stream": "stdout"
}
```

### Log retention

By default, Fluent Bit creates one Elasticsearch index per day:
`fluent-bit-2026.04.18`, `fluent-bit-2026.04.19`, etc.

For dev, manually delete old indices when disk fills up:

```bash
# Delete indices older than 7 days (adjust the date)
kubectl -n logging exec elasticsearch-master-0 -- \
  curl -X DELETE "localhost:9200/fluent-bit-2026.04.10"
```

For prod, set up ILM (Index Lifecycle Management) in Elasticsearch to
auto-delete indices after N days.

### Verify the pipeline

```bash
# Check Fluent Bit is running on every node
kubectl -n logging get pods -l app.kubernetes.io/name=fluent-bit -o wide

# Check Fluent Bit metrics (should show records_total > 0)
kubectl -n logging port-forward ds/fluent-bit 2020:2020 &
curl -s http://localhost:2020/api/v1/metrics | head -20

# Check Elasticsearch has data
kubectl -n logging exec elasticsearch-master-0 -- \
  curl -s "localhost:9200/_cat/indices?v" | grep fluent-bit

# Check Elasticsearch cluster health
kubectl -n logging exec elasticsearch-master-0 -- \
  curl -s "localhost:9200/_cluster/health?pretty"
```

### Upgrade / Uninstall

```bash
# Upgrade individual components
helm upgrade elasticsearch elastic/elasticsearch \
  -f helm/platform/efk/elasticsearch-values-dev.yaml -n logging
helm upgrade kibana elastic/kibana \
  -f helm/platform/efk/kibana-values-dev.yaml -n logging
helm upgrade fluent-bit fluent/fluent-bit \
  -f helm/platform/efk/fluent-bit-values-dev.yaml -n logging

# Uninstall (order: fluent-bit → kibana → elasticsearch)
helm uninstall fluent-bit -n logging
helm uninstall kibana -n logging
helm uninstall elasticsearch -n logging

# Clean up PVCs (deletes stored logs!)
kubectl -n logging delete pvc -l app=elasticsearch-master
```

### Dev vs Prod differences

| Setting | Dev | Prod |
|---|---|---|
| ES replicas | 1 (single node) | 3 master + 2 data minimum |
| ES storage | 10Gi | 100Gi+ with SSD |
| ES security | Disabled | xpack.security + TLS |
| ES anti-affinity | soft | hard (spread across nodes) |
| Index retention | Manual cleanup | ILM auto-delete after 30 days |
| Kibana replicas | 1 | 2 (behind LB) |
| Fluent Bit memory | 128Mi limit | 256Mi+ limit |

---

## 3. ArgoCD — GitOps

### What it does

ArgoCD watches your git repo and automatically syncs Kubernetes manifests to
the cluster. The workflow becomes:

1. You push code / Helm values to git.
2. ArgoCD detects the change.
3. ArgoCD renders the manifests and compares them to what's running.
4. If there's a diff, ArgoCD applies it (auto-sync) or flags it (manual sync).

This replaces `helm install/upgrade` from your laptop with a git-centric
workflow. Every deploy is a git commit — auditable, reversible, reviewable.

### Install

```bash
kubectl create namespace argocd

helm install argocd argo/argo-cd \
  -f helm/platform/argocd/values-dev.yaml \
  -n argocd
```

### Access the UI

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# Port-forward
kubectl -n argocd port-forward svc/argocd-server 8443:443
```

Open [https://localhost:8443](https://localhost:8443):
- Username: `admin`
- Password: (from the command above)

### Install the CLI

```bash
# macOS
brew install argocd

# Or download from GitHub
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
```

### Create your first Application

An "Application" tells ArgoCD what to deploy and where:

```bash
argocd login localhost:8443 --insecure

# Point ArgoCD at your omnifeed Helm chart
argocd app create omnifeed \
  --repo https://github.com/your-org/news-feed-infra.git \
  --path helm/omnifeed \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace omnifeed \
  --helm-set-file values=helm/omnifeed/values-dev.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

Or declaratively as a YAML manifest:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: omnifeed
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/news-feed-infra.git
    targetRevision: main
    path: helm/omnifeed
    helm:
      valueFiles:
        - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: omnifeed
  syncPolicy:
    automated:
      prune: true       # delete resources removed from git
      selfHeal: true     # revert manual kubectl changes
    syncOptions:
      - CreateNamespace=true
```

### Key concepts

| Concept | Meaning |
|---|---|
| **Sync** | Apply the desired state from git to the cluster |
| **Refresh** | Re-read git to check for changes |
| **Prune** | Delete K8s resources that no longer exist in git |
| **Self-heal** | Revert manual `kubectl` changes to match git |
| **Health** | ArgoCD checks if resources are healthy (pods running, etc) |
| **OutOfSync** | Git state differs from cluster state |

---

## 4. Atlantis — Terraform PR Automation

### What it does

Atlantis runs in your cluster and listens for GitHub webhooks. When someone
opens a PR that changes `.hcl` or `.tf` files:

1. Atlantis runs `terragrunt plan` and posts the output as a PR comment.
2. A reviewer reads the plan, approves the PR.
3. Someone comments `atlantis apply` on the PR.
4. Atlantis runs `terragrunt apply` and posts the result.

This eliminates "works on my machine" Terraform runs. Everyone sees the same
plan, and applies happen from a consistent environment.

### Install

```bash
kubectl create namespace atlantis

# Create the credentials secret first
kubectl -n atlantis create secret generic atlantis-creds \
  --from-literal=github-token='ghp_your_personal_access_token' \
  --from-literal=github-secret='your_random_webhook_secret'

helm install atlantis runatlantis/atlantis \
  -f helm/platform/atlantis/values-dev.yaml \
  -n atlantis
```

### Configure the GitHub webhook

1. Go to your repo → Settings → Webhooks → Add webhook.
2. Payload URL: `https://<atlantis-url>/events`
   (In dev, use ngrok or a public IP; in prod, expose via Ingress).
3. Content type: `application/json`
4. Secret: the same `your_random_webhook_secret` from the secret above.
5. Events: select "Pull requests" and "Push".

### Configure your repo (atlantis.yaml)

In the root of `news-feed-infra`, update `atlantis.yaml`:

```yaml
version: 3
projects:
  - name: dev-project
    dir: live/environments/dev/project
    workflow: terragrunt
    autoplan:
      when_modified: ["*.hcl", "*.yaml"]
      enabled: true

  - name: dev-vpc
    dir: live/environments/dev/networking/vpc
    workflow: terragrunt
    autoplan:
      when_modified: ["*.hcl", "*.yaml"]
      enabled: true

  - name: dev-cloud-nat
    dir: live/environments/dev/networking/cloud-nat
    workflow: terragrunt
    autoplan:
      when_modified: ["*.hcl", "*.yaml"]
      enabled: true

  - name: dev-gke-cluster
    dir: live/environments/dev/gke-cluster
    workflow: terragrunt
    autoplan:
      when_modified: ["*.hcl", "*.yaml"]
      enabled: true

workflows:
  terragrunt:
    plan:
      steps:
        - env:
            name: TERRAGRUNT_TFPATH
            command: 'which terraform'
        - run: terragrunt plan -no-color -out=$PLANFILE
    apply:
      steps:
        - env:
            name: TERRAGRUNT_TFPATH
            command: 'which terraform'
        - run: terragrunt apply -no-color $PLANFILE
```

### Atlantis PR workflow

```
Developer opens PR → Atlantis auto-plans → Posts plan as comment
                                              ↓
                                   Reviewer approves PR
                                              ↓
                              Comment "atlantis apply" → Atlantis applies
                                              ↓
                                   Merge PR (infra is live)
```

### Workload Identity for Atlantis (recommended)

Instead of mounting a GCP service account key, bind the Atlantis K8s
ServiceAccount to a GCP service account:

```bash
# 1. Create a GCP SA for Atlantis
gcloud iam service-accounts create atlantis \
  --project=<your-project-id>

# 2. Grant it the roles Terraform needs
gcloud projects add-iam-policy-binding <your-project-id> \
  --member="serviceAccount:atlantis@<your-project-id>.iam.gserviceaccount.com" \
  --role="roles/editor"

# 3. Bind the K8s SA to the GCP SA
gcloud iam service-accounts add-iam-policy-binding \
  atlantis@<your-project-id>.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:<your-project-id>.svc.id.goog[atlantis/atlantis]"

# 4. Annotate the K8s SA (update values-dev.yaml)
# serviceAccount:
#   annotations:
#     iam.gke.io/gcp-service-account: atlantis@<project-id>.iam.gserviceaccount.com
```

---

## Installation order (recommended)

```bash
# 1. Monitoring first — so you can observe everything else
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f helm/platform/monitoring/values-dev.yaml -n monitoring --create-namespace

# 2. EFK stack — centralized logging
kubectl create namespace logging
helm install elasticsearch elastic/elasticsearch \
  -f helm/platform/efk/elasticsearch-values-dev.yaml -n logging
kubectl -n logging rollout status statefulset/elasticsearch-master --timeout=300s
helm install kibana elastic/kibana \
  -f helm/platform/efk/kibana-values-dev.yaml -n logging
helm install fluent-bit fluent/fluent-bit \
  -f helm/platform/efk/fluent-bit-values-dev.yaml -n logging

# 3. ArgoCD — so it can manage subsequent deploys
helm install argocd argo/argo-cd \
  -f helm/platform/argocd/values-dev.yaml -n argocd --create-namespace

# 4. Atlantis — for Terraform PR automation
kubectl create namespace atlantis
kubectl -n atlantis create secret generic atlantis-creds \
  --from-literal=github-token='...' --from-literal=github-secret='...'
helm install atlantis runatlantis/atlantis \
  -f helm/platform/atlantis/values-dev.yaml -n atlantis

# 5. Your app (via ArgoCD or manually)
helm install omnifeed helm/omnifeed -f helm/omnifeed/values-dev.yaml \
  -n omnifeed --create-namespace
```

---

## Quick reference

| Tool | Namespace | Port-forward command | URL |
|---|---|---|---|
| Grafana | monitoring | `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` | http://localhost:3000 |
| Prometheus | monitoring | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090` | http://localhost:9090 |
| Kibana | logging | `kubectl -n logging port-forward svc/kibana-kibana 5601:5601` | http://localhost:5601 |
| Elasticsearch | logging | `kubectl -n logging port-forward svc/elasticsearch-master 9200:9200` | http://localhost:9200 |
| ArgoCD | argocd | `kubectl -n argocd port-forward svc/argocd-server 8443:443` | https://localhost:8443 |
| Atlantis | atlantis | `kubectl -n atlantis port-forward svc/atlantis 4141:80` | http://localhost:4141 |
| RabbitMQ UI | omnifeed | `kubectl -n omnifeed port-forward svc/omnifeed-rabbitmq 15672:15672` | http://localhost:15672 |
