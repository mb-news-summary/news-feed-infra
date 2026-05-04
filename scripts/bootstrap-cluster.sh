#!/usr/bin/env bash
# scripts/bootstrap-cluster.sh
#
# Full cluster bootstrap: namespaces → secrets → ArgoCD → GitOps → DNS.
# Run ONCE after `./scripts/infra-deploy.sh apply` has completed.
#
# Usage:
#   ./scripts/bootstrap-cluster.sh
#
# Pre-set to skip interactive prompts:
#   GCP_PROJECT, GKE_CLUSTER, GKE_ZONE, CLOUDFLARE_API_TOKEN, CF_API_TOKEN

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step() { echo -e "\n${CYAN}${BOLD}════════════════════════════════════${RESET}";
         echo -e "${CYAN}${BOLD}  $*${RESET}";
         echo -e "${CYAN}${BOLD}════════════════════════════════════${RESET}"; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
info() { echo -e "  $*"; }
die()  { echo -e "${RED}✗ $*${RESET}"; exit 1; }

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

# ── Step 0: Prerequisites ─────────────────────────────────────────────────────
step "0 / 7  Checking prerequisites"

for cmd in gcloud kubectl helm openssl curl jq; do
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

# ── Step 3: Secrets ───────────────────────────────────────────────────────────
step "3 / 7  Secrets"

info "Running gsm-secrets-version.sh (GCP Secret Manager + arc-github-secret)..."
bash "$SCRIPT_DIR/gsm-secrets-version.sh"
ok "GCP secrets + arc-github-secret done"

info ""
info "--- Cloudflare API token ---"
info "Create at: Cloudflare → My Profile → API Tokens → Create Token"
info "Template:  'Edit zone DNS' — Zone → DNS → Edit"
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

info "Applying ArgoCD Projects..."
kubectl apply -f "$REPO_ROOT/gitops/projects/"
ok "Projects applied"

info "Applying root App-of-Apps..."
kubectl apply -f "$REPO_ROOT/gitops/bootstrap/app-of-apps.yaml"
ok "App-of-Apps applied — ArgoCD will now deploy in sync-wave order:"
info "  wave -3 → cert-manager, Traefik (LoadBalancer)"
info "  wave -2 → cluster-issuer (Let's Encrypt), ESO, ARC controller"
info "  wave -1 → ARC runner set"
info "  wave  0 → Prometheus+Grafana, Loki, omnifeed app"
info "  wave  1 → Promtail"

# ── Step 6: Wait for Traefik external IP then set DNS ─────────────────────────
step "6 / 7  DNS setup"

info "Waiting for Traefik LoadBalancer IP (1-3 min)..."
echo -n "  Waiting"
for i in $(seq 1 60); do
  IP=$(kubectl get svc traefik -n traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "$IP" ]]; then
    echo ""
    ok "Traefik external IP: ${IP}"
    break
  fi
  echo -n "."
  sleep 5
done

if [[ -z "${IP:-}" ]]; then
  warn "Traefik not ready yet — DNS setup skipped. Run setup-dns.sh manually later:"
  warn "  CF_API_TOKEN=<token> ./scripts/setup-dns.sh"
else
  info "Running setup-dns.sh to create Cloudflare DNS records..."
  export CF_API_TOKEN="$CLOUDFLARE_API_TOKEN"
  bash "$SCRIPT_DIR/setup-dns.sh"
fi

# ── Step 7: Summary ───────────────────────────────────────────────────────────
step "7 / 7  Done"

echo ""
echo -e "${BOLD}Credentials:${RESET}"
echo "  ArgoCD admin password : ${ARGOCD_PASS}"
echo "  Grafana               : admin / omnifeed-dev-grafana"
echo ""
echo -e "${BOLD}Watch ArgoCD sync:${RESET}"
echo "  kubectl get applications -n argocd -w"
echo ""
echo -e "${BOLD}Services (once DNS + TLS are ready):${RESET}"
echo "  https://argocd.marianbodnar.uk"
echo "  https://grafana.marianbodnar.uk  (logs via Explore → Loki)"
echo "  https://app.marianbodnar.uk"
echo ""
echo -e "${BOLD}Port-forward fallback:${RESET}"
echo "  kubectl -n argocd     port-forward svc/argocd-server     8080:80"
echo "  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
