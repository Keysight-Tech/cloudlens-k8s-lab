#!/bin/bash
# ============================================================================
#  CloudLens K8s Visibility Lab - Full Deployment Script
# ============================================================================
#  Single script to deploy everything from scratch.
#  Usage: ./scripts/deploy.sh
#
#  What this script does:
#    1. Checks & installs prerequisites (terraform, kubectl, helm, aws, jq)
#    2. Validates AWS credentials & terraform.tfvars
#    3. Runs terraform init + apply (all infrastructure)
#    4. Waits for product initialization (CLMS, KVO, EKS)
#    5. Configures kubectl for EKS
#    6. Deploys K8s workloads (nginx-demo with TLS, beautiful landing page)
#    7. Deploys CyPerf agents + test session (if enabled)
#       - Prompts you to activate CyPerf license
#    8. Generates deployment documentation
#    9. Prints full deployment summary
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

prompt_continue() {
    echo ""
    read -rp "  Press Enter to continue (or Ctrl+C to abort)... "
    echo ""
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "  $prompt [Y/n]: " yn
        yn="${yn:-y}"
    else
        read -rp "  $prompt [y/N]: " yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        echo "windows"
    else
        echo "unknown"
    fi
}

OS=$(detect_os)

echo ""
echo -e "${BOLD}${CYAN}============================================================================${NC}"
echo -e "${BOLD}  CloudLens K8s Visibility Lab - Full Deployment${NC}"
echo -e "${BOLD}${CYAN}============================================================================${NC}"
echo ""
echo "  This script will deploy the complete lab environment including:"
echo "    - AWS infrastructure (VPC, EC2 instances, EKS cluster)"
echo "    - Keysight products (CLMS, KVO, vPB)"
echo "    - Kubernetes workloads (nginx-demo with TLS)"
echo "    - CyPerf traffic generator (if enabled)"
echo "    - Generated deployment documentation"
echo ""
echo -e "  ${YELLOW}Prerequisites you need BEFORE running this script:${NC}"
echo "    1. AWS account with Marketplace subscriptions (CLMS, KVO, vPB)"
echo "    2. EC2 key pair created in your target region"
echo "    3. Keysight license activation codes (KVO, CloudLens, CyPerf)"
echo ""

prompt_continue

# ============================================================================
# STEP 1: CHECK & INSTALL PREREQUISITES
# ============================================================================
log_step "1/9" "Checking Prerequisites"

MISSING_TOOLS=()

check_tool() {
    local tool="$1"
    local name="$2"
    if command -v "$tool" &>/dev/null; then
        local version
        version=$("$tool" --version 2>&1 | head -1 || echo "installed")
        echo -e "  ${GREEN}✓${NC} $name: $version"
    else
        echo -e "  ${RED}✗${NC} $name: NOT FOUND"
        MISSING_TOOLS+=("$tool")
    fi
}

