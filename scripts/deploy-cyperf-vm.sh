#!/bin/bash
# ============================================================================
# DEPLOY CYPERF VM AGENTS - NGINX REVERSE PROXY SETUP
# ============================================================================
# Post-terraform script for VM-based CyPerf agents.
# Sets up nginx reverse proxy to route CyPerf client traffic through
# nginx pods (where CloudLens sensors capture it) to the CyPerf server.
#
# Architecture:
#   CyPerf Client VM (test ENI) -> nginx NLB -> nginx pod -> CyPerf Server VM
#   CloudLens sensors on nginx pods see ALL traffic.
#
# This script:
#   1. Gets CyPerf Server test ENI IP from terraform output
#   2. For each SE namespace:
#      - Creates cyperf-backend Service + Endpoints (pointing to server VM)
#      - Rolling restart of nginx pods to pick up proxy config
#   3. Auto-configures CyPerf test session via configure-cyperf-test.sh
#
# Prerequisites:
#   - CyPerf Controller + Agent VMs deployed (terraform apply with cyperf_enabled=true)
#   - Shared EKS cluster running with SE namespaces
#   - nginx pods deployed in SE namespaces
#
# Usage:
#   ./deploy-cyperf-vm.sh [NUM_SES] [CLUSTER_NAME] [AWS_REGION] [AWS_PROFILE]
#   ./deploy-cyperf-vm.sh 25
#   ./deploy-cyperf-vm.sh 5 se-lab-shared-eks us-west-2 cloudlens-lab
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="$BASE_DIR/kubernetes_manifests"

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

# Configuration
NUM_SES=${1:-25}
CLUSTER_NAME=${2:-"se-lab-shared-eks"}
AWS_REGION=${3:-"us-west-2"}
AWS_PROFILE=${4:-"cloudlens-lab"}

show_help() {
    echo "Usage: $0 [NUM_SES] [CLUSTER_NAME] [AWS_REGION] [AWS_PROFILE]"
    echo ""
    echo "Sets up nginx reverse proxy for VM-based CyPerf agents."
    echo ""
    echo "Arguments:"
    echo "  NUM_SES        Number of SE namespaces (default: 25)"
    echo "  CLUSTER_NAME   EKS cluster name (default: se-lab-shared-eks)"
    echo "  AWS_REGION     AWS region (default: us-west-2)"
    echo "  AWS_PROFILE    AWS CLI profile (default: cloudlens-lab)"
    echo ""
    echo "Examples:"
    echo "  $0 25                    # Setup for 25 SE namespaces"
    echo "  $0 5                     # Setup for 5 SE namespaces"
    echo ""
    echo "Cleanup:"
    echo "  for i in \$(seq -f '%02g' 1 25); do"
    echo "    kubectl delete svc cyperf-backend -n se-\$i --ignore-not-found"
    echo "    kubectl delete endpoints cyperf-backend -n se-\$i --ignore-not-found"
    echo "  done"
    echo ""
    exit 0
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

# Verify manifest template exists
if [[ ! -f "$MANIFESTS_DIR/cyperf-nginx-proxy.yaml" ]]; then
    log_error "CyPerf nginx proxy template not found: $MANIFESTS_DIR/cyperf-nginx-proxy.yaml"
    exit 1
fi

echo ""
echo "============================================================================"
echo "  Deploy CyPerf VM Agents - Nginx Reverse Proxy Setup"
echo "============================================================================"
echo ""

# ============================================================================
# STEP 1: Get CyPerf Server test ENI IP from terraform
# ============================================================================

log_info "Getting CyPerf Server test ENI IP from terraform output..."
CYPERF_SERVER_TEST_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_server_test_ip 2>/dev/null || echo "")

if [[ -z "$CYPERF_SERVER_TEST_IP" ]]; then
    log_error "Could not get CyPerf Server test IP from terraform output."
    log_error "Ensure cyperf_enabled=true and terraform apply has been run."
    exit 1
fi
log_success "CyPerf Server test IP: $CYPERF_SERVER_TEST_IP"

