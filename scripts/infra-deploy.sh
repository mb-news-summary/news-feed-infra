#!/usr/bin/env bash
# scripts/infra-deploy.sh
#
# Runs terragrunt init + plan/apply/destroy for every dev unit in strict
# dependency order — one unit at a time, no parallelism, no timeout issues.
#
# Usage:
#   ./scripts/infra-deploy.sh [plan|apply|destroy] [dev|prod] [--clean]
#
# Examples:
#   ./scripts/infra-deploy.sh plan              # dry-run all units
#   ./scripts/infra-deploy.sh apply             # deploy everything
#   ./scripts/infra-deploy.sh apply dev --clean # wipe cache first, then apply
#   ./scripts/infra-deploy.sh destroy dev       # tear down (reverse order)
#
# --clean wipes .terragrunt-cache in every unit before init. Use this when
# you see "timeout while waiting for plugin to start" — it forces a fresh
# provider download into the shared cache (TF_PLUGIN_CACHE_DIR).

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
CMD="${1:-plan}"
ENV="${2:-dev}"
CLEAN=false
for arg in "$@"; do [[ "${arg}" == "--clean" ]] && CLEAN=true; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIVE="${REPO_ROOT}/live/environments/${ENV}"

# ---------------------------------------------------------------------------
# Shared plugin cache — providers are downloaded once, reused by every unit.
# Without this, each unit downloads its own copy and concurrent starts cause
# the "timeout while waiting for plugin to start" error.
# ---------------------------------------------------------------------------
export TF_PLUGIN_CACHE_DIR="${HOME}/.terraform.d/plugin-cache"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

# macOS Gatekeeper marks downloaded binaries with a quarantine flag and
# verifies them on first execution. That verification often exceeds
# Terraform's plugin-start timeout, causing the "timeout while waiting for
# plugin to start" error. Stripping the quarantine xattr fixes it.
if [[ "$(uname)" == "Darwin" ]]; then
  xattr -r -d com.apple.quarantine "${TF_PLUGIN_CACHE_DIR}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Dependency-ordered units (apply order).
# destroy reverses this list automatically.
# ---------------------------------------------------------------------------
UNITS=(
  "${LIVE}/project"
  "${LIVE}/networking/vpc"
  "${LIVE}/networking/cloud-nat"
  "${LIVE}/gke-cluster"
  "${LIVE}/artifact-registry"
  "${LIVE}/secret-manager"
  "${LIVE}/workload-identity"
)

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_header() { echo -e "\n${CYAN}${BOLD}══ [${1}/${2}] ${3} ══${RESET}"; }
log_ok()     { echo -e "${GREEN}✓ ${1}${RESET}"; }
log_warn()   { echo -e "${YELLOW}⚠ ${1}${RESET}"; }
log_err()    { echo -e "${RED}✗ ${1}${RESET}"; }

# ---------------------------------------------------------------------------
# Validate command
# ---------------------------------------------------------------------------
case "${CMD}" in
  plan|apply|destroy) ;;
  --help|-h)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    log_err "Unknown command '${CMD}'. Use: plan, apply, destroy"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Build flag arrays
# ---------------------------------------------------------------------------
INIT_FLAGS=("-no-color" "-input=false")

TG_FLAGS=("--non-interactive" "-no-color" "-input=false")
if [[ "${CMD}" == "apply" || "${CMD}" == "destroy" ]]; then
  TG_FLAGS+=("-auto-approve")
fi

# ---------------------------------------------------------------------------
# For destroy: reverse so dependents are removed before their dependencies
# ---------------------------------------------------------------------------
if [[ "${CMD}" == "destroy" ]]; then
  log_warn "Destroy mode — processing units in REVERSE order."
  REV=()
  for (( i=${#UNITS[@]}-1; i>=0; i-- )); do REV+=("${UNITS[$i]}"); done
  UNITS=("${REV[@]}")
fi

# ---------------------------------------------------------------------------
# Print what will run
# ---------------------------------------------------------------------------
TOTAL=${#UNITS[@]}
echo -e "${BOLD}Command:${RESET} ${CMD}   ${BOLD}Env:${RESET} ${ENV}   ${BOLD}Units:${RESET} ${TOTAL}   ${BOLD}Clean:${RESET} ${CLEAN}"
echo -e "${BOLD}Plugin cache:${RESET} ${TF_PLUGIN_CACHE_DIR}"
echo ""
for i in "${!UNITS[@]}"; do
  echo "  $((i+1)). ${UNITS[$i]#${REPO_ROOT}/}"
done

if [[ "${CMD}" == "apply" || "${CMD}" == "destroy" ]]; then
  echo ""
  read -r -p "$(echo -e "${YELLOW}Proceed with ${CMD}? [y/N]: ${RESET}")" CONFIRM
  [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
for i in "${!UNITS[@]}"; do
  UNIT="${UNITS[$i]}"
  LABEL="${UNIT#${REPO_ROOT}/}"

  log_header "$((i+1))" "${TOTAL}" "${LABEL}"

  if [[ ! -d "${UNIT}" ]]; then
    log_warn "Directory not found — skipping."
    continue
  fi

  cd "${UNIT}"
  T0=$(date +%s)

  # Wipe the unit's cache so the provider is re-fetched from the shared cache.
  if [[ "${CLEAN}" == true ]]; then
    log_warn "Clearing .terragrunt-cache"
    rm -rf .terragrunt-cache
  fi

  echo "→ init"
  terragrunt init "${INIT_FLAGS[@]}"

  # Strip macOS quarantine from any provider binaries downloaded by init.
  # New binaries are quarantined the moment they land on disk; applying
  # before stripping causes "timeout while waiting for plugin to start".
  if [[ "$(uname)" == "Darwin" ]]; then
    xattr -r -d com.apple.quarantine "${TF_PLUGIN_CACHE_DIR}" 2>/dev/null || true
  fi

  if [[ "${CMD}" == "apply" ]]; then
    # Run plan with -detailed-exitcode first:
    #   0 = no changes  → skip apply
    #   1 = plan error  → abort
    #   2 = has changes → apply
    echo "→ plan (checking for changes)"
    set +e
    terragrunt plan --non-interactive -no-color -input=false -detailed-exitcode
    PLAN_EXIT=$?
    set -e

    case ${PLAN_EXIT} in
      0)
        log_warn "No changes — skipping apply."
        cd "${REPO_ROOT}"
        continue
        ;;
      1)
        log_err "Plan failed for ${LABEL}"
        exit 1
        ;;
      2)
        echo "→ apply"
        terragrunt apply "${TG_FLAGS[@]}"
        ;;
    esac
  else
    echo "→ ${CMD}"
    terragrunt "${CMD}" "${TG_FLAGS[@]}"
  fi

  log_ok "${LABEL} — $(($(date +%s) - T0))s"
  cd "${REPO_ROOT}"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}══ Done ══${RESET}"
log_ok "All ${TOTAL} units completed (${CMD}, env=${ENV})."
