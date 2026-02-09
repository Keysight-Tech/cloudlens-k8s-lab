#!/bin/bash
# start-vms-only.sh - Start EC2 VMs only (when EKS was destroyed)

set -e

echo "================================================"
echo "CloudLens Lab - Start VMs Only"
echo "================================================"
echo ""

# Start all EC2 instances
echo "📍 Starting all stopped EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=cloudlens-demo" "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0]]' \
  --output text \
  --profile cloudlens-lab 2>/dev/null)

if [ -n "$INSTANCE_IDS" ]; then
  echo "Found stopped instances:"
  echo "$INSTANCE_IDS"
  echo ""

  INSTANCE_IDS_ONLY=$(echo "$INSTANCE_IDS" | awk '{print $1}')
  aws ec2 start-instances --instance-ids $INSTANCE_IDS_ONLY --profile cloudlens-lab
  echo "✓ Started instances"
  echo "⏳ Instances will be ready in ~2-3 minutes"
else
  echo "⚠ No stopped instances found (all may already be running)"
fi

echo ""
echo "================================================"
echo "✓ EC2 VMs starting"
echo "================================================"
echo ""
echo "⏳ Wait ~2-3 minutes for full availability"
echo ""
echo "💰 Running cost (VMs only): ~\$0.85/hour"
echo ""
echo "Access points:"
echo "  - CLMS UI: https://<CLMS_IP>"
echo "  - KVO UI: http://<KVO_IP>"
echo "  - vPB SSH: ssh admin@<VPB_IP>"
echo ""
echo "Note: EKS cluster was destroyed. To recreate:"
echo "  cd .. && terraform apply -target=aws_eks_cluster.main -target=aws_eks_node_group.main"
echo ""
echo "To stop VMs: ./stop-all.sh"
echo ""
