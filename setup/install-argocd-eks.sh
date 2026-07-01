#!/bin/bash

set -e

export AWS_PAGER=""

echo "================================================"
echo "Creating EKS Cluster for Days 2-5"
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

# Check if eksctl is installed
if ! command -v eksctl &> /dev/null; then
    print_error "eksctl is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    print_error "Helm is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed. Please run ./setup/install-prerequisites.sh first"
    exit 1
fi

# Verify AWS credentials
print_info "Verifying AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured. Please run 'aws configure' first"
    exit 1
fi

print_success "AWS credentials verified"
echo "Account ID: $(aws sts get-caller-identity --query Account --output text)"
echo "Region: $(aws configure get region || echo 'us-east-1')"
echo ""

# Check if cluster already exists
print_info "Checking if cluster exists..."
if aws eks describe-cluster --name argocd-training --region us-east-1 &> /dev/null; then
    print_info "Cluster argocd-training already exists, skipping creation"
else
    # Create cluster
    print_info "Creating EKS cluster (this will take ~15-20 minutes)..."
    echo ""

    eksctl create cluster -f "${SCRIPT_DIR}/eksctl-cluster.yaml"

    print_success "EKS cluster created successfully!"
fi

# Update kubeconfig
print_info "Updating kubeconfig..."
aws eks update-kubeconfig --name argocd-training --region us-east-1

print_success "Kubeconfig updated"

# Verify cluster access
print_info "Verifying cluster access..."
kubectl get nodes

print_success "Cluster access verified!"

# Install AWS Load Balancer Controller
print_info "Installing AWS Load Balancer Controller..."

# Install AWS Load Balancer Controller via Helm if not already installed
if helm list -n kube-system | grep -q aws-load-balancer-controller; then
    print_info "AWS Load Balancer Controller already installed, upgrading..."
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=argocd-training \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set tolerations[0].key=CriticalAddonsOnly \
      --set tolerations[0].operator=Exists \
      --set tolerations[0].effect=NoSchedule
    print_success "AWS Load Balancer Controller upgraded"
else
    print_info "Installing AWS Load Balancer Controller..."
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=argocd-training \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set tolerations[0].key=CriticalAddonsOnly \
      --set tolerations[0].operator=Exists \
      --set tolerations[0].effect=NoSchedule
    print_success "AWS Load Balancer Controller installed"
fi

# Wait for controller to be ready
print_info "Waiting for AWS Load Balancer Controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system

print_success "AWS Load Balancer Controller is ready"

# Install Metrics Server
print_info "Checking for Metrics Server..."

if kubectl get deployment metrics-server -n kube-system &> /dev/null; then
    print_info "Metrics Server already exists, checking tolerations..."

    # Check if tolerations are set
    if kubectl get deployment metrics-server -n kube-system -o json | grep -q "CriticalAddonsOnly"; then
        print_info "Metrics Server already has correct tolerations"
    else
        print_info "Patching Metrics Server to add tolerations..."
        kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
          {"op": "add", "path": "/spec/template/spec/tolerations", "value": [
            {"key": "CriticalAddonsOnly", "operator": "Exists", "effect": "NoSchedule"},
            {"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"},
            {"key": "node-role.kubernetes.io/master", "operator": "Exists", "effect": "NoSchedule"}
          ]}
        ]'
        print_success "Metrics Server patched"
    fi
else
    print_info "Installing Metrics Server..."

    # Apply metrics server
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    # Wait a moment for deployment to be created
    sleep 2

    # Add toleration for CriticalAddonsOnly taint
    print_info "Patching Metrics Server to tolerate CriticalAddonsOnly..."
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
      {"op": "add", "path": "/spec/template/spec/tolerations", "value": [
        {"key": "CriticalAddonsOnly", "operator": "Exists", "effect": "NoSchedule"},
        {"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"},
        {"key": "node-role.kubernetes.io/master", "operator": "Exists", "effect": "NoSchedule"}
      ]}
    ]'
    print_success "Metrics Server installed"
fi

# Wait for metrics server to be ready
print_info "Waiting for Metrics Server to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/metrics-server -n kube-system

