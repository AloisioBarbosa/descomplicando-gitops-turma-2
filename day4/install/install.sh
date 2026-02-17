#!/bin/bash
set -e

echo "Installing Argo Rollouts Controller..."

# Add Argo Helm repository if not already added
if ! helm repo list | grep -q "argo"; then
    echo "Adding Argo Helm repository..."
    helm repo add argo https://argoproj.github.io/argo-helm
fi

# Update repositories
echo "Updating Helm repositories..."
helm repo update

# Create namespace if it doesn't exist
if ! kubectl get namespace argo-rollouts &> /dev/null; then
    echo "Creating argo-rollouts namespace..."
    kubectl create namespace argo-rollouts
fi

# Install Argo Rollouts
echo "Installing Argo Rollouts..."
helm upgrade --install argo-rollouts argo/argo-rollouts \
    --namespace argo-rollouts \
    -f values.yaml \
    --wait

echo ""
echo "Argo Rollouts installed successfully!"
echo ""
echo "To verify installation:"
echo "  kubectl get pods -n argo-rollouts"
echo ""
echo "To install the kubectl plugin:"
echo "  brew install argoproj/tap/kubectl-argo-rollouts  # macOS"
echo ""
echo "To access the dashboard (if enabled):"
echo "  kubectl port-forward svc/argo-rollouts-dashboard 3100:3100 -n argo-rollouts"
echo "  Then open http://localhost:3100"
