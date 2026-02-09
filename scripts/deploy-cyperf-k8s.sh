#!/bin/bash
# ============================================================================
# DEPLOY CYPERF K8S AGENTS (STANDALONE - NO VM DEPENDENCY)
# ============================================================================
# Deploys CyPerf client and server agents as K8s pods in the cyperf-shared
# namespace. This replaces the VM-based agent approach which has ENA/
# AF_PACKET compatibility issues on AWS.
#
# Architecture (NLB-free, ClusterIP only):
#   CyPerf Client Pod -> cyperf-proxy Pod (ClusterIP) -> nginx-demo pods (CloudLens captures)
#   All pods use K8s networking
#
# This script:
#   1. Cleans up all existing CyPerf K8s resources
#   2. Cleans stale agent registrations on the controller
#   3. Deploys cyperf-proxy (nginx round-robin to all SE namespaces) as ClusterIP
#   4. Deploys client + server agent pods
#   5. Waits for agent registration, then gets proxy pod IP
#   6. Configures the CyPerf test session via REST API with proxy pod IP as DUT
#
# Prerequisites:
#   - CyPerf Controller VM deployed and accessible
#   - Shared EKS cluster running with SE namespaces
#   - nginx-demo pods deployed in SE namespaces
#
# Usage:
#   ./deploy-cyperf-k8s.sh [CONTROLLER_PRIVATE_IP] [CLUSTER_NAME] [AWS_REGION] [AWS_PROFILE]
#   ./deploy-cyperf-k8s.sh                          # Auto-detect all
#   ./deploy-cyperf-k8s.sh 10.100.30.103            # Explicit controller IP
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
CONTROLLER_PRIVATE_IP=${1:-""}
CLUSTER_NAME=${2:-"se-lab-shared-eks"}
AWS_REGION=${3:-"us-west-2"}
AWS_PROFILE=${4:-"cloudlens-lab"}
NAMESPACE="cyperf-shared"
AGENT_IMAGE="public.ecr.aws/keysight/cyperf-agent:release7.0"

show_help() {
    echo "Usage: $0 [CONTROLLER_PRIVATE_IP] [CLUSTER_NAME] [AWS_REGION] [AWS_PROFILE]"
    echo ""
    echo "Deploys CyPerf agents as K8s pods with ClusterIP proxy (no NLB, no VMs)."
    echo ""
    echo "Arguments:"
    echo "  CONTROLLER_PRIVATE_IP  CyPerf controller private IP (default: auto-detect)"
    echo "  CLUSTER_NAME           EKS cluster name (default: se-lab-shared-eks)"
    echo "  AWS_REGION             AWS region (default: us-west-2)"
    echo "  AWS_PROFILE            AWS CLI profile (default: cloudlens-lab)"
    echo ""
    echo "Cleanup:"
    echo "  kubectl delete pod,svc,deployment,configmap --all -n cyperf-shared"
    echo ""
    exit 0
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

echo ""
echo "============================================================================"
echo "  Deploy CyPerf K8s Agents (Standalone - ClusterIP Proxy)"
echo "============================================================================"
echo ""

# ============================================================================
# STEP 1: Auto-detect controller private IP
# ============================================================================

if [[ -z "$CONTROLLER_PRIVATE_IP" ]]; then
    log_info "Auto-detecting CyPerf Controller private IP..."
    CONTROLLER_PRIVATE_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_controller_private_ip 2>/dev/null || echo "")
    if [[ -z "$CONTROLLER_PRIVATE_IP" ]]; then
        log_error "Could not auto-detect CyPerf Controller private IP."
        log_error "Provide it explicitly: $0 <CONTROLLER_PRIVATE_IP>"
        exit 1
    fi
fi
log_success "Controller private IP: $CONTROLLER_PRIVATE_IP"

# Also get public IP for UI access
CONTROLLER_PUBLIC_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_controller_public_ip 2>/dev/null || echo "")

# Controller IP for API calls (prefer public)
CONTROLLER_API_IP="$CONTROLLER_PUBLIC_IP"
if [[ -z "$CONTROLLER_API_IP" ]]; then
    CONTROLLER_API_IP="$CONTROLLER_PRIVATE_IP"
fi

# ============================================================================
# STEP 2: Configure kubectl
# ============================================================================

log_info "Configuring kubectl..."
aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --profile "$AWS_PROFILE"

# ============================================================================
# STEP 3: Clean up ALL existing CyPerf K8s resources
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Cleaning up all existing CyPerf K8s resources"
echo "------------------------------------------------------------"
echo ""

