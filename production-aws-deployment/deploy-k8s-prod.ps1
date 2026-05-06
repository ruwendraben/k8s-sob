# SOB � Production EC2 / k3s Deployment Script
# Usage (SSM):  .\deploy-k8s-prod.ps1
# Usage (SSH):  .\deploy-k8s-prod.ps1 -SshKey ".\tf_ec2_instance.pem"

param(
    [string]$SshKey      = "",          # leave empty to use SSM instead
    [string]$AwsRegion   = "eu-west-2",
    [string]$Ec2User     = "ec2-user",
    [string]$Ec2Name     = "tf-prod",
    [string]$EcrRegistry = "397059225137.dkr.ecr.eu-west-2.amazonaws.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SOB_REPO_PROD = "https://github.com/ruwendraben/production-sob-k8s"
$SOB_DIR       = "..\sob"
$ECR_CLIENT    = "sob-prod/client"
$ECR_AUTHOR    = "sob-prod/author"

if ($SshKey -and -not (Test-Path $SshKey)) {
    Write-Host "ERROR: SSH key not found: $SshKey" -ForegroundColor Red
    exit 1
}

# -- 1. Check secrets ----------------------------------------------------------
Write-Host "`n[1/7] Checking secrets..." -ForegroundColor Cyan
if (-not (Test-Path ".\k8s\client-secret.yaml") -or
    -not (Test-Path ".\k8s\author-secret.yaml") -or
    -not (Test-Path ".\k8s\postgres-secret.yaml")) {
    Write-Host "ERROR: Secret files not found." -ForegroundColor Red
    Write-Host "Required:"
    Write-Host "  .\k8s\client-secret.yaml"
    Write-Host "  .\k8s\author-secret.yaml"
    Write-Host "  .\k8s\postgres-secret.yaml"
    Write-Host "See the *.example.yaml files for the required fields."
    exit 1
}

# -- 2. Find EC2 instance by Name tag -----------------------------------------
Write-Host "`n[2/7] Finding EC2 instance '$Ec2Name'..." -ForegroundColor Cyan
$EC2_QUERY = aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=$Ec2Name" "Name=instance-state-name,Values=running" `
    --query "Reservations[0].Instances[0].[PublicIpAddress,InstanceId]" `
    --output text `
    --region $AwsRegion

if (-not $EC2_QUERY -or $EC2_QUERY -eq "None") {
    Write-Host "ERROR: No running EC2 instance found with Name tag '$Ec2Name'." -ForegroundColor Red
    exit 1
}
$EC2_IP, $EC2_ID = $EC2_QUERY -split "`t"
Write-Host "Found: $EC2_IP ($EC2_ID)" -ForegroundColor DarkGray

# -- 3. Fetch & patch kubeconfig from EC2 (k3s) -------------------------------
Write-Host "`n[3/7] Fetching kubeconfig from EC2 (k3s)..." -ForegroundColor Cyan
$KUBECONFIG_PATH = "$env:TEMP\sob-prod-kubeconfig.yaml"

if ($SshKey) {
    Write-Host "Using SSH..." -ForegroundColor DarkGray
    ssh -i $SshKey -o StrictHostKeyChecking=no "${Ec2User}@${EC2_IP}" `
        "sudo cat /etc/rancher/k3s/k3s.yaml" | Out-File -FilePath $KUBECONFIG_PATH -Encoding ascii
} else {
    Write-Host "Using SSM..." -ForegroundColor DarkGray
    $cmdId = aws ssm send-command `
        --instance-ids $EC2_ID `
        --document-name 'AWS-RunShellScript' `
        --parameters 'commands=sudo cat /etc/rancher/k3s/k3s.yaml' `
        --query 'Command.CommandId' `
        --output text `
        --region $AwsRegion

    do {
        Start-Sleep -Seconds 2
        $cmdStatus = aws ssm get-command-invocation `
            --command-id $cmdId --instance-id $EC2_ID `
            --query "Status" --output text --region $AwsRegion
    } while ($cmdStatus -eq "InProgress" -or $cmdStatus -eq "Pending")

    if ($cmdStatus -ne "Success") {
        Write-Host "ERROR: SSM command failed with status: $cmdStatus" -ForegroundColor Red
        exit 1
    }

    aws ssm get-command-invocation `
        --command-id $cmdId --instance-id $EC2_ID `
        --query "StandardOutputContent" --output text `
        --region $AwsRegion | Out-File -FilePath $KUBECONFIG_PATH -Encoding ascii
}

(Get-Content $KUBECONFIG_PATH) `
    -replace "127\.0\.0\.1", $EC2_IP `
    -replace "certificate-authority-data:.*", "insecure-skip-tls-verify: true" |
    Set-Content $KUBECONFIG_PATH

$env:KUBECONFIG = $KUBECONFIG_PATH
Write-Host "Kubeconfig patched for $EC2_IP" -ForegroundColor DarkGray


# -- 4. Fetch app source & check for changes ----------------------------------
Write-Host "`n[4/7] Fetching app source..." -ForegroundColor Cyan
$repoChanged = $false
if ($SOB_REPO_PROD) {
    if (Test-Path "$SOB_DIR\.git") {
        Write-Host "Repo exists, checking for changes..." -ForegroundColor DarkGray
        $oldCommit = git -C $SOB_DIR rev-parse HEAD
        git -C $SOB_DIR pull | Out-Null
        $newCommit = git -C $SOB_DIR rev-parse HEAD
        if ($oldCommit -ne $newCommit) {
            $repoChanged = $true
            Write-Host "Code changes detected (commit $oldCommit -> $newCommit)." -ForegroundColor Yellow
        } else {
            Write-Host "No code changes detected in repo." -ForegroundColor Green
        }
    } else {
        git clone $SOB_REPO_PROD $SOB_DIR
        $repoChanged = $true
        Write-Host "Cloned repo, will build images." -ForegroundColor Yellow
    }
} else {
    Write-Host "Using local sob directory (SOB_REPO_PROD not set yet)." -ForegroundColor DarkGray
    if (-not (Test-Path $SOB_DIR)) {
        Write-Host "ERROR: $SOB_DIR not found and SOB_REPO_PROD is not set." -ForegroundColor Red
        exit 1
    }
    $repoChanged = $true
}

# -- 5. Build & push images to ECR only if changed ----------------------------
if ($repoChanged) {
    Write-Host "`n[5/7] Building and pushing images to ECR..." -ForegroundColor Cyan
    aws ecr get-login-password --region $AwsRegion |
        docker login --username AWS --password-stdin $EcrRegistry

    Write-Host "Building sob-client..." -ForegroundColor DarkGray
    docker build -t "${EcrRegistry}/${ECR_CLIENT}:latest" "$SOB_DIR\client"
    docker push "${EcrRegistry}/${ECR_CLIENT}:latest"

    Write-Host "Building sob-author..." -ForegroundColor DarkGray
    docker build -t "${EcrRegistry}/${ECR_AUTHOR}:latest" "$SOB_DIR\author"
    docker push "${EcrRegistry}/${ECR_AUTHOR}:latest"
} else {
    Write-Host "`n[5/7] No code changes, skipping image build/push." -ForegroundColor Green
}


# -- 6. Ensure ECR imagePullSecret & apply manifests --------------------------
# Terraform already attaches and mounts the EBS at /mnt/postgres-data.
# The EC2 overlay patches postgres to use that hostPath instead of a PVC.
Write-Host "`n[6/7] Ensuring ECR imagePullSecret and applying manifests..." -ForegroundColor Cyan

$overlayDir = ".\overlays\ec2"
New-Item -ItemType Directory -Force -Path $overlayDir | Out-Null


@"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  template:
    spec:
      volumes:
        - name: pgdata
          hostPath:
            path: /mnt/postgres-data/data
            type: DirectoryOrCreate
"@ | Set-Content "$overlayDir\patch-postgres-hostpath.yaml"


@"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: sob
resources:
    - ../../k8s
patches:
    - path: patch-postgres-hostpath.yaml
      target:
        kind: Deployment
        name: postgres
# EBS StorageClass and PVC are not needed on EC2 — Terraform manages the EBS mount directly.
# Kustomize cannot delete resources, so we explicitly remove them after apply.
images:
    - name: sob-client
      newName: ${EcrRegistry}/${ECR_CLIENT}
      newTag: latest
    - name: sob-author
      newName: ${EcrRegistry}/${ECR_AUTHOR}
      newTag: latest
"@ | Set-Content "$overlayDir\kustomization.yaml"

kubectl apply -f .\k8s\namespace.yaml
kubectl apply -f .\k8s\postgres-secret.yaml
kubectl apply -f .\k8s\client-secret.yaml
kubectl apply -f .\k8s\author-secret.yaml

# Create or update the ECR docker-registry secret in the sob namespace
Write-Host "Creating or updating ECR imagePullSecret (ecr-secret) in sob namespace..." -ForegroundColor DarkGray
$ecrPassword = aws ecr get-login-password --region $AwsRegion
kubectl create secret docker-registry ecr-secret `
    --docker-server=$EcrRegistry `
    --docker-username=AWS `
    --docker-password=$ecrPassword `
    --namespace=sob `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -k $overlayDir

# Remove PVC and StorageClass — not needed on EC2 (Terraform manages EBS directly)
kubectl delete pvc postgres-pvc -n sob --ignore-not-found
kubectl delete storageclass ebs-sc --ignore-not-found

# -- 7. Wait for rollout -------------------------------------------------------
Write-Host "`n[7/7] Waiting for pods to be ready..." -ForegroundColor Cyan
kubectl rollout status deployment/postgres   -n sob --timeout=120s
kubectl rollout status deployment/sob-client -n sob --timeout=120s
kubectl rollout status deployment/sob-author -n sob --timeout=120s

Write-Host "`nDeployment complete." -ForegroundColor Green
Write-Host "Client : http://${EC2_IP}:30080" -ForegroundColor Green
Write-Host "Admin  : http://${EC2_IP}:30081" -ForegroundColor Green
