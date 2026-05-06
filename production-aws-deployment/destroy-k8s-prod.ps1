# SOB — Production EC2 / k3s Teardown Script
# Usage (SSM):  .\destroy-k8s-prod.ps1
# Usage (SSH):  .\destroy-k8s-prod.ps1 -SshKey ".\tf_ec2_instance.pem"

param(
    [string]$SshKey      = "",          # leave empty to use SSM instead
    [string]$AwsRegion   = "eu-west-2",
    [string]$Ec2User     = "ec2-user",
    [string]$Ec2Name     = "tf-prod",
    [string]$EcrRegistry = "397059225137.dkr.ecr.eu-west-2.amazonaws.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ECR_CLIENT = "sob-prod/client"
$ECR_AUTHOR = "sob-prod/author"

if ($SshKey -and -not (Test-Path $SshKey)) {
    Write-Host "ERROR: SSH key not found: $SshKey" -ForegroundColor Red
    exit 1
}

# -- 1. Find EC2 instance by Name tag -----------------------------------------
Write-Host "`n[1/4] Finding EC2 instance '$Ec2Name'..." -ForegroundColor Cyan
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

# -- 2. Fetch & patch kubeconfig from EC2 (k3s) -------------------------------
Write-Host "`n[2/4] Fetching kubeconfig from EC2..." -ForegroundColor Cyan
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

# -- 3. Delete all Kubernetes resources ---------------------------------------
Write-Host "`n[3/4] Deleting Kubernetes resources..." -ForegroundColor Cyan

# Delete via overlay if it exists, otherwise fall back to base
$overlayDir = ".\overlays\ec2"
if (Test-Path "$overlayDir\kustomization.yaml") {
    kubectl delete -k $overlayDir --ignore-not-found
} else {
    kubectl delete -k .\k8s\ --ignore-not-found
}

kubectl delete secret sob-client-env sob-author-env sob-postgres-env ecr-secret `
    -n sob --ignore-not-found

kubectl delete namespace sob --ignore-not-found

Write-Host "Kubernetes resources deleted." -ForegroundColor DarkGray

Write-Host "`nTeardown complete." -ForegroundColor Green
Write-Host "Note: EBS volume and EC2 instance are managed by Terraform - run 'terraform destroy' to remove them." -ForegroundColor DarkGray
