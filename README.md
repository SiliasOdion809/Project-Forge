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
- [x] **Phase 3 — Self-service layer**: Backstage portal, golden-path service template, auto-populated service catalog
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
│   ├── ecr/               # Root module: ECR repositories (sample-api, greeting-service)
│   ├── addons/            # ArgoCD, ingress, cert-manager, app-of-apps + ApplicationSets
│   └── rds/                # (Phase 3) RDS Postgres for Backstage, reached via SSM bastion
├── modules/
│   ├── vpc/              # Reusable VPC module
│   ├── eks/               # Reusable EKS module
│   ├── ecr/               # Reusable ECR module
│   ├── rds/                # Reusable RDS module
│   └── bastion/             # SSM-only bastion (no SSH, no public IP)
├── templates/
│   └── fastapi-service/    # (Phase 3) golden-path Backstage scaffolder template
│       ├── skeleton/          # New service's own repo content (FastAPI app, Dockerfile, catalog-info.yaml)
│       ├── gitops-skeleton/    # Kustomize manifests + ApplicationSet merged into this repo via PR
│       └── template.yaml       # Backstage Template definition (parameters + steps)
└── .github/workflows/     # CI/CD pipelines + golden-path PR auto-merge
```
 
*(Backstage itself lives in a separate repo, `forge-backstage`, since it's an app the platform runs rather than infrastructure Forge provisions — see Phase 3 below.)*
 
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
 
## Phase 3: Self-Service Layer — Backstage, Golden Path, GitOps Automation
 
Phases 1 and 2 proved Forge could run infrastructure reliably. Phase 3 turns it into something other engineers could actually *use*: a developer portal with a real, auto-populated service catalog, and a golden-path template that takes a developer from "I need a new service" to running pods across dev/staging/prod — without ever touching Terraform, `kubectl`, or ArgoCD directly. This is the difference between "infrastructure that works" and "a platform that onboards people."
 
### What's provisioned
 
| Component | Details |
|---|---|
| **Developer portal** | [Backstage](https://backstage.io), run locally for now (see tradeoffs below), backed by a real Terraform-provisioned RDS Postgres instance, reached over an SSM port-forwarding tunnel — no public ingress, no SSH key, no bastion with a public IP |
| **Database** | `live/rds` (root module) + `modules/rds` (reusable module): a single-AZ RDS Postgres instance in the private subnets, credentials in AWS Secrets Manager |
| **Bastion access** | `modules/bastion`: a minimal EC2 instance with no public IP and no SSH, reachable only via AWS Systems Manager Session Manager, used purely to port-forward a local connection to RDS |
| **Service catalog** | Auto-populated via a `catalog-info.yaml` Component entity committed alongside each service's own source code; `sample-api` (Phase 2) and `greeting-service` (scaffolded via the golden path) are both registered |
| **Golden-path template** | `fastapi-service` — a Backstage Software Template (`templates/fastapi-service/template.yaml`) that, from one form, creates a brand-new GitHub repository for the service, opens a GitOps pull request into this repo with the service's Kustomize manifests and ApplicationSet, and registers the new service in the catalog |
| **Zero-touch GitOps merge** | `.github/workflows/auto-merge-golden-path-prs.yml` — a GitHub Actions workflow in this repo that auto-merges pull requests opened by the template, gated by a branch-naming convention (`add-<service>-service`), so onboarding a new service requires no manual PR approval |
| **Demo services** | `sample-api` (hand-built in Phase 2) and `greeting-service` (fully scaffolded through the golden path, end to end, as the template's proof-of-concept) — both running Healthy/Synced across dev, staging and prod |
 
### Architecture
 
```
Developer opens Backstage → "Create" → fastapi-service template
                                        │
                       fills in: serviceName, description,
                       owner, port, target repo
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              ▼                         ▼                         ▼
     1. New GitHub repo          2. GitOps PR opened        3. Catalog entry
        created                     into Project-Forge          registered
        (service source,            (branch: add-<svc>-         in Backstage
         Dockerfile,                 service)
         catalog-info.yaml)               │
                                 4. Auto-merge workflow
                                    (gated on branch name)
                                          │
                                          ▼
                                 live/addons/apps/<service>/
                                 (Kustomize base + overlays
                                  + ApplicationSet)
                                          │
                                 5. ArgoCD's root-app (App-of-Apps,
                                    prune: true, selfHeal: true)
                                    auto-discovers the new
                                    ApplicationSet
                                          │
                       ┌──────────────────┼──────────────────┐
                       ▼                  ▼                  ▼
                 dev namespace      staging namespace    prod namespace
                                          │
                                 6. Still manual: build + push
                                    the container image to ECR
                                    (ECR repo added via a second
                                    module block in live/ecr)
                                          │
                                          ▼
                                 pods flip Healthy + Synced
