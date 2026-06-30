#!/bin/bash

set -e

echo "================================================"
echo "Installing Argo CD for Day 1"
echo "================================================"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Namespace target
NAMESPACE="argocd"
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
LOCAL_MANIFEST="/tmp/argocd-install.yaml"

# Check if target cluster is active
if ! kubectl config current-context | grep -q "kind-argocd-day1"; then
    print_info "Switching kubectl context to kind-argocd-day1..."
    kubectl config use-context kind-argocd-day1 || { print_error "argocd-day1 cluster not found. Run cluster creation script first."; exit 1; }
fi

# Create Namespace
print_info "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Download manifest with error handling for WSL DNS issues
print_info "Downloading official Argo CD manifests..."
if curl -sSL --connect-timeout 10 "$MANIFEST_URL" > "$LOCAL_MANIFEST"; then
    print_success "Manifest downloaded successfully."
else
    print_error "Failed to download manifest via WSL network (DNS/Internet issue)."
    
    # Verifica se o usuário seguiu a dica e salvou localmente no diretório atual
    if [ -f "./argocd-install.yaml" ]; then
        print_info "Found local 'argocd-install.yaml' in current directory. Using it..."
        cp "./argocd-install.yaml" "$LOCAL_MANIFEST"
    else
        print_error "Local file 'argocd-install.yaml' not found. Execution aborted."
        exit 1
    fi
fi

# Install Argo CD Components using local file
print_info "Applying Argo CD manifests..."
kubectl apply -n "$NAMESPACE" --server-side --force-conflicts -f "$LOCAL_MANIFEST"

# Wait for deployments to be ready
print_info "Waiting for Argo CD components to be fully ready..."
kubectl rollout status deployment/argocd-server -n "$NAMESPACE" --timeout=300s

print_success "Argo CD components are running!"

# Configure Ingress for Argo CD
print_info "Creating Ingress resource for external local access..."
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOF

# Extract initial admin password
print_info "Retrieving initial admin password..."
INITIAL_PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Get the IP of the remote Docker machine or Control Plane for clarity
NODE_IP=$(kubectl get nodes argocd-day1-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

echo ""
echo "================================================"
print_success "Argo CD Setup Complete!"
echo "================================================"
echo ""
echo "Access Details:"
echo "  🌐 URL:               https://${NODE_IP}  (Ou o IP/Hostname da sua máquina Docker remota)"
echo "  👤 Username:          admin"
echo "  🔑 Initial Password:  $INITIAL_PASSWORD"
echo ""
echo "Notes:"
echo "  - Since your Docker host is remote, use the remote machine's IP instead of 'localhost'."
echo "  - To log in via Argo CD CLI use: argocd login ${NODE_IP} --insecure"
echo ""
