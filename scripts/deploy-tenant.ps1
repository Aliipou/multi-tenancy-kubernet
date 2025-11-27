# Deploy a specific tenant using Helm (PowerShell)

param(
    [Parameter(Mandatory=$true)]
    [int]$TenantNumber,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Status {
    param($message)
    Write-Host "[✓] $message" -ForegroundColor Green
}

function Write-Warning {
    param($message)
    Write-Host "[!] $message" -ForegroundColor Yellow
}

function Write-Failure {
    param($message)
    Write-Host "[✗] $message" -ForegroundColor Red
}

$tenantId = "tenant$TenantNumber"
$namespace = $tenantId
$valuesFile = ".\helm-charts\saas-app\values-overrides\tenant$TenantNumber.yaml"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Deploying Tenant: $tenantId" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

if ($DryRun) {
    Write-Warning "Running in DRY-RUN mode"
}

# Check if values file exists
if (-not (Test-Path $valuesFile)) {
    Write-Failure "Values file not found: $valuesFile"
    exit 1
}

Write-Status "Values file found: $valuesFile"

# Validate Helm chart
Write-Host "`nValidating Helm chart..." -ForegroundColor Cyan
helm lint .\helm-charts\saas-app -f $valuesFile

if ($LASTEXITCODE -eq 0) {
    Write-Status "Helm chart validation passed"
} else {
    Write-Failure "Helm chart validation failed"
    exit 1
}

# Deploy using Helm
Write-Host "`nDeploying tenant $tenantId..." -ForegroundColor Cyan

$helmArgs = @(
    "upgrade", "--install", "$tenantId-app", ".\helm-charts\saas-app",
    "--namespace", $namespace,
    "--create-namespace",
    "-f", ".\helm-charts\saas-app\values.yaml",
    "-f", $valuesFile,
    "--wait",
    "--timeout", "5m"
)

if ($DryRun) {
    $helmArgs += "--dry-run"
}

& helm $helmArgs

if ($LASTEXITCODE -eq 0) {
    Write-Status "Deployment successful"
} else {
    Write-Failure "Deployment failed"
    exit 1
}

if (-not $DryRun) {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "Deployment Summary" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    Write-Host "`nDeployments:" -ForegroundColor Cyan
    kubectl get deployments -n $namespace

    Write-Host "`nServices:" -ForegroundColor Cyan
    kubectl get services -n $namespace

    Write-Host "`nIngress:" -ForegroundColor Cyan
    kubectl get ingress -n $namespace

    Write-Host "`nHPA:" -ForegroundColor Cyan
    kubectl get hpa -n $namespace

    Write-Host "`nResource Quota:" -ForegroundColor Cyan
    kubectl get resourcequota -n $namespace

    Write-Host "`nNetwork Policy:" -ForegroundColor Cyan
    kubectl get networkpolicy -n $namespace

    Write-Host ""
    Write-Status "Tenant $tenantId deployed successfully!"
    Write-Host "`nAccess your application at: http://tenant$TenantNumber.localhost" -ForegroundColor Cyan
    Write-Host ""
}