```
 
Steps 1–5 are genuinely zero-touch — a developer fills in one form and the repo, PR, merge, and ArgoCD registration all happen without anyone clicking "approve" or running `kubectl apply`. Step 6 (image build/push) is the one deliberately-manual step left in this phase; see tradeoffs below.
 
### Design decisions & tradeoffs
 
- **GitOps PR + auto-merge, not a direct push to `main`.** Backstage's built-in scaffolder actions can't push straight to `main` of an existing repository — `publish:github:pull-request` only opens a pull request. Rather than leaving "merge the PR" as a manual step, a scoped GitHub Actions workflow auto-merges PRs that match the template's branch-naming convention. This keeps the onboarding flow genuinely self-service while still leaving a normal, auditable commit history on `main` — closer to how a real platform team would actually want this to behave than either "fully silent" (no record of what changed) or "a human has to click merge every time" (defeats the point of self-service).
- **Backstage runs locally, not in-cluster, for now.** Containerizing Backstage and deploying it through the same ArgoCD pattern used for application services is a natural next step. It's deferred here deliberately, to keep this phase's scope focused on the self-service *workflow* (template → repo → GitOps PR → catalog) rather than Backstage's own deployment.
- **Image build/push is still a manual step per new service.** The golden-path template doesn't yet wire up CI to build and push the container image automatically — a newly scaffolded service's pod sits in `ImagePullBackOff` until its ECR repository is created (via Terraform) and an image is built and pushed. The template's own generated `README.md` documents this explicitly so it's never a surprise. Wiring this into CI (so the golden path really is code-to-running-pods with zero manual steps) is the natural extension of this phase, and a good candidate to pull forward alongside Phase 4's security gating (image signing, SBOM, vulnerability scanning all need to hook into this same build step anyway).
### Incidents & what they taught
 
Two real failures surfaced while building this phase, both left documented in detail because they were genuinely instructive, not just "oops, typo":
 
**1. Cookiecutter naming convention used with the wrong scaffolder action.** The GitOps skeleton's folders and files were originally named using Backstage's `__serviceName__` cookiecutter-style convention (e.g. `live/addons/apps/__serviceName__/`). But the template's steps use the `fetch:template` action, not `fetch:cookiecutter` — and `fetch:template` only renders Nunjucks placeholders (`${{ values.serviceName }}`) inside file *content*, not inside file or directory *names* via the double-underscore convention.
 
   The first full end-to-end test (service name `hello-service`) made this failure mode genuinely confusing: Backstage reported all 5 steps green, the GitOps PR opened and auto-merged exactly as designed, and the generated files' *content* was correctly templated — the ApplicationSet's `metadata.name` and `path` fields both correctly said `hello-service`. Only the literal on-disk folder name was still `__serviceName__`. ArgoCD then failed with:
```
ComparisonError: ... app path does not exist
```
   because the path ArgoCD was told to sync from (`live/addons/apps/hello-service/k8s/overlays/dev`) genuinely didn't exist — the real folder was `live/addons/apps/__serviceName__/...`.
 
   **Fix:** renamed the skeleton's folders and files to use the literal `${{ values.serviceName }}` template expression as the path segment itself (which `fetch:template` *does* support for path templating), e.g. `mv '__serviceName__' '${{ values.serviceName }}'`. Also had to clean up the broken `hello-service` artifacts properly: deleting the generated ArgoCD Applications by hand didn't stick, because `root-app`'s `prune: true, selfHeal: true` policy kept recreating them from the still-present (broken) files in Git — the fix had to happen at the Git level (`git rm` the broken paths, commit, push), letting ArgoCD's next sync prune the ApplicationSet and cascade-delete its generated Applications for good.
 
   Re-verified clean with a second full run (`greeting-service`), which came up `Synced`/`Healthy` on the first try, confirming the fix.
 
**2. Backstage ↔ RDS over an SSM tunnel needed real connectivity debugging.** Getting Backstage's backend talking to its RDS database reliably took working through several layered issues: the `libpq`/`psql` client not being on `PATH` in fresh terminal sessions; a stale `session-manager-plugin` process left running from a previous tunnel attempt, silently preventing a new one from binding; and, at one point, an SSM `start-session --parameters` payload with a trailing whitespace character accidentally baked into the RDS hostname, causing the agent to accept the session and then immediately close it — a failure mode that looked identical to "server closed the connection unexpectedly" and took checking the raw JSON parameters character-by-character to catch. Rebuilding the parameters string programmatically from clean shell variables (rather than hand-editing a wrapped JSON blob) made this reproducible and fixed for good.
 
   A related, separate incident: the RDS instance's catalog data was unexpectedly found completely empty (`\dt` returned "Did not find any tables") partway through this phase. `aws rds describe-db-instances` showed the instance's `InstanceCreateTime` was from earlier the same day — meaning the instance had been recreated at some point, wiping prior state, even though no intentional `terraform apply` against `live/rds` was recalled since initial setup. Recovery was straightforward (Backstage's own knex migrations rebuild the catalog schema automatically on startup, and `sample-api` was re-registered from its `catalog-info.yaml`), but the root cause of the recreation itself was never conclusively identified — left here as an open, honestly-documented gap rather than a confident but unverified explanation.
 
### Reproducing this phase
 
```bash
# 1. Provision RDS Postgres for Backstage (and the SSM-only bastion, if not already up)
cd live/rds
terraform init && terraform apply
 
