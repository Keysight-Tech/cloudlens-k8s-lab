#!/bin/bash
# show-access-info.sh - Display all access information for CloudLens infrastructure

set -e

echo "=========================================="
echo "CloudLens Infrastructure Access Info"
echo "=========================================="
echo ""
echo "⏳ Gathering information..."
echo ""

# Check if AWS CLI is configured
if ! aws sts get-caller-identity --profile cloudlens-lab &>/dev/null; then
  echo "⚠️  ERROR: AWS CLI not configured with 'cloudlens-lab' profile"
  echo "Run: aws configure --profile cloudlens-lab"
  exit 1
fi

# Get terraform outputs
cd "$(dirname "$0")/.."

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 WEB INTERFACES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if terraform output clms_public_ip &>/dev/null; then
  CLMS_IP=$(terraform output -raw clms_public_ip 2>/dev/null)
  KVO_IP=$(terraform output -raw kvo_public_ip 2>/dev/null)

  echo "┌─────────────────────────────────────────────────────┐"
  echo "│ CLMS (CloudLens Manager)                            │"
  echo "├─────────────────────────────────────────────────────┤"
  echo "│ URL:      https://$CLMS_IP                      │"
  echo "│ User:     admin                                     │"
  echo "│ Pass:     <CLMS_PASSWORD>                            │"
  echo "│ Note:     Accept SSL certificate warning            │"
  echo "└─────────────────────────────────────────────────────┘"
  echo ""
  echo "┌─────────────────────────────────────────────────────┐"
  echo "│ KVO (Keysight Vision One)                           │"
  echo "├─────────────────────────────────────────────────────┤"
  echo "│ URL:      http://$KVO_IP                     │"
  echo "│ User:     admin                                     │"
  echo "│ Pass:     admin                                     │"
  echo "└─────────────────────────────────────────────────────┘"
  echo ""
else
  echo "⚠️  Terraform outputs not available (run terraform apply first)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔐 SSH ACCESS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get all EC2 instances
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=cloudlens-demo" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],PublicIpAddress,PrivateIpAddress,InstanceType]' \
  --output text \
  --profile cloudlens-lab 2>/dev/null)

if [ -n "$INSTANCES" ]; then
  echo "Key Location: ~/Downloads/cloudlens-se-training.pem"
  echo ""

  # Parse and display instances
  while IFS=$'\t' read -r NAME PUBLIC_IP PRIVATE_IP TYPE; do
    case $NAME in
      *vpb*)
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│ vPB (Virtual Packet Broker)                         │"
        echo "├─────────────────────────────────────────────────────┤"
        echo "│ Command:  ssh admin@$PUBLIC_IP               │"
        echo "│ Password: <VPB_PASSWORD>                                      │"
        echo "│ Private:  $PRIVATE_IP ($TYPE)              │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        ;;
      *tool*)
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│ Tool VM (Wireshark, tcpdump, tshark)               │"
        echo "├─────────────────────────────────────────────────────┤"
        echo "│ Command:  ssh -i ~/Downloads/cloudlens-se-training.pem ubuntu@$PUBLIC_IP"
        echo "│ Private:  $PRIVATE_IP ($TYPE)              │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        ;;
      *clms*)
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│ CLMS SSH Access                                     │"
        echo "├─────────────────────────────────────────────────────┤"
        echo "│ Command:  ssh -i ~/Downloads/cloudlens-se-training.pem ubuntu@$PUBLIC_IP"
        echo "│ Private:  $PRIVATE_IP ($TYPE)              │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        ;;
      *kvo*)
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│ KVO SSH Access                                      │"
        echo "├─────────────────────────────────────────────────────┤"
        echo "│ Command:  ssh -i ~/Downloads/cloudlens-se-training.pem ubuntu@$PUBLIC_IP"
        echo "│ Private:  $PRIVATE_IP ($TYPE)              │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        ;;
      *ubuntu*)
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│ $NAME (CloudLens Sensor)                            │"
        echo "├─────────────────────────────────────────────────────┤"
        echo "│ Command:  ssh -i ~/Downloads/cloudlens-se-training.pem ubuntu@$PUBLIC_IP"
        echo "│ Private:  $PRIVATE_IP ($TYPE)              │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        ;;
      *rhel*)
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│ $NAME (CloudLens Sensor)                            │"
        echo "├─────────────────────────────────────────────────────┤"
        echo "│ Command:  ssh -i ~/Downloads/cloudlens-se-training.pem ec2-user@$PUBLIC_IP"
        echo "│ Private:  $PRIVATE_IP ($TYPE)              │"
        echo "│ Note:     Username is 'ec2-user' not 'ubuntu'       │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        ;;
      *windows*)
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│ $NAME (CloudLens Sensor)                            │"
        echo "├─────────────────────────────────────────────────────┤"
        echo "│ Protocol: RDP (Remote Desktop)                      │"
        echo "│ Address:  $PUBLIC_IP                          │"
        echo "│ Private:  $PRIVATE_IP ($TYPE)              │"
        echo "│ User:     Administrator                             │"
        echo "│ Password: Get with: aws ec2 get-password-data ...   │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        ;;
    esac
  done <<< "$INSTANCES"