print_success "Metrics Server is ready"

# Setup Karpenter
echo ""
echo "================================================"
print_info "Setting up Karpenter for Autoscaling"
echo "================================================"
echo ""

CLUSTER_NAME="argocd-training"
REGION="us-east-1"
KARPENTER_VERSION="1.8.2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create Karpenter Node IAM Role
print_info "Creating Karpenter Node IAM Role..."

cat > /tmp/karpenter-node-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role if it doesn't exist
if aws iam get-role --role-name KarpenterNodeRole-${CLUSTER_NAME} --region ${REGION} &> /dev/null; then
    print_info "Role KarpenterNodeRole-${CLUSTER_NAME} already exists"
else
    aws iam create-role --role-name KarpenterNodeRole-${CLUSTER_NAME} \
        --assume-role-policy-document file:///tmp/karpenter-node-trust-policy.json \
        --region ${REGION}
    print_success "Created IAM role KarpenterNodeRole-${CLUSTER_NAME}"
fi

# Attach required policies to node role
print_info "Attaching policies to node role..."
aws iam attach-role-policy --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore > /dev/null 2>&1 || true

print_success "Policies attached"

# ============================================================
# CRITICAL: authorize KarpenterNodeRole to actually join the
# cluster. Without this, every EC2 instance Karpenter launches
# will show Launched=True but Registered=Unknown forever
# (kubelet boots but can't authenticate to the API server), and
# any pod that Karpenter is trying to schedule will time out
# waiting on a node that never becomes Ready.
# ============================================================
print_info "Granting KarpenterNodeRole access to join the cluster..."

NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"

AUTH_MODE=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION} \
    --query 'cluster.accessConfig.authenticationMode' --output text 2>/dev/null || echo "CONFIG_MAP")

if [ "$AUTH_MODE" = "CONFIG_MAP" ]; then
    print_info "Cluster uses CONFIG_MAP auth mode, mapping role via aws-auth..."
    if eksctl get iamidentitymapping --cluster ${CLUSTER_NAME} --region ${REGION} \
        --arn ${NODE_ROLE_ARN} &> /dev/null; then
        print_info "aws-auth mapping for KarpenterNodeRole already exists"
    else
        eksctl create iamidentitymapping \
            --cluster ${CLUSTER_NAME} \
            --region ${REGION} \
            --arn ${NODE_ROLE_ARN} \
            --group system:bootstrappers,system:nodes \
            --username system:node:{{EC2PrivateDNSName}}
        print_success "aws-auth mapping created for KarpenterNodeRole"
    fi
else
    print_info "Cluster uses ${AUTH_MODE} auth mode, creating EKS access entry..."
    if aws eks describe-access-entry --cluster-name ${CLUSTER_NAME} --region ${REGION} \
        --principal-arn ${NODE_ROLE_ARN} &> /dev/null; then
        print_info "Access entry for KarpenterNodeRole already exists"
    else
        aws eks create-access-entry \
            --cluster-name ${CLUSTER_NAME} \
            --region ${REGION} \
            --principal-arn ${NODE_ROLE_ARN} \
            --type EC2_LINUX > /dev/null
        print_success "Access entry created for KarpenterNodeRole"
    fi
fi

# Create instance profile if it doesn't exist
print_info "Creating instance profile..."
if aws iam get-instance-profile --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} --region ${REGION} &> /dev/null; then
    print_info "Instance profile already exists"
else
    aws iam create-instance-profile --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
        --region ${REGION}

    # Wait for instance profile to be created
    sleep 5

    # Add role to instance profile
    aws iam add-role-to-instance-profile \
        --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
        --role-name KarpenterNodeRole-${CLUSTER_NAME} \
        --region ${REGION}

    print_success "Created instance profile"
fi

# Tag subnets for Karpenter discovery
print_info "Tagging private subnets for Karpenter discovery..."
SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=shared" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
    --query 'Subnets[*].SubnetId' \
    --output text \
    --region ${REGION})

for subnet in $SUBNET_IDS; do
    aws ec2 create-tags --resources $subnet \
        --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME} \
        --region ${REGION} > /dev/null 2>&1 || true
done

