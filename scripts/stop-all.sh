#!/bin/bash
# stop-all.sh - Stop all SE Training Lab EC2 instances and scale EKS nodes to 0

set -e

AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"
EKS_CLUSTER="se-lab-shared-eks"

echo "================================================"
echo "CloudLens SE Training Lab - Stop All Resources"
echo "================================================"
echo ""
echo "AWS Profile: $AWS_PROFILE"
echo "AWS Region:  $AWS_REGION"
echo ""

# Stop all EC2 instances with Training tag
echo "📍 Stopping all EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" 2>/dev/null)

if [ -n "$INSTANCE_IDS" ]; then
  INSTANCE_COUNT=$(echo $INSTANCE_IDS | wc -w | tr -d ' ')
  echo "  Found $INSTANCE_COUNT running instances"
  aws ec2 stop-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
  echo "✓ Stop command sent to $INSTANCE_COUNT instances"
else
  echo "⚠ No running instances found"
fi

# Scale all EKS node groups to 0
echo ""
echo "📍 Scaling EKS node groups to 0..."

NODE_GROUPS=$(aws eks list-nodegroups \
  --cluster-name "$EKS_CLUSTER" \
  --query 'nodegroups[]' \
  --output text \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" 2>/dev/null || echo "")

if [ -n "$NODE_GROUPS" ]; then
  for NG in $NODE_GROUPS; do
    echo "  Scaling $NG to 0..."
    aws eks update-nodegroup-config \
      --cluster-name "$EKS_CLUSTER" \
      --nodegroup-name "$NG" \
      --scaling-config minSize=0,maxSize=10,desiredSize=0 \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" >/dev/null 2>&1 && echo "  ✓ $NG scaled to 0" || echo "  ⚠ Failed to scale $NG"
  done
else
  echo "⚠ No EKS node groups found (cluster may not exist)"
fi

echo ""
echo "================================================"
echo "✓ Stop commands sent - instances stopping"
echo "================================================"
echo ""
echo "⏳ Instances will fully stop in ~2-3 minutes"
echo ""
echo "💰 Estimated idle cost (stopped):"
echo "  - EKS Control Plane:  ~\$73/month"
echo "  - EBS Storage:        ~\$600/month (20 labs)"
echo "  - NAT Gateways (2):   ~\$65/month"
echo "  - Load Balancers:     ~\$400/month"
echo "  - Total idle:         ~\$1,138/month (~\$1.58/hour)"
echo ""
echo "To restart: ./scripts/start-all.sh"
echo ""