# 2. Start an SSM port-forwarding tunnel to RDS (no public ingress, no SSH)
aws ssm start-session \
  --target <bastion-instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"<rds-endpoint>\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"5432\"]}"
 
# 3. Run Backstage locally (separate repo: forge-backstage)
cd ../../forge-backstage
export POSTGRES_HOST=localhost POSTGRES_PORT=5432 \
       POSTGRES_USER=backstage_admin POSTGRES_DB=backstage
export POSTGRES_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id project-forge/backstage/db-credentials \
  --query SecretString --output text | jq -r .password)
export GITHUB_TOKEN=<classic PAT with repo + workflow scopes>
yarn start
 
# 4. In the Backstage UI: Create → FastAPI Service
#    Fill in: service name, description, owner, port, and the target
#    repo owner/name. This one form:
#      - creates a brand-new GitHub repo for the service
#      - opens a GitOps PR into Project-Forge (auto-merged by the
#        workflow in .github/workflows/auto-merge-golden-path-prs.yml)
#      - registers the new service in the Backstage catalog
#    ArgoCD then picks up the new ApplicationSet automatically — no
#    manual kubectl or argocd CLI step required.
 
# 5. One remaining manual step per new service: ECR repo + image push
#    (see "Design decisions & tradeoffs" above — this is intentionally
#    the one non-automated step in this phase)
cd live/ecr   # add a new module block pointing at modules/ecr for the new service
terraform apply
docker buildx build --platform linux/amd64 \
  -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/project-forge/<service>:v0.1.0 \
  --push .
```
 
---
 
## Author
 
**Silias** — Cloud & DevOps Engineer
[GitHub](https://github.com/SiliasOdion809) · [Upwork](#)
 