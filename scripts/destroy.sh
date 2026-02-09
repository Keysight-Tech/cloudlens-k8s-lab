#!/bin/bash
# ============================================================================
# CLOUDLENS SE TRAINING LAB - DESTROY SCRIPT
# ============================================================================
# Cleanly destroys all resources, handling AWS dependencies automatically
# Runs fully automatically without prompts
# Usage: ./destroy.sh
# ============================================================================

# Don't exit on first error - we want to continue cleanup
set +e

# ============================================================================
# DIRECTORY SETUP - Ensure paths work regardless of where script is invoked
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}CloudLens SE Training Lab - Destroy${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

wait_for_lb_deletion() {
    local vpc_id="$1"
    local max_wait=300  # 5 minutes max
    local elapsed=0
    local interval=10

    echo "  Waiting for load balancers to be fully deleted..."

    while [ $elapsed -lt $max_wait ]; do
        local classic_count=$(aws elb describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --query "LoadBalancerDescriptions[?VPCId=='$vpc_id'] | length(@)" --output text 2>/dev/null || echo "0")
        local v2_count=$(aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --query "LoadBalancers[?VpcId=='$vpc_id'] | length(@)" --output text 2>/dev/null || echo "0")

        if [ "$classic_count" = "0" ] && [ "$v2_count" = "0" ]; then
            echo -e "  ${GREEN}✓ All load balancers deleted${NC}"
            return 0
        fi

        echo "    Still waiting... (Classic: $classic_count, V2: $v2_count) - ${elapsed}s/${max_wait}s"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo -e "  ${YELLOW}Warning: Some load balancers may still be deleting${NC}"
    return 0
}

wait_for_nat_deletion() {
    local vpc_id="$1"
    local max_wait=180  # 3 minutes max
    local elapsed=0
    local interval=10

    echo "  Waiting for NAT gateways to be fully deleted..."

    while [ $elapsed -lt $max_wait ]; do
        local nat_count=$(aws ec2 describe-nat-gateways --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available,pending,deleting" \
            --query "NatGateways | length(@)" --output text 2>/dev/null || echo "0")

        if [ "$nat_count" = "0" ]; then
            echo -e "  ${GREEN}✓ All NAT gateways deleted${NC}"
            return 0
        fi

        echo "    Still waiting... ($nat_count remaining) - ${elapsed}s/${max_wait}s"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo -e "  ${YELLOW}Warning: Some NAT gateways may still be deleting${NC}"
    return 0
}

wait_for_eni_cleanup() {
    local vpc_id="$1"
    local max_wait=120  # 2 minutes max
    local elapsed=0
    local interval=10

    echo "  Waiting for ENIs to be released..."

    while [ $elapsed -lt $max_wait ]; do
        local eni_count=$(aws ec2 describe-network-interfaces --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query "NetworkInterfaces | length(@)" --output text 2>/dev/null || echo "0")

        if [ "$eni_count" = "0" ]; then
            echo -e "  ${GREEN}✓ All ENIs released${NC}"
            return 0
        fi

        echo "    Still waiting... ($eni_count ENIs remaining) - ${elapsed}s/${max_wait}s"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo -e "  ${YELLOW}Warning: Some ENIs may still exist${NC}"
    return 0
}

wait_for_nodegroup_deletion() {
    local cluster_name="$1"
    local max_wait=600  # 10 minutes max
    local elapsed=0
    local interval=15

    echo "  Waiting for EKS node groups to be fully deleted..."

    while [ $elapsed -lt $max_wait ]; do
        local ng_count=$(aws eks list-nodegroups --cluster-name "$cluster_name" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --query "nodegroups | length(@)" --output text 2>/dev/null || echo "0")

        if [ "$ng_count" = "0" ]; then
            echo -e "  ${GREEN}✓ All node groups deleted${NC}"
            return 0
        fi

        echo "    Still waiting... ($ng_count node groups remaining) - ${elapsed}s/${max_wait}s"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo -e "  ${YELLOW}Warning: Some node groups may still be deleting${NC}"
    return 0
}

# ============================================================================
# CHECK AWS CREDENTIALS
# ============================================================================
echo -e "${YELLOW}Checking AWS credentials...${NC}"
if ! aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" &>/dev/null; then
    echo -e "${RED}AWS credentials expired. Re-authenticating...${NC}"
    aws sso login --profile "$AWS_PROFILE"
fi
echo -e "${GREEN}✓ AWS credentials valid${NC}"
echo ""

# ============================================================================
# GET VPC ID (try multiple methods)
# ============================================================================
echo -e "${YELLOW}Finding VPC ID...${NC}"

# Method 1: Try terraform state
VPC_ID=$(terraform state show aws_vpc.main 2>/dev/null | grep "^    id" | awk -F'"' '{print $2}')

# Method 2: Try terraform output (filter out warnings)
if [ -z "$VPC_ID" ]; then
    VPC_ID=$(terraform output -raw shared_vpc_id 2>/dev/null | grep -E "^vpc-" | head -1)
fi

# Method 3: Find VPC by tag
if [ -z "$VPC_ID" ]; then
    VPC_ID=$(aws ec2 describe-vpcs --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=se-lab-shared-vpc" \
        --query "Vpcs[0].VpcId" --output text 2>/dev/null)
    if [ "$VPC_ID" = "None" ]; then
        VPC_ID=""
    fi
fi

# Method 4: Find VPC by CIDR
if [ -z "$VPC_ID" ]; then
    VPC_ID=$(aws ec2 describe-vpcs --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --filters "Name=cidr-block,Values=10.100.0.0/16" \
        --query "Vpcs[0].VpcId" --output text 2>/dev/null)
    if [ "$VPC_ID" = "None" ]; then
        VPC_ID=""
    fi
fi

if [ -z "$VPC_ID" ]; then
    echo -e "${YELLOW}No VPC found. Running terraform destroy to clean up state...${NC}"
    terraform destroy -auto-approve 2>/dev/null || true
    rm -rf "$BASE_DIR/generated" 2>/dev/null || true
    rm -f "$BASE_DIR/.post-deploy-state" 2>/dev/null || true
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}Destroy complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    exit 0
fi

echo -e "${GREEN}Found VPC: $VPC_ID${NC}"
echo ""

echo -e "${BLUE}Cleaning up AWS dependencies before destroy...${NC}"
echo ""

# ============================================================================
# Step 0: Delete Public ECR Repository Images and Helm Charts
# ============================================================================
echo -e "${YELLOW}Step 0: Cleaning up Public ECR repositories...${NC}"

# Public ECR is always in us-east-1
PUBLIC_ECR_REGION="us-east-1"
# Repo name must match Helm chart name for helm push to work
ECR_REPO_NAME="cloudlens-sensor"

# Check if public ECR repository exists
if aws ecr-public describe-repositories --repository-names "$ECR_REPO_NAME" \
    --profile "$AWS_PROFILE" --region "$PUBLIC_ECR_REGION" &>/dev/null; then

    echo "  Found public ECR repository: $ECR_REPO_NAME"

    # Delete all images in the repository (required before repo deletion)
    echo "  Deleting all images from repository..."
    IMAGE_IDS=$(aws ecr-public describe-images --repository-name "$ECR_REPO_NAME" \
        --profile "$AWS_PROFILE" --region "$PUBLIC_ECR_REGION" \
        --query "imageDetails[*].{imageDigest:imageDigest}" --output json 2>/dev/null)

    if [ -n "$IMAGE_IDS" ] && [ "$IMAGE_IDS" != "[]" ]; then
        # Delete images in batches
        echo "$IMAGE_IDS" | jq -c '.[]' | while read -r image; do
            digest=$(echo "$image" | jq -r '.imageDigest')
            echo "    Deleting image: ${digest:0:20}..."
            aws ecr-public batch-delete-image --repository-name "$ECR_REPO_NAME" \
                --image-ids imageDigest="$digest" \
                --profile "$AWS_PROFILE" --region "$PUBLIC_ECR_REGION" 2>/dev/null || true
        done
    fi

    # Delete the repository itself
    echo "  Deleting public ECR repository: $ECR_REPO_NAME"
    aws ecr-public delete-repository --repository-name "$ECR_REPO_NAME" --force \
        --profile "$AWS_PROFILE" --region "$PUBLIC_ECR_REGION" 2>/dev/null || true

    echo -e "${GREEN}✓ Public ECR repository cleaned up${NC}"
else
    echo "  No public ECR repository found (may have been already deleted)"
fi

# Also check for any private ECR repos (legacy cleanup)
PRIVATE_ECR_REPO="cloudlens-sensor"
if aws ecr describe-repositories --repository-names "$PRIVATE_ECR_REPO" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" &>/dev/null 2>&1; then

    echo "  Found private ECR repository: $PRIVATE_ECR_REPO (legacy)"
    echo "  Deleting private ECR repository..."
    aws ecr delete-repository --repository-name "$PRIVATE_ECR_REPO" --force \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    echo -e "${GREEN}✓ Private ECR repository cleaned up${NC}"
fi

echo ""

# ============================================================================
# Step 1: Delete Kubernetes LoadBalancer Services
# ============================================================================
echo -e "${YELLOW}Step 1: Deleting Kubernetes LoadBalancer services...${NC}"

EKS_CLUSTER=$(terraform output -raw shared_eks_cluster_name 2>/dev/null | grep -v "Warning" | head -1)
if [ -z "$EKS_CLUSTER" ]; then
    EKS_CLUSTER="se-lab-shared-eks"
fi

if aws eks describe-cluster --name "$EKS_CLUSTER" --profile "$AWS_PROFILE" --region "$AWS_REGION" &>/dev/null; then
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER" --profile "$AWS_PROFILE" 2>/dev/null || true

    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        # Delete all LoadBalancer services in SE namespaces
        for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep "^se-"); do
            echo "  Deleting services in namespace: $ns"
            kubectl delete svc --all -n "$ns" --ignore-not-found=true --wait=false 2>/dev/null || true
        done

        # Delete any LoadBalancer services anywhere
        for svc in $(kubectl get svc --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
            ns=$(echo "$svc" | cut -d'/' -f1)
            name=$(echo "$svc" | cut -d'/' -f2)
            echo "  Deleting LoadBalancer service: $ns/$name"
            kubectl delete svc "$name" -n "$ns" --ignore-not-found=true --wait=false 2>/dev/null || true
        done

        echo -e "${GREEN}✓ K8s services deletion initiated${NC}"
    else
        echo -e "${YELLOW}  kubectl not configured, skipping K8s cleanup...${NC}"
    fi
else
    echo "  EKS cluster not found, skipping K8s cleanup..."
fi
echo ""

sleep 10

# ============================================================================
# Step 2: Delete ALL Load Balancers in VPC
# ============================================================================
echo -e "${YELLOW}Step 2: Deleting Load Balancers...${NC}"

# Delete target groups
echo "  Deleting target groups..."
for tg_arn in $(aws elbv2 describe-target-groups --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
    echo "    Deleting target group: ${tg_arn##*/}"
    aws elbv2 delete-target-group --target-group-arn "$tg_arn" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

# Delete Classic ELBs (including K8s-created ones)
echo "  Deleting Classic Load Balancers..."
for elb in $(aws elb describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null); do
    echo "    Deleting Classic ELB: $elb"
    aws elb delete-load-balancer --load-balancer-name "$elb" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

# Delete NLBs and ALBs
echo "  Deleting Network/Application Load Balancers..."
for arn in $(aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    lb_name=$(echo "$arn" | rev | cut -d'/' -f2 | rev)
    echo "    Deleting ELBv2: $lb_name"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

echo -e "${GREEN}✓ Load balancer deletion initiated${NC}"
echo ""

wait_for_lb_deletion "$VPC_ID"
echo ""

# ============================================================================
# Step 3: Delete EKS Node Groups and Cluster
# ============================================================================
echo -e "${YELLOW}Step 3: Deleting EKS resources...${NC}"

if aws eks describe-cluster --name "$EKS_CLUSTER" --profile "$AWS_PROFILE" --region "$AWS_REGION" &>/dev/null; then
    # Delete node groups first
    for ng in $(aws eks list-nodegroups --cluster-name "$EKS_CLUSTER" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query "nodegroups[*]" --output text 2>/dev/null); do
        echo "  Deleting node group: $ng"
        aws eks delete-nodegroup --cluster-name "$EKS_CLUSTER" --nodegroup-name "$ng" \
            --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    done

    echo -e "${GREEN}✓ EKS node groups deletion initiated${NC}"
    wait_for_nodegroup_deletion "$EKS_CLUSTER"
else
    echo "  EKS cluster not found, skipping..."
fi
echo ""

# ============================================================================
# Step 4: Delete NAT Gateways
# ============================================================================
echo -e "${YELLOW}Step 4: Deleting NAT Gateways...${NC}"

NAT_EIP_ALLOCS=""
for nat_id in $(aws ec2 describe-nat-gateways --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,deleting" \
    --query "NatGateways[*].NatGatewayId" --output text 2>/dev/null); do

    eip_alloc=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" --output text 2>/dev/null)
    if [ -n "$eip_alloc" ] && [ "$eip_alloc" != "None" ]; then
        NAT_EIP_ALLOCS="$NAT_EIP_ALLOCS $eip_alloc"
    fi

    echo "  Deleting NAT Gateway: $nat_id"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

echo -e "${GREEN}✓ NAT Gateway deletion initiated${NC}"
wait_for_nat_deletion "$VPC_ID"
echo ""

# ============================================================================
# Step 5: Release Elastic IPs
# ============================================================================
echo -e "${YELLOW}Step 5: Releasing Elastic IPs...${NC}"

# Release NAT gateway EIPs first
if [ -n "$NAT_EIP_ALLOCS" ]; then
    echo "  Releasing NAT Gateway EIPs..."
    for alloc_id in $NAT_EIP_ALLOCS; do
        echo "    Releasing: $alloc_id"
        aws ec2 release-address --allocation-id "$alloc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    done
    sleep 5
fi

# Release all remaining EIPs
for alloc_id in $(aws ec2 describe-addresses --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query "Addresses[*].AllocationId" --output text 2>/dev/null); do
    echo "  Processing EIP: $alloc_id"

    assoc_id=$(aws ec2 describe-addresses --allocation-ids "$alloc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query "Addresses[0].AssociationId" --output text 2>/dev/null)
    if [ -n "$assoc_id" ] && [ "$assoc_id" != "None" ]; then
        echo "    Disassociating..."
        aws ec2 disassociate-address --association-id "$assoc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
        sleep 2
    fi

    echo "    Releasing..."
    aws ec2 release-address --allocation-id "$alloc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

echo -e "${GREEN}✓ Elastic IPs released${NC}"
echo ""

# ============================================================================
# Step 6: Delete VPC Peering Connections
# ============================================================================
echo -e "${YELLOW}Step 6: Deleting VPC Peering Connections...${NC}"

# Find peering connections where shared VPC is requester
for pcx_id in $(aws ec2 describe-vpc-peering-connections --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query "VpcPeeringConnections[*].VpcPeeringConnectionId" --output text 2>/dev/null); do
    echo "  Deleting peering (requester): $pcx_id"
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$pcx_id" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

# Find peering connections where shared VPC is accepter (SE lab → shared EKS)
for pcx_id in $(aws ec2 describe-vpc-peering-connections --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=accepter-vpc-info.vpc-id,Values=$VPC_ID" "Name=status-code,Values=active,pending-acceptance,provisioning" \
    --query "VpcPeeringConnections[*].VpcPeeringConnectionId" --output text 2>/dev/null); do
    echo "  Deleting peering (accepter): $pcx_id"
    aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$pcx_id" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

echo -e "${GREEN}✓ VPC peering connections deleted${NC}"
echo ""

# ============================================================================
# Step 7: Detach and Delete Internet Gateway
# ============================================================================
echo -e "${YELLOW}Step 7: Detaching Internet Gateway...${NC}"

IGW_ID=$(aws ec2 describe-internet-gateways --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null)

if [ -n "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
    echo "  Detaching IGW: $IGW_ID"
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    sleep 5

    echo "  Deleting IGW: $IGW_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    echo -e "${GREEN}✓ Internet Gateway detached and deleted${NC}"
else
    echo "  No Internet Gateway found"
fi
echo ""

# Wait for ENIs to be released after IGW deletion
sleep 10
wait_for_eni_cleanup "$VPC_ID"
echo ""

# ============================================================================
# Step 8: Delete Network Interfaces
# ============================================================================
echo -e "${YELLOW}Step 8: Deleting Network Interfaces...${NC}"

for pass in 1 2 3 4 5; do
    eni_count=0
    for eni_id in $(aws ec2 describe-network-interfaces --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" --output text 2>/dev/null); do
        echo "  Deleting ENI: $eni_id"
        aws ec2 delete-network-interface --network-interface-id "$eni_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
        eni_count=$((eni_count + 1))
    done

    if [ $eni_count -eq 0 ]; then
        break
    fi
    echo "  Pass $pass: Deleted $eni_count ENIs"
    sleep 5
done

echo -e "${GREEN}✓ Network interfaces cleaned up${NC}"
echo ""

# ============================================================================
# Step 9: Delete Security Groups (including K8s-created ones)
# ============================================================================
echo -e "${YELLOW}Step 9: Deleting Security Groups...${NC}"

# First remove all rules to break circular dependencies
for sg_id in $(aws ec2 describe-security-groups --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do

    # Revoke ingress rules
    ingress_rules=$(aws ec2 describe-security-groups --group-ids "$sg_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null)
    if [ -n "$ingress_rules" ] && [ "$ingress_rules" != "[]" ]; then
        aws ec2 revoke-security-group-ingress --group-id "$sg_id" --ip-permissions "$ingress_rules" \
            --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    fi

    # Revoke egress rules
    egress_rules=$(aws ec2 describe-security-groups --group-ids "$sg_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query "SecurityGroups[0].IpPermissionsEgress" --output json 2>/dev/null)
    if [ -n "$egress_rules" ] && [ "$egress_rules" != "[]" ]; then
        aws ec2 revoke-security-group-egress --group-id "$sg_id" --ip-permissions "$egress_rules" \
            --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    fi
done

# Now delete the security groups
for sg_id in $(aws ec2 describe-security-groups --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do

    sg_name=$(aws ec2 describe-security-groups --group-ids "$sg_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query "SecurityGroups[0].GroupName" --output text 2>/dev/null)
    echo "  Deleting security group: $sg_name ($sg_id)"
    aws ec2 delete-security-group --group-id "$sg_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

echo -e "${GREEN}✓ Security groups cleaned${NC}"
echo ""

# ============================================================================
# Step 10: Delete Subnets
# ============================================================================
echo -e "${YELLOW}Step 10: Deleting Subnets...${NC}"

for subnet_id in $(aws ec2 describe-subnets --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[*].SubnetId" --output text 2>/dev/null); do
    echo "  Deleting subnet: $subnet_id"
    aws ec2 delete-subnet --subnet-id "$subnet_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

echo -e "${GREEN}✓ Subnets deleted${NC}"
echo ""

# ============================================================================
# Step 11: Delete Route Tables (non-main)
# ============================================================================
echo -e "${YELLOW}Step 11: Deleting Route Tables...${NC}"

for rt_id in $(aws ec2 describe-route-tables --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null); do
    echo "  Deleting route table: $rt_id"

    # Delete associations first
    for assoc_id in $(aws ec2 describe-route-tables --route-table-ids "$rt_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output text 2>/dev/null); do
        aws ec2 disassociate-route-table --association-id "$assoc_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    done

    aws ec2 delete-route-table --route-table-id "$rt_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

echo -e "${GREEN}✓ Route tables deleted${NC}"
echo ""

# ============================================================================
# Step 12: Delete VPC
# ============================================================================
echo -e "${YELLOW}Step 12: Deleting VPC...${NC}"

aws ec2 delete-vpc --vpc-id "$VPC_ID" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null && \
    echo -e "${GREEN}✓ VPC deleted${NC}" || \
    echo -e "${YELLOW}  VPC deletion deferred to terraform${NC}"
echo ""

# ============================================================================
# Step 13: Run Terraform Destroy (cleanup state)
# ============================================================================
echo -e "${YELLOW}Step 13: Running terraform destroy...${NC}"
echo ""

rm -f "$BASE_DIR/.post-deploy-state"

MAX_RETRIES=3
RETRY=0
DESTROY_SUCCESS=false

while [ $RETRY -lt $MAX_RETRIES ] && [ "$DESTROY_SUCCESS" = "false" ]; do
    RETRY=$((RETRY + 1))
    echo "Terraform destroy attempt $RETRY of $MAX_RETRIES..."

    if terraform destroy -auto-approve 2>&1; then
        DESTROY_SUCCESS=true
    else
        # Check if state is empty (all resources already deleted)
        REMAINING=$(terraform state list 2>/dev/null | wc -l)
        if [ "$REMAINING" -eq 0 ]; then
            echo "  All resources already deleted from state"
            DESTROY_SUCCESS=true
        elif [ $RETRY -lt $MAX_RETRIES ]; then
            echo ""
            echo -e "${YELLOW}Terraform destroy failed. Cleaning up and retrying...${NC}"

            # Remove resources from state if they no longer exist in AWS
            for resource in $(terraform state list 2>/dev/null); do
                echo "  Checking: $resource"
                # Try to refresh - if resource doesn't exist, remove from state
                if ! terraform state show "$resource" &>/dev/null; then
                    echo "    Removing from state: $resource"
                    terraform state rm "$resource" 2>/dev/null || true
                fi
            done

            sleep 10
        fi
    fi
done

# Final state cleanup - remove any orphaned resources
echo ""
echo -e "${YELLOW}Final state cleanup...${NC}"
for resource in $(terraform state list 2>/dev/null); do
    echo "  Removing orphaned resource: $resource"
    terraform state rm "$resource" 2>/dev/null || true
done

# Cleanup generated files
echo -e "${YELLOW}Cleaning up generated files...${NC}"
rm -rf "$BASE_DIR/generated" 2>/dev/null || true
rm -f "$BASE_DIR/.post-deploy-state" 2>/dev/null || true
echo -e "${GREEN}✓ Generated files cleaned up${NC}"
echo ""

# Cleanup kubectl context
echo -e "${YELLOW}Cleaning up kubectl context...${NC}"
if command -v kubectl &>/dev/null; then
    # Remove the EKS cluster context
    kubectl config delete-context "$EKS_CLUSTER" 2>/dev/null || true
    kubectl config delete-cluster "arn:aws:eks:${AWS_REGION}:*:cluster/${EKS_CLUSTER}" 2>/dev/null || true
    kubectl config unset "users.arn:aws:eks:${AWS_REGION}:*:cluster/${EKS_CLUSTER}" 2>/dev/null || true
    echo -e "${GREEN}✓ kubectl context cleaned up${NC}"
else
    echo "  kubectl not installed, skipping context cleanup"
fi
echo ""

# Logout from ECR (clear Docker credentials)
echo -e "${YELLOW}Cleaning up Docker ECR credentials...${NC}"
if command -v docker &>/dev/null; then
    docker logout public.ecr.aws 2>/dev/null || true
    echo -e "${GREEN}✓ Docker ECR credentials cleaned up${NC}"
else
    echo "  Docker not installed, skipping"
fi
echo ""

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Destroy complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Resources cleaned up:"
echo "  - Public ECR repository and images"
echo "  - EKS cluster and node groups"
echo "  - Load balancers and target groups"
echo "  - NAT gateways and Elastic IPs"
echo "  - VPC and all networking resources"
echo "  - Generated SE documentation"
echo "  - kubectl context and Docker credentials"
echo ""
