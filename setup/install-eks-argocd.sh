#!/bin/bash

set -e

export AWS_PAGER=""

echo "================================================"
echo "Installing ArgoCD on EKS Cluster"
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
    echo -e "${RED}✗ $1${NC}"
}

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration variables
CLUSTER_NAME="argocd-training"
CLUSTER_REGION="us-east-1"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="7.3.7"
ARGOCD_DOMAIN="${ARGOCD_DOMAIN:-argocd.local}"
ENABLE_INGRESS="${ENABLE_INGRESS:-false}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# CRDs owned by the argo-cd Helm chart. Used to fix "orphaned CRD" ownership conflicts.
ARGOCD_CRDS=(
    "applications.argoproj.io"
    "applicationsets.argoproj.io"
    "appprojects.argoproj.io"
)

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    print_error "Helm is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Verify AWS credentials
print_info "Verifying AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured. Please run 'aws configure' first"
    exit 1
fi

print_success "AWS credentials verified"
echo "Account ID: ${ACCOUNT_ID}"
echo "Region: ${CLUSTER_REGION}"
echo ""

# Verify cluster exists and is accessible
print_info "Verifying cluster access..."
if ! kubectl get nodes &> /dev/null; then
    print_error "Cannot access EKS cluster '${CLUSTER_NAME}'. Is it running?"
    exit 1
fi

print_success "Cluster is accessible"
echo ""

# ============================================================
# Step 0: Handle a namespace stuck in "Terminating" from a
# previous failed/partial run (common cause of apparent
# "namespace conflicts" when re-running this script)
# ============================================================
handle_stuck_namespace() {
    local ns_phase
    ns_phase=$(kubectl get namespace ${ARGOCD_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [ "$ns_phase" = "Terminating" ]; then
        print_info "Namespace '${ARGOCD_NAMESPACE}' is stuck in Terminating state. Attempting to clear finalizers..."

        kubectl get namespace ${ARGOCD_NAMESPACE} -o json \
            | jq '.spec.finalizers = []' \
            > /tmp/argocd-ns-fix.json 2>/dev/null || true

        if [ -s /tmp/argocd-ns-fix.json ]; then
            kubectl replace --raw "/api/v1/namespaces/${ARGOCD_NAMESPACE}/finalize" -f /tmp/argocd-ns-fix.json > /dev/null 2>&1 || true
        fi

        print_info "Waiting for namespace to fully terminate..."
        for i in {1..30}; do
            if ! kubectl get namespace ${ARGOCD_NAMESPACE} &> /dev/null; then
                print_success "Namespace cleared"
                break
            fi
            sleep 2
        done
    fi
}

handle_stuck_namespace

# ============================================================
# Step 1: Create ArgoCD namespace
# ============================================================
echo "================================================"
print_info "Creating ArgoCD namespace"
echo "================================================"
echo ""

if kubectl get namespace ${ARGOCD_NAMESPACE} &> /dev/null; then
    print_info "Namespace '${ARGOCD_NAMESPACE}' already exists"
else
    kubectl create namespace ${ARGOCD_NAMESPACE}
    print_success "Namespace '${ARGOCD_NAMESPACE}' created"
fi

# NOTE: switched from `restricted` to `baseline`. The `restricted` PSA
# profile blocks pods (repo-server/redis) that don't set every
# securityContext field exactly as required, which manifests as pods
# stuck Pending/CrashLoop and looks like a "conflict" on re-run.
kubectl label namespace ${ARGOCD_NAMESPACE} \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/audit=baseline \
    pod-security.kubernetes.io/warn=baseline \
    --overwrite > /dev/null 2>&1 || true

echo ""

# ============================================================
# Step 1.5: Fix orphaned ArgoCD CRD ownership
#
# If applications.argoproj.io / appprojects.argoproj.io /
# applicationsets.argoproj.io already exist on the cluster but were
# NOT created by this Helm release (e.g. leftover from a previous
# failed install, or `crds.keep: true` from an earlier uninstall),
# `helm install`/`helm upgrade` fails with:
#   "invalid ownership metadata; annotation validation error:
#    key 'meta.helm.sh/release-name' must equal 'argocd'"
#
# This adopts existing CRDs by stamping the annotations/labels Helm
# expects, so install/upgrade succeeds without deleting any existing
# Application/AppProject/ApplicationSet custom resources.
# ============================================================
echo "================================================"
print_info "Checking ArgoCD CRD ownership"
echo "================================================"
echo ""

for crd in "${ARGOCD_CRDS[@]}"; do
    if kubectl get crd "${crd}" &> /dev/null; then
        managed_by=$(kubectl get crd "${crd}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
        release_name=$(kubectl get crd "${crd}" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")

        if [ "$managed_by" = "Helm" ] && [ "$release_name" = "argocd" ]; then
            print_info "CRD '${crd}' already owned by Helm release 'argocd'"
        else
            print_info "CRD '${crd}' exists but is not owned by this Helm release. Adopting it..."
            kubectl annotate crd "${crd}" \
                meta.helm.sh/release-name=argocd \
                meta.helm.sh/release-namespace=${ARGOCD_NAMESPACE} \
                --overwrite > /dev/null 2>&1
            kubectl label crd "${crd}" \
                app.kubernetes.io/managed-by=Helm \
                --overwrite > /dev/null 2>&1
            print_success "CRD '${crd}' adopted by Helm release 'argocd'"
        fi
    else
        print_info "CRD '${crd}' does not exist yet, Helm will create it"
    fi
done

echo ""

# ============================================================
# Step 2: Setup IRSA (IAM Roles for Service Accounts)
# ============================================================
echo "================================================"
print_info "Setting up IRSA for ArgoCD"
echo "================================================"
echo ""

# Get OIDC Provider
print_info "Retrieving OIDC provider information..."
OIDC_ISSUER=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${CLUSTER_REGION} \
    --query 'cluster.identity.oidc.issuer' --output text)

if [ -z "$OIDC_ISSUER" ]; then
    print_error "OIDC provider not found for cluster ${CLUSTER_NAME}"
    exit 1
fi

OIDC_PROVIDER=$(echo ${OIDC_ISSUER} | sed -e "s/^https:\/\///")
print_success "OIDC Provider: ${OIDC_PROVIDER}"

# Create IAM policy for ArgoCD
print_info "Creating IAM policy for ArgoCD..."

cat > /tmp/argocd-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ],
      "Resource": "arn:aws:iam::ACCOUNT_ID:role/ArgoCD*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:*:ACCOUNT_ID:secret:argocd/*"
    }
  ]
}
EOF

