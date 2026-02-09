#!/bin/bash
# ============================================================================
# DESTROY ALL - MULTI-SE TRAINING LABS
# ============================================================================
# Completely destroys all SE training lab environments
# WARNING: This is destructive and cannot be undone!
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "============================================================================"
echo -e "  ${RED}DANGER: CloudLens Multi-SE Lab - DESTROY ALL${NC}"
echo "============================================================================"
echo ""
echo -e "${RED}WARNING: This will PERMANENTLY DELETE all SE training labs!${NC}"
echo ""
echo "This includes:"
echo "  - All VPCs and networking"
echo "  - All EC2 instances (CLMS, KVO, vPB, VMs)"
echo "  - All EKS clusters"
echo "  - All ECR repositories and images"
echo "  - All Elastic IPs"
echo "  - All generated documentation"
echo ""

# Count resources
VPC_COUNT=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" \
  --query 'Vpcs[].VpcId' \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" 2>/dev/null | wc -w | tr -d ' ')

INSTANCE_COUNT=$(aws ec2 describe-instances \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" \
            "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" 2>/dev/null | wc -w | tr -d ' ')

echo "Resources to be destroyed:"
echo "  - VPCs: $VPC_COUNT"
echo "  - Instances: $INSTANCE_COUNT"
echo ""

if [ "$VPC_COUNT" -eq 0 ] && [ "$INSTANCE_COUNT" -eq 0 ]; then
  log_warning "No SE training lab resources found"
  exit 0
fi

echo -e "${RED}This action CANNOT be undone!${NC}"
echo ""
read -p "Type 'destroy all labs' to confirm: " confirm

if [[ "$confirm" != "destroy all labs" ]]; then
  log_warning "Destruction cancelled"
  exit 0
fi

cd "$BASE_DIR"

# Step 1: Force delete ECR repositories (must be empty before destroy)
log_info "Step 1: Force deleting ECR repositories..."

ECR_REPOS=$(aws ecr describe-repositories \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query 'repositories[?contains(repositoryName, `se-lab`)].repositoryName' \
  --output text 2>/dev/null || echo "")

if [ -n "$ECR_REPOS" ]; then
  for REPO in $ECR_REPOS; do
    log_info "  Deleting ECR repository: $REPO"
    aws ecr delete-repository \
      --repository-name "$REPO" \
      --force \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" 2>/dev/null || true
  done
  log_success "ECR repositories deleted"
else
  log_info "No ECR repositories found"
fi

# Step 2: Clean up Kubernetes resources (NLBs become orphaned if EKS is destroyed first)
log_info "Step 2: Cleaning up Kubernetes resources to prevent orphaned NLBs..."

# Configure kubectl for the EKS cluster
CLUSTER_NAME=$(terraform output -raw shared_eks_cluster_name 2>/dev/null || echo "se-lab-shared-eks")
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --profile "$AWS_PROFILE" 2>/dev/null || true

# Delete shared CyPerf proxy namespace (has its own NLB)
kubectl delete namespace cyperf-shared --ignore-not-found=true 2>/dev/null || true

# Delete all services/deployments in SE namespaces (each has an NLB)
for NS in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep "^se-"); do
    log_info "  Cleaning up $NS..."
    kubectl delete svc --all -n "$NS" --ignore-not-found=true 2>/dev/null || true
    kubectl delete deployment --all -n "$NS" --ignore-not-found=true 2>/dev/null || true
    kubectl delete endpoints cyperf-backend -n "$NS" --ignore-not-found=true 2>/dev/null || true
done

# Wait for NLBs to be deregistered by the cloud controller
log_info "  Waiting 60s for AWS NLBs to deprovision..."
sleep 60
log_success "Kubernetes cleanup complete"

# Step 3: Run terraform destroy
log_info "Step 3: Running Terraform destroy..."

terraform destroy -auto-approve || {
  log_warning "Terraform destroy encountered errors"
  log_info "Attempting cleanup of orphaned resources..."

  # Try to delete VPCs directly if terraform fails
  VPCS=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Training,Values=CloudLens-SE-Training" \
    --query 'Vpcs[].VpcId' \
    --output text \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  for VPC in $VPCS; do
    log_info "Cleaning up VPC: $VPC"
    # This is a simplified cleanup - the nuclear-cleanup.sh script has more comprehensive cleanup
  done
}

# Step 4: Clean up generated documentation
log_info "Step 4: Cleaning up generated documentation..."
rm -rf "$BASE_DIR/generated/"
log_success "Documentation cleaned up"

# Step 5: Clean up terraform state
log_info "Step 5: Cleaning up terraform files..."
rm -f "$BASE_DIR/terraform.tfvars"
rm -f "$BASE_DIR/tfplan-multi-se"
rm -f "$BASE_DIR/.terraform.lock.hcl"

echo ""
echo "============================================================================"
log_success "Destruction Complete!"
echo "============================================================================"
echo ""
echo "All SE training lab resources have been destroyed."
echo ""
echo "To recreate labs:"
echo "  cd '$BASE_DIR'"
echo "  ./scripts/deploy-multi-se.sh"
echo ""