echo "Checking required tools..."
echo ""
check_tool "terraform" "Terraform"
check_tool "kubectl" "kubectl"
check_tool "helm" "Helm"
check_tool "aws" "AWS CLI"
check_tool "jq" "jq"
check_tool "openssl" "OpenSSL"
check_tool "curl" "curl"
echo ""

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    log_warn "Missing tools: ${MISSING_TOOLS[*]}"
    echo ""

    if [[ "$OS" == "macos" ]]; then
        # Check for Homebrew
        if ! command -v brew &>/dev/null; then
            log_warn "Homebrew not found. Installing Homebrew first..."
            if prompt_yes_no "Install Homebrew?"; then
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
            else
                log_error "Cannot install tools without a package manager. Install manually and re-run."
                exit 1
            fi
        fi

        if prompt_yes_no "Install missing tools via Homebrew?"; then
            for tool in "${MISSING_TOOLS[@]}"; do
                case "$tool" in
                    terraform) brew install terraform ;;
                    kubectl)   brew install kubectl ;;
                    helm)      brew install helm ;;
                    aws)       brew install awscli ;;
                    jq)        brew install jq ;;
                    openssl)   brew install openssl ;;
                    curl)      brew install curl ;;
                esac
            done
            log_success "Tools installed"
        else
            log_error "Please install missing tools and re-run this script."
            exit 1
        fi

    elif [[ "$OS" == "linux" ]]; then
        echo "  Install on Linux (Ubuntu/Debian):"
        for tool in "${MISSING_TOOLS[@]}"; do
            case "$tool" in
                terraform) echo "    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && sudo apt-get update && sudo apt-get install terraform" ;;
                kubectl)   echo "    sudo snap install kubectl --classic" ;;
                helm)      echo "    sudo snap install helm --classic" ;;
                aws)       echo "    curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && unzip awscliv2.zip && sudo ./aws/install" ;;
                jq)        echo "    sudo apt-get install -y jq" ;;
                openssl)   echo "    sudo apt-get install -y openssl" ;;
                curl)      echo "    sudo apt-get install -y curl" ;;
            esac
        done
        echo ""
        log_error "Please install the missing tools above and re-run this script."
        exit 1

    elif [[ "$OS" == "windows" ]]; then
        echo "  Install on Windows (requires Chocolatey):"
        echo "    choco install terraform kubernetes-cli kubernetes-helm awscli jq openssl curl"
        echo ""
        log_error "Please install the missing tools and re-run this script."
        exit 1
    fi
fi

log_success "All prerequisites met"

# ============================================================================
# STEP 2: VALIDATE AWS CREDENTIALS & CONFIGURATION
# ============================================================================
log_step "2/9" "Validating AWS Configuration"

# Check terraform.tfvars exists
if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
    log_warn "terraform.tfvars not found. Creating from defaults..."
    echo ""
    echo "  You need to configure your deployment settings."
    echo ""

    # Prompt for required values
    read -rp "  AWS CLI profile name [cloudlens-lab]: " AWS_PROFILE
    AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"

    read -rp "  AWS region [us-west-2]: " AWS_REGION
    AWS_REGION="${AWS_REGION:-us-west-2}"

    read -rp "  EC2 key pair name [cloudlens-lab]: " KEY_PAIR
    KEY_PAIR="${KEY_PAIR:-cloudlens-lab}"

    read -rp "  SSH private key path [~/.ssh/${KEY_PAIR}.pem]: " KEY_PATH
    KEY_PATH="${KEY_PATH:-~/.ssh/${KEY_PAIR}.pem}"

    read -rp "  Deployment prefix [cloudlens-lab]: " PREFIX
    PREFIX="${PREFIX:-cloudlens-lab}"

    ENABLE_CYPERF="false"
    if prompt_yes_no "Enable CyPerf traffic generator?" "y"; then
        ENABLE_CYPERF="true"
    fi

    cat > "$TF_DIR/terraform.tfvars" << EOF
# Generated by deploy.sh
aws_profile       = "$AWS_PROFILE"
aws_region        = "$AWS_REGION"
key_pair_name     = "$KEY_PAIR"
private_key_path  = "$KEY_PATH"
deployment_prefix = "$PREFIX"

# Features
vpb_enabled     = true
eks_enabled     = true
use_elastic_ips = true
cyperf_enabled  = $ENABLE_CYPERF
EOF

    log_success "terraform.tfvars created"
    echo ""
    echo "  Config saved to: $TF_DIR/terraform.tfvars"
    echo "  Edit this file to customize instance types, CIDR ranges, etc."
    echo ""
else
    log_success "terraform.tfvars found"
fi

# Read config values
AWS_PROFILE=$(grep 'aws_profile' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)
AWS_REGION=$(grep 'aws_region' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)
DEPLOYMENT_PREFIX=$(grep 'deployment_prefix' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)
CYPERF_ENABLED=$(grep 'cyperf_enabled' "$TF_DIR/terraform.tfvars" | sed 's/.*= *//' | tr -d ' ' | head -1)
KEY_PAIR_NAME=$(grep 'key_pair_name' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)