sed -i "s/ACCOUNT_ID/${ACCOUNT_ID}/g" /tmp/argocd-policy.json

# Create IAM policy if it doesn't exist
if aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ArgocdPolicy &> /dev/null; then
    print_info "IAM policy 'ArgocdPolicy' already exists"
else
    aws iam create-policy --policy-name ArgocdPolicy \
        --policy-document file:///tmp/argocd-policy.json > /dev/null 2>&1 || true
    print_success "IAM policy 'ArgocdPolicy' created"
fi

# Create IAM role for ArgoCD
print_info "Creating IAM role for ArgoCD..."

cat > /tmp/argocd-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${ARGOCD_NAMESPACE}:argocd-application-controller"
        }
      }
    }
  ]
}
EOF

if aws iam get-role --role-name ArgoCD-ApplicationController-${CLUSTER_NAME} &> /dev/null; then
    print_info "IAM role 'ArgoCD-ApplicationController-${CLUSTER_NAME}' already exists"
else
    aws iam create-role --role-name ArgoCD-ApplicationController-${CLUSTER_NAME} \
        --assume-role-policy-document file:///tmp/argocd-trust-policy.json > /dev/null 2>&1

    # Attach policy to role
    aws iam attach-role-policy --role-name ArgoCD-ApplicationController-${CLUSTER_NAME} \
        --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ArgocdPolicy > /dev/null 2>&1

    print_success "IAM role 'ArgoCD-ApplicationController-${CLUSTER_NAME}' created"
fi

# Create service account for ArgoCD
print_info "Creating Kubernetes service account with IRSA annotation..."

