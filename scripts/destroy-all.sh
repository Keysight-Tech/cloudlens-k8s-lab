#!/bin/bash
# destroy-all.sh - Complete infrastructure destruction

set -e

echo "================================================"
echo "⚠️  WARNING: FULL INFRASTRUCTURE DESTRUCTION"
echo "================================================"
echo ""
echo "This will DESTROY:"
echo "  - All EC2 instances (CLMS, KVO, vPB, VMs, Tool)"
echo "  - EKS cluster and worker nodes"
echo "  - NAT Gateways and Elastic IPs"
echo "  - Load Balancers"
echo "  - All EBS volumes (data will be lost)"
echo "  - All subnets, route tables, security groups"
echo "  - VPC peering connections"
echo ""
echo "What will remain:"
echo "  ✓ ECR images (CloudLens sensor, nginx, apache)"
echo "  ✓ Terraform state files"
echo ""
echo "💰 Cost after destruction: ~\$0.05/hour (\$36/month for ECR)"
echo "⏳ Time to recreate: ~45 minutes (terraform apply)"
echo ""
echo "⚠️  THIS ACTION CANNOT BE UNDONE!"
echo ""
read -p "Type 'DELETE EVERYTHING' to confirm: " confirm

if [ "$confirm" != "DELETE EVERYTHING" ]; then
  echo "Cancelled (you typed: '$confirm')"
  exit 0
fi

echo ""
echo "================================================"
echo "Starting full destruction..."
echo "================================================"
echo ""

cd "$(dirname "$0")/.."

AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"

# Delete Kubernetes resources first to avoid orphaned NLBs ($$$)
echo "Step 1: Cleaning up Kubernetes resources (NLBs, services, deployments)..."

# Configure kubectl for EKS cluster
CLUSTER_NAME=$(terraform output -raw shared_eks_cluster_name 2>/dev/null || echo "se-lab-shared-eks")
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --profile "$AWS_PROFILE" 2>/dev/null || true

# Delete shared CyPerf proxy (has its own NLB)
kubectl delete namespace cyperf-shared --ignore-not-found=true 2>/dev/null || true

# Delete all LoadBalancer services and deployments across all SE namespaces
for NS in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep "^se-"); do
    echo "  Cleaning up $NS..."
    kubectl delete svc --all -n "$NS" --ignore-not-found=true 2>/dev/null || true
    kubectl delete deployment --all -n "$NS" --ignore-not-found=true 2>/dev/null || true
    kubectl delete endpoints cyperf-backend -n "$NS" --ignore-not-found=true 2>/dev/null || true
done

# Wait for NLBs to be deregistered
echo "  Waiting 30s for NLBs to deprovision..."
sleep 30

echo ""
echo "Step 2: Running terraform destroy..."
terraform destroy -auto-approve || {
  echo "WARNING: Terraform destroy encountered errors."
  echo "Some resources may need manual cleanup."
  echo "Check: aws ec2 describe-vpcs --filters 'Name=tag:Training,Values=CloudLens-SE-Training' --profile $AWS_PROFILE --region $AWS_REGION"
}

echo ""
echo "================================================"
echo "✓ Full destruction complete"
echo "================================================"
echo ""
echo "💰 Remaining cost: ~\$0.05/hour (\$36/month for ECR images)"
echo ""
echo "What remains:"
echo "  ✓ ECR images:"
echo "    - se-demo-cloudlens-sensor:6.13.0-359"
echo "    - se-demo-cloudlens-sensor:latest"
echo "    - se-demo-nginx-app:latest"
echo "  ✓ Terraform state: terraform.tfstate"
echo ""
echo "To recreate infrastructure:"
echo "  terraform apply"
echo "  (Takes ~45 minutes)"
echo ""
echo "To delete ECR images (save \$36/month):"
echo "  aws ecr delete-repository --repository-name se-demo-cloudlens-sensor --force --profile cloudlens-lab"
echo "  aws ecr delete-repository --repository-name se-demo-nginx-app --force --profile cloudlens-lab"
echo ""
