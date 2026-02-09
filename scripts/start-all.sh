#!/bin/bash
# start-all.sh - Start all lab EC2 instances and scale EKS nodes back up

set -e

AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DEPLOYMENT_PREFIX="${DEPLOYMENT_PREFIX:-cloudlens-lab}"

echo "================================================"
echo "CloudLens Lab - Start All Resources"
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
    --filters "Name=tag:Name,Values=${DEPLOYMENT_PREFIX}*" "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" 2>/dev/null)
fi

if [ -n "$INSTANCE_IDS" ]; then
  INSTANCE_COUNT=$(echo $INSTANCE_IDS | wc -w | tr -d ' ')
  echo "Starting $INSTANCE_COUNT instances..."
  aws ec2 start-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
  echo "Start command sent to $INSTANCE_COUNT instances"
else
  echo "No stopped instances found (all may already be running)"
fi

# Scale EKS node groups back up
echo ""
EKS_CLUSTER="${DEPLOYMENT_PREFIX}-eks-cluster"
NODE_GROUPS=$(aws eks list-nodegroups \
  --cluster-name "$EKS_CLUSTER" \
  --query 'nodegroups[]' \
  --output text \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" 2>/dev/null || echo "")

if [ -n "$NODE_GROUPS" ]; then
  echo "Scaling EKS node groups back up..."
  for NG in $NODE_GROUPS; do
    echo "  Scaling $NG to 2..."
    aws eks update-nodegroup-config \
      --cluster-name "$EKS_CLUSTER" \
      --nodegroup-name "$NG" \
      --scaling-config minSize=1,maxSize=4,desiredSize=2 \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" >/dev/null 2>&1 && echo "  $NG scaled to 2" || echo "  Failed to scale $NG"
  done
else
  echo "No EKS node groups found (cluster may not exist or EKS not enabled)"
fi

echo ""
echo "================================================"
echo "Start commands sent - resources starting"
echo "================================================"
echo ""
echo "Wait times:"
echo "  - EC2 instances: ~2-3 minutes"
echo "  - CLMS/KVO initialization: ~10-15 minutes"
echo "  - EKS nodes: ~3-5 minutes"
echo ""
echo "To check instance status:"
echo "  aws ec2 describe-instances --filters \"Name=tag:Name,Values=${DEPLOYMENT_PREFIX}*\" --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==\`Name\`].Value|[0]]' --output table --profile $AWS_PROFILE --region $AWS_REGION"
echo ""
echo "To stop when done: ./scripts/stop-all.sh"
echo ""
