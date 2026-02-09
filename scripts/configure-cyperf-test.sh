#!/bin/bash
# ============================================================================
# CONFIGURE CYPERF TEST - DUT MODE WITH CYPERF-PROXY (CLUSTERIP)
# ============================================================================
# Creates the "SE Training Traffic" test configuration on the CyPerf
# Controller via REST API. Configures DUT (Device Under Test) mode where
# traffic flows through the cyperf-proxy pod (round-robin to SE nginx pods)
# so CloudLens sensors can capture real HTTP traffic.
#
# Traffic path:
#   CyPerf Client Pod -> cyperf-proxy Pod (DUT) -> nginx-demo pods (CloudLens captures)
#
# Applications: HTTP App 1, Netflix, Youtube Chrome, ChatGPT, Discord
#
# This script is idempotent - it checks for an existing session first
# and skips creation if one already exists.
#
# Prerequisites:
#   - CyPerf Controller running and accessible
#   - K8s agents deployed and connected
#   - EULA accepted
#   - License activated
#
# Usage:
#   ./configure-cyperf-test.sh [CONTROLLER_PUBLIC_IP] [AWS_PROFILE] [AWS_REGION] [DUT_HOST_IP]
#   ./configure-cyperf-test.sh                                            # Auto-detect all
#   ./configure-cyperf-test.sh 1.2.3.4                                     # Explicit IP
#   ./configure-cyperf-test.sh 1.2.3.4 your-aws-profile us-west-2 10.100.5.42
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

# Configuration
CONTROLLER_IP=${1:-""}
AWS_PROFILE=${2:-"${AWS_PROFILE:-cloudlens-lab}"}
AWS_REGION=${3:-"${AWS_REGION:-us-west-2}"}
DUT_HOST_IP=${4:-""}  # Proxy pod IP passed from deploy-cyperf-k8s.sh
CYPERF_USER="admin"
CYPERF_PASS='<CYPERF_PASSWORD>'
SESSION_NAME="SE Training - CyPerf DUT Mode"
PROFILE_NAME="SE Training DUT Traffic"

# App definitions: HTTP-focused since nginx proxies HTTP traffic
# resource_id|protocol_id|display_name
APPS=(
    "128|HTTP|HTTP App 1"
    "466|Netflix|Netflix"
    "292|Youtube|Youtube Chrome"
    "351|ChatGPT|ChatGPT"
    "367|Discord|Discord"
)

# Objectives - higher throughput for VM-based agents
THROUGHPUT_VALUE=10
THROUGHPUT_UNIT="Mbps"
DURATION=600

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

get_token() {
    curl -sk "https://${CONTROLLER_IP}/auth/realms/keysight/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=admin-cli&username=${CYPERF_USER}&password=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("'"${CYPERF_PASS}"'"))')" \
        2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null
}

api_get() {
    local path="$1"
    local token
    token=$(get_token)
    curl -sk -H "Authorization: Bearer $token" "https://${CONTROLLER_IP}${path}" 2>/dev/null
}

api_post() {
    local path="$1"
    local data="$2"
    local token
    token=$(get_token)
    curl -sk -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        -d "$data" "https://${CONTROLLER_IP}${path}" 2>/dev/null
}

api_patch() {
    local path="$1"
    local data="$2"
    local token
    token=$(get_token)
    curl -sk -X PATCH -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        -d "$data" "https://${CONTROLLER_IP}${path}" 2>/dev/null
}

# ============================================================================
# MAIN
# ============================================================================

echo ""
echo "============================================================================"
echo "  Configure CyPerf Test Session"
echo "  Auto-creating: $SESSION_NAME"
echo "============================================================================"
echo ""

# Auto-detect controller IP
if [[ -z "$CONTROLLER_IP" ]]; then
    log_info "Auto-detecting CyPerf Controller public IP..."
    CONTROLLER_IP=$(cd "$BASE_DIR" && terraform output -raw cyperf_controller_public_ip 2>/dev/null || echo "")
    if [[ -z "$CONTROLLER_IP" ]]; then
        log_error "Could not auto-detect CyPerf Controller IP."
        log_error "Provide it explicitly: $0 <CONTROLLER_PUBLIC_IP>"
        exit 1
    fi
    log_success "Detected controller IP: $CONTROLLER_IP"
