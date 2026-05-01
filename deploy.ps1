# SOB — Local Minikube Deployment Script

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 1. Check secrets exist ────────────────────────────────────────────────────
if (-not (Test-Path ".\k8s\client-secret.yaml") -or -not (Test-Path ".\k8s\author-secret.yaml")) {
    Write-Host "ERROR: Secret files not found." -ForegroundColor Red
    Write-Host "Create the following files and fill in your AWS values before deploying:"
    Write-Host "  .\k8s\client-secret.yaml"
    Write-Host "  .\k8s\author-secret.yaml"
    Write-Host "See the *.example.yaml files for the required fields."
    exit 1
}

# ── 2. Start Minikube ─────────────────────────────────────────────────────────
Write-Host "`n[1/6] Starting Minikube..." -ForegroundColor Cyan
$minikubeStatus = minikube status --format "{{.Host}}" 2>$null
if ($minikubeStatus -ne "Running") {
    minikube config set WantUpdateNotification false | Out-Null
    minikube start
} else {
    Write-Host "Minikube already running, skipping start." -ForegroundColor DarkGray
}

# ── 3. Point Docker at Minikube ───────────────────────────────────────────────
Write-Host "`n[2/6] Configuring Docker to use Minikube's daemon..." -ForegroundColor Cyan
minikube -p minikube docker-env --shell powershell | Invoke-Expression

# ── 4. Build images ───────────────────────────────────────────────────────────
Write-Host "`n[3/6] Building sob-client image..." -ForegroundColor Cyan
docker build -t sob-client:local ./client

Write-Host "`n[4/6] Building sob-author image..." -ForegroundColor Cyan
docker build -t sob-author:local ./author

# ── 5. Apply namespace + secrets ─────────────────────────────────────────────
Write-Host "`n[5/6] Applying namespace and secrets..." -ForegroundColor Cyan
kubectl apply -f .\k8s\namespace.yaml
kubectl apply -f .\k8s\client-secret.yaml
kubectl apply -f .\k8s\author-secret.yaml

# ── 6. Apply all manifests ────────────────────────────────────────────────────
Write-Host "`n[6/6] Applying Kubernetes manifests..." -ForegroundColor Cyan
kubectl apply -k .\k8s\

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host "`nDeployment complete. Waiting for pods to be ready..." -ForegroundColor Green
kubectl rollout status deployment/sob-client -n sob
kubectl rollout status deployment/sob-author -n sob

Write-Host "`nStarting port-forwarding in background..." -ForegroundColor Green
Start-Process powershell -ArgumentList "-NoExit", "-Command", "kubectl port-forward svc/sob-client 3000:3000 -n sob"
Start-Process powershell -ArgumentList "-NoExit", "-Command", "kubectl port-forward svc/sob-author 3001:3001 -n sob"

Write-Host "Client : http://localhost:3000" -ForegroundColor Green
Write-Host "Admin  : http://localhost:3001" -ForegroundColor Green