# Also get agent public IPs for status report
CYPERF_CLIENT_PUBLIC_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_client_public_ip 2>/dev/null || echo "")
CYPERF_SERVER_PUBLIC_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_server_public_ip 2>/dev/null || echo "")
CYPERF_CLIENT_TEST_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_client_test_ip 2>/dev/null || echo "")

echo ""
log_info "Configuration:"
echo "  CyPerf Client public IP:  $CYPERF_CLIENT_PUBLIC_IP"
echo "  CyPerf Client test IP:    $CYPERF_CLIENT_TEST_IP"
echo "  CyPerf Server public IP:  $CYPERF_SERVER_PUBLIC_IP"
echo "  CyPerf Server test IP:    $CYPERF_SERVER_TEST_IP"
echo "  SE namespaces:            se-01 through se-$(printf '%02d' $NUM_SES)"
echo "  EKS Cluster:              $CLUSTER_NAME"
echo "  Region:                   $AWS_REGION"
echo ""

# ============================================================================
# STEP 2: Accept EULA on controller
# ============================================================================

CONTROLLER_PUBLIC_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_controller_public_ip 2>/dev/null || echo "")
if [[ -n "$CONTROLLER_PUBLIC_IP" ]]; then
    log_info "Accepting CyPerf EULA on controller..."
    EULA_STATUS=$(curl -sk "https://${CONTROLLER_PUBLIC_IP}/eula/v1/eula" 2>/dev/null || echo "[]")
    if echo "$EULA_STATUS" | grep -q '"accepted":false'; then
        curl -sk "https://${CONTROLLER_PUBLIC_IP}/eula/v1/eula/CyPerf" \
            -X POST -H "Content-Type: application/json" -d '{"accepted": true}' >/dev/null 2>&1
        log_success "EULA accepted"
    else
        log_info "EULA already accepted"
    fi
fi

# ============================================================================
# STEP 3: Configure kubectl
# ============================================================================

log_info "Configuring kubectl..."
aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --profile "$AWS_PROFILE"

# ============================================================================
# STEP 4: Create cyperf-backend Service + Endpoints per SE namespace
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Creating cyperf-backend Service + Endpoints per namespace"
echo "------------------------------------------------------------"
echo ""

DEPLOYED=0
SKIPPED=0

for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"

    echo -e "${BLUE}[${i}/${NUM_SES}]${NC} Setting up proxy for: $NAMESPACE"

    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_warning "  Namespace $NAMESPACE does not exist. Skipping."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Apply cyperf-backend Service + Endpoints template
    sed -e "s/\${NAMESPACE}/$NAMESPACE/g" \
        -e "s/\${CYPERF_SERVER_TEST_IP}/$CYPERF_SERVER_TEST_IP/g" \
        "$MANIFESTS_DIR/cyperf-nginx-proxy.yaml" | kubectl apply -n "$NAMESPACE" -f -

    log_success "  Created cyperf-backend service -> $CYPERF_SERVER_TEST_IP"
    DEPLOYED=$((DEPLOYED + 1))
done

# ============================================================================
# STEP 5: Patch nginx ConfigMap with reverse proxy upstream
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Patching nginx ConfigMap with CyPerf reverse proxy config"
echo "------------------------------------------------------------"
echo ""

for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"

    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        continue
    fi

    # Detect configmap name (nginx-ssl-config or nginx-config)
    CONFIGMAP_NAME=""
    if kubectl get configmap nginx-ssl-config -n "$NAMESPACE" &>/dev/null; then
        CONFIGMAP_NAME="nginx-ssl-config"
    elif kubectl get configmap nginx-config -n "$NAMESPACE" &>/dev/null; then
        CONFIGMAP_NAME="nginx-config"
    else
        log_warning "  No nginx configmap found in $NAMESPACE. Skipping."
        continue
    fi

    # Check if already patched (contains cyperf_backend)
    if kubectl get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o jsonpath='{.data.default\.conf}' 2>/dev/null | grep -q "CyPerf DUT mode"; then
        log_info "  $NAMESPACE: nginx config already patched for CyPerf"
    else
        # Patch the configmap: port 80 serves CyPerf traffic, port 443 serves SE demo page
        # CyPerf server agent doesn't listen on OS-level TCP ports, so nginx responds
        # directly to HTTP requests. CloudLens sensors capture all traffic on the pods.
        kubectl apply -n "$NAMESPACE" -f - <<CFGEOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $CONFIGMAP_NAME