echo ""
echo "  Configuration:"
echo "    Profile:    $AWS_PROFILE"
echo "    Region:     $AWS_REGION"
echo "    Prefix:     $DEPLOYMENT_PREFIX"
echo "    Key Pair:   $KEY_PAIR_NAME"
echo "    CyPerf:     $CYPERF_ENABLED"
echo ""

# Validate AWS credentials
log_info "Validating AWS credentials..."
if aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
    log_success "AWS authenticated (Account: $ACCOUNT_ID)"
else
    log_error "AWS authentication failed for profile '$AWS_PROFILE'"
    echo ""
    echo "  Configure your AWS CLI profile:"
    echo "    aws configure --profile $AWS_PROFILE"
    echo ""
    echo "  Or for SSO:"
    echo "    aws sso login --profile $AWS_PROFILE"
    exit 1
fi

# Verify key pair exists
log_info "Checking EC2 key pair '$KEY_PAIR_NAME' in $AWS_REGION..."
if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" &>/dev/null; then
    log_success "Key pair '$KEY_PAIR_NAME' found"
else
    log_error "Key pair '$KEY_PAIR_NAME' not found in $AWS_REGION"
    echo ""
    echo "  Create it in the AWS Console: EC2 > Key Pairs > Create key pair"
    echo "  Or via CLI: aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --region $AWS_REGION --profile $AWS_PROFILE"
    exit 1
fi

# ============================================================================
# STEP 3: TERRAFORM INIT & APPLY
# ============================================================================
log_step "3/9" "Deploying Infrastructure (Terraform)"

cd "$TF_DIR"

log_info "Running terraform init..."
terraform init -input=false -upgrade 2>&1
echo ""

log_info "Running terraform plan..."
terraform plan -input=false -out=tfplan 2>&1
echo ""

echo -e "  ${YELLOW}This will create AWS resources that incur costs.${NC}"
if prompt_yes_no "Proceed with terraform apply?"; then
    log_info "Running terraform apply (this takes ~15-20 minutes)..."
    terraform apply -input=false tfplan 2>&1
    rm -f tfplan
    echo ""
    log_success "Infrastructure deployed"
else
    log_warn "Deployment cancelled."
    rm -f tfplan
    exit 0
fi

# ============================================================================
# STEP 4: WAIT FOR PRODUCT INITIALIZATION
# ============================================================================
log_step "4/9" "Waiting for Product Initialization"

CLMS_IP=$(terraform output -raw clms_url 2>/dev/null | sed 's|https://||')
KVO_IP=$(terraform output -raw kvo_url 2>/dev/null | sed 's|https://||')
CLMS_PRIVATE_IP=$(terraform output -raw clms_private_ip 2>/dev/null)

echo "  Products need time to initialize after first boot."
echo ""
echo "  Checking connectivity (will retry for up to 15 minutes)..."
echo ""

# Wait for CLMS
MAX_WAIT=45
for i in $(seq 1 $MAX_WAIT); do
    if curl -sk --connect-timeout 5 "https://$CLMS_IP" >/dev/null 2>&1; then
        log_success "CLMS is reachable (https://$CLMS_IP)"
        break
    fi
    if [[ $i -eq $MAX_WAIT ]]; then
        log_warn "CLMS not reachable yet. It may still be initializing. Continuing..."
    else
        echo -ne "  Waiting for CLMS... ($i/$MAX_WAIT)\r"
        sleep 20
    fi
done

# Wait for KVO
for i in $(seq 1 $MAX_WAIT); do
    if curl -sk --connect-timeout 5 "https://$KVO_IP" >/dev/null 2>&1; then
        log_success "KVO is reachable (https://$KVO_IP)"
        break
    fi
    if [[ $i -eq $MAX_WAIT ]]; then
        log_warn "KVO not reachable yet. It may still be initializing. Continuing..."
    else
        echo -ne "  Waiting for KVO... ($i/$MAX_WAIT)\r"
        sleep 20
    fi
