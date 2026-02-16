# Argo Rollouts Controller Installation

This directory contains the Helm values and instructions for installing the Argo Rollouts controller.

## Prerequisites

- Kubernetes cluster (1.24+)
- Helm 3.x installed
- kubectl configured to access your cluster

## Installation

### Option 1: Using Helm directly

```bash
# Add the Argo Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install Argo Rollouts
helm install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts \
  --create-namespace \
  -f values.yaml
```

### Option 2: Using the install script

```bash
chmod +x install.sh
./install.sh
```

## Install Argo Rollouts kubectl plugin

The kubectl plugin provides a convenient way to manage and visualize rollouts:

```bash
# On macOS with Homebrew
brew install argoproj/tap/kubectl-argo-rollouts

# On Linux
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x ./kubectl-argo-rollouts-linux-amd64
sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# Verify installation
kubectl argo rollouts version
```

## Verify Installation

```bash
# Check if the controller is running
kubectl get pods -n argo-rollouts

# Check CRDs
kubectl get crd | grep argo
```

## Uninstall

```bash
helm uninstall argo-rollouts -n argo-rollouts
kubectl delete namespace argo-rollouts
```
