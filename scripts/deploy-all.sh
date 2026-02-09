#!/bin/bash
# ============================================================================
# CLOUDLENS SE TRAINING LAB - FULL DEPLOYMENT SCRIPT
# ============================================================================
# This script runs the complete deployment workflow:
#   1. terraform apply - Create all AWS infrastructure
#   2. post-deploy.sh - Deploy K8s apps, generate docs, distribute SSH keys
#
# Usage:
#   ./deploy-all.sh           # Full deployment (terraform + post-deploy)
#   ./deploy-all.sh --skip-tf # Skip terraform, only run post-deploy
#   ./deploy-all.sh --dry-run # Preview terraform plan, don't apply
#
# Prerequisites:
#   - AWS CLI configured with 'cloudlens-lab' profile
#   - Terraform installed
#   - Docker running (for post-deploy image push)
#   - SSH key at ~/Downloads/cloudlens-se-training.pem or in repo root
#   - TLS certs (tls.crt, tls.key) in repo root
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
SKIP_TF=false
DRY_RUN=false
FORCE=false

for arg in "$@"; do
    case $arg in
        --skip-tf) SKIP_TF=true ;;
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
        --help)
            echo "Usage: ./deploy-all.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-tf   Skip terraform apply, only run post-deploy.sh"
            echo "  --dry-run   Preview terraform plan, don't apply"
            echo "  --force     Pass --force to post-deploy.sh (re-run all steps)"
            echo "  --help      Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  AWS_PROFILE   AWS profile to use (default: cloudlens-lab)"
            echo "  AWS_REGION    AWS region (default: us-west-2)"
            echo ""
            exit 0
            ;;
    esac
done

cd "$BASE_DIR"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}CloudLens SE Training Lab - Full Deployment${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

# AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not found${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} AWS CLI found"

# Terraform
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}Error: Terraform not found${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Terraform found"

# AWS credentials
AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &> /dev/null; then
    echo -e "${RED}Error: AWS authentication failed. Run: aws sso login --profile $AWS_PROFILE${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} AWS credentials valid ($AWS_PROFILE)"

# Docker (for post-deploy)
if ! docker info &>/dev/null; then
    echo -e "${YELLOW}  ! Docker not running (needed for ECR image push)${NC}"
else
    echo -e "  ${GREEN}✓${NC} Docker running"
fi

# SSH key
if [ -f "$BASE_DIR/cloudlens-se-training.pem" ]; then
    echo -e "  ${GREEN}✓${NC} SSH key found in repo"
elif [ -f "$HOME/Downloads/cloudlens-se-training.pem" ]; then
    echo -e "  ${GREEN}✓${NC} SSH key found in Downloads"
else
    echo -e "${YELLOW}  ! SSH key not found (SEs won't get SSH key)${NC}"
fi

# TLS certs
if [ -f "$BASE_DIR/tls.crt" ] && [ -f "$BASE_DIR/tls.key" ]; then
    echo -e "  ${GREEN}✓${NC} TLS certs found"
else
    echo -e "${YELLOW}  ! TLS certs not found (nginx HTTPS may fail)${NC}"
fi

echo ""

# ============================================================================
# STEP 1: Terraform Apply
# ============================================================================
if [ "$SKIP_TF" = "true" ]; then
    echo -e "${YELLOW}Step 1: Terraform (skipped --skip-tf)${NC}"
else
    echo -e "${YELLOW}Step 1: Terraform Infrastructure${NC}"

    # Initialize if needed
    if [ ! -d ".terraform" ]; then
        echo "  Initializing Terraform..."
        terraform init
    fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "  Running terraform plan (dry-run)..."
        terraform plan
        echo ""
        echo -e "${YELLOW}Dry-run complete. Run without --dry-run to apply changes.${NC}"
        exit 0
    else
        echo "  Running terraform apply..."
        terraform apply -auto-approve
        echo -e "  ${GREEN}✓ Terraform apply complete${NC}"
    fi
fi
echo ""

# ============================================================================
# STEP 2: Post-Deploy (nginx, kubeconfigs, SSH keys, docs)
# ============================================================================
echo -e "${YELLOW}Step 2: Post-Deployment Setup${NC}"
echo "  This will:"
echo "    - Deploy nginx to all SE namespaces"
echo "    - Generate kubeconfig files"
echo "    - Distribute SSH keys to SE folders"
echo "    - Update SE guides with nginx URLs"
echo ""

POST_DEPLOY_ARGS=""
if [ "$FORCE" = "true" ]; then
    POST_DEPLOY_ARGS="--force"
fi

if [ -f "$SCRIPT_DIR/post-deploy.sh" ]; then
    bash "$SCRIPT_DIR/post-deploy.sh" $POST_DEPLOY_ARGS
else
    echo -e "${RED}Error: post-deploy.sh not found at $SCRIPT_DIR/post-deploy.sh${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Full deployment complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "What was deployed:"
echo "  - EC2 instances (CLMS, KVO, vPB, VMs)"
echo "  - Shared EKS cluster with SE-dedicated nodes"
echo "  - Nginx with LoadBalancer per SE namespace"
echo "  - SE guides with access info"
echo "  - SSH keys distributed to SE folders"
echo "  - Kubeconfig files for each SE"
echo ""
echo "Next steps:"
echo "  1. Wait 15 minutes for CLMS/KVO to initialize"
echo "  2. Distribute SE folders from ./generated/se-lab-XX/"
echo "  3. Each folder contains: guide, SSH key, kubeconfig"
echo ""
echo "To destroy everything:"
echo "  ./scripts/destroy-all.sh"
echo ""
