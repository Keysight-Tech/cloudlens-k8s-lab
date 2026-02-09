#!/bin/bash
# start-all.sh - Start all SE Training Lab EC2 instances and scale EKS nodes back up

set -e

AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"
EKS_CLUSTER="se-lab-shared-eks"

echo "================================================"
echo "CloudLens SE Training Lab - Start All Resources"
echo "================================================"
echo ""
echo "AWS Profile: $AWS_PROFILE"
echo "AWS Region:  $AWS_REGION"
echo ""

# Start all EC2 instances with Training tag
echo "📍 Starting all EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Training,Values=CloudLens-SE-Training" "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" 2>/dev/null)

if [ -n "$INSTANCE_IDS" ]; then
  INSTANCE_COUNT=$(echo $INSTANCE_IDS | wc -w | tr -d ' ')
  echo "  Found $INSTANCE_COUNT stopped instances"
  aws ec2 start-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
  echo "✓ Start command sent to $INSTANCE_COUNT instances"
else
  echo "⚠ No stopped instances found (all may already be running)"
fi

# Scale EKS node groups back up
echo ""
echo "📍 Scaling EKS node groups back up..."

NODE_GROUPS=$(aws eks list-nodegroups \
  --cluster-name "$EKS_CLUSTER" \
  --query 'nodegroups[]' \
  --output text \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" 2>/dev/null || echo "")

if [ -n "$NODE_GROUPS" ]; then
  for NG in $NODE_GROUPS; do
    # System nodes scale to 2, SE dedicated nodes scale to 1
    if [[ "$NG" == *"system"* ]]; then
      DESIRED=2
    else
      DESIRED=1
    fi
    echo "  Scaling $NG to $DESIRED..."
    aws eks update-nodegroup-config \
      --cluster-name "$EKS_CLUSTER" \
      --nodegroup-name "$NG" \
      --scaling-config minSize=$DESIRED,maxSize=10,desiredSize=$DESIRED \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" >/dev/null 2>&1 && echo "  ✓ $NG scaled to $DESIRED" || echo "  ⚠ Failed to scale $NG"
  done
else
  echo "⚠ No EKS node groups found (cluster may not exist)"
fi

echo ""
echo "================================================"
echo "✓ Start commands sent - resources starting"
echo "================================================"
echo ""
echo "⏳ Wait times:"
echo "  - EC2 instances: ~2-3 minutes"
echo "  - CLMS/KVO initialization: ~10-15 minutes"
echo "  - EKS nodes: ~3-5 minutes"
echo ""
echo "💰 Estimated running cost (20 labs):"
echo "  - EC2 instances:     ~\$12,000/month"
echo "  - EKS nodes:         ~\$550/month"
echo "  - Other (storage, etc): ~\$1,200/month"
echo "  - Total running:     ~\$13,750/month (~\$19/hour)"
echo ""
echo "To check instance status:"
echo "  aws ec2 describe-instances --filters \"Name=tag:Training,Values=CloudLens-SE-Training\" --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==\`Name\`].Value|[0]]' --output table --profile $AWS_PROFILE --region $AWS_REGION"
echo ""
echo "To stop when done: ./scripts/stop-all.sh"
echo ""