done

# ============================================================================
# STEP 5: CONFIGURE KUBECTL FOR EKS
# ============================================================================
log_step "5/9" "Configuring kubectl for EKS"

EKS_CLUSTER=$(terraform output -raw eks_cluster_name 2>/dev/null)
KUBECONFIG_CMD=$(terraform output -raw eks_kubeconfig_command 2>/dev/null)

log_info "Running: $KUBECONFIG_CMD"
eval "$KUBECONFIG_CMD" 2>&1
echo ""

log_info "Verifying cluster connectivity..."
kubectl get nodes 2>&1
echo ""
log_success "kubectl configured for $EKS_CLUSTER"

# ============================================================================
# STEP 6: DEPLOY KUBERNETES WORKLOADS
# ============================================================================
log_step "6/9" "Deploying Kubernetes Workloads"

# 6a: Generate self-signed TLS cert
log_info "Generating self-signed TLS certificate..."
TLS_DIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" \
    -days 365 -nodes \
    -subj "/CN=cloudlens-lab.local/O=Keysight" 2>/dev/null

# Create or replace TLS secret
kubectl delete secret nginx-tls-secret --ignore-not-found 2>/dev/null
kubectl create secret tls nginx-tls-secret --cert="$TLS_DIR/tls.crt" --key="$TLS_DIR/tls.key" 2>&1
rm -rf "$TLS_DIR"
log_success "TLS secret created"