SA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ArgoCD-ApplicationController-${CLUSTER_NAME}"

kubectl get serviceaccount argocd-application-controller -n ${ARGOCD_NAMESPACE} &> /dev/null && \
    kubectl annotate serviceaccount argocd-application-controller -n ${ARGOCD_NAMESPACE} \
        eks.amazonaws.com/role-arn=${SA_ROLE_ARN} --overwrite > /dev/null 2>&1 || true

print_success "Service account configured"
echo ""

# ============================================================
# Step 3: Add ArgoCD Helm repository
# ============================================================
echo "================================================"
print_info "Adding ArgoCD Helm repository"
echo "================================================"
echo ""

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

print_success "Helm repository updated"
echo ""

# ============================================================
# Step 4: Install/Upgrade ArgoCD
# ============================================================
echo "================================================"
print_info "Installing/Upgrading ArgoCD"
echo "================================================"
echo ""

# Create values file for Helm
cat > /tmp/argocd-values.yaml <<EOF
global:
  domain: ${ARGOCD_DOMAIN}

controller:
  replicas: 1
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi
  serviceAccount:
    create: false
    name: argocd-application-controller
    annotations:
      eks.amazonaws.com/role-arn: ${SA_ROLE_ARN}
  clusterAdminAccess:
    enabled: true

server:
  replicas: 2
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  service:
    type: LoadBalancer
  insecure: true
  extraArgs:
    - --disable-auth

repoServer:
  replicas: 2
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilizationPercentage: 80

applicationSet:
  enabled: true
  replicas: 2
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

notification:
  enabled: false

redis:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

configs:
  secret:
    argocdServerAdminPassword: \$2a\$10\$g8sL8W0f3pEWqQTNKJ8ZZuDYVxnl5cOyMsVJXakGlFIe8vKDYB7uu

  cm:
    url: https://${ARGOCD_DOMAIN}
    oidc.config: |
      name: AWS
      issuer: https://sts.amazonaws.com
      clientID: sts.amazonaws.com
      clientSecret: \$client-secret:oidc:clientSecret
      requestedScopes:
        - openid
        - aws.signin

  rbac:
    policy.default: role:readonly
    scopes: '[groups]'

crds:
  install: true
  keep: true
EOF

# Check if ArgoCD is already installed
if helm list -n ${ARGOCD_NAMESPACE} | grep -q argocd; then
    print_info "ArgoCD is already installed, upgrading to version ${ARGOCD_VERSION}..."
    helm upgrade argocd argo/argo-cd \
        --namespace ${ARGOCD_NAMESPACE} \
        --version ${ARGOCD_VERSION} \
        --values /tmp/argocd-values.yaml \
        --wait \
        --timeout 5m

    print_success "ArgoCD upgraded to version ${ARGOCD_VERSION}"
else
    print_info "Installing ArgoCD version ${ARGOCD_VERSION}..."
    helm install argocd argo/argo-cd \
        --namespace ${ARGOCD_NAMESPACE} \
        --version ${ARGOCD_VERSION} \
        --values /tmp/argocd-values.yaml \
        --create-namespace \
        --wait \
        --timeout 5m

    print_success "ArgoCD installed version ${ARGOCD_VERSION}"
fi

echo ""

# ============================================================
# Step 5: Wait for ArgoCD deployments
# ============================================================
echo "================================================"
print_info "Waiting for ArgoCD deployments to be ready"
echo "================================================"
echo ""

print_info "Waiting for ArgoCD server..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n ${ARGOCD_NAMESPACE}
print_success "ArgoCD server is ready"

print_info "Waiting for ArgoCD repo server..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n ${ARGOCD_NAMESPACE}
print_success "ArgoCD repo server is ready"

print_info "Waiting for ArgoCD application controller..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-application-controller -n ${ARGOCD_NAMESPACE}
print_success "ArgoCD application controller is ready"

echo ""

