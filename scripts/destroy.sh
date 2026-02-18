#!/bin/bash
# ============================================================================
#  CloudLens K8s Visibility Lab - Full Destroy Script
# ============================================================================
#  Tears down everything created by deploy.sh
#  Usage: ./scripts/destroy.sh
#
#  What this script does:
#    1. Confirms you really want to destroy everything
#    2. Cleans up K8s resources (CyPerf, nginx-demo, services, secrets)
#    3. Removes LoadBalancers (avoids terraform destroy hanging on dangling ENIs)
#    4. Runs terraform destroy (all AWS infrastructure)
#    5. Cleans up local files (kubeconfig, temp files)
# ============================================================================

set -euo pipefail

# ============================================================================
# COLORS & HELPERS
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_DIR/terraform"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}  STEP $1: $2${NC}"; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# Read config
AWS_PROFILE=""
AWS_REGION=""
DEPLOYMENT_PREFIX=""

if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
    AWS_PROFILE=$(grep 'aws_profile' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)
    AWS_REGION=$(grep 'aws_region' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)
    DEPLOYMENT_PREFIX=$(grep 'deployment_prefix' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)
fi

AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DEPLOYMENT_PREFIX="${DEPLOYMENT_PREFIX:-cloudlens-lab}"

echo ""
echo -e "${BOLD}${RED}============================================================================${NC}"
echo -e "${BOLD}${RED}  CloudLens K8s Visibility Lab - DESTROY ALL RESOURCES${NC}"
echo -e "${BOLD}${RED}============================================================================${NC}"
echo ""
echo "  This will PERMANENTLY DELETE all lab resources:"
echo ""
echo "    - All EC2 instances (CLMS, KVO, vPB, workload VMs, tool VMs)"
echo "    - CyPerf Controller"
echo "    - EKS cluster and all worker nodes"
echo "    - All Kubernetes workloads (nginx-demo, CyPerf pods)"
echo "    - VPC, subnets, security groups, NAT gateway"
echo "    - Elastic IPs"
echo "    - ECR repositories"
echo "    - Generated documentation"
echo ""
echo "  Deployment: $DEPLOYMENT_PREFIX"
echo "  Region:     $AWS_REGION"
echo "  Profile:    $AWS_PROFILE"
echo ""
echo -e "  ${RED}${BOLD}THIS ACTION CANNOT BE UNDONE.${NC}"
echo ""

read -rp "  Type 'destroy' to confirm: " CONFIRM
if [[ "$CONFIRM" != "destroy" ]]; then
    echo ""
    log_info "Destroy cancelled."
    exit 0
fi

echo ""

# ============================================================================
# STEP 1: CLEAN UP KUBERNETES RESOURCES
# ============================================================================
log_step "1/4" "Cleaning Up Kubernetes Resources"

