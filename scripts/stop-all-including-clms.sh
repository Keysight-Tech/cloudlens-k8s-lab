#!/bin/bash
# stop-all-including-clms.sh - Stop ALL EC2 instances (including CLMS) after EKS destruction

set -e

echo "================================================"
echo "CloudLens Lab - Stop Everything (Max Savings)"
echo "================================================"
echo ""
echo "This will stop ALL EC2 instances including CLMS."
echo "EKS should already be destroyed (run smart-stop.sh first)"
echo ""
echo "💰 Cost after: ~\$0.18/hour (\$130/month for EBS only)"
echo "⏳ Restart time: ~2-3 minutes"
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Cancelled"
  exit 0
fi

echo ""
echo "📍 Stopping ALL EC2 instances (including CLMS)..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=cloudlens-demo" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text \
  --profile cloudlens-lab 2>/dev/null)

if [ -n "$INSTANCE_IDS" ]; then
  aws ec2 stop-instances --instance-ids $INSTANCE_IDS --profile cloudlens-lab
  echo "✓ Stopped all instances: $INSTANCE_IDS"
else
  echo "⚠ No running instances found"
fi

echo ""
echo "================================================"
echo "✓ All resources stopped"
echo "================================================"
echo ""
echo "💰 Current idle cost: ~\$0.18/hour (\$4.32/day, \$130/month)"
echo ""
echo "What's still costing money:"
echo "  - EBS volumes only (contains all your data)"
echo ""
echo "What was stopped:"
echo "  ✗ CLMS (no longer accessible)"
echo "  ✗ KVO, vPB, VMs, Tool VM"
echo ""
echo "To restart:"
echo "  ./start-vms-only.sh (starts all EC2 instances)"
echo ""
echo "To save even more:"
echo "  ./destroy-all.sh (destroys everything, keeps only ECR images)"
echo ""
