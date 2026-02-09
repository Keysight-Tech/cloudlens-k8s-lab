#!/bin/bash
# ============================================================================
# SMART STOP - MULTI-SE TRAINING LABS
# ============================================================================
# Cost-optimized stop for all SE training lab environments
# - Destroys EKS clusters (most expensive)
# - Destroys NAT Gateways
# - Stops all VMs except CLMS (keeps sensor management available)
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
echo "  CloudLens Multi-SE Lab - Smart Stop"
echo "============================================================================"
echo ""
echo "This will for ALL SE labs:"
echo "  1. Destroy EKS clusters (saves ~\$0.10/hour per cluster)"
echo "  2. Destroy NAT Gateways (saves ~\$0.09/hour per lab)"
echo "  3. Stop all VMs except CLMS (saves ~\$0.85/hour per lab)"
echo "  4. Keep CLMS running for sensor management"
echo ""

# Count labs
LAB_COUNT=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" \
  --query 'Vpcs[].VpcId' \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" 2>/dev/null | wc -w | tr -d ' ')

if [ "$LAB_COUNT" -eq 0 ]; then
  log_warning "No SE training labs found"
  exit 0
fi

# Calculate savings
EKS_SAVINGS=$(echo "$LAB_COUNT * 0.19" | bc)
VM_SAVINGS=$(echo "$LAB_COUNT * 0.85" | bc)
TOTAL_SAVINGS=$(echo "$EKS_SAVINGS + $VM_SAVINGS" | bc)

echo "Labs found: $LAB_COUNT"
echo "Estimated savings: ~\$$TOTAL_SAVINGS/hour"
echo ""

read -p "Continue with smart stop? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  log_warning "Smart stop cancelled"
  exit 0
fi

cd "$BASE_DIR"

# Step 1: Destroy EKS clusters and NAT gateways
log_info "Step 1: Destroying EKS clusters and NAT gateways..."

# Get list of EKS clusters with our tag
EKS_CLUSTERS=$(aws eks list-clusters \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query "clusters[?contains(@, 'se-lab')]" \
  --output text 2>/dev/null || echo "")

if [ -n "$EKS_CLUSTERS" ]; then
  log_info "Found EKS clusters to destroy:"
  echo "$EKS_CLUSTERS" | tr '\t' '\n' | sed 's/^/  - /'

  for CLUSTER in $EKS_CLUSTERS; do
    log_info "Destroying EKS cluster: $CLUSTER"

    # Delete node groups first
    NODE_GROUPS=$(aws eks list-nodegroups \
      --cluster-name "$CLUSTER" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query 'nodegroups[]' \
      --output text 2>/dev/null || echo "")

    for NG in $NODE_GROUPS; do
      log_info "  Deleting node group: $NG"
      aws eks delete-nodegroup \
        --cluster-name "$CLUSTER" \
        --nodegroup-name "$NG" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null &
    done

    # Wait for node groups to be deleted
    wait 2>/dev/null || true

    # Delete cluster
    aws eks delete-cluster \
      --name "$CLUSTER" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" 2>/dev/null &
  done

  log_info "EKS clusters deletion initiated (running in background)"
else
  log_info "No EKS clusters found"
fi

# Delete NAT Gateways
log_info "Destroying NAT Gateways..."
NAT_GWS=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Training,Values=CloudLens-SE-Training" \
           "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId' \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$NAT_GWS" ]; then
  for NAT in $NAT_GWS; do
    log_info "  Deleting NAT Gateway: $NAT"
    aws ec2 delete-nat-gateway \
      --nat-gateway-id "$NAT" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" 2>/dev/null &
  done
  log_info "NAT Gateway deletion initiated"
else
  log_info "No NAT Gateways found"
fi

# Step 2: Stop all VMs except CLMS
log_info "Step 2: Stopping all VMs except CLMS..."

# Get all training instances
ALL_INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]' \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" 2>/dev/null || echo "")

# Get CLMS instances
CLMS_INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" \
            "Name=tag:Name,Values=*clms*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" 2>/dev/null || echo "")

CLMS_LIST=" $CLMS_INSTANCES "

STOPPED=0
KEPT=0

while IFS=$'\t' read -r instance_id instance_name; do
  if [ -z "$instance_id" ]; then
    continue
  fi

  if [[ "$CLMS_LIST" =~ " $instance_id " ]]; then
    log_info "Keeping running (CLMS): $instance_name ($instance_id)"
    ((KEPT++))
  else
    log_info "Stopping: $instance_name ($instance_id)"
    aws ec2 stop-instances \
      --instance-ids "$instance_id" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" 2>/dev/null &
    ((STOPPED++))
  fi
done <<< "$ALL_INSTANCES"

# Wait for stops to complete
wait 2>/dev/null || true

echo ""
echo "============================================================================"
log_success "Smart Stop Complete!"
echo "============================================================================"
echo ""
echo "Summary:"
echo "  - VMs stopped: $STOPPED"
echo "  - CLMS kept running: $KEPT"
echo "  - EKS clusters: Deletion in progress"
echo "  - NAT Gateways: Deletion in progress"
echo ""
echo "Estimated savings: ~\$$TOTAL_SAVINGS/hour"
echo ""
echo "To restart all labs: ./scripts/start-multi-se.sh"
echo "To recreate EKS: terraform apply -var='eks_enabled_for_all=true'"
echo ""
