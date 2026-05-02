#!/usr/bin/env bash
# scripts/bootstrap-cluster.sh
#
# Full cluster bootstrap: namespaces → secrets → ArgoCD → GitOps.
# Run this ONCE after `./scripts/infra-deploy.sh apply` has completed.
# ArgoCD takes over after step 5 and manages everything else automatically.
#
# GCP Secret Manager secrets + GitHub K8s secret are handled by:
#   scripts/gsm-secrets-version.sh
# The only additional secret this script prompts for is the Cloudflare
# API token (used by cert-manager for Let's Encrypt DNS-01 challenges).
#
# Usage:
#   ./scripts/bootstrap-cluster.sh
#
# Pre-set to skip interactive prompts:
#   GCP_PROJECT, GKE_CLUSTER, GKE_ZONE, CLOUDFLARE_API_TOKEN
#
# What it deploys (via ArgoCD sync waves):
#   wave -3  cert-manager, nginx-ingress
#   wave -2  cluster-issuer (Let's Encrypt+Cloudflare), ESO, ARC controller
#   wave -1  ARC runner set
#   wave  0  Prometheus+Grafana, Elasticsearch, omnifeed app
#   wave  1  Kibana, Fluent Bit

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step()   { echo -e "\n${CYAN}${BOLD}════════════════════════════════════${RESET}"; \
           echo -e "${CYAN}${BOLD}  $*${RESET}"; \
           echo -e "${CYAN}${BOLD}════════════════════════════════════${RESET}"; }
ok()     { echo -e "${GREEN}✓ $*${RESET}"; }
warn()   { echo -e "${YELLOW}⚠ $*${RESET}"; }
info()   { echo -e "  $*"; }
die()    { echo -e "${RED}✗ $*${RESET}"; exit 1; }

prompt() {
  local var=$1 msg=$2 default=${3:-}
  if [[ -z "${!var:-}" ]]; then
    read -r -p "$(echo -e "${YELLOW}${msg}${default:+ [default: ${default}]}: ${RESET}")" val
    export "$var"="${val:-$default}"
  fi
}

