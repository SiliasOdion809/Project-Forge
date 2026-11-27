#!/usr/bin/env bash
#
# destroy-all.sh — Tear down all Project Forge infrastructure (Phases 1–3)
#
# Usage:
#   ./destroy-all.sh                       # interactive, asks for confirmation
#   ./destroy-all.sh --dry-run             # plans + reports leftovers, deletes nothing
#   ./destroy-all.sh --yes                 # skip the confirmation prompt
#   ./destroy-all.sh --destroy-bootstrap   # also tear down the S3/DynamoDB state backend last

set -o pipefail

DRY_RUN=false
AUTO_YES=false
DESTROY_BOOTSTRAP=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes) AUTO_YES=true ;;
    --destroy-bootstrap) DESTROY_BOOTSTRAP=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Dependents first, foundation last.
MODULES=(
  "live/bastion"
  "live/rds"
  "live/ecr"
  "live/addons"
  "live/cluster"
  "live/network"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="$(aws configure get region 2>/dev/null)"
REGION="${REGION:-us-east-1}"
CLUSTER_NAME="project-forge"
DB_SECRET_ID="project-forge/backstage/db-credentials"
LOG_DIR="$(mktemp -d)"

FAILED=()
SKIPPED=()
SUCCEEDED=()

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$1"; }

print_summary() {
  echo
  log "Summary"
  if [ ${#SUCCEEDED[@]} -gt 0 ]; then echo "  Destroyed: ${SUCCEEDED[*]}"; fi
  if [ ${#SKIPPED[@]}   -gt 0 ]; then echo "  Skipped:   ${SKIPPED[*]}"; fi
  if [ ${#FAILED[@]}    -gt 0 ]; then echo "  Failed:    ${FAILED[*]}"; fi
}

# ---------- network resilience ----------

check_dns() {
  nslookup "ec2.${REGION}.amazonaws.com" >/dev/null 2>&1 && \
  nslookup "dynamodb.${REGION}.amazonaws.com" >/dev/null 2>&1
}

wait_for_network() {
  local tries=0
  until check_dns; do
    tries=$((tries + 1))
    if [ $tries -ge 30 ]; then return 1; fi
    warn "Can't resolve AWS endpoints — waiting 10s (attempt $tries/30)..."
    sleep 10
  done
}

terraform_destroy_with_retry() {
  local label="$1"
  local log_file="$LOG_DIR/$(echo "$label" | tr '/' '_').log"
  local attempt=1 max=3 rc lock_id

  while [ $attempt -le $max ]; do
    wait_for_network || { err "No network after 5 minutes — giving up on $label."; return 1; }

    terraform destroy -auto-approve -input=false 2>&1 | tee "$log_file"
    rc=${PIPESTATUS[0]}
    [ $rc -eq 0 ] && return 0

    if grep -qE "no such host|i/o timeout|connection reset|RequestError|TLS handshake timeout" "$log_file"; then
      lock_id="$(sed -nE 's/.*lock ID "([^"]+)".*/\1/p' "$log_file" | head -n 1)"
      if [ -n "$lock_id" ]; then
        wait_for_network
        warn "Releasing stale state lock $lock_id"
        terraform force-unlock -force "$lock_id"
      fi
      attempt=$((attempt + 1))
      warn "Network error during destroy — retrying (attempt $attempt/$max)"
      sleep 15
      continue
    fi
    return $rc
  done
  return 1
}

# ---------- pre-destroy cleanup hooks ----------

k8s_precleanup() {
  log "Cleaning up Kubernetes-created AWS resources (load balancers)"
  if ! kubectl config current-context 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    warn "kubectl is not pointed at the $CLUSTER_NAME cluster — skipping"
    return 0
  fi
  if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    warn "Cluster not reachable — skipping"
    return 0
  fi

  local svcs
  svcs="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)"

  if [ "$DRY_RUN" = true ]; then
    echo "  LoadBalancer services that would be deleted:"
    echo "${svcs:-  (none)}"
    return 0
  fi

  # Stop ArgoCD from recreating things we delete
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 2>/dev/null
  kubectl delete ingress --all -A --ignore-not-found --wait=false 2>/dev/null
  echo "$svcs" | while read -r ns name; do
    [ -n "$name" ] && kubectl delete svc "$name" -n "$ns" --ignore-not-found
  done
  if [ -n "$svcs" ]; then
    log "Waiting 60s for AWS to remove the load balancers..."
    sleep 60
  fi
}

get_vpc_id() {
  (cd "$REPO_ROOT/live/network" && \
   terraform state show -no-color module.vpc.aws_vpc.main 2>/dev/null | \
   awk '$1=="id"{print $3; exit}' | tr -d '"')
}

vpc_precleanup() {
  local vpc_id
  vpc_id="$(get_vpc_id)"
  if [ -z "$vpc_id" ]; then
    warn "Could not determine the VPC id (already destroyed?) — skipping VPC pre-cleanup"
    return 0
  fi
  log "Checking for leftovers that would block deleting $vpc_id"

  local instances elbs classic sgs enis avail
  instances="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  elbs="$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text 2>/dev/null)"
  classic="$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$vpc_id'].LoadBalancerName" --output text 2>/dev/null)"
  sgs="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)"

  if [ "$DRY_RUN" = true ]; then
    echo "  EC2 instances:      ${instances:-none}"
    echo "  Load balancers:     ${elbs:-none} ${classic}"
    echo "  Security groups:    ${sgs:-none}"
    return 0
  fi

  if [ -n "$instances" ]; then
    warn "Terminating leftover EC2 instances: $instances"
    aws ec2 terminate-instances --region "$REGION" --instance-ids $instances >/dev/null
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $instances
  fi
  for arn in $elbs; do
    warn "Deleting load balancer $arn"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn"
  done
  for name in $classic; do
    warn "Deleting classic load balancer $name"
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name"
  done

  # Let user-owned network interfaces drain (skips AWS-managed ones such as NAT gateway ENIs)
  local i
  for i in $(seq 1 30); do
    enis="$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=requester-managed,Values=false" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
    [ -z "$enis" ] && break
    avail="$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=requester-managed,Values=false" "Name=status,Values=available" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
    for e in $avail; do aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$e" 2>/dev/null; done
    echo "  waiting for network interfaces to detach: $enis"
    sleep 10
  done

  # Non-default security groups block VPC deletion
  local pass sg
  for pass in 1 2 3; do
    sgs="$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$vpc_id" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)"
    [ -z "$sgs" ] && break
    for sg in $sgs; do
      aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null && echo "  deleted security group $sg"
    done
    sleep 5
  done
}

secret_cleanup() {
  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$DB_SECRET_ID" >/dev/null 2>&1; then
    warn "Force-deleting Secrets Manager secret $DB_SECRET_ID so the name can be reused"
    aws secretsmanager delete-secret --region "$REGION" --secret-id "$DB_SECRET_ID" \
      --force-delete-without-recovery >/dev/null
  fi
}

# ---------- main ----------

log "Current AWS identity:"
aws sts get-caller-identity --output table || { err "Could not reach AWS — check your credentials."; exit 1; }
log "Region: $REGION"

wait_for_network || { err "Can't resolve AWS endpoints — check your internet/DNS first."; exit 1; }

if [ "$DRY_RUN" = false ] && [ "$AUTO_YES" = false ]; then
  echo
  warn "This will DESTROY the following Terraform-managed modules, in this order:"
  for m in "${MODULES[@]}"; do echo "    - $m"; done
  [ "$DESTROY_BOOTSTRAP" = true ] && warn "AND the state backend (bootstrap/) at the very end."
  echo
  read -rp 'Type "destroy" to continue: ' CONFIRM
  if [ "$CONFIRM" != "destroy" ]; then
    echo "Aborted — nothing was touched."
    exit 0
  fi
fi

run_destroy() {
  local module_path="$1"
  local full_path="$REPO_ROOT/$module_path"

  if [ ! -d "$full_path" ]; then
    warn "Skipping $module_path (directory not found)"
    SKIPPED+=("$module_path")
    return
  fi
  if ! ls "$full_path"/*.tf >/dev/null 2>&1; then
    warn "Skipping $module_path (no .tf files — not a Terraform root module)"
    SKIPPED+=("$module_path")
    return
  fi

  log "Processing $module_path"
  pushd "$full_path" >/dev/null || return

  if ! terraform init -input=false; then
    err "terraform init failed for $module_path"
    FAILED+=("$module_path")
    popd >/dev/null
    print_summary
    exit 1
  fi

  case "$module_path" in
    live/cluster) k8s_precleanup ;;
    live/network) vpc_precleanup ;;
  esac

  if [ "$DRY_RUN" = true ]; then
    terraform plan -destroy -input=false
    popd >/dev/null
    return
  fi

  if terraform_destroy_with_retry "$module_path"; then
    SUCCEEDED+=("$module_path")
    [ "$module_path" = "live/rds" ] && secret_cleanup
  else
    err "terraform destroy failed for $module_path — stopping so you can inspect it before touching anything upstream."
    FAILED+=("$module_path")
    popd >/dev/null
    print_summary
    exit 1
  fi

  popd >/dev/null
}

for module in "${MODULES[@]}"; do
  run_destroy "$module"
done

if [ "$DESTROY_BOOTSTRAP" = true ] && [ "$DRY_RUN" = false ]; then
  log "Destroying state backend (bootstrap/) — irreversible for Terraform history."
  if [ -d "$REPO_ROOT/bootstrap" ]; then
    pushd "$REPO_ROOT/bootstrap" >/dev/null
    terraform init -input=false
    if terraform_destroy_with_retry "bootstrap"; then SUCCEEDED+=("bootstrap"); else FAILED+=("bootstrap"); fi
    popd >/dev/null
  else
    warn "bootstrap/ not found — skipping"
  fi
fi

print_summary

if [ ${#FAILED[@]} -gt 0 ]; then
  exit 1
fi

echo
echo "Done."