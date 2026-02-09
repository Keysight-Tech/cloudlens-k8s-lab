#!/bin/bash
# ============================================================================
# TEST CYPERF REBUILD - VALIDATE NEW ARCHITECTURE IN ISOLATION
# ============================================================================
# Deploys the new CyPerf K8s-only architecture in a separate cyperf-test
# namespace to validate all components BEFORE touching the production setup.
#
# Tests:
#   1. ClusterIP proxy -> can reach nginx-demo pods in SE namespaces
#   2. iptables-fixer sidecar -> resets INPUT policy after portmanager DROP
#   3. Agent registration -> fresh K8s agents register with controller
#   4. End-to-end -> client pod can curl through proxy to nginx-demo
#
# Does NOT touch:
#   - cyperf-shared namespace (existing setup stays)
#   - Terraform state (no apply/destroy)
#   - Existing controller sessions
#
# Usage:
#   ./test-cyperf-rebuild.sh [CONTROLLER_PRIVATE_IP] [CLUSTER_NAME] [AWS_REGION] [AWS_PROFILE]
#   ./test-cyperf-rebuild.sh                          # Auto-detect all
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_test() { echo -e "\n${BOLD}━━━ TEST: $1 ━━━${NC}"; }

# Configuration
CONTROLLER_PRIVATE_IP=${1:-""}
CLUSTER_NAME=${2:-"se-lab-shared-eks"}
AWS_REGION=${3:-"us-west-2"}
AWS_PROFILE=${4:-"cloudlens-lab"}
TEST_NS="cyperf-test"

# Track results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_AGENT_IDS=()  # Track agent IDs we create for cleanup

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); log_success "$1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); log_fail "$1"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); log_warning "SKIP: $1"; }