fi

# Verify controller is reachable (with retry for fresh deploys)
MAX_RETRIES=30
RETRY_INTERVAL=20
log_info "Checking controller connectivity (will retry up to ${MAX_RETRIES} times for fresh deploys)..."

CONTROLLER_READY=false
for attempt in $(seq 1 $MAX_RETRIES); do
    if curl -sk --connect-timeout 10 "https://${CONTROLLER_IP}" >/dev/null 2>&1; then
        CONTROLLER_READY=true
        break
    fi
    if [[ $attempt -eq 1 ]]; then
        log_warning "Controller not reachable yet. This is normal for fresh deploys (~10 min startup)."
    fi
    echo -e "  Attempt $attempt/$MAX_RETRIES - retrying in ${RETRY_INTERVAL}s..."
    sleep $RETRY_INTERVAL
done

if [[ "$CONTROLLER_READY" != "true" ]]; then
    log_error "Cannot reach CyPerf Controller at https://${CONTROLLER_IP} after $MAX_RETRIES attempts."
    exit 1
fi
log_success "Controller is reachable"

# Verify authentication (with retry - controller may accept connections before auth is ready)
log_info "Authenticating..."
TOKEN=""
for attempt in $(seq 1 10); do
    TOKEN=$(get_token)
    if [[ -n "$TOKEN" ]]; then
        break
    fi
    if [[ $attempt -eq 1 ]]; then
        log_warning "Auth not ready yet. Retrying..."
    fi
    sleep 10
done

if [[ -z "$TOKEN" ]]; then
    log_error "Failed to authenticate to CyPerf Controller after retries."
    exit 1
fi
log_success "Authenticated"

# ============================================================================
# ACCEPT EULA (required before first test - idempotent)
# ============================================================================

log_info "Checking EULA status..."
EULA_STATUS=$(curl -sk "https://${CONTROLLER_IP}/eula/v1/eula" 2>/dev/null || echo "[]")
if echo "$EULA_STATUS" | grep -q '"accepted":false'; then
    curl -sk "https://${CONTROLLER_IP}/eula/v1/eula/CyPerf" \
        -X POST -H "Content-Type: application/json" -d '{"accepted": true}' >/dev/null 2>&1
    log_success "EULA accepted"
else
    log_info "EULA already accepted"
fi

# ============================================================================
# CHECK LICENSE (manual activation required on fresh deploy)
# ============================================================================