else
  echo "⚠️  No running EC2 instances found"
  echo "Start instances with: ./start-all.sh"
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "☸️  KUBERNETES (EKS) ACCESS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if EKS cluster exists
if aws eks describe-cluster --name se-demo-eks-cluster --region us-west-2 --profile cloudlens-lab &>/dev/null; then
  echo "Cluster: se-demo-eks-cluster"
  echo ""
  echo "Configure kubectl (run once):"
  echo "  aws eks update-kubeconfig --region us-west-2 \\"
  echo "    --name se-demo-eks-cluster --profile cloudlens-lab"
  echo ""

  # Try to get LoadBalancer info if kubectl is configured
  if kubectl cluster-info &>/dev/null; then
    echo "LoadBalancer URLs:"

    NGINX_LB=$(kubectl get svc nginx-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ -n "$NGINX_LB" ]; then
      echo "  Nginx:  http://$NGINX_LB"
    else
      echo "  Nginx:  Not deployed or pending"
    fi

    APACHE_LB=$(kubectl get svc apache-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ -n "$APACHE_LB" ]; then
      echo "  Apache: http://$APACHE_LB"
    else
      echo "  Apache: Not deployed or pending"
    fi

    echo ""
    echo "Quick Commands:"
    echo "  kubectl get nodes              # View worker nodes"
    echo "  kubectl get pods -A            # View all pods"
    echo "  kubectl get svc                # View services"
  else
    echo "⚠️  kubectl not configured yet (run command above)"
  fi
else
  echo "⚠️  EKS cluster not found (may be destroyed)"
  echo "Recreate with: cd .. && terraform apply"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 INFRASTRUCTURE STATUS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Count running instances
RUNNING_COUNT=$(echo "$INSTANCES" | grep -c . 2>/dev/null || echo "0")
echo "EC2 Instances Running: $RUNNING_COUNT"

# Check EKS
if aws eks describe-cluster --name se-demo-eks-cluster --region us-west-2 --profile cloudlens-lab &>/dev/null; then
  EKS_STATUS=$(aws eks describe-cluster --name se-demo-eks-cluster --region us-west-2 --profile cloudlens-lab --query 'cluster.status' --output text)
  echo "EKS Cluster Status: $EKS_STATUS"

  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | xargs)
  if [ "$NODE_COUNT" -gt 0 ]; then
    echo "EKS Worker Nodes: $NODE_COUNT"
  fi
else
  echo "EKS Cluster Status: Not deployed"
fi

# Check NAT Gateways
NAT_COUNT=$(aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --region us-west-2 \
  --profile cloudlens-lab \
  --query 'NatGateways | length(@)' \
  --output text 2>/dev/null || echo "0")
echo "NAT Gateways: $NAT_COUNT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💰 ESTIMATED COSTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Calculate estimated cost
COST=0
EC2_COST=0
EKS_COST=0
NAT_COST=0

# EC2 costs (rough estimate)
EC2_COST=$(echo "$RUNNING_COUNT * 0.10" | bc 2>/dev/null || echo "0")

# EKS costs
if [ "$EKS_STATUS" = "ACTIVE" ]; then
  EKS_COST=0.10
fi

# NAT costs
NAT_COST=$(echo "$NAT_COUNT * 0.045" | bc 2>/dev/null || echo "0")

TOTAL_COST=$(echo "$EC2_COST + $EKS_COST + $NAT_COST" | bc 2>/dev/null || echo "0")

echo "Current hourly cost (estimate): \$$TOTAL_COST/hour"
echo "  - EC2 instances: \$$EC2_COST/hour"
echo "  - EKS control plane: \$$EKS_COST/hour"
echo "  - NAT Gateways: \$$NAT_COST/hour"
echo ""
echo "Daily estimate: \$$(echo "$TOTAL_COST * 24" | bc)/day"
echo "Monthly estimate: \$$(echo "$TOTAL_COST * 730" | bc)/month"
echo ""

if [ "$RUNNING_COUNT" -gt 0 ]; then
  echo "💡 To save costs when not in use:"
  echo "   ./smart-stop.sh    # Saves ~\$0.92/hour (\$662/month)"
  echo "   ./stop-all.sh      # Saves ~\$0.90/hour (\$657/month)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 QUICK COMMANDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Start infrastructure:   ./start-all.sh"
echo "Stop infrastructure:    ./smart-stop.sh (recommended)"
echo "Get this info again:    ./show-access-info.sh"
echo ""
echo "Full documentation:     ../ACCESS-AUTHENTICATION-GUIDE.md"
echo "Quick reference:        ../QUICK-ACCESS-CARD.md"
echo ""
echo "=========================================="
