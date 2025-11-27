# Remove a specific tenant deployment (PowerShell)

param(
    [Parameter(Mandatory=$true)]
    [int]$TenantNumber
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

$tenantId = "tenant$TenantNumber"
$namespace = $tenantId

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Cleaning up Tenant: $tenantId" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Warning "This will delete all resources for tenant $tenantId"
$confirm = Read-Host "Are you sure? (yes/no)"

if ($confirm -ne "yes") {
    Write-Host "Cleanup cancelled"
    exit 0
}

# Uninstall Helm release
Write-Host "`nUninstalling Helm release..." -ForegroundColor Cyan
helm uninstall "$tenantId-app" --namespace $namespace 2>$null

# Delete namespace
Write-Host "`nDeleting namespace $namespace..." -ForegroundColor Cyan
kubectl delete namespace $namespace --timeout=60s 2>$null

Write-Status "Tenant $tenantId cleaned up successfully"