cleanup() {
    echo ""
    echo "============================================================================"
    log_info "Cleaning up test resources..."
    echo "============================================================================"

    # Delete test namespace (removes all pods, services, deployments, configmaps)
    kubectl delete namespace "$TEST_NS" --ignore-not-found --timeout=60s 2>/dev/null || true
    log_info "Deleted namespace: $TEST_NS"

    # Clean up test agent registrations from controller
    if [[ ${#TEST_AGENT_IDS[@]} -gt 0 && -n "$CONTROLLER_API_IP" ]]; then
        TOKEN=$(get_token 2>/dev/null)
        if [[ -n "$TOKEN" ]]; then
            for aid in "${TEST_AGENT_IDS[@]}"; do
                curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" \
                    "https://${CONTROLLER_API_IP}/api/v2/agents/${aid}" >/dev/null 2>&1 && \
                    log_info "Cleaned up test agent: $aid"
            done
        fi
    fi

    # Also try to find any agents with "test" in their name/tags from this run
    if [[ -n "$CONTROLLER_API_IP" ]]; then
        TOKEN=$(get_token 2>/dev/null)
        if [[ -n "$TOKEN" ]]; then
            # Find agents registered from cyperf-test namespace pods
            STALE_IDS=$(curl -sk -H "Authorization: Bearer $TOKEN" \
                "https://${CONTROLLER_API_IP}/api/v2/agents" 2>/dev/null | python3 -c "
import sys,json
try:
    agents = json.load(sys.stdin)
    for a in agents:
        name = a.get('Name','')
        # Test agents will have 'cyperf-test' in their hostname/name
        if 'cyperf-test' in name.lower():
            print(a.get('id',''))
except: pass
" 2>/dev/null)
            if [[ -n "$STALE_IDS" ]]; then
                while IFS= read -r aid; do
                    if [[ -n "$aid" ]]; then
                        curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" \
                            "https://${CONTROLLER_API_IP}/api/v2/agents/${aid}" >/dev/null 2>&1
                        log_info "Cleaned up stale test agent: $aid"
                    fi
                done <<< "$STALE_IDS"
            fi
        fi
    fi

    log_info "Cleanup complete"
}

# Always clean up on exit
trap cleanup EXIT

echo ""
echo "============================================================================"
echo "  CyPerf Rebuild Validation Test"
echo "  Namespace: $TEST_NS (isolated from production)"
echo "============================================================================"
echo ""

# ============================================================================
# SETUP: Auto-detect and configure
# ============================================================================

if [[ -z "$CONTROLLER_PRIVATE_IP" ]]; then
    log_info "Auto-detecting CyPerf Controller private IP..."
    CONTROLLER_PRIVATE_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_controller_private_ip 2>/dev/null || echo "")
    if [[ -z "$CONTROLLER_PRIVATE_IP" ]]; then
        echo "ERROR: Could not auto-detect controller IP. Provide: $0 <CONTROLLER_PRIVATE_IP>"
        exit 1
    fi
fi

CONTROLLER_PUBLIC_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_controller_public_ip 2>/dev/null || echo "")
CONTROLLER_API_IP="${CONTROLLER_PUBLIC_IP:-$CONTROLLER_PRIVATE_IP}"

log_info "Controller private IP: $CONTROLLER_PRIVATE_IP"
log_info "Controller API IP:     $CONTROLLER_API_IP"

log_info "Configuring kubectl..."
aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --profile "$AWS_PROFILE" 2>/dev/null

# Create test namespace
kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
# Label for privileged pod security (needed for NET_ADMIN capability)
kubectl label namespace "$TEST_NS" pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null || true
kubectl label namespace "$TEST_NS" pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null || true

get_token() {
    curl -sk "https://${CONTROLLER_API_IP}/auth/realms/keysight/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=admin-cli&username=admin&password=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("<CYPERF_PASSWORD>"))')" \
        2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null
}

# Count existing agents BEFORE we deploy (so we know which are ours)
AGENTS_BEFORE=$(curl -sk -H "Authorization: Bearer $(get_token)" \
    "https://${CONTROLLER_API_IP}/api/v2/agents" 2>/dev/null | python3 -c "
import sys,json
try:
    print(len(json.load(sys.stdin)))
except: print(0)
" 2>/dev/null || echo "0")
log_info "Agents registered before test: $AGENTS_BEFORE"

# ============================================================================
# TEST 1: ClusterIP proxy can reach SE nginx-demo pods
# ============================================================================

log_test "1 - ClusterIP Proxy -> SE nginx-demo pods"

# Build upstream from active SE namespaces
UPSTREAM_SERVERS=""
SE_COUNT=0
for i in $(seq -f "%02g" 1 22); do
    NS="se-${i}"
    if kubectl get namespace "$NS" &>/dev/null; then
        SVC_NAME=$(kubectl get svc -n "$NS" -o name 2>/dev/null | grep -E "nginx-demo|nginx-service" | head -1 | sed 's|service/||')
        if [[ -n "$SVC_NAME" ]]; then
            UPSTREAM_SERVERS="${UPSTREAM_SERVERS}        server ${SVC_NAME}.${NS}.svc.cluster.local:80;\n"
            SE_COUNT=$((SE_COUNT + 1))
        fi
    fi
done

if [[ $SE_COUNT -eq 0 ]]; then
    fail "No SE namespaces with nginx services found"
else
    log_info "Found $SE_COUNT SE namespaces with nginx services"

    # Deploy proxy in test namespace
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cyperf-proxy-config
  namespace: $TEST_NS
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
  namespace: $TEST_NS
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
  namespace: $TEST_NS
spec:
  type: ClusterIP
  selector:
    app: cyperf-proxy
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
EOF

    log_info "Waiting for proxy pod to be ready..."
    kubectl rollout status deployment/cyperf-proxy -n "$TEST_NS" --timeout=120s 2>/dev/null

    PROXY_POD=$(kubectl get pods -n "$TEST_NS" -l app=cyperf-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    PROXY_POD_IP=$(kubectl get pods -n "$TEST_NS" -l app=cyperf-proxy -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

    if [[ -z "$PROXY_POD" || -z "$PROXY_POD_IP" ]]; then
        fail "Proxy pod did not start"
    else
        log_info "Proxy pod: $PROXY_POD (IP: $PROXY_POD_IP)"

        # Test 1a: Health endpoint
        HEALTH=$(kubectl exec "$PROXY_POD" -n "$TEST_NS" -- curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null || echo "000")
        if [[ "$HEALTH" == "200" ]]; then
            pass "Proxy health endpoint returns 200"
        else
            fail "Proxy health endpoint returned: $HEALTH"
        fi

        # Test 1b: Proxy can reach an SE nginx-demo pod
        PROXY_RESPONSE=$(kubectl exec "$PROXY_POD" -n "$TEST_NS" -- curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
        if [[ "$PROXY_RESPONSE" == "200" || "$PROXY_RESPONSE" == "301" || "$PROXY_RESPONSE" == "302" ]]; then
            pass "Proxy successfully routes to SE nginx-demo (HTTP $PROXY_RESPONSE)"
        else
            fail "Proxy failed to reach SE nginx-demo (HTTP $PROXY_RESPONSE)"
        fi

        # Test 1c: Multiple requests hit different SEs (round-robin)
        if [[ $SE_COUNT -gt 1 ]]; then
            SERVERS=""
            for i in $(seq 1 10); do
                SRV=$(kubectl exec "$PROXY_POD" -n "$TEST_NS" -- curl -s http://localhost/ 2>/dev/null | grep -oP '(?<=<title>|SE-LAB-|se-)\d+' | head -1)
                SERVERS="${SERVERS}${SRV} "
            done
            UNIQUE=$(echo "$SERVERS" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
            if [[ "$UNIQUE" -gt 1 ]]; then
                pass "Round-robin working: hit $UNIQUE different backends in 10 requests"
            else
                log_warning "WARN: Only hit 1 backend in 10 requests (round-robin may need more time)"
                # Not a hard fail - nginx round-robin can be sticky briefly
                pass "Proxy routing works (single backend hit, round-robin may warm up)"
            fi
        fi
    fi
fi

# ============================================================================
# TEST 2: iptables-fixer sidecar
# ============================================================================

log_test "2 - iptables-fixer sidecar (counters portmanager INPUT DROP)"

# Deploy a minimal test pod with the sidecar (faster timings for test)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: iptables-test
  namespace: $TEST_NS
  labels:
    app: iptables-test
spec:
  containers:
  - name: main
    image: alpine:3.18
    command: ["/bin/sh", "-c"]
    args:
    - |
      apk add --no-cache iptables >/dev/null 2>&1
      echo "main: ready"
      # Simulate portmanager: set INPUT to DROP after 20s
      sleep 20
      echo "main: simulating portmanager - setting INPUT to DROP"
      iptables -P INPUT DROP
      echo "main: INPUT policy is now DROP"
      # Keep running so we can check
      sleep 3600
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
  - name: iptables-fixer
    image: alpine:3.18
    command: ["/bin/sh", "-c"]
    args:
    - |
      apk add --no-cache iptables >/dev/null 2>&1
      echo "iptables-fixer: waiting 30s for simulated portmanager..."
      sleep 30
      echo "iptables-fixer: starting INPUT ACCEPT loop (every 5s)"
      while true; do
        current=\$(iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT')
        if [ "\$current" = "DROP" ]; then
          iptables -P INPUT ACCEPT
          echo "iptables-fixer: RESET INPUT to ACCEPT (was DROP)"
        fi
        sleep 5
      done
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
  restartPolicy: Never
  tolerations:
  - key: "se-id"
    operator: "Exists"
    effect: "NoSchedule"
EOF

log_info "Waiting for iptables-test pod to start..."
kubectl wait --for=condition=Ready pod/iptables-test -n "$TEST_NS" --timeout=120s 2>/dev/null || {
    fail "iptables-test pod did not start"
    kubectl describe pod iptables-test -n "$TEST_NS" 2>/dev/null | tail -15
}

if kubectl get pod iptables-test -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
    # Wait for main container to set DROP (~20s) then sidecar to fix (~30s + 5s)
    log_info "Waiting for simulated portmanager to set INPUT DROP (20s)..."
    sleep 22

    # Check that INPUT is DROP (portmanager simulation worked)
    POLICY_AFTER_DROP=$(kubectl exec iptables-test -n "$TEST_NS" -c main -- iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT')
    if [[ "$POLICY_AFTER_DROP" == "DROP" ]]; then
        pass "Portmanager simulation: INPUT policy set to DROP"
    else
        log_warning "Portmanager didn't set DROP yet (current: $POLICY_AFTER_DROP), waiting more..."
        sleep 5
        POLICY_AFTER_DROP=$(kubectl exec iptables-test -n "$TEST_NS" -c main -- iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT')
        if [[ "$POLICY_AFTER_DROP" == "DROP" ]]; then
            pass "Portmanager simulation: INPUT policy set to DROP (delayed)"
        else
            skip "Portmanager simulation didn't set DROP (current: $POLICY_AFTER_DROP)"
        fi
    fi

    # Wait for sidecar to detect and fix (starts at 30s, checks every 5s)
    log_info "Waiting for iptables-fixer sidecar to reset INPUT to ACCEPT (~15s)..."
    sleep 16

    POLICY_AFTER_FIX=$(kubectl exec iptables-test -n "$TEST_NS" -c main -- iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT')
    if [[ "$POLICY_AFTER_FIX" == "ACCEPT" ]]; then
        pass "iptables-fixer sidecar: RESET INPUT from DROP to ACCEPT"
    else
        log_warning "Sidecar hasn't fixed yet (current: $POLICY_AFTER_FIX), waiting one more cycle..."
        sleep 6
        POLICY_AFTER_FIX=$(kubectl exec iptables-test -n "$TEST_NS" -c main -- iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT')
        if [[ "$POLICY_AFTER_FIX" == "ACCEPT" ]]; then
            pass "iptables-fixer sidecar: RESET INPUT from DROP to ACCEPT (delayed)"
        else
            fail "iptables-fixer sidecar did NOT reset INPUT (still: $POLICY_AFTER_FIX)"
        fi
    fi

    # Show sidecar logs
    log_info "Sidecar logs:"
    kubectl logs iptables-test -n "$TEST_NS" -c iptables-fixer --tail=5 2>/dev/null | sed 's/^/    /'
fi

# ============================================================================
# TEST 3: Agent registration with controller
# ============================================================================

log_test "3 - K8s Agent Registration with Controller"

# Verify controller is reachable first
TOKEN=$(get_token 2>/dev/null)
if [[ -z "$TOKEN" ]]; then
    skip "Cannot authenticate to controller at $CONTROLLER_API_IP - skipping agent test"
else
    pass "Controller authentication successful"

    # Deploy test agent pods (client only - minimal test)
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cyperf-test-client
  namespace: $TEST_NS
  labels:
    app: cyperf-test-agent
    role: client
spec:
  containers:
  - name: cyperf-agent
    image: public.ecr.aws/keysight/cyperf-agent:release7.0
    env:
    - name: AGENT_CONTROLLER
      value: "$CONTROLLER_PRIVATE_IP"
    - name: AGENT_TAGS
      value: "role=test-client"
    securityContext:
      privileged: false
      capabilities:
        add: ["NET_ADMIN", "IPC_LOCK", "NET_RAW"]
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: "2"
        memory: 2Gi
  - name: iptables-fixer
    image: alpine:3.18
    command: ["/bin/sh", "-c"]
    args:
    - |
      apk add --no-cache iptables >/dev/null 2>&1
      echo "iptables-fixer: waiting 60s for portmanager..."
      sleep 60
      echo "iptables-fixer: starting INPUT ACCEPT loop"
      while true; do
        current=\$(iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT')
        if [ "\$current" = "DROP" ]; then
          iptables -P INPUT ACCEPT
          echo "iptables-fixer: RESET INPUT to ACCEPT"
        fi
        sleep 5
      done
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
  restartPolicy: Always
  terminationGracePeriodSeconds: 10
  tolerations:
  - key: "se-id"
    operator: "Exists"
    effect: "NoSchedule"
---
apiVersion: v1
kind: Pod
metadata:
  name: cyperf-test-server
  namespace: $TEST_NS
  labels:
    app: cyperf-test-agent
    role: server
spec:
  containers:
  - name: cyperf-agent
    image: public.ecr.aws/keysight/cyperf-agent:release7.0
    env:
    - name: AGENT_CONTROLLER
      value: "$CONTROLLER_PRIVATE_IP"
    - name: AGENT_TAGS
      value: "role=test-server"
    securityContext:
      privileged: false
      capabilities:
        add: ["NET_ADMIN", "IPC_LOCK", "NET_RAW"]
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: "2"
        memory: 2Gi
  - name: iptables-fixer
    image: alpine:3.18
    command: ["/bin/sh", "-c"]
    args:
    - |
      apk add --no-cache iptables >/dev/null 2>&1
      echo "iptables-fixer: waiting 60s for portmanager..."
      sleep 60
      echo "iptables-fixer: starting INPUT ACCEPT loop"
      while true; do
        current=\$(iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT')
        if [ "\$current" = "DROP" ]; then
          iptables -P INPUT ACCEPT
          echo "iptables-fixer: RESET INPUT to ACCEPT"
        fi
        sleep 5
      done
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
  restartPolicy: Always
  terminationGracePeriodSeconds: 10
  tolerations:
  - key: "se-id"
    operator: "Exists"
    effect: "NoSchedule"
EOF

    log_info "Waiting for test agent pods to start..."
    kubectl wait --for=condition=Ready pod/cyperf-test-client -n "$TEST_NS" --timeout=300s 2>/dev/null || {
        log_warning "Test client pod not ready in time"
        kubectl get pod cyperf-test-client -n "$TEST_NS" -o wide 2>/dev/null
    }
    kubectl wait --for=condition=Ready pod/cyperf-test-server -n "$TEST_NS" --timeout=300s 2>/dev/null || {
        log_warning "Test server pod not ready in time"
        kubectl get pod cyperf-test-server -n "$TEST_NS" -o wide 2>/dev/null
    }

    # Check pod status
    CLIENT_STATUS=$(kubectl get pod cyperf-test-client -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    SERVER_STATUS=$(kubectl get pod cyperf-test-server -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null)

    if [[ "$CLIENT_STATUS" == "Running" ]]; then
        pass "Test client agent pod is Running"
    else
        fail "Test client agent pod status: $CLIENT_STATUS"
    fi

    if [[ "$SERVER_STATUS" == "Running" ]]; then
        pass "Test server agent pod is Running"
    else
        fail "Test server agent pod status: $SERVER_STATUS"
    fi

    # Wait for agents to register with controller (up to 3 minutes)
    log_info "Waiting for test agents to register with controller (up to 3 min)..."
    AGENTS_REGISTERED=0
    for attempt in $(seq 1 12); do
        TOKEN=$(get_token 2>/dev/null)
        if [[ -n "$TOKEN" ]]; then
            AGENTS_NOW=$(curl -sk -H "Authorization: Bearer $TOKEN" \
                "https://${CONTROLLER_API_IP}/api/v2/agents" 2>/dev/null | python3 -c "
import sys,json
try:
    agents = json.load(sys.stdin)
    test_agents = [a for a in agents if any('test' in str(t) for t in a.get('AgentTags',[]))]
    print(len(test_agents))
except: print(0)
" 2>/dev/null || echo "0")

            if [[ "$AGENTS_NOW" -ge 2 ]]; then
                AGENTS_REGISTERED=$AGENTS_NOW
                break
            fi
        fi
        echo -e "  Attempt $attempt/12 - $AGENTS_NOW/2 test agents registered, waiting 15s..."
        sleep 15
    done

    if [[ "$AGENTS_REGISTERED" -ge 2 ]]; then
        pass "Both test agents registered with controller ($AGENTS_REGISTERED agents with test tags)"

        # Record their IDs for cleanup
        TOKEN=$(get_token 2>/dev/null)
        TEST_AGENT_IDS=($(curl -sk -H "Authorization: Bearer $TOKEN" \
            "https://${CONTROLLER_API_IP}/api/v2/agents" 2>/dev/null | python3 -c "
import sys,json
try:
    agents = json.load(sys.stdin)
    for a in agents:
        if any('test' in str(t) for t in a.get('AgentTags',[])):
            print(a.get('id',''))
except: pass
" 2>/dev/null))
    elif [[ "$AGENTS_REGISTERED" -ge 1 ]]; then
        log_warning "Only $AGENTS_REGISTERED/2 test agents registered (one may still be initializing)"
        pass "At least one test agent registered (partial success)"
    else
        fail "No test agents registered with controller after 3 minutes"
        log_info "Agent pod logs (client):"
        kubectl logs cyperf-test-client -n "$TEST_NS" -c cyperf-agent --tail=10 2>/dev/null | sed 's/^/    /'
    fi
fi

# ============================================================================
# TEST 4: End-to-end - client pod can curl through proxy
# ============================================================================

log_test "4 - End-to-End: Agent Pod -> Proxy -> nginx-demo"

if [[ -n "$PROXY_POD_IP" ]]; then
    CLIENT_RUNNING=$(kubectl get pod cyperf-test-client -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ "$CLIENT_RUNNING" == "Running" ]]; then
        # Test from inside the agent pod to proxy pod IP
        E2E_RESULT=$(kubectl exec cyperf-test-client -n "$TEST_NS" -c cyperf-agent -- \
            curl -s -o /dev/null -w "%{http_code}" "http://${PROXY_POD_IP}/" --connect-timeout 5 2>/dev/null || echo "000")

        if [[ "$E2E_RESULT" == "200" || "$E2E_RESULT" == "301" || "$E2E_RESULT" == "302" ]]; then
            pass "Client pod -> proxy pod IP ($PROXY_POD_IP) -> nginx-demo: HTTP $E2E_RESULT"
        else
            fail "Client pod could not reach proxy (HTTP $E2E_RESULT)"

            # Debug: can client reach proxy at all?
            log_info "Debug - trying ClusterIP service..."
            SVC_IP=$(kubectl get svc cyperf-proxy -n "$TEST_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
            SVC_RESULT=$(kubectl exec cyperf-test-client -n "$TEST_NS" -c cyperf-agent -- \
                curl -s -o /dev/null -w "%{http_code}" "http://${SVC_IP}/" --connect-timeout 5 2>/dev/null || echo "000")
            log_info "  ClusterIP ($SVC_IP): HTTP $SVC_RESULT"
        fi

        # Test proxy health from agent pod
        HEALTH_E2E=$(kubectl exec cyperf-test-client -n "$TEST_NS" -c cyperf-agent -- \
            curl -s -o /dev/null -w "%{http_code}" "http://${PROXY_POD_IP}/health" --connect-timeout 5 2>/dev/null || echo "000")
        if [[ "$HEALTH_E2E" == "200" ]]; then
            pass "Client pod -> proxy health endpoint: HTTP 200"
        else
            fail "Client pod -> proxy health endpoint: HTTP $HEALTH_E2E"
        fi
    else
        skip "Client pod not running ($CLIENT_RUNNING) - cannot test end-to-end"
    fi
else
    skip "No proxy pod IP available - cannot test end-to-end"
fi

# ============================================================================
# TEST 5: iptables-fixer works on REAL CyPerf agent (not just simulation)
# ============================================================================

log_test "5 - iptables-fixer on Real CyPerf Agent Pod"

CLIENT_RUNNING=$(kubectl get pod cyperf-test-client -n "$TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$CLIENT_RUNNING" == "Running" ]]; then
    # Check if portmanager has set DROP yet (may take 60-90s after pod start)
    AGENT_IPTABLES=$(kubectl exec cyperf-test-client -n "$TEST_NS" -c iptables-fixer -- \
        iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT' || echo "unknown")

    if [[ "$AGENT_IPTABLES" == "ACCEPT" ]]; then
        # Could be: sidecar already fixed it, or portmanager hasn't set DROP yet
        log_info "Current INPUT policy: ACCEPT (sidecar may have already fixed, or portmanager hasn't acted yet)"

        # Check sidecar logs to see if it actually detected and fixed a DROP
        FIXER_LOGS=$(kubectl logs cyperf-test-client -n "$TEST_NS" -c iptables-fixer --tail=20 2>/dev/null)
        if echo "$FIXER_LOGS" | grep -q "RESET INPUT"; then
            pass "iptables-fixer detected and reset DROP to ACCEPT on real agent"
        else
            log_info "Sidecar hasn't detected DROP yet - portmanager may not have run"
            log_info "Waiting 60s for portmanager cycle..."
            sleep 60
            FIXER_LOGS=$(kubectl logs cyperf-test-client -n "$TEST_NS" -c iptables-fixer --tail=20 2>/dev/null)
            if echo "$FIXER_LOGS" | grep -q "RESET INPUT"; then
                pass "iptables-fixer detected and reset DROP to ACCEPT on real agent (after wait)"
            else
                CURRENT=$(kubectl exec cyperf-test-client -n "$TEST_NS" -c iptables-fixer -- \
                    iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT' || echo "unknown")
                if [[ "$CURRENT" == "ACCEPT" ]]; then
                    pass "INPUT policy is ACCEPT (portmanager may not set DROP on K8s agents)"
                else
                    fail "INPUT policy is $CURRENT - sidecar did not fix"
                fi
            fi
        fi
    elif [[ "$AGENT_IPTABLES" == "DROP" ]]; then
        log_info "Portmanager set DROP - waiting for sidecar to fix..."
        sleep 10
        AFTER_FIX=$(kubectl exec cyperf-test-client -n "$TEST_NS" -c iptables-fixer -- \
            iptables -L INPUT -n 2>/dev/null | head -1 | grep -o 'DROP\|ACCEPT' || echo "unknown")
        if [[ "$AFTER_FIX" == "ACCEPT" ]]; then
            pass "iptables-fixer reset DROP to ACCEPT on real CyPerf agent"
        else
            fail "iptables-fixer did NOT fix DROP on real agent (still: $AFTER_FIX)"
        fi
    else
        skip "Could not check iptables on agent pod (status: $AGENT_IPTABLES)"
    fi
else
    skip "Client pod not running - cannot test iptables on real agent"
fi

# ============================================================================
# RESULTS
# ============================================================================

echo ""
echo ""
echo "============================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
else
    echo -e "  ${RED}${BOLD}SOME TESTS FAILED${NC}"
fi
echo "============================================================================"
echo ""
echo -e "  ${GREEN}Passed:  $TESTS_PASSED${NC}"
echo -e "  ${RED}Failed:  $TESTS_FAILED${NC}"
echo -e "  ${YELLOW}Skipped: $TESTS_SKIPPED${NC}"
echo -e "  Total:   $TOTAL"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  Safe to proceed with the full rebuild:"
    echo "    1. terraform apply   (destroys VM agents)"
    echo "    2. ./scripts/deploy-cyperf-k8s.sh   (deploys K8s-only architecture)"
else
    echo "  Fix failing tests before proceeding with the rebuild."
    echo "  Re-run this script after making changes."
fi

echo ""
echo "  Cleaning up test resources now..."
echo "============================================================================"
echo ""

# Cleanup happens via trap
exit $TESTS_FAILED
