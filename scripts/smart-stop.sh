#!/bin/bash
# smart-stop.sh - Cost-optimized stop (Destroy EKS, keep CLMS running, stop other VMs)

set -e

echo "================================================"
echo "CloudLens Lab - Smart Stop (Recommended)"
echo "================================================"
echo ""
echo "This will:"
echo "  1. Destroy EKS cluster (saves \$0.28/hour)"
echo "  2. Destroy NAT Gateways (saves \$0.09/hour)"
echo "  3. Stop all VMs except CLMS (saves \$0.55/hour)"
echo "  4. Keep CLMS running for sensor management"
echo ""
echo "Total savings: \$0.92/hour (\$662/month)"
echo "Remaining cost: \$0.36/hour (\$259/month)"
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Cancelled"
  exit 0
fi

echo ""
echo "================================================"
echo "Step 1: Destroying EKS cluster and NAT Gateways..."
echo "================================================"
cd "$(dirname "$0")/.."

terraform destroy \
  -target=aws_eks_cluster.main \
  -target=aws_eks_node_group.main \
  -target=aws_nat_gateway.eks_az1 \
  -target=aws_nat_gateway.eks_az2 \
  -target=aws_eip.eks_nat_az1 \
  -target=aws_eip.eks_nat_az2 \
  -auto-approve

echo ""
echo "================================================"
echo "Step 2: Stopping all VMs except CLMS..."
echo "================================================"

# Get CLMS instance ID
CLMS_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*clms*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text \
  --profile cloudlens-lab 2>/dev/null)

if [ -n "$CLMS_ID" ]; then
  echo "✓ CLMS instance found: $CLMS_ID (will keep running)"
else
  echo "⚠ CLMS instance not found"
fi

# Stop all other instances
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=cloudlens-demo" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0]]' \
  --output text \
  --profile cloudlens-lab 2>/dev/null | grep -v clms | awk '{print $1}')

if [ -n "$INSTANCE_IDS" ]; then
  aws ec2 stop-instances --instance-ids $INSTANCE_IDS --profile cloudlens-lab
  echo "✓ Stopped instances: $INSTANCE_IDS"
else
  echo "⚠ No other running instances found"
fi

echo ""
echo "================================================"
echo "✓ Smart Stop Complete"
echo "================================================"
echo ""
echo "💰 Current idle cost: ~\$0.36/hour (\$8.64/day, \$259/month)"
echo ""
echo "What's still running:"
echo "  ✓ CLMS (t3.xlarge): Always accessible at https://<CLMS_IP>"
echo "  ✓ EBS volumes: Preserved with all data"
echo ""
echo "What was destroyed:"
echo "  ✗ EKS control plane (saved \$0.10/hour)"
echo "  ✗ EKS worker nodes (saved \$0.08/hour)"
echo "  ✗ NAT Gateways (saved \$0.09/hour)"
echo "  ✗ Load Balancers (saved \$0.045/hour)"
echo ""
echo "To restart VMs: ./start-vms-only.sh (2 minutes)"
echo "To recreate EKS: cd .. && terraform apply (15 minutes)"
echo "To stop CLMS too: ./stop-all-including-clms.sh (saves another \$0.17/hour)"
echo ""
