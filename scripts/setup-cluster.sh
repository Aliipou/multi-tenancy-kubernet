#!/bin/bash
# Cluster Setup Script for Multi-Tenant Kubernetes Thesis Project
# This script sets up a local Kubernetes cluster with all required components

set -e

echo "=========================================="
echo "Multi-Tenant Kubernetes Cluster Setup"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to print colored output
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Check prerequisites
echo ""
echo "Checking prerequisites..."

if ! command_exists docker; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi
print_status "Docker is installed"

if ! command_exists kubectl; then
    print_error "kubectl is not installed. Please install kubectl first."
    exit 1
fi
print_status "kubectl is installed"

if ! command_exists helm; then
    print_error "Helm is not installed. Please install Helm first."
    exit 1
fi
print_status "Helm is installed"

# Check if kind is installed, if not provide instructions
if ! command_exists kind; then
    print_warning "kind is not installed. Installing kind..."

    # Detect OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    if [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    fi

    # Download kind
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v0.20.0/kind-${OS}-${ARCH}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind

    print_status "kind installed successfully"
else
    print_status "kind is installed"
fi

# Create kind cluster with custom configuration
echo ""
echo "Creating kind cluster..."

cat <<EOF | kind create cluster --name multi-tenant-thesis --config=-
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
EOF

print_status "Cluster created successfully"

# Wait for cluster to be ready
echo ""
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
print_status "Cluster is ready"

# Install NGINX Ingress Controller
echo ""
echo "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "Waiting for NGINX Ingress Controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

print_status "NGINX Ingress Controller installed"

# Install Metrics Server
echo ""
echo "Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch metrics server for kind (disable TLS verification)
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

echo "Waiting for Metrics Server to be ready..."
kubectl wait --namespace kube-system \
  --for=condition=ready pod \
  --selector=k8s-app=metrics-server \
  --timeout=300s

print_status "Metrics Server installed"

# Display cluster info
echo ""
echo "=========================================="
echo "Cluster Setup Complete!"
echo "=========================================="
kubectl cluster-info --context kind-multi-tenant-thesis
echo ""
echo "Available nodes:"
kubectl get nodes
echo ""
print_status "Setup completed successfully!"
echo ""
echo "Next steps:"
echo "  1. Deploy the microservices"
echo "  2. Deploy tenants using Helm charts"
echo "  3. Test multi-tenancy isolation"
