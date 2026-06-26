#!/bin/bash

set -e

echo "================================================"
echo "Creating KinD Cluster for Day 1"
echo "================================================"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Delete existing cluster if it exists
if kind get clusters | grep -q "^argocd-day1$"; then
    print_info "Deleting existing argocd-day1 cluster..."
    kind delete cluster --name argocd-day1
    sleep 5
fi

# Create new cluster
print_info "Creating KinD cluster with config from kind-config.yaml..."
kind create cluster --config="${SCRIPT_DIR}/kind-config.yaml" --wait 30s

print_success "KinD cluster created successfully!"

# Wait for cluster to be ready
print_info "Waiting for cluster to be fully ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

print_success "Cluster is ready!"

# Install Ingress NGINX
print_info "Installing Ingress NGINX Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

print_info "Patching Ingress NGINX to use hostPort for external access..."
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/nodeSelector", "value": {"kubernetes.io/hostname": "argocd-day1-control-plane"}},
  {"op": "replace", "path": "/spec/template/spec/tolerations", "value": [{"key": "node-role.kubernetes.io/control-plane", "operator": "Equal", "effect": "NoSchedule"}, {"key": "node-role.kubernetes.io/master", "operator": "Equal", "effect": "NoSchedule"}]},
  {"op": "add", "path": "/spec/template/spec/containers/0/ports/0/hostPort", "value": 80},
  {"op": "add", "path": "/spec/template/spec/containers/0/ports/1/hostPort", "value": 443}
]'

print_info "Waiting for Ingress NGINX to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

print_success "Ingress NGINX Controller installed successfully!"

# Display cluster info
echo ""
echo "================================================"
print_success "KinD Cluster Setup Complete!"
echo "================================================"
echo ""
echo "Cluster Name: argocd-day1"
echo "Nodes:"
kubectl get nodes -o wide
echo ""
echo "Next steps:"
echo "  1. Run './setup/install-argocd-kind.sh' to install ArgoCD"
echo "  2. Or proceed to Day 1 labs"
echo ""