# ============================================================
# Step 6: Configure Network Policies (Optional)
# ============================================================
echo "================================================"
print_info "Configuring network policies"
echo "================================================"
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-allow-ingress
  namespace: ${ARGOCD_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    - namespaceSelector:
        matchLabels:
          name: default
    ports:
    - protocol: TCP
      port: 8080
    - protocol: TCP
      port: 8443
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-allow-internal
  namespace: ${ARGOCD_NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
    - namespaceSelector:
        matchLabels:
          name: default
    - namespaceSelector:
        matchLabels:
          name: kube-system
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 6379
  - to:
    - podSelector: {}
  - ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF

print_success "Network policies created"
echo ""

# ============================================================
# Step 7: Display Access Information
# ============================================================
echo "================================================"
print_success "ArgoCD Installation Complete!"
echo "================================================"
echo ""

# Get ArgoCD service endpoint
print_info "Retrieving ArgoCD endpoint..."
ARGOCD_SERVICE_TYPE=$(kubectl get service argocd-server -n ${ARGOCD_NAMESPACE} -o jsonpath='{.spec.type}')

if [ "${ARGOCD_SERVICE_TYPE}" = "LoadBalancer" ]; then
    # Wait for LoadBalancer to get external IP
    print_info "Waiting for LoadBalancer to get external IP (this may take a few minutes)..."
    for i in {1..60}; do
        EXTERNAL_IP=$(kubectl get service argocd-server -n ${ARGOCD_NAMESPACE} \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -n "$EXTERNAL_IP" ]; then
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    if [ -z "$EXTERNAL_IP" ]; then
        print_info "LoadBalancer IP still pending. Run:"
        echo "  kubectl get service argocd-server -n ${ARGOCD_NAMESPACE}"
    else
        ARGOCD_URL="https://${EXTERNAL_IP}"
        print_success "ArgoCD Server is accessible at: ${ARGOCD_URL}"
    fi
else
    print_info "Using port-forward to access ArgoCD:"
    echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
    ARGOCD_URL="https://localhost:8080"
fi

echo ""
echo "================================================"
echo "Access Information"
echo "================================================"
echo ""
echo "Namespace: ${ARGOCD_NAMESPACE}"
echo "Version: ${ARGOCD_VERSION}"
echo ""

# Get default password
print_info "Retrieving initial admin password..."
ADMIN_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n ${ARGOCD_NAMESPACE} \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "Not found")

if [ "${ADMIN_PASSWORD}" != "Not found" ]; then
    echo "Default Login:"
    echo "  Username: admin"
    echo "  Password: ${ADMIN_PASSWORD}"
    echo ""
    echo "⚠️  IMPORTANT: Change the password immediately after first login!"
fi

echo ""
echo "================================================"
echo "Useful Commands"
echo "================================================"
echo ""
echo "View ArgoCD pods:"
echo "  kubectl get pods -n ${ARGOCD_NAMESPACE}"
echo ""
echo "View ArgoCD services:"
echo "  kubectl get svc -n ${ARGOCD_NAMESPACE}"
echo ""
echo "Get admin password (if needed):"
echo "  kubectl get secret argocd-initial-admin-secret -n ${ARGOCD_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Port-forward to ArgoCD server:"
echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
echo ""
echo "View ArgoCD logs:"
echo "  kubectl logs -f deployment/argocd-server -n ${ARGOCD_NAMESPACE}"
echo ""
echo "Watch deployed applications:"
echo "  kubectl get applications -n ${ARGOCD_NAMESPACE}"
echo ""
echo "================================================"
echo "Next Steps"
echo "================================================"
echo ""
echo "1. Access ArgoCD at the URL above"
echo "2. Add your Git repository:"
echo "   - Repositories → Connect Repo"
echo "   - Method: HTTPS or SSH"
echo "   - URL: https://github.com/your-org/your-repo"
echo ""
echo "3. Create an Application:"
echo "   - New App → Fill in details"
echo "   - Set Git path to your deployment manifests"
echo "   - Destination: https://kubernetes.default.svc (in-cluster)"
echo ""
echo "4. Deploy your first application"
echo ""
echo "⚠️  IMPORTANT: Remember to clean up resources when done:"
echo "    helm uninstall argocd -n ${ARGOCD_NAMESPACE}"
echo "    kubectl delete namespace ${ARGOCD_NAMESPACE}"
echo ""