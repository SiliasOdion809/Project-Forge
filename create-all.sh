#!/usr/bin/env bash
#
# create-all.sh — Recreate all Project Forge infrastructure (Phases 1–3)
#
# Order matters: the network must exist before the cluster, the cluster
# before anything that talks to it via kubectl, and ArgoCD's root-app last,
# since it pulls in every ApplicationSet (sample-api, greeting-service)
# automatically once applied.
#
# Assumes the Terraform state backend (bootstrap/) already exists.
# If you also destroyed that, pass --include-bootstrap to recreate it first.
#
# Usage:
#   ./create-all.sh                      # interactive, asks for confirmation
#   ./create-all.sh --dry-run            # runs `terraform plan` only, creates nothing
#   ./create-all.sh --yes                # skip the confirmation prompt
#   ./create-all.sh --include-bootstrap  # also (re)create the state backend first

set -o pipefail

DRY_RUN=false
AUTO_YES=false
INCLUDE_BOOTSTRAP=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes) AUTO_YES=true ;;
    --include-bootstrap) INCLUDE_BOOTSTRAP=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Terraform root modules, foundation first, dependents after.
MODULES=(
  "live/network"
  "live/cluster"
  "live/ecr"
  "live/rds"
  "live/bastion"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="$(aws configure get region 2>/dev/null)"
REGION="${REGION:-us-east-1}"
CLUSTER_NAME="project-forge"

FAILED=()
SUCCEEDED=()
SKIPPED=()

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$1"; }

print_summary() {
  echo
  log "Summary"
  if [ ${#SUCCEEDED[@]} -gt 0 ]; then echo "  Applied:  ${SUCCEEDED[*]}"; fi
  if [ ${#SKIPPED[@]}   -gt 0 ]; then echo "  Skipped:  ${SKIPPED[*]}"; fi
  if [ ${#FAILED[@]}    -gt 0 ]; then echo "  Failed:   ${FAILED[*]}"; fi
}

log "Current AWS identity:"
aws sts get-caller-identity --output table || { err "Could not reach AWS — check your credentials."; exit 1; }
log "Region: $REGION"

if [ "$DRY_RUN" = false ] && [ "$AUTO_YES" = false ]; then
  echo
  warn "This will CREATE/APPLY the following, in this order:"
  [ "$INCLUDE_BOOTSTRAP" = true ] && echo "    - bootstrap (state backend)"
  for m in "${MODULES[@]}"; do echo "    - $m"; done
  echo "    - kubeconfig + ArgoCD install + root-app (kubectl, not Terraform)"
  echo
  read -rp 'Type "apply" to continue: ' CONFIRM
  if [ "$CONFIRM" != "apply" ]; then
    echo "Aborted — nothing was touched."
    exit 0
  fi
fi

apply_dir() {
  local label="$1"
  local full_path="$2"

  log "Processing $label"
  pushd "$full_path" >/dev/null || return 1

  if ! terraform init -input=false; then
    err "terraform init failed for $label"
    FAILED+=("$label")
    popd >/dev/null
    print_summary
    exit 1
  fi

  if [ "$DRY_RUN" = true ]; then
    terraform plan -input=false
    popd >/dev/null
    return 0
  fi

  if terraform apply -auto-approve -input=false; then
    SUCCEEDED+=("$label")
  else
    err "terraform apply failed for $label — stopping before anything downstream depends on it."
    FAILED+=("$label")
    popd >/dev/null
    print_summary
    exit 1
  fi

  popd >/dev/null
}

# 1. Optional: state backend
if [ "$INCLUDE_BOOTSTRAP" = true ]; then
  if [ -d "$REPO_ROOT/bootstrap" ]; then
    apply_dir "bootstrap" "$REPO_ROOT/bootstrap"
  else
    warn "bootstrap/ not found — skipping"
    SKIPPED+=("bootstrap")
  fi
fi

# 2. Terraform root modules, in dependency order
for module in "${MODULES[@]}"; do
  full_path="$REPO_ROOT/$module"
  if [ ! -d "$full_path" ]; then
    warn "Skipping $module (directory not found)"
    SKIPPED+=("$module")
    continue
  fi
  if ! ls "$full_path"/*.tf >/dev/null 2>&1; then
    warn "Skipping $module (no .tf files)"
    SKIPPED+=("$module")
    continue
  fi
  apply_dir "$module" "$full_path"
done

# 3. Cluster access + ArgoCD (kubectl-level, not Terraform)
if [ "$DRY_RUN" = false ]; then
  log "Configuring kubectl access to the cluster"
  if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"; then
    log "Waiting for nodes to be Ready (up to ~5 min)..."
    NODES_READY=false
    for i in $(seq 1 30); do
      if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
        kubectl get nodes
        NODES_READY=true
        break
      fi
      sleep 10
    done

    if [ "$NODES_READY" = false ]; then
      err "Nodes never became Ready — skipping ArgoCD install."
      FAILED+=("nodes-ready")
    else
      log "Installing ArgoCD (server-side apply, required for the ApplicationSet CRD)"
      kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
      if kubectl apply --server-side -n argocd \
           -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml; then
        SUCCEEDED+=("argocd-install")
      else
        err "ArgoCD install failed"
        FAILED+=("argocd-install")
      fi

      log "Waiting for ArgoCD server to be available..."
      kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

      log "Applying App-of-Apps root (root-app)"
      ROOT_APP="$REPO_ROOT/live/addons/argocd/root-app.yaml"
      if [ -f "$ROOT_APP" ]; then
        if kubectl apply -f "$ROOT_APP"; then
          SUCCEEDED+=("root-app")
        else
          FAILED+=("root-app")
        fi
      else
        warn "$ROOT_APP not found — skipping"
        SKIPPED+=("root-app")
      fi
    fi
  else
    err "update-kubeconfig failed — skipping ArgoCD install and root-app."
    FAILED+=("kubeconfig")
  fi
fi

print_summary

if [ ${#FAILED[@]} -gt 0 ]; then
  exit 1
fi

if [ "$DRY_RUN" = false ]; then
  echo
  log "Remaining manual steps (intentionally not automated):"
  echo "  1. Build and push the sample-api and greeting-service images to their ECR repos:"
  echo "     docker buildx build --platform linux/amd64 -t <acct>.dkr.ecr.$REGION.amazonaws.com/project-forge/<service>:<tag> --push ."
  echo "  2. Start the SSM tunnel to RDS and run Backstage locally (see README, Phase 3)."
  echo "  3. Re-register services in the Backstage catalog if they don't reappear."
fi

echo
echo "Done."