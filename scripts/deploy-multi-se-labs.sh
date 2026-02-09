#!/bin/bash

################################################################################
# CloudLens Training Lab - Multi-SE Deployment Script
#
# This script deploys 20 isolated CloudLens training environments
# for Solutions Engineer training sessions.
#
# Usage:
#   ./deploy-multi-se-labs.sh [number_of_labs] [action]
#
# Examples:
#   ./deploy-multi-se-labs.sh 20 deploy     # Deploy 20 labs
#   ./deploy-multi-se-labs.sh 5 deploy      # Deploy 5 labs
#   ./deploy-multi-se-labs.sh 20 destroy    # Destroy all 20 labs
#   ./deploy-multi-se-labs.sh 20 status     # Check status of all labs
#
# Author: CloudLens SE Team
# Version: 1.0
# Date: 2026-01-13
################################################################################

set -e

# Configuration
NUM_LABS=${1:-20}
ACTION=${2:-deploy}
AWS_REGION="us-west-2"
AWS_PROFILE="cloudlens-lab"
KEY_NAME="cloudlens-se-training"
KEY_PATH="~/Downloads/cloudlens-se-training.pem"
PARALLEL_JOBS=5  # Deploy 5 labs at a time to avoid API rate limits
DEPLOYMENT_DIR="deployments"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Terraform
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform not found. Please install Terraform 1.0+"
        exit 1
    fi

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &> /dev/null; then
        log_error "AWS authentication failed. Run: aws sso login --profile $AWS_PROFILE"
        exit 1
    fi

    # Verify SSH key exists
    if [ ! -f "$(eval echo $KEY_PATH)" ]; then
        log_error "SSH key not found at: $KEY_PATH"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

create_lab_directory() {
    local lab_num=$1
    local lab_id=$(printf "se%02d" $lab_num)
    local lab_dir="$DEPLOYMENT_DIR/$lab_id"

    mkdir -p "$lab_dir"

    # Copy Terraform configuration
    cp clms_vpb_kvo.tf "$lab_dir/"

    # Create unique terraform.tfvars
    cat > "$lab_dir/terraform.tfvars" <<EOF
# Lab Configuration for $lab_id
deployment_prefix = "$lab_id"

# AWS Configuration
aws_region = "$AWS_REGION"
aws_profile = "$AWS_PROFILE"
availability_zone = "${AWS_REGION}a"

# SSH Key Configuration
key_pair_name = "$KEY_NAME"
private_key_path = "$KEY_PATH"

# Network Configuration (unique per lab)
vpc_cidr = "10.$lab_num.0.0/16"
management_subnet_cidr = "10.$lab_num.1.0/24"
ingress_subnet_cidr = "10.$lab_num.2.0/24"
egress_subnet_cidr = "10.$lab_num.3.0/24"

# Security (default: allow all, restrict in production)
allowed_ssh_cidr = "0.0.0.0/0"
allowed_https_cidr = "0.0.0.0/0"

# Tags
extra_tags = {
  Training = "CloudLens-SE-Training"
  Lab = "$lab_id"
  BatchDeployment = "true"
}
EOF

    log_success "Created configuration for $lab_id"
}

deploy_lab() {
    local lab_num=$1
    local lab_id=$(printf "se%02d" $lab_num)
    local lab_dir="$DEPLOYMENT_DIR/$lab_id"

    log_info "Deploying $lab_id..."

    cd "$lab_dir"

    # Initialize Terraform
    terraform init -input=false > init.log 2>&1
    if [ $? -ne 0 ]; then
        log_error "$lab_id: Terraform init failed (see $lab_dir/init.log)"
        cd - > /dev/null
        return 1
    fi

    # Apply configuration
    terraform apply -auto-approve -input=false > apply.log 2>&1
    if [ $? -ne 0 ]; then
        log_error "$lab_id: Terraform apply failed (see $lab_dir/apply.log)"
        cd - > /dev/null
        return 1
    fi

    # Generate credentials file
    cat > "${lab_id}-credentials.txt" <<EOF
========================================
CloudLens Training Lab: $lab_id
========================================
Deployed: $(date)
Region: $AWS_REGION

KEYSIGHT PRODUCTS:
------------------
KVO UI:       https://$(terraform output -raw kvo_public_ip 2>/dev/null || echo "N/A")
  Username:   admin
  Password:   admin

CLMS UI:      https://$(terraform output -raw clms_public_ip 2>/dev/null || echo "N/A")
  Username:   admin
  Password:   <CLMS_PASSWORD>

vPB SSH:      ssh -i $KEY_PATH admin@$(terraform output -raw vpb_public_ip 2>/dev/null || echo "N/A")
  Password:   <VPB_PASSWORD>

WORKLOAD VMs:
-------------
Ubuntu 1:     $(terraform output -raw tapped_ubuntu_1_public_ip 2>/dev/null || echo "N/A")
Ubuntu 2:     $(terraform output -raw tapped_ubuntu_2_public_ip 2>/dev/null || echo "N/A")
Windows:      $(terraform output -raw tapped_windows_public_ip 2>/dev/null || echo "N/A")
RHEL:         $(terraform output -raw tapped_rhel_public_ip 2>/dev/null || echo "N/A")

Tool VM:      $(terraform output -raw tool_public_ip 2>/dev/null || echo "N/A")

SSH COMMAND:
------------
ssh -i $KEY_PATH ubuntu@<IP>
ssh -i $KEY_PATH ec2-user@<RHEL-IP>

Windows Admin Password:
-----------------------
$(terraform output -raw windows_password 2>/dev/null | base64 -d | openssl rsautl -decrypt -inkey $(eval echo $KEY_PATH) 2>/dev/null || echo "Run after deployment completes")

========================================
Wait 10-15 minutes after deployment
for all services to initialize
========================================
EOF

    log_success "$lab_id deployed successfully"
    cd - > /dev/null
    return 0
}