data:
  default.conf: |
    # Port 80: Accept ALL HTTP traffic and respond (CyPerf DUT mode)
    # CyPerf client sends real HTTP/Netflix traffic here.
    # CloudLens sensors capture all traffic on nginx pods.
    server {
        listen 80;

        location / {
            root /usr/share/nginx/html;
            index index.html index.htm;
            try_files \$uri \$uri/ =200;
        }

        client_max_body_size 100m;

        location /health {
            return 200 'healthy';
            add_header Content-Type text/plain;
        }
    }

    # Port 443: Static SE demo page (HTTPS)
    server {
        listen 443 ssl;

        ssl_certificate /etc/nginx/ssl/tls.crt;
        ssl_certificate_key /etc/nginx/ssl/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        location / {
            root /usr/share/nginx/html;
            index index.html index.htm;
        }

        location /health {
            return 200 'healthy';
            add_header Content-Type text/plain;
        }
    }
CFGEOF
        log_success "  Patched nginx config in $NAMESPACE"
    fi
done

# ============================================================================
# STEP 6: Rolling restart nginx pods to pick up proxy config
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Rolling restart nginx pods to activate reverse proxy"
echo "------------------------------------------------------------"
echo ""

for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"

    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        continue
    fi

    # Check if nginx deployment exists (try both names)
    if kubectl get deployment nginx-demo -n "$NAMESPACE" &>/dev/null; then
        kubectl rollout restart deployment/nginx-demo -n "$NAMESPACE"
        log_success "  Restarted nginx in $NAMESPACE"
    elif kubectl get deployment nginx-cloudlens -n "$NAMESPACE" &>/dev/null; then
        kubectl rollout restart deployment/nginx-cloudlens -n "$NAMESPACE"
        log_success "  Restarted nginx in $NAMESPACE"
    fi
done

# ============================================================================
# STEP 7: Collect NLB hostnames for status report
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Collecting nginx NLB endpoints"
echo "------------------------------------------------------------"
echo ""

NLB_LIST=""
for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"

    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        continue
    fi

    NLB_HOST=$(kubectl get svc nginx-demo -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || \
              kubectl get svc nginx-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -n "$NLB_HOST" ]]; then
        echo "  $NAMESPACE: $NLB_HOST"
        NLB_LIST="${NLB_LIST}${NLB_HOST},"
    fi
done

# ============================================================================
# STEP 8: Create shared proxy NLB for cross-SE traffic distribution
# ============================================================================
# CyPerf uses raw sockets that bypass iptables, so we can't DNAT on the client.
# Instead, we create a proxy nginx pod that round-robins to all SE nginx services.
# This gives every SE real traffic from CyPerf for CloudLens to capture.

echo ""
echo "------------------------------------------------------------"
log_info "Setting up shared CyPerf traffic proxy (distributes to all SEs)"
echo "------------------------------------------------------------"
echo ""

# Create shared namespace
kubectl create namespace cyperf-shared --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

# Build upstream block dynamically from active SE namespaces
UPSTREAM_SERVERS=""
for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        UPSTREAM_SERVERS="${UPSTREAM_SERVERS}        server nginx-demo.${NAMESPACE}.svc.cluster.local:80;\n"
    fi
done

if [[ -z "$UPSTREAM_SERVERS" ]]; then
    log_warning "No SE namespaces found for proxy upstream. Skipping proxy setup."
else
    # Apply proxy ConfigMap, Deployment, and Service
    cat <<PROXYEOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cyperf-proxy-config
  namespace: cyperf-shared
