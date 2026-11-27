#!/usr/bin/env bash
#
# post-create.sh — Finish bringing Project Forge up after create-all.sh
#
# Does the steps create-all.sh leaves manual:
#   1. Log in to ECR
#   2. Build + push sample-api and greeting-service images (linux/amd64)
#   3. Restart the service deployments so pods re-pull immediately
#   4. Wait for the ArgoCD Applications to be Healthy + Synced
#   5. Print the ArgoCD admin password and the port-forward command
#
# Usage:
#   ./post-create.sh
#   GREETING_SRC=~/code/greeting-service ./post-create.sh   # use a local checkout
#   ./post-create.sh --skip-wait                            # don't wait for ArgoCD health

set -o pipefail

SKIP_WAIT=false
for arg in "$@"; do
  case "$arg" in
    --skip-wait) SKIP_WAIT=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="$(aws configure get region 2>/dev/null)"
REGION="${REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
GITHUB_OWNER="SiliasOdion809"

# Fallback tags if they can't be read from the manifests
SAMPLE_API_TAG_DEFAULT="v0.1.1"
GREETING_TAG_DEFAULT="v0.1.0"

SAMPLE_API_SRC="$REPO_ROOT/live/addons/apps/sample-api"
GREETING_SRC="${GREETING_SRC:-}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$1"; }

if [ -z "$ACCOUNT_ID" ]; then
  err "Could not determine AWS account — check your credentials."
  exit 1
fi

# Read the image tag for a service from its base deployment.yaml, else use the default.
tag_from_manifest() {
  local service="$1" default="$2" file tag
  file="$(find "$REPO_ROOT/live/addons/apps" -path "*${service}*" -name deployment.yaml 2>/dev/null | head -n 1)"
  if [ -n "$file" ]; then
    tag="$(grep -E "image:.*project-forge/${service}:" "$file" | head -n 1 | sed -E 's/.*:([^:[:space:]]+)[[:space:]]*$/\1/')"
  fi
  echo "${tag:-$default}"
}

image_exists() {
  aws ecr describe-images --region "$REGION" \
    --repository-name "project-forge/$1" --image-ids imageTag="$2" >/dev/null 2>&1
}

build_and_push() {
  local service="$1" src="$2" tag="$3"
  local image="$REGISTRY/project-forge/$service:$tag"

  if image_exists "$service" "$tag"; then
    warn "$service:$tag already exists in ECR (tags are immutable) — skipping build."
    return 0
  fi
  if [ ! -f "$src/Dockerfile" ]; then
    err "No Dockerfile found in $src"
    return 1
  fi

  log "Building and pushing $image"
  docker buildx build --platform linux/amd64 -t "$image" --push "$src"
}

# 1. ECR login
log "Logging in to ECR ($REGISTRY)"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$REGISTRY" || { err "ECR login failed"; exit 1; }

# 2a. sample-api
SAMPLE_TAG="$(tag_from_manifest sample-api "$SAMPLE_API_TAG_DEFAULT")"
build_and_push "sample-api" "$SAMPLE_API_SRC" "$SAMPLE_TAG" || exit 1

# 2b. greeting-service (its own repo)
GREETING_TAG="$(tag_from_manifest greeting-service "$GREETING_TAG_DEFAULT")"
CLONED_DIR=""
if [ -z "$GREETING_SRC" ]; then
  CLONED_DIR="$(mktemp -d)"
  GREETING_SRC="$CLONED_DIR/greeting-service"
  log "Cloning $GITHUB_OWNER/greeting-service"
  if command -v gh >/dev/null 2>&1; then
    gh repo clone "$GITHUB_OWNER/greeting-service" "$GREETING_SRC" || { err "Clone failed"; exit 1; }
  else
    git clone "https://github.com/$GITHUB_OWNER/greeting-service.git" "$GREETING_SRC" || { err "Clone failed"; exit 1; }
  fi
fi
build_and_push "greeting-service" "$GREETING_SRC" "$GREETING_TAG" || exit 1
[ -n "$CLONED_DIR" ] && rm -rf "$CLONED_DIR"

# 3. Restart deployments so pods re-pull instead of waiting out ImagePullBackOff
log "Restarting service deployments"
for svc in sample-api greeting-service; do
  for env in dev staging prod; do
    kubectl rollout restart "deployment/$svc" -n "$env" 2>/dev/null \
      && echo "  restarted $svc in $env" \
      || echo "  (skipped $svc in $env — not found yet)"
  done
done

# 4. Wait for ArgoCD apps to be Healthy + Synced
if [ "$SKIP_WAIT" = false ]; then
  log "Waiting for ArgoCD Applications to be Healthy + Synced (up to ~10 min)"
  ALL_GOOD=false
  for i in $(seq 1 60); do
    kubectl get applications -n argocd --no-headers 2>/dev/null \
      | grep -E "sample-api|greeting-service" > /tmp/forge-apps.txt
    TOTAL="$(wc -l < /tmp/forge-apps.txt | tr -d ' ')"
    GOOD="$(grep -c "Synced.*Healthy" /tmp/forge-apps.txt)"
    echo "  $GOOD/$TOTAL healthy+synced"
    if [ "$TOTAL" -gt 0 ] && [ "$GOOD" -eq "$TOTAL" ]; then
      ALL_GOOD=true
      break
    fi
    sleep 10
  done
  kubectl get applications -n argocd
  if [ "$ALL_GOOD" = false ]; then
    warn "Not everything is healthy yet — check: kubectl get pods -A | grep -E 'sample-api|greeting-service'"
  fi
fi

# 5. ArgoCD access info
log "ArgoCD access"
echo "  Port-forward (run in its own terminal tab):"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Username: admin"
echo -n "  Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d
echo
echo "  URL: https://localhost:8080"

echo
echo "Done. Backstage + the RDS SSM tunnel are still started manually (see README, Phase 3)."