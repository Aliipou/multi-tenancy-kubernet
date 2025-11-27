# Cluster Setup Script for Multi-Tenant Kubernetes Thesis Project (Windows)
# This script sets up a local Kubernetes cluster with all required components

$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Multi-Tenant Kubernetes Cluster Setup" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

function Test-CommandExists {
    param($command)
    $null -ne (Get-Command $command -ErrorAction SilentlyContinue)
}

function Write-Success {
    param($message)
    Write-Host "[✓] $message" -ForegroundColor Green
}

function Write-Failure {
    param($message)
    Write-Host "[✗] $message" -ForegroundColor Red
}

function Write-Warning {
    param($message)
    Write-Host "[!] $message" -ForegroundColor Yellow
}

# Check prerequisites
Write-Host "`nChecking prerequisites..." -ForegroundColor Cyan

if (-not (Test-CommandExists docker)) {
    Write-Failure "Docker is not installed. Please install Docker Desktop for Windows first."
    exit 1
}
Write-Success "Docker is installed"

if (-not (Test-CommandExists kubectl)) {
    Write-Failure "kubectl is not installed. Please install kubectl first."
    exit 1
}
Write-Success "kubectl is installed"

if (-not (Test-CommandExists helm)) {
    Write-Failure "Helm is not installed. Please install Helm first."
    exit 1
}
Write-Success "Helm is installed"

if (-not (Test-CommandExists kind)) {
    Write-Warning "kind is not installed."
    Write-Host "Please install kind using: choco install kind" -ForegroundColor Yellow
    Write-Host "Or download from: https://kind.sigs.k8s.io/docs/user/quick-start/#installation" -ForegroundColor Yellow
    exit 1
}
Write-Success "kind is installed"

# Create kind cluster configuration
Write-Host "`nCreating kind cluster..." -ForegroundColor Cyan

$clusterConfig = @"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
"@

$clusterConfig | kind create cluster --name multi-tenant-thesis --config=-

Write-Success "Cluster created successfully"

# Wait for cluster to be ready
Write-Host "`nWaiting for cluster to be ready..." -ForegroundColor Cyan
kubectl wait --for=condition=Ready nodes --all --timeout=300s
Write-Success "Cluster is ready"

# Install NGINX Ingress Controller
Write-Host "`nInstalling NGINX Ingress Controller..." -ForegroundColor Cyan
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

Write-Host "Waiting for NGINX Ingress Controller to be ready..." -ForegroundColor Cyan
kubectl wait --namespace ingress-nginx `
  --for=condition=ready pod `
  --selector=app.kubernetes.io/component=controller `
  --timeout=300s

Write-Success "NGINX Ingress Controller installed"

# Install Metrics Server
Write-Host "`nInstalling Metrics Server..." -ForegroundColor Cyan
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch metrics server for kind (disable TLS verification)
kubectl patch deployment metrics-server -n kube-system --type='json' `
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

Write-Host "Waiting for Metrics Server to be ready..." -ForegroundColor Cyan
kubectl wait --namespace kube-system `
  --for=condition=ready pod `
  --selector=k8s-app=metrics-server `
  --timeout=300s

Write-Success "Metrics Server installed"

# Display cluster info
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Cluster Setup Complete!" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
kubectl cluster-info --context kind-multi-tenant-thesis
Write-Host "`nAvailable nodes:" -ForegroundColor Cyan
kubectl get nodes
Write-Host ""
Write-Success "Setup completed successfully!"
Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Deploy the microservices"
Write-Host "  2. Deploy tenants using Helm charts"
Write-Host "  3. Test multi-tenancy isolation"
