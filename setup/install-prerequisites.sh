#!/bin/bash

set -e

echo "================================================"
echo "ArgoCD Training - Prerequisites Installation"
echo "================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

echo "Detected OS: ${MACHINE}"
echo ""

# Check if running on macOS or Linux
if [[ "${MACHINE}" != "Mac" && "${MACHINE}" != "Linux" ]]; then
    print_error "Unsupported operating system: ${MACHINE}"
    exit 1
fi

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install Docker
install_docker() {
    if command_exists docker; then
        print_success "Docker is already installed ($(docker --version))"
        return
    fi

    print_warning "Docker not found. Please install Docker Desktop manually:"
    if [[ "${MACHINE}" == "Mac" ]]; then
        echo "  - Visit: https://docs.docker.com/desktop/install/mac-install/"
    else
        echo "  - Visit: https://docs.docker.com/engine/install/"
    fi
    exit 1
}

# Function to install kubectl
install_kubectl() {
    if command_exists kubectl; then
        print_success "kubectl is already installed ($(kubectl version --client -o yaml | grep gitVersion | cut -d':' -f2 | tr -d ' '))"
        return
    fi

    print_info "Installing kubectl..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        if command_exists brew; then
            brew install kubectl
            print_success "kubectl installed via Homebrew"
        else
            print_error "Homebrew not found. Please install Homebrew first: https://brew.sh"
            exit 1
        fi
    else
        # Linux installation
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
        print_success "kubectl installed"
    fi
}

# Function to install Helm
install_helm() {
    if command_exists helm; then
        print_success "Helm is already installed ($(helm version --short))"
        return
    fi

    print_info "Installing Helm..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        brew install helm
        print_success "Helm installed via Homebrew"
    else
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        print_success "Helm installed"
    fi
}

# Function to install KinD (Day 1 only)
install_kind() {
    if command_exists kind; then
        print_success "KinD is already installed ($(kind version))"
        return
    fi

    print_info "Installing KinD..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        brew install kind
        print_success "KinD installed via Homebrew"
    else
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
        print_success "KinD installed"
    fi
}

# Function to install eksctl (Days 2-5)
install_eksctl() {
    if command_exists eksctl; then
        print_success "eksctl is already installed ($(eksctl version))"
        return
    fi

    print_info "Installing eksctl..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        brew tap weaveworks/tap
        brew install weaveworks/tap/eksctl
        print_success "eksctl installed via Homebrew"
    else
        curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
        sudo mv /tmp/eksctl /usr/local/bin
        print_success "eksctl installed"
    fi
}

# Function to install AWS CLI
install_aws_cli() {
    if command_exists aws; then
        print_success "AWS CLI is already installed ($(aws --version | cut -d' ' -f1))"
        return
    fi

    print_info "Installing AWS CLI..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "/tmp/AWSCLIV2.pkg"
        sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
        rm /tmp/AWSCLIV2.pkg
        print_success "AWS CLI installed"
    else
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
        cd /tmp
        unzip -q awscliv2.zip
        sudo ./aws/install
        rm -rf aws awscliv2.zip
        cd -
        print_success "AWS CLI installed"
    fi
}

# Function to install ArgoCD CLI
install_argocd_cli() {
    if command_exists argocd; then
        print_success "ArgoCD CLI is already installed ($(argocd version --client --short))"
        return
    fi

    print_info "Installing ArgoCD CLI..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        brew install argocd
        print_success "ArgoCD CLI installed via Homebrew"
    else
        curl -sSL -o /tmp/argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
        sudo install -m 555 /tmp/argocd-linux-amd64 /usr/local/bin/argocd
        rm /tmp/argocd-linux-amd64
        print_success "ArgoCD CLI installed"
    fi
}

# Function to install jq
install_jq() {
    if command_exists jq; then
        print_success "jq is already installed ($(jq --version))"
        return
    fi

    print_info "Installing jq..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        brew install jq
        print_success "jq installed via Homebrew"
    else
        sudo apt-get update && sudo apt-get install -y jq
        print_success "jq installed"
    fi
}

# Function to install yq
install_yq() {
    if command_exists yq; then
        print_success "yq is already installed ($(yq --version))"
        return
    fi

    print_info "Installing yq..."
    if [[ "${MACHINE}" == "Mac" ]]; then
        brew install yq
        print_success "yq installed via Homebrew"
    else
        sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
        sudo chmod a+x /usr/local/bin/yq
        print_success "yq installed"
    fi
}

# Main installation flow
echo "Starting prerequisites installation..."
echo ""

# Core tools
install_docker
install_kubectl
install_helm

# Day 1 tools
echo ""
print_info "Installing Day 1 tools (KinD)..."
install_kind

# Days 2-5 tools
echo ""
print_info "Installing Days 2-5 tools (EKS)..."
install_eksctl
install_aws_cli

# ArgoCD CLI
echo ""
print_info "Installing ArgoCD tools..."
install_argocd_cli

# Utility tools
echo ""
print_info "Installing utility tools..."
install_jq
install_yq

echo ""
echo "================================================"
print_success "All prerequisites installed successfully!"
echo "================================================"
echo ""
echo "Next steps:"
echo "  1. For Day 1: Run './setup/install-argocd-kind.sh'"
echo "  2. For Days 2-5: Configure AWS credentials and run './setup/create-eks-cluster.sh'"
echo ""