# 6b: Deploy nginx HTML ConfigMap (beautiful landing page)
log_info "Deploying nginx landing page..."
cat <<'YAMLEOF' | kubectl apply -f - 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-html-config
data:
  index.html: |
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>CloudLens K8s Visibility Lab</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                background: url('https://media.licdn.com/dms/image/v2/D4E12AQGQULcjkrFfLQ/article-cover_image-shrink_720_1280/B4EZdbNmg3HsAI-/0/1749581987621?e=2147483647&v=beta&t=uYez1XMOuUx8PXRmhH7hIvoNddW_IDQb-4hb5nWknPE') no-repeat center center fixed;
                background-size: cover;
                min-height: 100vh;
                overflow-x: hidden;
                position: relative;
            }
            .particles { position: absolute; top: 0; left: 0; width: 100%; height: 100%; pointer-events: none; z-index: 1; }
            .particle { position: absolute; background: rgba(255, 255, 255, 0.7); border-radius: 50%; animation: float 6s ease-in-out infinite; }
            @keyframes float {
                0% { transform: translateY(0px) translateX(0px) rotate(0deg); opacity: 0.4; }
                50% { transform: translateY(-60px) translateX(-10px) rotate(180deg); opacity: 1; }
                100% { transform: translateY(0px) translateX(0px) rotate(360deg); opacity: 0.4; }
            }
            .container { position: relative; z-index: 2; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
            .logo { width: 200px; height: auto; display: flex; align-items: center; justify-content: center; margin-bottom: 40px; animation: pulse 2s ease-in-out infinite; }
            .logo img { width: 100%; height: auto; filter: drop-shadow(0 10px 20px rgba(0,0,0,0.3)); }
            @keyframes pulse { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.05); } }
            .title { font-size: 3.5rem; font-weight: 900; background: linear-gradient(45deg, #ff6b6b, #4ecdc4, #45b7d1, #96ceb4, #feca57, #ff9ff3, #54a0ff); background-size: 400% 400%; -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; text-align: center; margin-bottom: 20px; animation: colorShift 4s ease-in-out infinite; }
            @keyframes colorShift { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }
            .subtitle { font-size: 1.4rem; color: rgba(255,255,255,0.95); margin-bottom: 20px; text-align: center; }
            .traffic-status { font-size: 1.1rem; color: rgba(255,255,255,0.85); margin-bottom: 40px; text-align: center; background: rgba(255,255,255,0.1); backdrop-filter: blur(10px); padding: 15px 30px; border-radius: 25px; border: 1px solid rgba(255,255,255,0.2); max-width: 600px; }
            .pod-info-card { background: rgba(255,255,255,0.18); backdrop-filter: blur(25px); border-radius: 25px; padding: 40px 50px; box-shadow: 0 30px 60px rgba(0,0,0,0.4); border: 1px solid rgba(255,255,255,0.25); min-width: 500px; max-width: 700px; }
            .pod-info-item { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; padding: 15px 0; border-bottom: 1px solid rgba(255,255,255,0.15); }
            .pod-info-item:last-child { border-bottom: none; margin-bottom: 0; }
            .pod-label { font-weight: 700; color: #ffd700; font-size: 1.2rem; min-width: 140px; }
            .pod-value { color: white; font-size: 1.2rem; font-weight: 500; text-align: right; flex: 1; }
            .refresh-btn { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; border: none; padding: 12px 35px; border-radius: 30px; font-size: 1.1rem; font-weight: 700; cursor: pointer; margin-top: 30px; transition: all 0.3s ease; box-shadow: 0 8px 20px rgba(0,0,0,0.4); }
            .refresh-btn:hover { transform: translateY(-3px); box-shadow: 0 12px 30px rgba(0,0,0,0.5); }
            @media (max-width: 768px) { .title { font-size: 2.5rem; } .logo { width: 150px; } .pod-info-card { min-width: 90%; padding: 30px 25px; } .pod-info-item { flex-direction: column; align-items: flex-start; gap: 8px; } .pod-value { text-align: left; } }
        </style>
    </head>
    <body>
        <div class="particles" id="particles"></div>
        <div class="container">
            <div class="logo"><img src="https://www.netpoleons.com/uploads/1/0/7/8/107892225/keysight-logo-01_orig.png" alt="Keysight Logo"></div>
            <h1 class="title">CLOUDLENS K8s VISIBILITY LAB</h1>
            <p class="subtitle">Powered by Keysight Technologies</p>
            <p class="traffic-status">If you see this page, your Kubernetes pod traffic is being successfully tapped and monitored by CloudLens</p>
            <div class="pod-info-card">
                <div class="pod-info-item"><span class="pod-label">Lab:</span><span class="pod-value">CloudLens K8s Lab</span></div>
                <div class="pod-info-item"><span class="pod-label">Namespace:</span><span class="pod-value">default</span></div>
                <div class="pod-info-item"><span class="pod-label">Cluster:</span><span class="pod-value">EKS</span></div>
                <div class="pod-info-item"><span class="pod-label">Platform:</span><span class="pod-value">AWS EKS</span></div>
                <div class="pod-info-item"><span class="pod-label">Status:</span><span class="pod-value" style="color: #00ff88;">Active & Monitored</span></div>
                <button class="refresh-btn" onclick="location.reload()">Refresh Page</button>
            </div>
        </div>
        <script>
            function createParticles() { const c = document.getElementById('particles'); for (let i = 0; i < 50; i++) { const p = document.createElement('div'); p.className = 'particle'; const size = Math.random() * 8 + 3; p.style.width = size + 'px'; p.style.height = size + 'px'; p.style.left = Math.random() * 100 + '%'; p.style.top = Math.random() * 100 + '%'; p.style.animationDelay = Math.random() * 8 + 's'; p.style.animationDuration = (Math.random() * 4 + 4) + 's'; c.appendChild(p); } }
            createParticles();
        </script>
    </body>
    </html>
YAMLEOF

# 6c: Deploy nginx config
log_info "Deploying nginx configuration..."
cat <<'YAMLEOF' | kubectl apply -f - 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  default.conf: |
    server {
        listen 80;
        listen 443 ssl;
        ssl_certificate /etc/nginx/ssl/tls.crt;
        ssl_certificate_key /etc/nginx/ssl/tls.key;
        location / {
            root /usr/share/nginx/html;
            index index.html;
        }
        location /health {
            return 200 'healthy';
            add_header Content-Type text/plain;
        }
    }
YAMLEOF

# 6d: Deploy cloudlens-config ConfigMap
log_info "Deploying CloudLens config..."
cat <<EOF | kubectl apply -f - 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudlens-config
data:
  clms_ip: "$CLMS_PRIVATE_IP"
  project_key: "REPLACE_WITH_YOUR_PROJECT_KEY"
EOF

# 6e: Deploy nginx-demo Deployment + Service
log_info "Deploying nginx-demo (2 replicas with TLS)..."
cat <<'YAMLEOF' | kubectl apply -f - 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  labels:
    app: nginx-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-demo
  template:
    metadata:
      labels:
        app: nginx-demo
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
          name: http
        - containerPort: 443
          name: https
        volumeMounts:
        - name: nginx-ssl
          mountPath: /etc/nginx/ssl
          readOnly: true
        - name: nginx-config
          mountPath: /etc/nginx/conf.d
          readOnly: true
        - name: nginx-html
          mountPath: /usr/share/nginx/html
          readOnly: true
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 5
      volumes:
      - name: nginx-ssl
        secret:
          secretName: nginx-tls-secret
      - name: nginx-config
        configMap:
          name: nginx-config
      - name: nginx-html
        configMap:
          name: nginx-html-config
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo
  labels:
    app: nginx-demo
spec:
  type: LoadBalancer
  ports:
  - name: http
    port: 80
    targetPort: 80
  - name: https
    port: 443
    targetPort: 443
  selector:
    app: nginx-demo
YAMLEOF

# Wait for pods
log_info "Waiting for nginx-demo pods..."
kubectl rollout status deployment/nginx-demo --timeout=120s 2>&1
log_success "nginx-demo deployed (2 replicas)"

# Wait for LoadBalancer URL
log_info "Waiting for LoadBalancer URL (may take 2-3 minutes)..."
for i in $(seq 1 30); do
    NGINX_URL=$(kubectl get svc nginx-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -n "$NGINX_URL" ]]; then
        log_success "nginx LoadBalancer: http://$NGINX_URL"
        break
    fi
    echo -ne "  Waiting for ELB... ($i/30)\r"
    sleep 10
done

if [[ -z "$NGINX_URL" ]]; then
    log_warn "LoadBalancer URL not ready yet. Check later: kubectl get svc nginx-demo"
fi

# ============================================================================
# STEP 7: DEPLOY CYPERF (IF ENABLED)
# ============================================================================
if [[ "$CYPERF_ENABLED" == "true" ]]; then
    log_step "7/9" "Deploying CyPerf Traffic Generator"

    CYPERF_PUBLIC_IP=$(terraform output -raw cyperf_controller_public_ip 2>/dev/null || echo "")
    CYPERF_PRIVATE_IP=$(terraform output -raw cyperf_controller_private_ip 2>/dev/null || echo "")

    if [[ -z "$CYPERF_PUBLIC_IP" ]]; then
        log_warn "CyPerf Controller IP not found. Skipping CyPerf deployment."
    else
        echo ""
        echo -e "  ${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${BOLD}${YELLOW}║          CyPerf License Activation Required             ║${NC}"
        echo -e "  ${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "  ${BOLD}${YELLOW}║                                                          ║${NC}"
        echo -e "  ${BOLD}${YELLOW}║  Before CyPerf can run tests, activate your license:     ║${NC}"
        echo -e "  ${BOLD}${YELLOW}║                                                          ║${NC}"
        echo -e "  ${BOLD}${YELLOW}║  1. Open: https://${CYPERF_PUBLIC_IP}$(printf '%*s' $((24 - ${#CYPERF_PUBLIC_IP})) '')║${NC}"
        echo -e "  ${BOLD}${YELLOW}║  2. Login: admin / CyPerf&Keysight#1                     ║${NC}"
        echo -e "  ${BOLD}${YELLOW}║  3. Settings (gear) > Licensing > License Manager         ║${NC}"
        echo -e "  ${BOLD}${YELLOW}║  4. Activate licenses > paste your codes > Activate       ║${NC}"
        echo -e "  ${BOLD}${YELLOW}║                                                          ║${NC}"
        echo -e "  ${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""

        if prompt_yes_no "Have you activated the CyPerf license (or want to skip and do it later)?"; then
            log_info "Deploying CyPerf K8s agents..."
            echo ""

            # Run the CyPerf deploy script
            if [[ -x "$SCRIPT_DIR/deploy-cyperf-k8s.sh" ]]; then
                "$SCRIPT_DIR/deploy-cyperf-k8s.sh" "$CYPERF_PRIVATE_IP" "$EKS_CLUSTER" "$AWS_REGION" "$AWS_PROFILE" 2>&1 || {
                    log_warn "CyPerf deployment had issues. You can re-run manually:"
                    echo "  ./scripts/deploy-cyperf-k8s.sh"
                }
            else
                log_warn "deploy-cyperf-k8s.sh not found or not executable. Run manually:"
                echo "  chmod +x ./scripts/deploy-cyperf-k8s.sh"
                echo "  ./scripts/deploy-cyperf-k8s.sh"
            fi
        else
            log_info "Skipping CyPerf deployment. Run later:"
            echo "  ./scripts/deploy-cyperf-k8s.sh"
        fi
    fi
else
    log_step "7/9" "CyPerf Deployment (Skipped - not enabled)"
    echo "  To enable CyPerf, set cyperf_enabled = true in terraform.tfvars"
    echo "  Then run: terraform apply && ./scripts/deploy-cyperf-k8s.sh"
fi

# ============================================================================
# STEP 8: GENERATE DOCUMENTATION
# ============================================================================
log_step "8/9" "Generating Deployment Documentation"

cd "$TF_DIR"

# Re-apply just documentation module (picks up any changes)
log_info "Regenerating documentation with current IPs..."
terraform apply -target=module.documentation -auto-approve -input=false 2>&1
echo ""

# Run post-deploy to patch nginx URL
if [[ -x "$SCRIPT_DIR/post-deploy.sh" ]]; then
    "$SCRIPT_DIR/post-deploy.sh" 2>&1
fi

GUIDE_PATH="$TF_DIR/generated/$DEPLOYMENT_PREFIX/$(echo "$DEPLOYMENT_PREFIX" | tr '[:lower:]' '[:upper:]')-GUIDE.md"
CREDS_PATH="$TF_DIR/generated/$DEPLOYMENT_PREFIX/credentials.txt"

if [[ -f "$GUIDE_PATH" ]]; then
    log_success "Lab guide: $GUIDE_PATH"
fi
if [[ -f "$CREDS_PATH" ]]; then
    log_success "Credentials: $CREDS_PATH"
fi

# ============================================================================
# STEP 9: DEPLOYMENT SUMMARY
# ============================================================================
log_step "9/9" "Deployment Complete!"

cd "$TF_DIR"

# Gather all outputs
CLMS_URL=$(terraform output -raw clms_url 2>/dev/null || echo "N/A")
KVO_URL=$(terraform output -raw kvo_url 2>/dev/null || echo "N/A")
VPB_IP=$(terraform output -raw vpb_ip 2>/dev/null || echo "N/A")
UBUNTU_IP=$(terraform output -raw ubuntu_ip 2>/dev/null || echo "N/A")
WINDOWS_IP=$(terraform output -raw windows_ip 2>/dev/null || echo "N/A")
TOOL_LINUX_IP=$(terraform output -raw tool_linux_ip 2>/dev/null || echo "N/A")
TOOL_WINDOWS_IP=$(terraform output -raw tool_windows_ip 2>/dev/null || echo "N/A")
CYPERF_URL=$(terraform output -raw cyperf_controller_ui_url 2>/dev/null || echo "")
PRIVATE_KEY=$(grep 'private_key_path' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/' | head -1)

echo ""
echo -e "${BOLD}${GREEN}============================================================================${NC}"
echo -e "${BOLD}${GREEN}  CLOUDLENS K8s VISIBILITY LAB - DEPLOYMENT COMPLETE${NC}"
echo -e "${BOLD}${GREEN}============================================================================${NC}"
echo ""
echo -e "  ${BOLD}Keysight Products${NC}"
echo "  ─────────────────────────────────────────────────────"
echo "  CLMS (CloudLens Manager):  $CLMS_URL"
echo "                             admin / Cl0udLens@dm!n"
echo "  KVO  (Vision One):         $KVO_URL"
echo "                             admin / admin"
echo "  vPB  (Packet Broker):      ssh -i $PRIVATE_KEY admin@$VPB_IP"
echo "                             admin / ixia"
if [[ -n "$CYPERF_URL" && "$CYPERF_URL" != "null" ]]; then
echo "  CyPerf Controller:         $CYPERF_URL"
echo "                             admin / CyPerf&Keysight#1"
fi
echo ""
echo -e "  ${BOLD}Workload VMs${NC}"
echo "  ─────────────────────────────────────────────────────"
echo "  Ubuntu:   ssh -i $PRIVATE_KEY ubuntu@$UBUNTU_IP"
echo "  Windows:  RDP to $WINDOWS_IP:3389 (Administrator)"
echo ""
echo -e "  ${BOLD}Tool VMs (Traffic Receivers)${NC}"
echo "  ─────────────────────────────────────────────────────"
echo "  Linux:    ssh -i $PRIVATE_KEY ubuntu@$TOOL_LINUX_IP"
echo "  Windows:  RDP to $TOOL_WINDOWS_IP:3389 (Administrator / CloudLens2024!)"
echo ""
if [[ -n "$NGINX_URL" ]]; then
echo -e "  ${BOLD}Nginx Demo App${NC}"
echo "  ─────────────────────────────────────────────────────"
echo "  HTTP:     http://$NGINX_URL"
echo "  HTTPS:    https://$NGINX_URL"
echo ""
fi
echo -e "  ${BOLD}EKS Cluster${NC}"
echo "  ─────────────────────────────────────────────────────"
echo "  Name:     $EKS_CLUSTER"
echo "  kubectl:  $KUBECONFIG_CMD"
echo ""
echo -e "  ${BOLD}Generated Documentation${NC}"
echo "  ─────────────────────────────────────────────────────"
echo "  Lab Guide:    $GUIDE_PATH"
echo "  Credentials:  $CREDS_PATH"
echo ""
echo -e "  ${BOLD}${YELLOW}NEXT STEPS:${NC}"
echo "  ─────────────────────────────────────────────────────"
echo "  1. Activate licenses in KVO: $KVO_URL"
echo "     (Settings > Product Licensing > Activate licenses)"
echo "  2. Log in to CLMS and create KVO user: $CLMS_URL"
echo "  3. Register CLMS in KVO Inventory"
echo "  4. Follow the lab guide for exercises"
if [[ -n "$CYPERF_URL" && "$CYPERF_URL" != "null" ]]; then
echo "  5. Activate CyPerf license: $CYPERF_URL"
echo "     (Settings > Licensing > License Manager)"
fi
echo ""
echo -e "  ${BOLD}Cost Management:${NC}"
echo "    Stop all:    ./scripts/stop-all.sh"
echo "    Start all:   ./scripts/start-all.sh"
echo "    Destroy all: cd terraform && terraform destroy"
echo ""
echo -e "${BOLD}${GREEN}============================================================================${NC}"
echo ""