print_success "Subnets tagged"

# Tag security groups for Karpenter discovery
print_info "Tagging security groups for Karpenter discovery..."
SECURITY_GROUP_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text \
    --region ${REGION})

aws ec2 create-tags --resources $SECURITY_GROUP_ID \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME} \
    --region ${REGION} > /dev/null 2>&1 || true

print_success "Security groups tagged"

# Create EC2 Spot service-linked role if it doesn't exist
print_info "Checking EC2 Spot service-linked role..."
if aws iam get-role --role-name AWSServiceRoleForEC2Spot &> /dev/null; then
    print_info "EC2 Spot service-linked role already exists"
else
    aws iam create-service-linked-role --aws-service-name spot.amazonaws.com > /dev/null 2>&1 || true
    print_success "Created EC2 Spot service-linked role"
fi

# Install Karpenter via Helm
print_info "Checking for Karpenter installation..."

# Logout of any existing Helm registry
helm registry logout public.ecr.aws > /dev/null 2>&1 || true

# Get cluster endpoint
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --query 'cluster.endpoint' \
    --output text \
    --region ${REGION})

# Check if Karpenter is already installed
if helm list -n kube-system | grep -q karpenter; then
    print_info "Karpenter already installed, upgrading to version ${KARPENTER_VERSION}..."
    helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
        --version ${KARPENTER_VERSION} \
        --namespace kube-system \
        --set settings.clusterName=${CLUSTER_NAME} \
        --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
        --set serviceAccount.create=false \
        --set serviceAccount.name=karpenter \
        --set tolerations[0].key=CriticalAddonsOnly \
        --set tolerations[0].operator=Exists \
        --set tolerations[0].effect=NoSchedule \
        --wait
    print_success "Karpenter upgraded"
else
    print_info "Installing Karpenter ${KARPENTER_VERSION} via Helm..."
    helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --version ${KARPENTER_VERSION} \
        --namespace kube-system \
        --create-namespace \
        --set settings.clusterName=${CLUSTER_NAME} \
        --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
        --set serviceAccount.create=false \
        --set serviceAccount.name=karpenter \
        --set tolerations[0].key=CriticalAddonsOnly \
        --set tolerations[0].operator=Exists \
        --set tolerations[0].effect=NoSchedule \
        --wait
    print_success "Karpenter installed"
fi

# Wait for Karpenter to be ready
print_info "Waiting for Karpenter pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=karpenter -n kube-system --timeout=300s

print_success "Karpenter is ready"

# Create default NodePool and EC2NodeClass
print_info "Checking for default NodePool and EC2NodeClass..."

if kubectl get nodepool default &> /dev/null; then
    print_info "Default NodePool already exists, updating if needed..."
else
    print_info "Creating default NodePool and EC2NodeClass..."
fi

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3.large", "t3.xlarge"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
  limits:
    cpu: "100"
    memory: 100Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-${CLUSTER_NAME}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
    Name: karpenter-node
    Environment: training
EOF

print_success "Default NodePool and EC2NodeClass created"

# Display cluster info
echo ""
echo "================================================"
print_success "EKS Cluster Setup Complete!"
echo "================================================"
echo ""
echo "Cluster Name: argocd-training"
echo "Region: us-east-1"
echo ""
echo "Nodes:"
kubectl get nodes -o wide
echo ""
echo "Cluster Endpoint:"
aws eks describe-cluster --name argocd-training --region us-east-1 --query cluster.endpoint --output text
echo ""
echo "Karpenter:"
echo "  Version: ${KARPENTER_VERSION}"
echo "  NodePool: default (Spot + On-Demand, t3.medium/large/xlarge)"
echo "  View NodePools: kubectl get nodepools"
echo ""
echo "Next steps:"
echo "  1. Run './setup/install-argocd-eks.sh' to install ArgoCD"
echo "  2. Deploy workloads and watch Karpenter auto-scale nodes"
echo "  3. Proceed to Day 2 labs"
echo ""
echo "⚠️  IMPORTANT: Remember to delete the cluster when done to avoid AWS charges:"
echo "     eksctl delete cluster --name argocd-training --region us-east-1"
echo ""