destroy_lab() {
    local lab_num=$1
    local lab_id=$(printf "se%02d" $lab_num)
    local lab_dir="$DEPLOYMENT_DIR/$lab_id"

    if [ ! -d "$lab_dir" ]; then
        log_warning "$lab_id directory not found, skipping"
        return 0
    fi

    log_info "Destroying $lab_id..."

    cd "$lab_dir"
    terraform destroy -auto-approve -input=false > destroy.log 2>&1
    if [ $? -ne 0 ]; then
        log_error "$lab_id: Terraform destroy failed (see $lab_dir/destroy.log)"
        cd - > /dev/null
        return 1
    fi

    log_success "$lab_id destroyed"
    cd - > /dev/null
    return 0
}

check_lab_status() {
    local lab_num=$1
    local lab_id=$(printf "se%02d" $lab_num)
    local lab_dir="$DEPLOYMENT_DIR/$lab_id"

    if [ ! -d "$lab_dir" ]; then
        echo "$lab_id: NOT DEPLOYED"
        return
    fi

    cd "$lab_dir" > /dev/null 2>&1

    if [ ! -f "terraform.tfstate" ]; then
        echo "$lab_id: CONFIGURED (not deployed)"
        cd - > /dev/null
        return
    fi

    local resources=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources | length' 2>/dev/null || echo "0")

    if [ "$resources" -gt 0 ]; then
        echo "$lab_id: DEPLOYED ($resources resources)"
    else
        echo "$lab_id: EMPTY STATE"
    fi

    cd - > /dev/null
}

deploy_all_labs() {
    log_info "Starting deployment of $NUM_LABS labs..."
    log_info "Deploying $PARALLEL_JOBS labs in parallel"

    # Create all lab directories first
    for i in $(seq 1 $NUM_LABS); do
        create_lab_directory $i
    done

    # Deploy in batches
    local batch=1
    for i in $(seq 1 $NUM_LABS); do
        deploy_lab $i &

        # Wait after each batch
        if [ $((i % PARALLEL_JOBS)) -eq 0 ]; then
            log_info "Waiting for batch $batch to complete..."
            wait
            batch=$((batch + 1))
        fi
    done

    # Wait for final batch
    wait

    log_success "All lab deployments initiated"
    log_info "Generating combined credentials file..."

    # Create combined credentials file
    cat > "$DEPLOYMENT_DIR/ALL-LABS-CREDENTIALS.txt" <<EOF
========================================
CloudLens Training - All Lab Credentials
========================================
Generated: $(date)
Total Labs: $NUM_LABS

EOF

    for i in $(seq 1 $NUM_LABS); do
        local lab_id=$(printf "se%02d" $i)
        if [ -f "$DEPLOYMENT_DIR/$lab_id/${lab_id}-credentials.txt" ]; then
            cat "$DEPLOYMENT_DIR/$lab_id/${lab_id}-credentials.txt" >> "$DEPLOYMENT_DIR/ALL-LABS-CREDENTIALS.txt"
            echo "" >> "$DEPLOYMENT_DIR/ALL-LABS-CREDENTIALS.txt"
        fi
    done

    log_success "Combined credentials file created: $DEPLOYMENT_DIR/ALL-LABS-CREDENTIALS.txt"
}

destroy_all_labs() {
    log_warning "Destroying $NUM_LABS labs..."

    for i in $(seq 1 $NUM_LABS); do
        destroy_lab $i &

        # Wait after each batch
        if [ $((i % PARALLEL_JOBS)) -eq 0 ]; then
            wait
        fi
    done

    wait
    log_success "All labs destroyed"
}

check_all_status() {
    log_info "Checking status of $NUM_LABS labs..."
    echo ""

    for i in $(seq 1 $NUM_LABS); do
        check_lab_status $i
    done

    echo ""
    log_info "Status check complete"
}

# Main script
main() {
    echo "=========================================="
    echo "CloudLens Training Lab Deployment"
    echo "=========================================="
    echo "Labs: $NUM_LABS"
    echo "Action: $ACTION"
    echo "AWS Profile: $AWS_PROFILE"
    echo "Region: $AWS_REGION"
    echo "=========================================="
    echo ""

    case "$ACTION" in
        deploy)
            check_prerequisites
            deploy_all_labs
            log_success "Deployment complete!"
            log_info "Credentials saved in: $DEPLOYMENT_DIR/ALL-LABS-CREDENTIALS.txt"
            log_warning "Wait 10-15 minutes for all instances to initialize"
            ;;
        destroy)
            destroy_all_labs
            ;;
        status)
            check_all_status
            ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Usage: $0 [number_of_labs] [deploy|destroy|status]"
            exit 1
            ;;
    esac
}

# Run main
main
