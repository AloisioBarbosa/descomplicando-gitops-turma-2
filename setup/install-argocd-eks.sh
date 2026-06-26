#!/usr/bin/env bash
# Install ArgoCD on the EKS cluster
# Run this once after terraform apply
set -euo pipefail

ARGOCD_VERSION=${1:-v2.10.0}

echo "Installing ArgoCD ${ARGOCD_VERSION}..."

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "Waiting for ArgoCD pods to be ready..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd

echo "Getting initial admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "ArgoCD installed successfully"
echo "URL: https://$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Username: admin"
echo "Password: ${ARGOCD_PASSWORD}"
echo ""
echo "Next: kubectl apply -f argocd/projects/ && kubectl apply -f argocd/apps/"