# Day 4 - Argo Rollouts Lab

This directory contains the installation scripts and configurations for the Argo Rollouts lab.

## Structure

```
day4/
├── deps/
│   ├── install-deps.sh          # Installs ArgoCD + Prometheus + Grafana (dependencies)
│   ├── argocd/
│   │   └── values.yaml          # ArgoCD values with ingress enabled
│   ├── prometheus/
│   │   ├── values.yaml          # Prometheus/Grafana values with ingress
│   │   └── argocd-dashboard.yaml # Grafana dashboard for ArgoCD metrics
│   └── ingress/
│       └── rollouts-ingress.yaml # Ingress for Argo Rollouts dashboard
└── install/
    ├── install.sh               # Argo Rollouts controller installer
    ├── values.yaml              # Argo Rollouts values with ingress enabled
    └── README.md
```

**Demo Applications:** Located in `microservicos-argocd-treinamento/rollouts/`

## Quick Start

### Prerequisites

1. Ensure you have an ingress controller installed (e.g., NGINX Ingress Controller):
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
   ```

2. Add to your `/etc/hosts` file:
   ```
   127.0.0.1  argocd.argocd.local prometheus.argocd.local grafana.argocd.local rollouts.argocd.local
   ```

### Installation

1. **Install Dependencies** (ArgoCD + Prometheus + Grafana):
   ```bash
   ./deps/install-deps.sh
   ```

2. **Install Argo Rollouts**:
   ```bash
   cd install/
   ./install.sh
   ```

3. **Deploy Demo Application** (from `microservicos-argocd-treinamento/rollouts/`):
   ```bash
   # Deploy services first
   kubectl apply -f /path/to/microservicos-argocd-treinamento/rollouts/k8s/services.yaml
   
   # Deploy a rollout (choose one)
   kubectl apply -f /path/to/microservicos-argocd-treinamento/rollouts/k8s/canary-rollout.yaml
   # OR
   kubectl apply -f /path/to/microservicos-argocd-treinamento/rollouts/k8s/blue-green-rollout.yaml
   ```

## Access URLs

After installation, access the services at:

| Service | URL |
|---------|-----|
| ArgoCD | http://argocd.argocd.local |
| Grafana | http://grafana.argocd.local (admin/admin) |
| Prometheus | http://prometheus.argocd.local |
| Argo Rollouts Dashboard | http://rollouts.argocd.local |

## Ingress Configuration

All services are configured with ingress using the `nginx` ingress class:

- **ArgoCD**: Configured via Helm values (`server.ingress.enabled: true`)
- **Prometheus**: Configured via Helm values (`prometheus.ingress.enabled: true`)
- **Grafana**: Configured via Helm values (`grafana.ingress.enabled: true`)
- **Argo Rollouts**: Separate ingress resource in `deps/ingress/rollouts-ingress.yaml`

## Notes

- The `deps/install-deps.sh` is separate from the Argo Rollouts installation to keep concerns separated
- All ingresses use `argocd.local` subdomain pattern for easy local development
- Make sure your ingress controller is running before installing
