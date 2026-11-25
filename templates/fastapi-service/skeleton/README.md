# ${{ values.serviceName }}

${{ values.description }}

Scaffolded from Project-Forge's `fastapi-service` golden-path template.

## Status

This repo was created automatically along with a GitOps pull request into
[Project-Forge](https://github.com/SiliasOdion809/Project-Forge) adding its
Kubernetes manifests and ArgoCD ApplicationSet under `live/addons/apps/`.

**One manual step remains before this service will actually run:** its
container image does not exist in ECR yet, so ArgoCD will report the pod(s)
as `ImagePullBackOff` until you:

1. Create an ECR repository for this service (e.g. `project-forge/${{ values.serviceName }}`).
2. Build and push the image:
   ```bash
   docker buildx build --platform linux/amd64 \
     -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/project-forge/${{ values.serviceName }}:v0.1.0 \
     --push .
   ```
3. Update the image tag in `live/addons/apps/${{ values.serviceName }}/k8s/base/deployment.yaml`
   in the Project-Forge repo and let ArgoCD sync.

## Local development

```bash
pip install -r requirements.txt
uvicorn app.main:app --reload --port ${{ values.port }}
```