# Check if kubectl is connected
if kubectl cluster-info &>/dev/null 2>&1; then
    log_info "kubectl connected. Cleaning up K8s resources..."

    # Delete CyPerf namespace (agents, proxy, services)
    if kubectl get namespace cyperf &>/dev/null 2>&1; then
        log_info "Deleting CyPerf resources..."
        kubectl delete pod,svc,deployment,configmap --all -n cyperf --timeout=60s 2>&1 || true
        log_success "CyPerf resources deleted"
    else
        log_info "No CyPerf namespace found (skipping)"
    fi

    # Delete nginx-demo LoadBalancer service FIRST (critical - prevents ENI leak)
    if kubectl get svc nginx-demo &>/dev/null 2>&1; then
        log_info "Deleting nginx-demo LoadBalancer service..."
        kubectl delete svc nginx-demo --timeout=60s 2>&1 || true
        log_info "Waiting for ELB to deprovision (30s)..."
        sleep 30
        log_success "nginx-demo service deleted"
    fi

    # Delete remaining nginx-demo resources
    log_info "Deleting nginx-demo deployment and configs..."
    kubectl delete deployment nginx-demo --ignore-not-found --timeout=60s 2>&1 || true
    kubectl delete configmap nginx-html-config nginx-config cloudlens-config --ignore-not-found 2>&1 || true
    kubectl delete secret nginx-tls-secret --ignore-not-found 2>&1 || true
    log_success "nginx-demo resources deleted"

    # Delete any remaining LoadBalancer services (prevent ENI leaks)
    log_info "Checking for remaining LoadBalancer services..."
    LB_SVCS=$(kubectl get svc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
    if [[ -n "$LB_SVCS" ]]; then
        log_warn "Deleting remaining LoadBalancer services to prevent ENI leaks:"
        echo "$LB_SVCS" | while read -r svc; do
            NS=$(echo "$svc" | cut -d/ -f1)
            NAME=$(echo "$svc" | cut -d/ -f2)
            echo "  Deleting $svc..."
            kubectl delete svc "$NAME" -n "$NS" --timeout=60s 2>&1 || true
        done
        log_info "Waiting for ELBs to deprovision (30s)..."
        sleep 30
    else
        log_info "No LoadBalancer services found"
    fi

    log_success "Kubernetes cleanup complete"
else
    log_warn "kubectl not connected to cluster. Skipping K8s cleanup."
    log_warn "If EKS LoadBalancer services exist, terraform destroy may hang on ENI deletion."
    log_warn "If that happens, manually delete the ELBs in the AWS Console and retry."
fi

# ============================================================================
# STEP 2: KILL BACKGROUND PROCESSES
# ============================================================================
log_step "2/4" "Stopping Background Processes"

# Kill any iptables-fixer processes from CyPerf deploy
IPTABLES_PIDS=$(pgrep -f "iptables-fixer\|iptables.*cyperf" 2>/dev/null || echo "")
if [[ -n "$IPTABLES_PIDS" ]]; then
    log_info "Killing iptables-fixer processes: $IPTABLES_PIDS"
    kill $IPTABLES_PIDS 2>/dev/null || true
    log_success "Background processes stopped"
else
    log_info "No background processes found"
fi

# ============================================================================
# STEP 3: TERRAFORM DESTROY
# ============================================================================
log_step "3/4" "Destroying AWS Infrastructure (Terraform)"

cd "$TF_DIR"

if [[ ! -f "terraform.tfstate" ]] && [[ ! -d ".terraform" ]]; then
    log_warn "No terraform state found. Nothing to destroy."
    echo "  If resources exist, run: cd terraform && terraform init && terraform destroy"
else
    log_info "Running terraform init..."
    terraform init -input=false -upgrade 2>&1
    echo ""

    log_info "Running terraform destroy..."
    echo ""
    terraform destroy -auto-approve -input=false 2>&1
    echo ""
    log_success "Infrastructure destroyed"
fi

# ============================================================================
# STEP 4: CLEANUP LOCAL FILES
# ============================================================================
log_step "4/4" "Cleaning Up Local Files"

# Remove tfplan files
rm -f "$TF_DIR/tfplan" "$TF_DIR/tfplan-"* 2>/dev/null
log_info "Removed terraform plan files"

# Remove generated docs (terraform destroy provisioner should handle this, but just in case)
if [[ -d "$TF_DIR/generated" ]]; then
    rm -rf "$TF_DIR/generated"
    log_info "Removed generated documentation"
fi

# Clean kubeconfig entry
EKS_CLUSTER="${DEPLOYMENT_PREFIX}-eks-cluster"
if command -v kubectl &>/dev/null; then
    kubectl config delete-context "arn:aws:eks:${AWS_REGION}:*:cluster/${EKS_CLUSTER}" 2>/dev/null || true
    kubectl config delete-cluster "arn:aws:eks:${AWS_REGION}:*:cluster/${EKS_CLUSTER}" 2>/dev/null || true
    log_info "Cleaned kubeconfig entries for $EKS_CLUSTER"
fi

log_success "Local cleanup complete"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${BOLD}${GREEN}============================================================================${NC}"
echo -e "${BOLD}${GREEN}  DESTROY COMPLETE${NC}"
echo -e "${BOLD}${GREEN}============================================================================${NC}"
echo ""
echo "  All lab resources have been destroyed:"
echo "    - Kubernetes workloads (nginx-demo, CyPerf)  deleted"
echo "    - LoadBalancer services                       deleted"
echo "    - EC2 instances                               terminated"
echo "    - EKS cluster                                 deleted"
echo "    - VPC, subnets, security groups               deleted"
echo "    - Elastic IPs                                 released"
echo "    - ECR repositories                            deleted"
echo "    - Generated documentation                     deleted"
echo ""
echo "  To redeploy: ./scripts/deploy.sh"
echo ""
echo -e "${BOLD}${GREEN}============================================================================${NC}"
echo ""
