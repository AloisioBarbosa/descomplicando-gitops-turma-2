#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing Dependencies for Argo Rollouts Lab (from deps/) ==="
echo "  - Argo CD"
echo "  - Prometheus + Grafana"
echo "  - Ingress for all services"
echo ""

# Add Helm repos
echo "[1/5] Adding Helm repositories..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# Create namespaces
echo "[2/5] Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Install Prometheus FIRST (creates ServiceMonitor CRD)
echo "[3/5] Installing Prometheus + Grafana..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f "$SCRIPT_DIR/prometheus/values.yaml" \
  --wait

# Install Argo CD AFTER (so ServiceMonitors can be created)
echo "[4/5] Installing Argo CD..."
helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  -f "$SCRIPT_DIR/argocd/values.yaml" \
  --wait

# Apply Grafana dashboard
echo ""
echo "Applying Argo CD dashboard to Grafana..."
kubectl apply -f "$SCRIPT_DIR/prometheus/argocd-dashboard.yaml"

# Apply Ingress resources
echo "[5/5] Applying Ingress resources..."
kubectl apply -f "$SCRIPT_DIR/ingress/"

echo ""
echo "=== Installation Complete! ==="
echo ""
echo "Access the services via:"
echo ""
echo "Argo CD:"
echo "  URL: http://argocd.argocd.local"
echo "  Username: admin"
echo "  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Grafana:"
echo "  URL: http://grafana.argocd.local"
echo "  Login: admin / admin"
echo ""
echo "Prometheus:"
echo "  URL: http://prometheus.argocd.local"
echo ""
echo "Argo Rollouts Dashboard (will be available after installing rollouts):"
echo "  URL: http://rollouts.argocd.local"
echo ""
echo "Note: Make sure you have added the following to your /etc/hosts file:"
echo "  127.0.0.1  argocd.argocd.local prometheus.argocd.local grafana.argocd.local rollouts.argocd.local"
echo ""
echo "Or if using a local k8s cluster with ingress, ensure your ingress controller is running:"
echo "  kubectl get pods -n ingress-nginx"
echo ""
