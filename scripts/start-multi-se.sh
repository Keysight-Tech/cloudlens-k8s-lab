#!/bin/bash
# ============================================================================
# START ALL - MULTI-SE TRAINING LABS
# ============================================================================
# Starts all stopped SE training lab VMs
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
echo "  CloudLens Multi-SE Lab - Start All"
echo "============================================================================"
echo ""

# Get all stopped training instances
STOPPED_INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" \
            "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]' \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -z "$STOPPED_INSTANCES" ]; then
  log_info "No stopped instances found"
  exit 0
fi

# Count instances
INSTANCE_COUNT=$(echo "$STOPPED_INSTANCES" | grep -c "i-" || echo "0")

log_info "Found $INSTANCE_COUNT stopped instances"
echo ""
echo "Instances to start:"
echo "$STOPPED_INSTANCES" | while IFS=$'\t' read -r id name; do
  echo "  - $name ($id)"
done
echo ""

read -p "Start all instances? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  log_warning "Start cancelled"
  exit 0
fi

log_info "Starting all instances..."

# Start instances
STARTED=0
while IFS=$'\t' read -r instance_id instance_name; do
  if [ -z "$instance_id" ]; then
    continue
  fi

  log_info "Starting: $instance_name ($instance_id)"
  aws ec2 start-instances \
    --instance-ids "$instance_id" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" 2>/dev/null &
  ((STARTED++))
done <<< "$STOPPED_INSTANCES"

# Wait for starts to complete
wait 2>/dev/null || true

echo ""
echo "============================================================================"
log_success "Start Complete!"
echo "============================================================================"
echo ""
echo "Started $STARTED instances"
echo ""
echo "Note: Wait 5-15 minutes for instances to fully initialize"
echo "  - CLMS: 15 minutes"
echo "  - KVO: 15 minutes"
echo "  - vPB: 5 minutes"
echo "  - Other VMs: 2-3 minutes"
echo ""

# Check if EKS needs to be recreated
log_info "Checking EKS cluster status..."
EKS_CLUSTERS=$(aws eks list-clusters \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query "clusters[?contains(@, 'se-lab')]" \
  --output text 2>/dev/null || echo "")

if [ -z "$EKS_CLUSTERS" ]; then
  log_warning "No EKS clusters found"
  echo ""
  echo "If EKS was previously destroyed, recreate with:"
  echo "  cd '$BASE_DIR'"
  echo "  terraform apply -var='eks_enabled_for_all=true'"
  echo ""
fi
