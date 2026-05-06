# SOB — Teardown Script

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 1. Delete all manifests ───────────────────────────────────────────────────
Write-Host "`n[1/3] Deleting Kubernetes resources..." -ForegroundColor Cyan
kubectl delete -k .\k8s\ --ignore-not-found

# ── 2. Delete secrets (not managed by kustomize) ─────────────────────────────
Write-Host "`n[2/3] Deleting secrets..." -ForegroundColor Cyan
kubectl delete secret sob-client-env sob-author-env -n sob --ignore-not-found

# ── 3. Remove images from Minikube's Docker ───────────────────────────────────
Write-Host "`n[3/3] Removing local images from Minikube..." -ForegroundColor Cyan
minikube -p minikube docker-env --shell powershell | Invoke-Expression
docker rmi sob-client:local sob-author:local --force 2>$null

Write-Host "`nTeardown complete. Run .\deploy.ps1 for a clean deployment." -ForegroundColor Green