secret_prompt() {
  local var=$1 msg=$2
  if [[ -z "${!var:-}" ]]; then
    read -r -s -p "$(echo -e "${YELLOW}${msg} (input hidden): ${RESET}")" val; echo
    [[ -z "$val" ]] && die "$var cannot be empty"
    export "$var"="$val"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Step 0: Prerequisites ────────────────────────────────────────────────────
step "0 / 7  Checking prerequisites"

for cmd in gcloud kubectl helm openssl; do
  command -v "$cmd" &>/dev/null || die "$cmd not found — please install it."
  ok "$cmd"
done

# ── Step 1: Cluster config ────────────────────────────────────────────────────
step "1 / 7  GKE cluster"

prompt GCP_PROJECT "GCP project ID"   "news-feed-omnifeed"
prompt GKE_CLUSTER "GKE cluster name" "omnifeed-dev-cluster"
prompt GKE_ZONE    "GKE zone"         "europe-west1-b"

gcloud container clusters get-credentials "$GKE_CLUSTER" \
  --zone "$GKE_ZONE" --project "$GCP_PROJECT"
ok "kubectl context set to $GKE_CLUSTER"
kubectl cluster-info --context "$(kubectl config current-context)"

# ── Step 2: Namespaces ────────────────────────────────────────────────────────
step "2 / 7  Namespaces"

kubectl apply -f "$REPO_ROOT/k8s/namespaces.yaml"
ok "All namespaces created (idempotent)"

# ── Step 3: Secrets ────────────────────────────────────────────────────────────
step "3 / 7  Secrets"

# 3a — GCP Secret Manager + GitHub K8s secret (delegated to dedicated script)
info "Running gsm-secrets-version.sh (GCP Secret Manager + arc-github-secret)..."
bash "$SCRIPT_DIR/gsm-secrets-version.sh"
ok "GCP secrets + arc-github-secret done"

# 3b — Cloudflare API token (not in gsm-secrets-version.sh — stored as K8s secret
#      in the cert-manager namespace so cert-manager can use it for DNS-01 challenges)
info ""
info "--- Cloudflare API token ---"
info "Create at: Cloudflare → My Profile → API Tokens → Create Token"
info "Template:  'Edit zone DNS'"
info "Permission: Zone → DNS → Edit  (scope to your domain only)"
echo ""
secret_prompt CLOUDFLARE_API_TOKEN "Cloudflare API token"

kubectl delete secret cloudflare-api-token -n cert-manager --ignore-not-found >/dev/null
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN"
ok "cloudflare-api-token → cert-manager namespace"

# ── Step 4: ArgoCD ────────────────────────────────────────────────────────────
step "4 / 7  ArgoCD"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values "$REPO_ROOT/helm/platform/argocd/values-dev.yaml" \
  --wait --timeout 5m

kubectl wait crd/appprojects.argoproj.io  --for=condition=Established --timeout=120s
kubectl wait crd/applications.argoproj.io --for=condition=Established --timeout=120s
ok "ArgoCD installed and CRDs ready"

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(already rotated)")
ok "ArgoCD admin password: ${ARGOCD_PASS}"

# ── Step 5: GitOps bootstrap ──────────────────────────────────────────────────
step "5 / 7  GitOps bootstrap"

info "Applying ArgoCD Projects (access control boundaries)..."
kubectl apply -f "$REPO_ROOT/gitops/projects/"
ok "Projects applied"

info "Applying root App-of-Apps..."
kubectl apply -f "$REPO_ROOT/gitops/bootstrap/app-of-apps.yaml"
ok "App-of-Apps applied"

info ""
info "ArgoCD will now deploy everything in sync-wave order:"
info "  wave -3 → cert-manager, nginx-ingress"
info "  wave -2 → cluster-issuer, ESO, ARC controller"
info "  wave -1 → ARC runner set"
info "  wave  0 → Prometheus+Grafana, Elasticsearch, omnifeed"
info "  wave  1 → Kibana, Fluent Bit"

# ── Step 6: Wait for nginx-ingress external IP ───────────────────────────────
step "6 / 7  Waiting for nginx-ingress external IP"

info "nginx-ingress creates a GCP LoadBalancer — this takes 1-3 minutes..."
echo -n "  Waiting"
for i in $(seq 1 60); do
  IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "$IP" ]]; then
    echo ""
    ok "External IP: ${IP}"
    echo ""
    warn "ACTION REQUIRED — Add these DNS records in Cloudflare:"
    echo ""
    printf "  %-8s %-30s %-16s %s\n" "Type" "Name" "Content" "Proxy"
    printf "  %-8s %-30s %-16s %s\n" "----" "----" "-------" "-----"
    printf "  %-8s %-30s %-16s %s\n" "A" "argocd"  "$IP" "🟠 Proxied"
    printf "  %-8s %-30s %-16s %s\n" "A" "grafana" "$IP" "🟠 Proxied"
    printf "  %-8s %-30s %-16s %s\n" "A" "kibana"  "$IP" "🟠 Proxied"
    printf "  %-8s %-30s %-16s %s\n" "A" "app"     "$IP" "🟠 Proxied"
    printf "  %-8s %-30s %-16s %s\n" "A" "api"     "$IP" "🟠 Proxied"
    echo ""
    warn "Cloudflare SSL/TLS mode must be set to: Full (strict)"
    warn "Dashboard: your domain → SSL/TLS → Overview → Full (strict)"
    break
  fi
  echo -n "."
  sleep 5
done
if [[ -z "${IP:-}" ]]; then
  warn "nginx-ingress not ready yet. Check later with:"
  warn "  kubectl get svc ingress-nginx-controller -n ingress-nginx"
fi

# ── Step 7: Summary ────────────────────────────────────────────────────────────
step "7 / 7  Done"

echo ""
echo -e "${BOLD}Credentials:${RESET}"
echo "  ArgoCD admin password : ${ARGOCD_PASS}"
echo "  App secrets           : see scripts/gsm-secrets-version.sh"
echo ""
echo -e "${BOLD}Watch ArgoCD sync progress:${RESET}"
echo "  kubectl get applications -n argocd -w"
echo ""
echo -e "${BOLD}Once DNS is set and cert-manager issues certs, access via:${RESET}"
echo "  https://argocd.marianbodnar.uk"
echo "  https://grafana.marianbodnar.uk"
echo "  https://kibana.marianbodnar.uk"
echo "  https://app.marianbodnar.uk"
echo ""
echo -e "${BOLD}Port-forward fallback (while DNS propagates):${RESET}"
echo "  kubectl -n argocd     port-forward svc/argocd-server     8080:80"
echo "  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
