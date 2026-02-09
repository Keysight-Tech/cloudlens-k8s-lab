#!/bin/bash
# ============================================================================
# DEPLOY MULTI-SE TRAINING LABS
# ============================================================================
# Deploys 25 isolated SE training lab environments
# Each SE gets: VPC, CLMS, KVO, vPB, Ubuntu x2, Windows, RHEL, Tool VMs
# Optional: EKS cluster and ECR repositories
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
NUM_LABS=${1:-25}
EKS_ENABLED=${2:-false}
SPECIFIC_LABS=${3:-""}
CYPERF=${4:-true}

# When CyPerf generates traffic, Ubuntu workload VMs and admin traffic gen are redundant
if [[ "$CYPERF" == "true" ]]; then
    UBUNTU_WORKLOAD=false
    ADMIN_TRAFFIC_GEN=false
else
    UBUNTU_WORKLOAD=true
    ADMIN_TRAFFIC_GEN=true
fi

show_help() {
    echo "Usage: $0 [NUM_LABS] [EKS_ENABLED] [SPECIFIC_LABS] [CYPERF_ENABLED]"
    echo ""
    echo "Arguments:"
    echo "  NUM_LABS         Number of SE labs to create (1-25, default: 25)"
    echo "  EKS_ENABLED      Enable EKS for all labs (true/false, default: false)"
    echo "  SPECIFIC_LABS    Comma-separated list of specific labs (e.g., 'se-lab-01,se-lab-02')"
    echo "  CYPERF_ENABLED   Enable CyPerf traffic generation (true/false, default: true)"
    echo "                   When true: disables Ubuntu workload VMs and admin traffic gen"
    echo ""
    echo "Examples:"
    echo "  $0 25                         # Deploy 25 labs with CyPerf"
    echo "  $0 5                          # Deploy 5 labs with CyPerf"
    echo "  $0 10 true                    # Deploy 10 labs with EKS + CyPerf"
    echo "  $0 5 false '' false           # Deploy 5 labs, no CyPerf (uses Ubuntu VMs)"
    echo "  $0 0 false 'se-lab-01,se-lab-05'  # Deploy specific labs"
    echo ""
    echo "Cost estimates:"
    echo "  Without EKS: ~\$1.00/hour per lab (\$25/hour for 25 labs)"
    echo "  With EKS: ~\$1.30/hour per lab (\$32.50/hour for 25 labs)"
    exit 0
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

cd "$BASE_DIR"

echo ""
echo "============================================================================"
echo "  CloudLens Multi-SE Training Lab Deployment"
echo "============================================================================"
echo ""
echo "Configuration:"
echo "  Number of Labs:   $NUM_LABS"
echo "  EKS Enabled:      $EKS_ENABLED"
echo "  CyPerf Enabled:   $CYPERF"
if [[ "$CYPERF" == "true" ]]; then
echo "  Ubuntu VMs:       disabled (CyPerf generates traffic)"
echo "  Traffic Gen VM:   disabled (CyPerf generates traffic)"
fi
if [[ -n "$SPECIFIC_LABS" ]]; then
echo "  Specific Labs:    $SPECIFIC_LABS"
fi
echo ""
echo "============================================================================"
echo ""

# Estimate costs
if [[ "$EKS_ENABLED" == "true" ]]; then
    COST_PER_LAB="1.30"
else
    COST_PER_LAB="1.00"
fi

if [[ -n "$SPECIFIC_LABS" ]]; then
    LAB_COUNT=$(echo "$SPECIFIC_LABS" | tr ',' '\n' | wc -l | tr -d ' ')
else
    LAB_COUNT=$NUM_LABS
fi

HOURLY_COST=$(echo "$LAB_COUNT * $COST_PER_LAB" | bc)
DAILY_COST=$(echo "$HOURLY_COST * 24" | bc)

log_info "Estimated costs:"
echo "  - Per hour: \$$HOURLY_COST"
echo "  - Per day:  \$$DAILY_COST"
echo ""

read -p "Continue with deployment? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    log_warning "Deployment cancelled"
    exit 0
fi

# Create terraform.tfvars for this deployment
log_info "Creating terraform configuration..."

if [[ -n "$SPECIFIC_LABS" ]]; then
    # Convert comma-separated to terraform list format
    LABS_TF_FORMAT=$(echo "$SPECIFIC_LABS" | sed 's/,/", "/g')
    cat > terraform.tfvars <<EOF
# Multi-SE Training Lab Configuration
# Generated: $(date)

multi_se_mode              = true
num_se_labs                = $NUM_LABS
eks_enabled_for_all        = $EKS_ENABLED
enabled_labs               = ["$LABS_TF_FORMAT"]
cyperf_enabled             = $CYPERF
ubuntu_workload_enabled    = $UBUNTU_WORKLOAD
admin_traffic_gen_enabled  = $ADMIN_TRAFFIC_GEN
EOF
else
    cat > terraform.tfvars <<EOF
# Multi-SE Training Lab Configuration
# Generated: $(date)

multi_se_mode              = true
num_se_labs                = $NUM_LABS
eks_enabled_for_all        = $EKS_ENABLED
enabled_labs               = []
cyperf_enabled             = $CYPERF
ubuntu_workload_enabled    = $UBUNTU_WORKLOAD
admin_traffic_gen_enabled  = $ADMIN_TRAFFIC_GEN
EOF
fi

log_success "Configuration saved to terraform.tfvars"
echo ""

# Initialize Terraform
log_info "Initializing Terraform..."
terraform init -upgrade

# Validate configuration
log_info "Validating configuration..."
terraform validate

# Create plan
log_info "Creating deployment plan..."
terraform plan -out=tfplan-multi-se

echo ""
echo "============================================================================"
echo "  Review the plan above"
echo "============================================================================"
echo ""

read -p "Apply this plan? (yes/no): " apply_confirm
if [[ "$apply_confirm" != "yes" ]]; then
    log_warning "Deployment cancelled"
    rm -f tfplan-multi-se
    exit 0
fi

# Apply
log_info "Deploying Multi-SE Training Labs..."
terraform apply tfplan-multi-se

# Cleanup plan file
rm -f tfplan-multi-se

echo ""
echo "============================================================================"
log_success "Deployment Complete!"
echo "============================================================================"
echo ""
echo "Documentation generated in: $BASE_DIR/generated/"
echo ""
ls -la "$BASE_DIR/generated/" 2>/dev/null || echo "No documentation generated yet."
echo ""

# Prompt for ECR image push if EKS enabled
if [[ "$EKS_ENABLED" == "true" ]]; then
    echo ""
    read -p "Push CloudLens sensor to ECR repositories? (yes/no): " push_ecr
    if [[ "$push_ecr" == "yes" ]]; then
        "$SCRIPT_DIR/push-ecr-images.sh"
    fi
fi

# ============================================================================
# AUTO-DEPLOY CYPERF VM AGENTS (if cyperf_enabled=true)
# ============================================================================

CYPERF_ENABLED=$(terraform output -raw cyperf_enabled 2>/dev/null || echo "false")
SHARED_EKS=$(terraform output -raw shared_eks_enabled 2>/dev/null || echo "false")

if [[ "$CYPERF_ENABLED" == "true" ]]; then
    echo ""
    echo "============================================================================"
    log_info "CyPerf is enabled - configuring VM agents and nginx proxy"
    echo "============================================================================"
    echo ""

    # VM agents are already deployed by terraform (cyperf-agents-vm.tf)
    # This script sets up nginx reverse proxy in K8s namespaces
    if [[ "$SHARED_EKS" == "true" ]]; then
        CYPERF_NUM_SES=$(terraform output -raw num_se_labs 2>/dev/null || echo "$NUM_LABS")
        CYPERF_CLUSTER=$(terraform output -raw shared_eks_cluster_name 2>/dev/null || echo "se-lab-shared-eks")
        CYPERF_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-west-2")
        CYPERF_PROFILE=$(terraform output -raw aws_profile 2>/dev/null || echo "cloudlens-lab")

        "$SCRIPT_DIR/deploy-cyperf-vm.sh" "$CYPERF_NUM_SES" "$CYPERF_CLUSTER" "$CYPERF_REGION" "$CYPERF_PROFILE"
    else
        log_warning "Shared EKS is disabled. CyPerf VM agents are deployed but nginx proxy setup requires EKS."
        log_warning "Enable shared_eks_enabled=true, then run: scripts/deploy-cyperf-vm.sh"
        echo ""
        echo "  CyPerf VM agent status:"
        echo "    Client: $(terraform output -raw cyperf_client_public_ip 2>/dev/null || echo 'N/A')"
        echo "    Server: $(terraform output -raw cyperf_server_public_ip 2>/dev/null || echo 'N/A')"
    fi
fi

echo ""
log_success "All done! SE training labs are ready."
echo ""
echo "Next steps:"
echo "  1. Review generated documentation in $BASE_DIR/generated/"
echo "  2. Distribute per-SE guides to trainees"
echo "  3. Access CLMS/KVO UIs (wait 15 minutes for initialization)"
if [[ "$CYPERF_ENABLED" == "true" ]]; then
echo "  4. Access CyPerf UI: $(terraform output -raw cyperf_controller_ui_url 2>/dev/null || echo 'https://<controller-public-ip>')"
echo "     Login: admin / <CYPERF_PASSWORD>"
echo "     (wait ~10 minutes for controller initialization)"
fi
echo ""
