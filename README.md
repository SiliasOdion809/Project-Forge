# Project Forge

A self-service Internal Developer Platform (IDP) built from scratch on AWS — designed to demonstrate the kind of platform-engineering work that lets developers ship infrastructure and applications safely, without needing to touch Terraform or `kubectl` directly.

Forge is built in phases, each one a working, independently-verifiable piece of infrastructure — not a toy demo. Every phase is provisioned with Terraform, backed by remote state, and documented with the actual design tradeoffs made along the way.

---

## Tech Stack

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=flat&logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-232F3E?style=flat&logo=amazonaws&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white)
![Amazon EKS](https://img.shields.io/badge/Amazon_EKS-FF9900?style=flat&logo=amazoneks&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-EF7B4D?style=flat&logo=argo&logoColor=white)
![Backstage](https://img.shields.io/badge/Backstage-9BF0E1?style=flat&logo=backstage&logoColor=black)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=flat&logo=githubactions&logoColor=white)

---

## Why this project exists

Most infrastructure portfolios stop at "I can deploy an app to Kubernetes." Forge goes further: it's the platform other engineers would use to ship *their* services safely — self-service provisioning, GitOps delivery, security enforced at admission, real observability with SLOs, cost visibility, and a resilience test with actual numbers. Each phase below is built to reflect what a mid-size engineering org's platform team is actually hired to do.

---

## Roadmap

- [x] **Phase 1 — Foundation**: VPC, EKS cluster, node group, IRSA-ready OIDC provider (see below)
- [x] **Phase 2 — GitOps delivery**: ArgoCD (App-of-Apps pattern), ApplicationSets for dev→staging→prod promotion
- [ ] **Phase 3 — Self-service layer**: Backstage portal, golden-path service template, auto-populated service catalog
- [ ] **Phase 4 — Security**: OPA/Kyverno admission policies, image signing (Cosign), SBOM generation (Syft), vulnerability gating (Trivy)
- [ ] **Phase 5 — Observability**: OpenTelemetry tracing, Prometheus/Grafana, Loki, SLOs with error-budget-based alerting
- [ ] **Phase 6 — FinOps**: OpenCost/Kubecost, Karpenter for cost-aware autoscaling
- [ ] **Phase 7 — Resilience capstone**: Chaos Mesh fault injection, documented incident response

---

## Repository structure

```
Project-Forge/
├── bootstrap/          # One-time: Terraform state backend (S3 + DynamoDB)
├── live/
│   ├── network/         # Root module: VPC, subnets, NAT/IGW
│   ├── cluster/          # Root module: EKS cluster + node group
│   └── addons/            # (Phase 2+) ArgoCD, ingress, cert-manager
├── modules/
│   ├── vpc/              # Reusable VPC module
│   └── eks/               # Reusable EKS module
└── .github/workflows/     # CI/CD pipelines
```

---

## Phase 1: Foundation — VPC & EKS Cluster

This phase provisions the core AWS infrastructure Forge runs on: an isolated network and a managed Kubernetes control plane, built entirely with Terraform and backed by remote state.

### Architecture

```
                     ┌─────────────────────────────┐
                     │           AWS Account         │
                     │                                │
                     │   ┌────────────────────────┐   │
                     │   │   VPC (10.0.0.0/16)     │   │
                     │   │                          │   │
                     │   │  ┌───────────────────┐  │   │
                     │   │  │  Public Subnets    │  │   │
                     │   │  │  (us-east-1a/1b)   │  │   │
                     │   │  │  NAT Gateway, IGW   │  │   │
                     │   │  └─────────┬──────────┘  │   │
                     │   │            │              │   │
                     │   │  ┌─────────▼──────────┐  │   │
                     │   │  │  Private Subnets    │  │   │
                     │   │  │  (us-east-1a/1b)    │  │   │
                     │   │  │  EKS Node Group     │  │   │
                     │   │  └────────────────────┘  │   │
                     │   └────────────────────────┘   │
                     │                                │
                     │   EKS Control Plane (managed)  │
                     │   OIDC Provider (IRSA-ready)    │
                     └─────────────────────────────┘
```

### What's provisioned

| Component | Details |
|---|---|
| **State backend** | S3 bucket (versioned, encrypted, public access blocked) + DynamoDB table for state locking |
| **Networking** | 1 VPC, 2 public + 2 private subnets across two AZs, 1 Internet Gateway, 1 NAT Gateway (single NAT for cost efficiency — see tradeoffs below) |
| **Compute** | EKS cluster (control plane) + one managed node group in private subnets |
| **Identity** | OIDC provider attached to the cluster, enabling IAM Roles for Service Accounts (IRSA) for later phases (ArgoCD, cert-manager, Kyverno) |

### Design decisions & tradeoffs

- **Single NAT Gateway, not one per AZ** — reduces cost (~$32/mo per additional NAT) at the expense of losing AZ-level fault isolation for outbound traffic. Acceptable for a portfolio/dev-grade environment; a production system would use one NAT per AZ.
- **Nodes in private subnets only** — no direct internet exposure for worker nodes; outbound traffic routes through the NAT Gateway.
- **Two root modules, one state bucket** — `live/network` and `live/cluster` are separate Terraform root modules with independent state files (`network/terraform.tfstate`, `cluster/terraform.tfstate`) in the same S3 bucket, connected via `terraform_remote_state`. This avoids a structural limitation where Kubernetes/Helm provider resources can't safely depend on data from EKS resources created in the same `apply` run.
- **EKS API authentication mode** — cluster uses AWS's newer Access Entries model (`authentication_mode = "API"`) instead of the legacy `aws-auth` ConfigMap, with `bootstrap_cluster_creator_admin_permissions = true` set explicitly to guarantee the creating IAM identity gets cluster-admin access.

### Reproducing this phase

```bash
# 1. Bootstrap the state backend (one-time, per AWS account)
cd bootstrap
terraform init && terraform apply

# 2. Update the bucket name in live/network/backend.tf and live/cluster/backend.tf
#    (backend config can't reference Terraform variables, so this is manual)

# 3. Provision the network
cd ../live/network
terraform init && terraform apply

# 4. Provision the cluster (reads network outputs via remote state)
cd ../cluster
terraform init && terraform apply

# 5. Configure kubectl access
aws eks update-kubeconfig --region us-east-1 --name project-forge
kubectl get nodes
```

**Note:** EKS cluster creation takes ~13–15 minutes; node group creation is typically 2–3 minutes but can take longer depending on account-level EC2 service quotas.

---

## Phase 2: GitOps Delivery — ArgoCD & Environment Promotion

This phase installs ArgoCD and demonstrates the App-of-Apps + ApplicationSet pattern with a real deployed service — not a placeholder.

### What's provisioned

| Component | Details |
|---|---|
| **Container registry** | ECR repository (`project-forge/sample-api`), Terraform-managed — immutable tags, scan-on-push, 10-image lifecycle policy |
| **GitOps controller** | ArgoCD, installed via official manifests, App-of-Apps root (`root-app`) watching `live/addons/apps/` |
| **Sample service** | `sample-api` — a FastAPI backend with `/health`, `/`, `/api/v1/items`, built as a multi-stage Docker image, pushed to the ECR repo above |
| **Environment promotion** | Kustomize base + `dev`/`staging`/`prod` overlays (namespace-per-environment, replica counts 1/2/3), driven by a single `ApplicationSet` (list generator) — one commit updates all three environments automatically |

### Architecture

```
Git push → ArgoCD detects change → auto-sync → cluster reconciles
                                          │
                      ┌───────────────────┼───────────────────┐
                      ▼                   ▼                   ▼
                 dev namespace     staging namespace      prod namespace
                 replicas: 1       replicas: 2            replicas: 3
                 sample-api:v0.1.1 sample-api:v0.1.1     sample-api:v0.1.1
```

One image, one Git commit, three environments — that's the actual point of this pattern: promotion means bumping a tag in Git, not redeploying by hand.

### Design decisions & tradeoffs

- **Immutable ECR tags** — once pushed, a tag can never be overwritten, preventing silent image swaps. This is why promotion happens via explicit version bumps (`v0.1.0` → `v0.1.1`) in the Kustomize base, not a floating `latest` tag.

- **Multi-stage Docker build, non-root user** — keeps build tooling out of the runtime image and avoids running the container as root, a baseline practice that later becomes enforceable policy in Phase 4 (Kyverno).

### Incidents & what they taught

Two real production-grade failures happened building this phase, both left in as-is because they're more instructive than a clean run:

**1. Cross-platform image mismatch.** Images built on Apple Silicon (`arm64`) failed to run on EKS's `amd64` node group — `ImagePullBackOff` with "no match for platform in manifest." Fixed with `docker buildx build --platform linux/amd64 --push`. A common, real gotcha for anyone developing on Apple Silicon and deploying to x86 cloud infrastructure.

**2. CRD deletion cascade.** The ApplicationSet CRD initially failed to install via plain `kubectl apply` (metadata annotation exceeded Kubernetes' 256KB limit). The first fix attempt, `kubectl replace --force`, deletes-then-recreates rather than patching — this triggered a cascading delete of the entire ArgoCD stack and a stuck-finalizer deadlock (the CRD couldn't finish deleting because the controller that processes its finalizers had itself just been deleted). Recovered by reinstalling via `kubectl apply --server-side`, which is the correct way to apply large CRDs without triggering delete-then-recreate semantics.

### Reproducing this phase

```bash
# 1. Provision the ECR repository
cd live/ecr
terraform init && terraform apply

# 2. Build and push the sample-api image (must target linux/amd64 — see incident notes above)
cd ../addons/apps/sample-api
docker buildx build --platform linux/amd64 \
  -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/project-forge/sample-api:v0.1.1 \
  --push .

# 3. Install ArgoCD (server-side apply — required for the ApplicationSet CRD, see incident notes)
kubectl create namespace argocd
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 4. Apply the App-of-Apps root — this auto-syncs everything else,
#    including the sample-api ApplicationSet, with no further manual kubectl needed
kubectl apply -f live/addons/argocd/root-app.yaml
```

---


## Author

**Silias** — Cloud & DevOps Engineer
[GitHub](https://github.com/SiliasOdion809) · [Upwork](#)