# Delete everything in cyperf-shared namespace
log_info "Deleting all resources in $NAMESPACE namespace..."
kubectl delete pod,svc,deployment,configmap,endpoints --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

# Delete cyperf-backend services/endpoints from SE namespaces
log_info "Cleaning cyperf-backend from SE namespaces..."
for i in $(seq -f "%02g" 1 22); do
    NS="se-${i}"
    if kubectl get namespace "$NS" &>/dev/null; then
        kubectl delete svc cyperf-backend -n "$NS" --ignore-not-found 2>/dev/null || true
        kubectl delete endpoints cyperf-backend -n "$NS" --ignore-not-found 2>/dev/null || true
    fi
done
log_success "K8s cleanup complete"

# Wait for pods to fully terminate
log_info "Waiting for old pods to terminate..."
sleep 5
kubectl wait --for=delete pod -l app=cyperf-agent -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl wait --for=delete pod -l app=cyperf-proxy -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

# ============================================================================
# STEP 4: Clean stale agent registrations on controller
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Cleaning stale agent registrations on controller"
echo "------------------------------------------------------------"
echo ""

get_token() {
    curl -sk "https://${CONTROLLER_API_IP}/auth/realms/keysight/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=admin-cli&username=admin&password=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("<CYPERF_PASSWORD>"))')" \
        2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null
}

