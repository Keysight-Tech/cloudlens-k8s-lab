#!/bin/bash
# stop-all.sh - Stop all lab EC2 instances and scale EKS nodes to 0

set -e

AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DEPLOYMENT_PREFIX="${DEPLOYMENT_PREFIX:-cloudlens-lab}"

echo "================================================"
echo "CloudLens Lab - Stop All Resources"
echo "================================================"
echo ""
echo "AWS Profile: $AWS_PROFILE"
echo "AWS Region:  $AWS_REGION"
echo "Prefix:      $DEPLOYMENT_PREFIX"
echo ""

# Get instance IDs from terraform output if available
INSTANCE_IDS=""
if [ -d "../terraform" ] || [ -d "terraform" ]; then
  TF_DIR=$([ -d "terraform" ] && echo "terraform" || echo "../terraform")
  INSTANCE_IDS=$(terraform -chdir="$TF_DIR" output -json all_instance_ids 2>/dev/null | jq -r '.[]' | tr '\n' ' ' || echo "")
fi

# Fallback: find instances by deployment prefix tag
if [ -z "$INSTANCE_IDS" ]; then
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${DEPLOYMENT_PREFIX}*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" 2>/dev/null)
fi

if [ -n "$INSTANCE_IDS" ]; then
  INSTANCE_COUNT=$(echo $INSTANCE_IDS | wc -w | tr -d ' ')
  echo "Stopping $INSTANCE_COUNT instances..."
  aws ec2 stop-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
  echo "Stop command sent to $INSTANCE_COUNT instances"
else
  echo "No running instances found"
fi

# Scale EKS node groups to 0
echo ""
EKS_CLUSTER="${DEPLOYMENT_PREFIX}-eks-cluster"
NODE_GROUPS=$(aws eks list-nodegroups \
  --cluster-name "$EKS_CLUSTER" \
  --query 'nodegroups[]' \
  --output text \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" 2>/dev/null || echo "")

if [ -n "$NODE_GROUPS" ]; then
  echo "Scaling EKS node groups to 0..."
  for NG in $NODE_GROUPS; do
    aws eks update-nodegroup-config \
      --cluster-name "$EKS_CLUSTER" \
      --nodegroup-name "$NG" \
      --scaling-config minSize=0,maxSize=4,desiredSize=0 \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" >/dev/null 2>&1 && echo "  $NG scaled to 0" || echo "  Failed to scale $NG"
  done
else
  echo "No EKS node groups found (cluster may not exist or EKS not enabled)"
fi

echo ""
echo "================================================"
echo "Stop commands sent - instances stopping"
echo "================================================"
echo ""
echo "Instances will fully stop in ~2-3 minutes"
echo ""
echo "Note: EKS control plane charges (~\$73/month) continue while stopped."
echo "Use 'terraform destroy' to remove everything if not needed."
echo ""
echo "To restart: ./scripts/start-all.sh"
echo ""
