# Deploy all tenants (PowerShell)

$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Deploying All Tenants" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

foreach ($tenant in 1..3) {
    Write-Host "`nDeploying Tenant $tenant..." -ForegroundColor Green

    & .\scripts\deploy-tenant.ps1 -TenantNumber $tenant

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Tenant $tenant deployed successfully" -ForegroundColor Green
    } else {
        Write-Host "Failed to deploy tenant $tenant" -ForegroundColor Red
        exit 1
    }

    if ($tenant -lt 3) {
        Write-Host "`nWaiting 10 seconds before next deployment..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "All Tenants Deployed Successfully!" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "`nAccess URLs:" -ForegroundColor Cyan
Write-Host "  Tenant 1: http://tenant1.localhost"
Write-Host "  Tenant 2: http://tenant2.localhost"
Write-Host "  Tenant 3: http://tenant3.localhost"
Write-Host ""