TOKEN=$(get_token)
if [[ -n "$TOKEN" ]]; then
    # Delete all existing sessions
    SESSIONS=$(curl -sk -H "Authorization: Bearer $TOKEN" \
        "https://${CONTROLLER_API_IP}/api/v2/sessions" 2>/dev/null)
    SESSION_IDS=$(echo "$SESSIONS" | python3 -c "
import sys,json
try:
    sessions = json.load(sys.stdin)
    for s in sessions:
        print(s['id'])
except: pass
" 2>/dev/null)

    if [[ -n "$SESSION_IDS" ]]; then
        while IFS= read -r sid; do
            if [[ -n "$sid" ]]; then
                curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" \
                    "https://${CONTROLLER_API_IP}/api/v2/sessions/${sid}" >/dev/null 2>&1
                log_info "  Deleted session: $sid"
            fi
        done <<< "$SESSION_IDS"
        log_success "All existing sessions deleted"
    else
        log_info "No existing sessions to clean"
    fi

    # Delete stale agent registrations
    AGENT_IDS=$(curl -sk -H "Authorization: Bearer $TOKEN" \
        "https://${CONTROLLER_API_IP}/api/v2/agents" 2>/dev/null | python3 -c "
import sys,json
try:
    agents = json.load(sys.stdin)
    for a in agents:
        print(a.get('id',''))
except: pass
" 2>/dev/null)

    if [[ -n "$AGENT_IDS" ]]; then
        while IFS= read -r aid; do
            if [[ -n "$aid" ]]; then
                curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" \
                    "https://${CONTROLLER_API_IP}/api/v2/agents/${aid}" >/dev/null 2>&1
                log_info "  Deleted agent: $aid"
            fi
        done <<< "$AGENT_IDS"
        log_success "Stale agent registrations cleaned"
    else
        log_info "No stale agents to clean"
    fi
else
    log_warning "Could not authenticate to controller. Skipping controller cleanup."
fi

# ============================================================================
# STEP 5: Ensure cyperf-shared namespace exists
# ============================================================================

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

# ============================================================================
# STEP 6: Deploy cyperf-proxy (ClusterIP, round-robin to all SE namespaces)
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Deploying cyperf-proxy (ClusterIP -> all SE nginx-demo services)"
echo "------------------------------------------------------------"
echo ""

# Build upstream block from active SE namespaces
UPSTREAM_SERVERS=""
SE_COUNT=0
for i in $(seq -f "%02g" 1 22); do
    NS="se-${i}"
    if kubectl get namespace "$NS" &>/dev/null; then
        # Check for nginx-demo service
        SVC_NAME=$(kubectl get svc -n "$NS" -o name 2>/dev/null | grep -E "nginx-demo|nginx-service" | head -1 | sed 's|service/||')
        if [[ -n "$SVC_NAME" ]]; then
            UPSTREAM_SERVERS="${UPSTREAM_SERVERS}        server ${SVC_NAME}.${NS}.svc.cluster.local:80;\n"
            SE_COUNT=$((SE_COUNT + 1))
        fi
    fi
done

if [[ -z "$UPSTREAM_SERVERS" ]]; then
    log_error "No SE namespaces with nginx services found. Cannot create proxy."
    exit 1
fi

log_info "Found $SE_COUNT SE namespaces with nginx services"

cat <<PROXYEOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cyperf-proxy-config
  namespace: $NAMESPACE
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
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cyperf-proxy
  namespace: $NAMESPACE
spec:
  replicas: 1
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
        image: nginx:1.25-alpine
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
      tolerations:
      - key: "se-id"
        operator: "Exists"
        effect: "NoSchedule"
---
apiVersion: v1
kind: Service
metadata:
  name: cyperf-proxy
  namespace: $NAMESPACE
  labels:
    app: cyperf-proxy
spec:
  type: ClusterIP
  selector:
    app: cyperf-proxy
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
PROXYEOF

log_success "cyperf-proxy Deployment + ClusterIP Service created"

# Wait for proxy pod to be ready
log_info "Waiting for cyperf-proxy pod to be ready..."
kubectl rollout status deployment/cyperf-proxy -n "$NAMESPACE" --timeout=120s 2>/dev/null || {
    log_warning "Proxy deployment not ready yet. Checking status..."
    kubectl get pods -n "$NAMESPACE" -l app=cyperf-proxy -o wide
}

# Get proxy pod IP (direct pod IP, not ClusterIP - avoids kube-proxy NAT)
PROXY_POD_IP=$(kubectl get pods -n "$NAMESPACE" -l app=cyperf-proxy -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
if [[ -z "$PROXY_POD_IP" ]]; then
    log_warning "Could not get proxy pod IP. Falling back to ClusterIP service IP."
    PROXY_POD_IP=$(kubectl get svc cyperf-proxy -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
fi
log_success "Proxy pod IP (DUT target): $PROXY_POD_IP"

# Verify proxy can reach SE nginx pods
log_info "Verifying proxy connectivity to SE nginx pods..."
PROXY_POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=cyperf-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$PROXY_POD_NAME" ]]; then
    PROXY_TEST=$(kubectl exec "$PROXY_POD_NAME" -n "$NAMESPACE" -- curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null || echo "000")
    if [[ "$PROXY_TEST" == "200" ]]; then
        log_success "Proxy health check passed"
    else
        log_warning "Proxy health check returned: $PROXY_TEST"
    fi
fi

# ============================================================================
# STEP 7: Deploy CyPerf agent pods
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Deploying CyPerf agent pods (image: $AGENT_IMAGE)"
echo "------------------------------------------------------------"
echo ""

# Deploy client agent
log_info "Deploying CyPerf Client agent..."
sed -e "s|\${CONTROLLER_PRIVATE_IP}|${CONTROLLER_PRIVATE_IP}|g" \
    "$MANIFESTS_DIR/cyperf-agent-client.yaml" | kubectl apply -f -
log_success "Client agent pod created"

# Deploy server agent + service
log_info "Deploying CyPerf Server agent..."
sed -e "s|\${CONTROLLER_PRIVATE_IP}|${CONTROLLER_PRIVATE_IP}|g" \
    "$MANIFESTS_DIR/cyperf-agent-server.yaml" | kubectl apply -f -
log_success "Server agent pod + service created"

# ============================================================================
# STEP 8: Wait for pods to be ready
# ============================================================================

echo ""
log_info "Waiting for CyPerf agent pods to start..."
kubectl wait --for=condition=Ready pod/cyperf-agent-client -n "$NAMESPACE" --timeout=300s 2>/dev/null || {
    log_warning "Client pod not ready yet. Checking status..."
    kubectl describe pod cyperf-agent-client -n "$NAMESPACE" 2>/dev/null | tail -20
}

kubectl wait --for=condition=Ready pod/cyperf-agent-server -n "$NAMESPACE" --timeout=300s 2>/dev/null || {
    log_warning "Server pod not ready yet. Checking status..."
    kubectl describe pod cyperf-agent-server -n "$NAMESPACE" 2>/dev/null | tail -20
}

echo ""
log_info "Pod status:"
kubectl get pods -n "$NAMESPACE" -o wide

# ============================================================================
# STEP 9: Verify agent registration with controller
# ============================================================================

echo ""
log_info "Waiting for agents to register with controller..."

AGENTS_READY=false
for attempt in $(seq 1 20); do
    TOKEN=$(get_token)
    if [[ -n "$TOKEN" ]]; then
        AGENT_COUNT=$(curl -sk -H "Authorization: Bearer $TOKEN" \
            "https://${CONTROLLER_API_IP}/api/v2/agents" 2>/dev/null | python3 -c "
import sys,json
agents = json.load(sys.stdin)
tagged = [a for a in agents if any('role' in str(t) for t in a.get('AgentTags',[]))]
print(len(tagged))
" 2>/dev/null || echo "0")

        if [[ "$AGENT_COUNT" -ge 2 ]]; then
            AGENTS_READY=true
            log_success "Both K8s agents registered with controller ($AGENT_COUNT agents with role tags)"
            break
        fi
    fi
    echo -e "  Attempt $attempt/20 - ${AGENT_COUNT:-0}/2 agents registered, waiting 15s..."
    sleep 15
done

if [[ "$AGENTS_READY" != "true" ]]; then
    log_warning "Not all agents registered yet. They may still be initializing."
    log_warning "Check the CyPerf Controller UI: https://$CONTROLLER_API_IP"
fi

# ============================================================================
# STEP 10: Configure CyPerf test session (with proxy pod IP as DUT)
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Configuring CyPerf test session (DUT = proxy pod IP: $PROXY_POD_IP)"
echo "------------------------------------------------------------"
echo ""

if [[ -n "$CONTROLLER_PUBLIC_IP" && -n "$PROXY_POD_IP" ]]; then
    "$SCRIPT_DIR/configure-cyperf-test.sh" "$CONTROLLER_PUBLIC_IP" "$AWS_PROFILE" "$AWS_REGION" "$PROXY_POD_IP"
elif [[ -n "$CONTROLLER_PUBLIC_IP" ]]; then
    log_warning "No proxy pod IP available. Test session DUT will need manual configuration."
    "$SCRIPT_DIR/configure-cyperf-test.sh" "$CONTROLLER_PUBLIC_IP" "$AWS_PROFILE" "$AWS_REGION"
else
    log_warning "Cannot auto-configure test session (no controller public IP)"
    log_warning "Configure manually at: https://<controller-ip>"
fi

# ============================================================================
# STEP 11: iptables fixer (background)
# CyPerf portmanager sets INPUT DROP after test init — reset to ACCEPT
# ============================================================================

echo ""
echo "------------------------------------------------------------"
log_info "Starting iptables fixer (background, 15 min)..."
echo "------------------------------------------------------------"
echo ""

(for i in $(seq 1 180); do
    kubectl exec -n "$NAMESPACE" cyperf-agent-client -- iptables-nft -P INPUT ACCEPT 2>/dev/null
    kubectl exec -n "$NAMESPACE" cyperf-agent-server -- iptables-nft -P INPUT ACCEPT 2>/dev/null
    sleep 5
done) &
IPTABLES_FIXER_PID=$!
log_success "iptables fixer PID: $IPTABLES_FIXER_PID (will run for ~15 min in background)"

# ============================================================================
# STATUS REPORT
# ============================================================================

CLIENT_POD_IP=$(kubectl get pod cyperf-agent-client -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "pending")
SERVER_POD_IP=$(kubectl get pod cyperf-agent-server -n "$NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "pending")

echo ""
echo "============================================================================"
echo "  CyPerf K8s Agent Deployment Complete"
echo "============================================================================"
echo ""
echo "  Agent Pods (namespace: $NAMESPACE):"
echo "    Client: cyperf-agent-client (IP: $CLIENT_POD_IP)"
echo "    Server: cyperf-agent-server (IP: $SERVER_POD_IP)"
echo ""
echo "  Proxy (ClusterIP - no NLB):"
echo "    cyperf-proxy pod IP: $PROXY_POD_IP (used as DUT target)"
echo "    Routes to $SE_COUNT SE namespaces' nginx-demo services"
echo ""
echo "  Traffic Path:"
echo "    CyPerf Client Pod ($CLIENT_POD_IP)"
echo "      -> cyperf-proxy ($PROXY_POD_IP) [ClusterIP, round-robin]"
echo "      -> nginx-demo pods in SE namespaces (CloudLens captures here)"
echo ""
echo "  Controller UI: https://$CONTROLLER_API_IP"
echo "  Login:         admin / <CYPERF_PASSWORD>"
echo ""
echo "  Verify proxy connectivity from client pod:"
echo "    kubectl exec cyperf-agent-client -n $NAMESPACE -- curl -s http://$PROXY_POD_IP/"
echo ""
echo "  Monitor pods:"
echo "    kubectl get pods -n $NAMESPACE -o wide"
echo "    kubectl logs cyperf-agent-client -n $NAMESPACE --tail=50"
echo ""
echo "  Cleanup:"
echo "    kubectl delete pod,svc,deployment,configmap --all -n $NAMESPACE"
echo ""
echo "============================================================================"
echo ""