LICENSE_SERVERS=$(api_get "/api/v2/license-servers" 2>/dev/null)
LICENSE_COUNT=$(echo "$LICENSE_SERVERS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "$LICENSE_COUNT" -eq 0 ]]; then
    log_warning "No license server configured on the CyPerf Controller."
    log_warning "CyPerf requires a license to run tests."
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  MANUAL STEP: Activate your CyPerf license              │"
    echo "  │                                                          │"
    echo "  │  1. Open https://${CONTROLLER_IP} in your browser        │"
    echo "  │  2. Login: admin / <CYPERF_PASSWORD>                     │"
    echo "  │  3. Go to Settings (gear icon) > License                 │"
    echo "  │  4. Activate your license                                │"
    echo "  │                                                          │"
    echo "  │  Press Enter after activating, or Ctrl+C to skip.       │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""

    # Wait for user to activate license (non-interactive mode: skip after timeout)
    if [[ -t 0 ]]; then
        read -r -p "  Press Enter to continue after activating the license... "
    else
        log_warning "Non-interactive mode: skipping license wait. Activate manually later."
    fi
    echo ""
fi

# ============================================================================
# CHECK FOR EXISTING SESSION
# ============================================================================

log_info "Checking for existing test configuration..."
EXISTING_SESSION=$(api_get "/api/v2/sessions" | python3 -c "
import sys,json
sessions = json.load(sys.stdin)
for s in sessions:
    if s.get('name','').startswith('SE Training'):
        print(s['id'])
        break
" 2>/dev/null)

if [[ -n "$EXISTING_SESSION" ]]; then
    # Verify it has apps with actions
    APP_COUNT=$(api_get "/api/v2/sessions/${EXISTING_SESSION}/config/config/TrafficProfiles/1/Applications" | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$APP_COUNT" -ge 5 ]]; then
        ACTION_COUNT=$(api_get "/api/v2/sessions/${EXISTING_SESSION}/config/config/TrafficProfiles/1/Applications/1/Tracks/1/Actions" | \
            python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [[ "$ACTION_COUNT" -gt 0 ]]; then
            log_success "Test configuration already exists with $APP_COUNT apps (session: $EXISTING_SESSION)"
            log_info "Skipping creation. Delete the session in the UI to force recreation."
            exit 0
        fi
    fi

    # Existing session but broken/incomplete - delete and recreate
    log_warning "Found incomplete session ($EXISTING_SESSION). Deleting and recreating..."
    TOKEN=$(get_token)
    curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" \
        "https://${CONTROLLER_IP}/api/v2/sessions/${EXISTING_SESSION}" >/dev/null 2>&1
fi

# ============================================================================
# CREATE SESSION
# ============================================================================

log_info "Creating new session from empty config template..."
SESSION_ID=$(api_post "/api/v2/sessions" '{"configUrl":"appsec-empty-config"}' | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if isinstance(d,list) else d['id'])" 2>/dev/null)

if [[ -z "$SESSION_ID" ]]; then
    log_error "Failed to create session"
    exit 1
fi
log_success "Session created: $SESSION_ID"

# Rename session
api_patch "/api/v2/sessions/${SESSION_ID}" "{\"name\":\"${SESSION_NAME}\"}" >/dev/null 2>&1

BASE="/api/v2/sessions/${SESSION_ID}/config/config"

# ============================================================================
# CREATE TRAFFIC PROFILE
# ============================================================================

log_info "Creating traffic profile: $PROFILE_NAME"
api_post "${BASE}/TrafficProfiles" "{\"Name\":\"${PROFILE_NAME}\",\"Active\":true}" >/dev/null 2>&1

# ============================================================================
# ADD APPLICATIONS WITH FULL ACTIONS
# ============================================================================

log_info "Adding applications with traffic actions from resource library..."

for APP_DEF in "${APPS[@]}"; do
    IFS='|' read -r RESOURCE_ID PROTOCOL_ID DISPLAY_NAME <<< "$APP_DEF"

    echo -n "  Adding ${DISPLAY_NAME}..."

    # Create app shell
    APP_RESPONSE=$(api_post "${BASE}/TrafficProfiles/1/Applications" \
        "{\"ProtocolID\":\"${PROTOCOL_ID}\",\"Name\":\"${DISPLAY_NAME}\",\"Active\":true,\"ObjectiveWeight\":1}")

    # Get the new app ID (last in array)
    APP_ID=$(echo "$APP_RESPONSE" | python3 -c "
import sys,json
d = json.load(sys.stdin)
if isinstance(d, list):
    print(d[-1]['id'])
else:
    print(d.get('id',''))
" 2>/dev/null)

    if [[ -z "$APP_ID" ]]; then
        echo -e " ${RED}FAILED${NC}"
        log_error "Failed to create app: $DISPLAY_NAME"
        continue
    fi

    # Get actions from resource library
    ACTIONS=$(api_get "/api/v2/resources/apps/${RESOURCE_ID}/app/Tracks/1/Actions")
    NUM_ACTIONS=$(echo "$ACTIONS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$NUM_ACTIONS" == "0" ]]; then
        echo -e " ${YELLOW}(no actions in resource library)${NC}"
        continue
    fi

    # Copy each action with its exchanges
    COPIED=0
    for ACTION_IDX in $(seq 1 "$NUM_ACTIONS"); do
        # Get action detail
        ACTION_DATA=$(api_get "/api/v2/resources/apps/${RESOURCE_ID}/app/Tracks/1/Actions/${ACTION_IDX}")

        # Get exchanges for this action
        EXCHANGES=$(api_get "/api/v2/resources/apps/${RESOURCE_ID}/app/Tracks/1/Actions/${ACTION_IDX}/Exchanges")

        # Build payload: action fields + inline exchanges (strip id/links)
        PAYLOAD=$(python3 -c "
import sys, json

action = json.loads('''${ACTION_DATA}''')
exchanges = json.loads('''${EXCHANGES}''')

# Clean action: remove id, links, keep essential fields
clean_action = {}
skip_keys = {'id', 'links', 'Index'}
for k, v in action.items():
    if k not in skip_keys:
        clean_action[k] = v

# Clean exchanges: remove id, links from each
clean_exchanges = []
for ex in exchanges:
    clean_ex = {}
    for k, v in ex.items():
        if k not in skip_keys:
            clean_ex[k] = v
    clean_exchanges.append(clean_ex)

clean_action['Exchanges'] = clean_exchanges
print(json.dumps(clean_action))
" 2>/dev/null)

        if [[ -z "$PAYLOAD" || "$PAYLOAD" == "null" ]]; then
            continue
        fi

        # POST action to session app
        RESULT=$(api_post "${BASE}/TrafficProfiles/1/Applications/${APP_ID}/Tracks/1/Actions" "$PAYLOAD")
        HTTP_CHECK=$(echo "$RESULT" | python3 -c "
import sys,json
d = json.load(sys.stdin)
if isinstance(d, list):
    print('ok')
elif 'message' in d:
    print(d['message'])
else:
    print('ok')
" 2>/dev/null || echo "error")

        if [[ "$HTTP_CHECK" == "ok" ]]; then
            COPIED=$((COPIED + 1))
        fi
    done

    echo -e " ${GREEN}OK${NC} (id=$APP_ID, $COPIED/$NUM_ACTIONS actions)"
done

# ============================================================================
# CONFIGURE OBJECTIVES & TIMELINE
# ============================================================================

log_info "Setting objectives: ${THROUGHPUT_VALUE} ${THROUGHPUT_UNIT} throughput, ${DURATION}s steady state"
api_patch "${BASE}/TrafficProfiles/1/ObjectivesAndTimeline/TimelineSegments/1" \
    "{\"PrimaryObjectiveValue\":${THROUGHPUT_VALUE},\"PrimaryObjectiveUnit\":\"${THROUGHPUT_UNIT}\",\"Duration\":${DURATION}}" >/dev/null 2>&1

# ============================================================================
# CONFIGURE NETWORK PROFILES (DUT MODE)
# ============================================================================

# Get the DUT host IP (cyperf-proxy pod IP).
# Using pod IP directly avoids NLB checksum validation and kube-proxy NAT.
DUT_HOST=""
if [[ -n "$DUT_HOST_IP" ]]; then
    DUT_HOST="$DUT_HOST_IP"
    log_success "Using provided DUT host (proxy pod IP): $DUT_HOST"
else
    log_info "Auto-detecting cyperf-proxy pod IP for DUT configuration..."
    # Try proxy pod IP first (direct, avoids kube-proxy)
    DUT_HOST=$(kubectl get pods -n cyperf-shared -l app=cyperf-proxy \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
    if [[ -n "$DUT_HOST" ]]; then
        log_success "Detected proxy pod IP: $DUT_HOST"
    else
        # Fallback: ClusterIP service
        DUT_HOST=$(kubectl get svc cyperf-proxy -n cyperf-shared \
            -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        if [[ -n "$DUT_HOST" ]]; then
            log_warning "Using ClusterIP service IP: $DUT_HOST (pod IP not available)"
        else
            log_warning "Could not detect proxy IP. DUT network will use placeholder."
            DUT_HOST="cyperf-proxy-placeholder"
        fi
    fi
fi

log_info "Configuring network: Client -> DUT (cyperf-proxy: $DUT_HOST) -> Server"

# Create IP Network 1 (Client)
api_post "${BASE}/NetworkProfiles/1/IPNetworkSegment" \
    '{"Name":"Client Network","active":true,"networkTags":["Client"]}' >/dev/null 2>&1

# Create IP Network 2 (Server)
api_post "${BASE}/NetworkProfiles/1/IPNetworkSegment" \
    '{"Name":"Server Network","active":true,"networkTags":["Server"]}' >/dev/null 2>&1

# Configure DUT Network Segment (built-in, between client and server)
# This is the actual DUT connection - NOT an IPNetworkSegment
log_info "Configuring DUT Network Segment with proxy pod IP: $DUT_HOST"
api_patch "${BASE}/NetworkProfiles/1/DUTNetworkSegment/1" \
    "{\"active\":true,\"host\":\"${DUT_HOST}\",\"ServerDUTHost\":\"${DUT_HOST}\",\"ServerDUTActive\":true}" >/dev/null 2>&1

# ============================================================================
# CONFIGURE DNS RESOLVER (required for DUT hostname resolution)
# ============================================================================

log_info "Configuring DNS resolver on Client Network (AWS VPC DNS: 10.100.0.2)"
api_patch "${BASE}/NetworkProfiles/1/IPNetworkSegment/1/DNSResolver" \
    '{"cacheTimeout":30}' >/dev/null 2>&1
api_post "${BASE}/NetworkProfiles/1/IPNetworkSegment/1/DNSResolver/nameServers" \
    '{"name":"10.100.0.2"}' >/dev/null 2>&1

# ============================================================================
# WAIT FOR AGENTS TO REGISTER (fresh deploy: VMs need time to boot + connect)
# ============================================================================

log_info "Waiting for CyPerf agents to register with controller..."
AGENT_WAIT_MAX=20
AGENT_WAIT_INTERVAL=15
AGENTS_READY=false

for attempt in $(seq 1 $AGENT_WAIT_MAX); do
    AGENT_COUNT=$(api_get "/api/v2/agents" | python3 -c "
import sys,json
agents = json.load(sys.stdin)
# Count agents that have role tags (client or server)
tagged = [a for a in agents if any('role' in str(t) for t in a.get('AgentTags',[]))]
print(len(tagged))
" 2>/dev/null || echo "0")

    if [[ "$AGENT_COUNT" -ge 2 ]]; then
        AGENTS_READY=true
        log_success "Both agents registered ($AGENT_COUNT agents with role tags)"
        break
    fi

    if [[ $attempt -eq 1 ]]; then
        log_warning "Agents not registered yet. K8s agents typically register within 1-2 minutes."
    fi
    echo -e "  Attempt $attempt/$AGENT_WAIT_MAX - $AGENT_COUNT/2 agents registered, retrying in ${AGENT_WAIT_INTERVAL}s..."
    sleep $AGENT_WAIT_INTERVAL
done

if [[ "$AGENTS_READY" != "true" ]]; then
    log_warning "Not all agents registered yet ($AGENT_COUNT/2). Proceeding with tag assignment anyway."
    log_warning "Agents will be assigned automatically when they connect with the correct role tags."
fi

# ============================================================================
# CONFIGURE AGENT ASSIGNMENTS BY TAG
# ============================================================================

log_info "Assigning agents by tag: role:client -> Client, role:server -> Server"

api_patch "${BASE}/NetworkProfiles/1/IPNetworkSegment/1/agentAssignments" \
    '{"ByTag":["role:client"]}' >/dev/null 2>&1

api_patch "${BASE}/NetworkProfiles/1/IPNetworkSegment/2/agentAssignments" \
    '{"ByTag":["role:server"]}' >/dev/null 2>&1

# ============================================================================
# VERIFY
# ============================================================================

echo ""
log_info "Verifying configuration..."

FINAL_APPS=$(api_get "${BASE}/TrafficProfiles/1/Applications" | python3 -c "
import sys,json
d = json.load(sys.stdin)
for a in d:
    print(f'  {a[\"id\"]}. {a[\"Name\"]} ({a[\"ProtocolID\"]}) - {a.get(\"ObjectiveWeight\",1)} weight')
print(f'Total: {len(d)} apps')
" 2>/dev/null)

FINAL_TIMELINE=$(api_get "${BASE}/TrafficProfiles/1/ObjectivesAndTimeline/TimelineSegments" | python3 -c "
import sys,json
d = json.load(sys.stdin)
for s in d:
    print(f'  {s[\"PrimaryObjectiveValue\"]} {s[\"PrimaryObjectiveUnit\"]} for {s[\"Duration\"]}s')
" 2>/dev/null)

DUT_STATUS=$(api_get "${BASE}/NetworkProfiles/1/DUTNetworkSegment/1" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(f'  Host: {d.get(\"host\",\"N/A\")}')
print(f'  ServerDUTHost: {d.get(\"ServerDUTHost\",\"N/A\")}')
print(f'  Active: {d.get(\"active\",False)}')
print(f'  ServerDUTActive: {d.get(\"ServerDUTActive\",False)}')
" 2>/dev/null)

# ============================================================================
# AUTO-START TEST WITH RETRY
# ============================================================================

log_info "Attempting to auto-start CyPerf test..."

TEST_STARTED=false
for attempt in $(seq 1 8); do
    TOKEN=$(get_token)
    # PATCH to start
    START_RESP=$(curl -sk -o /dev/null -w "%{http_code}" \
        -X PATCH "https://${CONTROLLER_IP}/api/v2/sessions/$SESSION_ID/test" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"status":"STARTED"}')

    if [[ "$START_RESP" == "204" || "$START_RESP" == "200" ]]; then
        sleep 15
        # Check if test is actually running
        TOKEN=$(get_token)
        TEST_STATUS=$(curl -sk "https://${CONTROLLER_IP}/api/v2/sessions/$SESSION_ID/test" \
            -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('testElapsed',0))" 2>/dev/null || echo "0")
        if [[ "$TEST_STATUS" != "0" ]]; then
            log_success "Test started successfully (elapsed: ${TEST_STATUS}s)"
            TEST_STARTED=true
            break
        fi
    fi
    log_warning "Start attempt $attempt/8 — waiting 15s..."
    sleep 15
done

if [[ "$TEST_STARTED" != "true" ]]; then
    log_warning "Auto-start did not confirm. Please start from CyPerf UI: https://$CONTROLLER_IP"
fi

echo ""
echo "============================================================================"
echo "  CyPerf Test Configuration Created (DUT Mode - ClusterIP Proxy)"
echo "============================================================================"
echo ""
echo "  Session:    $SESSION_NAME"
echo "  Session ID: $SESSION_ID"
echo ""
echo "  App Mix (HTTP-focused for nginx proxy):"
echo "$FINAL_APPS"
echo ""
echo "  Objectives:"
echo "$FINAL_TIMELINE"
echo ""
echo "  DUT Network Segment:"
echo "$DUT_STATUS"
echo ""
echo "  Network:     Client -> DUT (cyperf-proxy: $DUT_HOST) -> Server"
echo "  TLS:         Disabled (default)"
echo "  Agent Tags:  role:client -> Client, role:server -> Server"
echo ""
echo "  Traffic Path:"
echo "    CyPerf Client Pod -> cyperf-proxy ($DUT_HOST) -> nginx-demo pods"
echo "    CloudLens sensors on nginx pods capture all HTTP traffic"
echo ""
echo "  Controller UI: https://$CONTROLLER_IP"
echo "  Login:         admin / <CYPERF_PASSWORD>"
echo ""
if [[ "$TEST_STARTED" == "true" ]]; then
echo "  Test Status:   STARTED (auto-started successfully)"
else
echo "  Test Status:   NOT STARTED — start from CyPerf UI"
fi
echo "============================================================================"
echo ""