data:
  default.conf: |
    upstream all_ses {
$(echo -e "$UPSTREAM_SERVERS")    }
    server {
        listen 80;
        location / {
            proxy_pass http://all_ses;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
        location /health {
            return 200 'healthy';
            add_header Content-Type text/plain;
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cyperf-proxy
  namespace: cyperf-shared
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cyperf-proxy
  template:
    metadata:
      labels:
        app: cyperf-proxy
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
        volumeMounts:
        - name: config
          mountPath: /etc/nginx/conf.d
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 128Mi
      volumes:
      - name: config
        configMap:
          name: cyperf-proxy-config
---
apiVersion: v1
kind: Service
metadata:
  name: cyperf-traffic-lb
  namespace: cyperf-shared
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  selector:
    app: cyperf-proxy
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
PROXYEOF

    # Wait for proxy NLB to be provisioned
    log_info "Waiting for shared proxy NLB to provision..."
    for attempt in $(seq 1 20); do
        PROXY_NLB_HOST=$(kubectl get svc cyperf-traffic-lb -n cyperf-shared \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [[ -n "$PROXY_NLB_HOST" ]]; then
            log_success "Shared proxy NLB: $PROXY_NLB_HOST"
            break
        fi
        echo -e "  Attempt $attempt/20 - provisioning..."
        sleep 15
    done

    if [[ -z "$PROXY_NLB_HOST" ]]; then
        log_warning "Shared proxy NLB not ready yet. It will provision in the background."
    fi
fi

# ============================================================================
# STEP 9: Auto-configure CyPerf test session
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Configuring CyPerf test session"
echo "------------------------------------------------------------"
echo ""

if [[ -n "$CONTROLLER_PUBLIC_IP" ]]; then
    "$SCRIPT_DIR/configure-cyperf-test.sh" "$CONTROLLER_PUBLIC_IP" "$AWS_PROFILE" "$AWS_REGION"
else
    "$SCRIPT_DIR/configure-cyperf-test.sh" "" "$AWS_PROFILE" "$AWS_REGION"
fi

# ============================================================================
# STATUS REPORT
# ============================================================================

echo ""
echo "============================================================================"
echo "  CyPerf VM Agent Deployment Complete"
echo "============================================================================"
echo ""
echo "  Agent VMs:"
echo "    Client: $CYPERF_CLIENT_PUBLIC_IP (test: $CYPERF_CLIENT_TEST_IP)"
echo "    Server: $CYPERF_SERVER_PUBLIC_IP (test: $CYPERF_SERVER_TEST_IP)"
echo ""
echo "  Nginx Reverse Proxy:"
echo "    Namespaces configured: $DEPLOYED"
echo "    Skipped:               $SKIPPED"
echo ""
echo "  Traffic Path:"
echo "    CyPerf Client ($CYPERF_CLIENT_TEST_IP)"
echo "      -> nginx NLB -> nginx pod (CloudLens captures here)"
echo "      -> cyperf-backend service -> CyPerf Server ($CYPERF_SERVER_TEST_IP)"
echo ""
echo "  SSH Access:"
echo "    Client: ssh -i ~/Downloads/cloudlens-se-training.pem cyperf@$CYPERF_CLIENT_PUBLIC_IP"
echo "    Server: ssh -i ~/Downloads/cloudlens-se-training.pem cyperf@$CYPERF_SERVER_PUBLIC_IP"
echo ""
echo "  Controller UI: https://$CONTROLLER_PUBLIC_IP"
echo "  Login:         admin / <CYPERF_PASSWORD>"
echo ""
echo "  Verify:"
echo "    kubectl get svc cyperf-backend -n se-01"
echo "    kubectl get endpoints cyperf-backend -n se-01"
echo ""
echo "  Cleanup:"
echo "    for i in \$(seq -f '%02g' 1 $NUM_SES); do"
echo "      kubectl delete svc cyperf-backend -n se-\$i --ignore-not-found"
echo "      kubectl delete endpoints cyperf-backend -n se-\$i --ignore-not-found"
echo "    done"
echo ""
echo "============================================================================"
