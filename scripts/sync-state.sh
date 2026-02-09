#!/bin/bash
# Sync existing EKS resources into Terraform state

CLUSTER="se-lab-shared-eks"
AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Syncing Terraform state with existing AWS resources..."

# Import addons
echo "Importing EKS addons..."
terraform import 'aws_eks_addon.shared_coredns[0]' "${CLUSTER}:coredns" 2>/dev/null || echo "coredns already in state or doesn't exist"
terraform import 'aws_eks_addon.shared_ebs_csi_driver[0]' "${CLUSTER}:aws-ebs-csi-driver" 2>/dev/null || echo "ebs-csi already in state or doesn't exist"

# Get list of existing node groups
echo "Finding existing node groups..."
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'nodegroups[*]' --output text 2>/dev/null)

for ng in $NODEGROUPS; do
    echo "Processing node group: $ng"

    # Determine the terraform resource address
    if [[ "$ng" == *"system-nodes"* ]]; then
        terraform import 'aws_eks_node_group.system[0]' "${CLUSTER}:${ng}" 2>/dev/null || echo "  Already in state"
    elif [[ "$ng" =~ se-lab-se-([0-9]+)-node ]]; then
        se_num="${BASH_REMATCH[1]}"
        se_id="se-${se_num}"
        terraform import "aws_eks_node_group.se_dedicated[\"${se_id}\"]" "${CLUSTER}:${ng}" 2>/dev/null || echo "  Already in state"
    fi
done

echo ""
echo "State sync complete. Now run: terraform apply -parallelism=5"
