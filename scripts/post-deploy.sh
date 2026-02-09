#!/bin/bash
# ============================================================================
# CLOUDLENS SE TRAINING LAB - POST DEPLOYMENT SCRIPT
# ============================================================================
# Run this after 'terraform apply' completes successfully
# Usage: ./post-deploy.sh [OPTIONS]
#
# Options:
#   --skip-images  Skip pushing Docker images to ECR
#   --skip-apps    Skip deploying sample apps to namespaces
#   --force        Re-run all steps even if previously completed
#   --reset        Clear state and start fresh
#   --status       Show status of all steps
#   --dry-run      Preview what would happen without making changes
#   --cleanup      Remove all resources created by this script
#   --steps N,M    Run only specific steps (e.g., --steps 1,3,5)
#   --no-color     Disable colored output
#   --verbose      Show detailed output
#   --help         Show this help message
#
# This script is idempotent - re-running will skip already completed steps.
# ============================================================================

set -e

# ============================================================================
# DIRECTORY SETUP - Ensure paths work regardless of where script is invoked
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============================================================================
# CONFIGURATION - Edit these paths if needed
# ============================================================================
CLOUDLENS_SENSOR_TAR="$HOME/Downloads/CloudLens-Sensor-6.13.0-359.tar"
CLOUDLENS_HELM_CHART="$HOME/Downloads/cloudlens-sensor-6.13.0-359.tgz"
# SSH key - check local first, then Downloads folder
if [ -f "$BASE_DIR/cloudlens-se-training.pem" ]; then
    SSH_KEY_FILE="$BASE_DIR/cloudlens-se-training.pem"
elif [ -f "$HOME/Downloads/cloudlens-se-training.pem" ]; then
    SSH_KEY_FILE="$HOME/Downloads/cloudlens-se-training.pem"
else
    SSH_KEY_FILE="$BASE_DIR/cloudlens-se-training.pem"  # Default path for error message
fi
TLS_CRT_FILE="$BASE_DIR/tls.crt"
TLS_KEY_FILE="$BASE_DIR/tls.key"
STATE_FILE="$BASE_DIR/.post-deploy-state"
LOG_FILE="$BASE_DIR/post-deploy-$(date +%Y%m%d-%H%M%S).log"
REPORT_FILE="$BASE_DIR/generated/deployment-report.md"
RETRY_COUNT=3
RETRY_DELAY=5
# ============================================================================

# Parse arguments
SKIP_IMAGES=false
SKIP_APPS=false
FORCE_RUN=false
SHOW_STATUS=false
DRY_RUN=false
CLEANUP_MODE=false
NO_COLOR=false
VERBOSE=false
SELECTED_STEPS=""

for arg in "$@"; do
    case $arg in
        --skip-images) SKIP_IMAGES=true ;;
        --skip-apps) SKIP_APPS=true ;;
        --force) FORCE_RUN=true ;;
        --dry-run) DRY_RUN=true ;;
        --cleanup) CLEANUP_MODE=true ;;
        --no-color) NO_COLOR=true ;;
        --verbose) VERBOSE=true ;;
        --steps=*) SELECTED_STEPS="${arg#*=}" ;;
        --reset)
            rm -f "$STATE_FILE"
            echo "State cleared. All steps will run on next execution."
            exit 0
            ;;
        --status)
            SHOW_STATUS=true
            ;;
        --help)
            echo "Usage: ./post-deploy.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-images  Skip pushing Docker images to ECR"
            echo "  --skip-apps    Skip deploying sample apps to namespaces"
            echo "  --force        Re-run all steps even if previously completed"
            echo "  --reset        Clear state and start fresh"
            echo "  --status       Show status of all steps"
            echo "  --dry-run      Preview what would happen without making changes"
            echo "  --cleanup      Remove all resources created by this script"
            echo "  --steps=N,M    Run only specific steps (e.g., --steps=1,3,5)"
            echo "  --no-color     Disable colored output"
            echo "  --verbose      Show detailed output"
            echo "  --help         Show this help message"
            echo ""
            echo "Examples:"
            echo "  ./post-deploy.sh                    # Run all steps"
            echo "  ./post-deploy.sh --dry-run          # Preview without changes"
            echo "  ./post-deploy.sh --steps=1,2        # Run only steps 1 and 2"
            echo "  ./post-deploy.sh --force --steps=4  # Force re-run step 4"
            echo "  ./post-deploy.sh --cleanup          # Remove deployed resources"
            echo ""
            echo "This script is idempotent - re-running will skip completed steps."
            exit 0
            ;;
    esac
done

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo "  [DEBUG] $*"
    fi
    log "[DEBUG] $*"
}

# ============================================================================
# STATE MANAGEMENT FUNCTIONS
# ============================================================================
mark_step_complete() {
    local step="$1"
    local duration="$2"
    if [ ! -f "$STATE_FILE" ]; then
        echo "# Post-deploy state file - do not edit manually" > "$STATE_FILE"
        echo "# Created: $(date)" >> "$STATE_FILE"
    fi
    if ! grep -q "^$step=complete" "$STATE_FILE" 2>/dev/null; then
        echo "$step=complete:$(date +%s):${duration:-0}" >> "$STATE_FILE"
    fi
}

is_step_complete() {
    local step="$1"
    if [ "$FORCE_RUN" = "true" ]; then
        return 1  # Not complete (force re-run)
    fi
    if [ -f "$STATE_FILE" ]; then
        grep -q "^$step=complete" "$STATE_FILE" 2>/dev/null
        return $?
    fi
    return 1  # Not complete
}

should_run_step() {
    local step_num="$1"
    if [ -n "$SELECTED_STEPS" ]; then
        echo ",$SELECTED_STEPS," | grep -q ",$step_num,"
        return $?
    fi
    return 0  # Run all steps if none selected
}

show_step_status() {
    local step="$1"
    local desc="$2"
    if is_step_complete "$step"; then
        local completed_time=$(grep "^$step=complete" "$STATE_FILE" 2>/dev/null | cut -d: -f2)
        local duration=$(grep "^$step=complete" "$STATE_FILE" 2>/dev/null | cut -d: -f3)
        local completed_date=""
        if [ -n "$completed_time" ]; then
            completed_date=" ($(date -r "$completed_time" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$completed_time" '+%Y-%m-%d %H:%M' 2>/dev/null))"
        fi
        echo -e "  ${GREEN}✓${NC} $desc${completed_date}"
    else
        echo -e "  ${YELLOW}○${NC} $desc (pending)"
    fi
}

# ============================================================================
# TIME TRACKING
# ============================================================================
STEP_START_TIME=0
TOTAL_START_TIME=$(date +%s)

start_timer() {
    STEP_START_TIME=$(date +%s)
}

get_elapsed() {
    local end_time=$(date +%s)
    local elapsed=$((end_time - STEP_START_TIME))
    echo "$elapsed"
}

format_duration() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    fi
}

# ============================================================================
# RETRY LOGIC
# ============================================================================
retry_command() {
    local max_attempts=$RETRY_COUNT
    local delay=$RETRY_DELAY
    local attempt=1
    local cmd="$@"

    while [ $attempt -le $max_attempts ]; do
        log_verbose "Attempt $attempt/$max_attempts: $cmd"
        if eval "$cmd"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo -e "${YELLOW}  Retry $attempt/$max_attempts failed, waiting ${delay}s...${NC}"
            sleep $delay
        fi
        attempt=$((attempt + 1))
    done

    echo -e "${RED}  Command failed after $max_attempts attempts${NC}"
    return 1
}

# ============================================================================
# HEALTH CHECK FUNCTIONS
# ============================================================================
wait_for_pods_ready() {
    local namespace="$1"
    local label_selector="$2"
    local timeout="${3:-120}"
    local poll_interval=5
    local elapsed=0

    echo "    Waiting for pods with selector '$label_selector' in namespace '$namespace' to be Running..."
    log "Health check: waiting for pods $label_selector in $namespace (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        # Get pod status
        local pod_status=$(kubectl get pods -n "$namespace" -l "$label_selector" -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
        local ready_output=$(kubectl get pods -n "$namespace" -l "$label_selector" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c "true" 2>/dev/null) || true
        local ready_count=${ready_output:-0}
        local total_pods=$(kubectl get pods -n "$namespace" -l "$label_selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        log_verbose "Pod status check: phase='$pod_status', ready=$ready_count/$total_pods"

        # Check if all pods are Running and all containers are ready
        if [ "$total_pods" -gt 0 ]; then
            local running_output=$(echo "$pod_status" | tr ' ' '\n' | grep -c "Running" 2>/dev/null) || true
            local running_count=${running_output:-0}
            if [ "$running_count" -eq "$total_pods" ] && [ "$ready_count" -eq "$total_pods" ]; then
                echo -e "    ${GREEN}✓ All $total_pods pod(s) are Running and Ready${NC}"
                log "Health check passed: $total_pods pods ready in $namespace"
                return 0
            fi
        fi

        # Check for failed pods
        local failed_output=$(echo "$pod_status" | tr ' ' '\n' | grep -c "Failed" 2>/dev/null) || true
        local failed=${failed_output:-0}
        if [ "$failed" -gt 0 ]; then
            echo -e "    ${RED}✗ $failed pod(s) in Failed state${NC}"
            log "Health check failed: $failed pods failed in $namespace"
            kubectl get pods -n "$namespace" -l "$label_selector" --no-headers 2>/dev/null
            return 1
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
        echo -e "    ${YELLOW}○ Waiting... ($elapsed/${timeout}s)${NC}"
    done

    echo -e "    ${RED}✗ Timeout waiting for pods to be ready${NC}"
    log "Health check timeout: pods not ready after ${timeout}s in $namespace"
    kubectl get pods -n "$namespace" -l "$label_selector" --no-headers 2>/dev/null
    return 1
}

wait_for_all_namespace_pods() {
    local namespace="$1"
    local timeout="${2:-180}"
    local success=true

    echo "  Performing health checks for namespace: $namespace"
    log "Starting health checks for namespace: $namespace"

    # Wait for nginx-demo pods
    if ! wait_for_pods_ready "$namespace" "app=nginx-demo" "$timeout"; then
        success=false
    fi

    if [ "$success" = "true" ]; then
        echo -e "  ${GREEN}✓ All pods healthy in $namespace${NC}"
        return 0
    else
        echo -e "  ${RED}✗ Some pods failed health check in $namespace${NC}"
        return 1
    fi
}

# ============================================================================
# LOADBALANCER FUNCTIONS
# ============================================================================
wait_for_loadbalancer() {
    local namespace="$1"
    local service_name="$2"
    local timeout="${3:-180}"
    local poll_interval=10
    local elapsed=0

    echo "    Waiting for LoadBalancer external hostname for $service_name in $namespace..." >&2
    log "LoadBalancer wait: $service_name in $namespace (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        local hostname=$(kubectl get svc "$service_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        local ip=$(kubectl get svc "$service_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

        if [ -n "$hostname" ]; then
            echo -e "    ${GREEN}✓ LoadBalancer ready: $hostname${NC}" >&2
            log "LoadBalancer ready: $hostname"
            echo "$hostname"
            return 0
        elif [ -n "$ip" ]; then
            echo -e "    ${GREEN}✓ LoadBalancer ready: $ip${NC}" >&2
            log "LoadBalancer ready: $ip"
            echo "$ip"
            return 0
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
        echo -e "    ${YELLOW}○ Waiting for LoadBalancer... ($elapsed/${timeout}s)${NC}" >&2
    done

    echo -e "    ${RED}✗ Timeout waiting for LoadBalancer${NC}" >&2
    log "LoadBalancer timeout: $service_name in $namespace"
    return 1
}

update_se_guide_with_nginx_url() {
    local namespace="$1"
    local nginx_url="$2"
    local se_num="${namespace#se-}"  # Extract "01" from "se-01"
    local guide_file="$BASE_DIR/generated/se-lab-${se_num}/SE-LAB-${se_num}-GUIDE.md"

    if [ ! -f "$guide_file" ]; then
        log_verbose "SE guide not found: $guide_file"
        return 1
    fi

    # Check if nginx section already has real URLs (not placeholders)
    if grep -q "curl http://" "$guide_file" 2>/dev/null && ! grep -q "Pending" "$guide_file" 2>/dev/null && ! grep -q "NGINX_URL_PLACEHOLDER" "$guide_file" 2>/dev/null; then
        log_verbose "Nginx URLs already configured in $guide_file"
        return 0
    fi

    echo "  Updating SE guide: $guide_file"
    log "Updating SE guide with nginx URL: $guide_file"

    # Create the nginx section content (matches reference SE guide format)
    local nginx_section
    nginx_section=$(cat << NGINX_EOF
Your dedicated nginx application is deployed and accessible at:

| Protocol | URL |
|----------|-----|
| **HTTP** | http://${nginx_url} |
| **HTTPS** | https://${nginx_url} |

**Test it:**
\`\`\`bash
# HTTP
curl http://${nginx_url}

# HTTPS (may show certificate warning)
curl -k https://${nginx_url}
\`\`\`

This nginx service is running in your dedicated Kubernetes namespace (\`${namespace}\`) on your dedicated EKS node.
NGINX_EOF
)

    # Check if there's a placeholder section to replace (new template format)
    if grep -q "NGINX_URL_PLACEHOLDER_START" "$guide_file" 2>/dev/null; then
        # Replace content between placeholder markers with actual URLs
        local temp_file="${guide_file}.tmp"
        local in_placeholder=false

        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" == *"NGINX_URL_PLACEHOLDER_START"* ]]; then
                in_placeholder=true
                echo "$nginx_section" >> "$temp_file"
                continue
            fi
            if [[ "$line" == *"NGINX_URL_PLACEHOLDER_END"* ]]; then
                in_placeholder=false
                continue
            fi
            if [ "$in_placeholder" = "false" ]; then
                echo "$line" >> "$temp_file"
            fi
        done < "$guide_file"

        mv "$temp_file" "$guide_file"
        echo -e "  ${GREEN}✓ Replaced placeholder with nginx URL in SE guide${NC}"
        return 0
    fi

    # Check if there's old-format content to replace (pre-template nginx sections)
    if grep -q "Kubernetes Demo App" "$guide_file" 2>/dev/null || \
       (grep -q "Nginx LoadBalancer URL" "$guide_file" 2>/dev/null && grep -q "Pending" "$guide_file" 2>/dev/null); then
        # Find and replace the old nginx section
        local temp_file="${guide_file}.tmp"
        local skip_until_next_section=false
        local replaced=false

        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" == "### Kubernetes Demo App"* ]] || \
               ([[ "$line" == "## Nginx LoadBalancer URL"* ]] && ! $replaced); then
                skip_until_next_section=true
                # If it's the ## header, keep it and add content after
                if [[ "$line" == "## Nginx LoadBalancer URL"* ]]; then
                    echo "$line" >> "$temp_file"
                    echo "" >> "$temp_file"
                    echo "$nginx_section" >> "$temp_file"
                    echo "" >> "$temp_file"
                else
                    echo "$nginx_section" >> "$temp_file"
                    echo "" >> "$temp_file"
                fi
                replaced=true
                continue
            fi
            if [ "$skip_until_next_section" = "true" ]; then
                # Stop skipping when we hit the next ## or ### section
                if [[ "$line" == "## "* ]] || [[ "$line" == "---" ]]; then
                    skip_until_next_section=false
                    echo "$line" >> "$temp_file"
                fi
                continue
            fi
            echo "$line" >> "$temp_file"
        done < "$guide_file"

        if [ "$replaced" = "true" ]; then
            mv "$temp_file" "$guide_file"
            echo -e "  ${GREEN}✓ Updated nginx URL in SE guide${NC}"
        else
            rm -f "$temp_file"
        fi
        return 0
    fi

    # No existing section - add after "## Nginx LoadBalancer URL" or "## All Access Information"
    local temp_file="${guide_file}.tmp"
    local nginx_added=false

    while IFS= read -r line || [ -n "$line" ]; do
        echo "$line" >> "$temp_file"
        if [[ "$line" == "## Nginx LoadBalancer URL" ]] && [ "$nginx_added" = "false" ]; then
            echo "" >> "$temp_file"
            echo "$nginx_section" >> "$temp_file"
            echo "" >> "$temp_file"
            nginx_added=true
        elif [[ "$line" == "## All Access Information" ]] && [ "$nginx_added" = "false" ]; then
            echo "" >> "$temp_file"
            echo "## Nginx LoadBalancer URL" >> "$temp_file"
            echo "" >> "$temp_file"
            echo "$nginx_section" >> "$temp_file"
            echo "" >> "$temp_file"
            nginx_added=true
        fi
    done < "$guide_file"

    if [ "$nginx_added" = "true" ]; then
        mv "$temp_file" "$guide_file"
        echo -e "  ${GREEN}✓ Added nginx URL to SE guide${NC}"
    else
        rm -f "$temp_file"
        log_verbose "Could not find insertion point in $guide_file"
    fi
}

copy_ssh_key_to_se_folder() {
    local se_num="$1"
    local guide_dir="$BASE_DIR/generated/se-lab-${se_num}"
    local guide_file="${guide_dir}/SE-LAB-${se_num}-GUIDE.md"

    if [ ! -f "$SSH_KEY_FILE" ]; then
        log_verbose "SSH key file not found: $SSH_KEY_FILE"
        return 1
    fi

    if [ ! -d "$guide_dir" ]; then
        log_verbose "SE guide directory not found: $guide_dir"
        return 1
    fi

    # Copy SSH key to SE folder (remove existing first due to 400 permissions)
    rm -f "${guide_dir}/cloudlens-se-training.pem"
    cp "$SSH_KEY_FILE" "${guide_dir}/cloudlens-se-training.pem"
    chmod 400 "${guide_dir}/cloudlens-se-training.pem"
    echo "    Copied SSH key to ${guide_dir}/"
    log "Copied SSH key to ${guide_dir}/"

    # Update the guide to reference the local key
    if [ -f "$guide_file" ]; then
        # Update the note about asking administrator
        if grep -q "Ask your lab administrator" "$guide_file" 2>/dev/null; then
            sed -i.bak 's|Ask your lab administrator for the `cloudlens-se-training.pem` key file if you don.t have it.|The SSH key file `cloudlens-se-training.pem` is included in this folder.|g' "$guide_file"
            rm -f "${guide_file}.bak"

            # Also update the save location instruction
            sed -i.bak 's|Save the .pem file to your Downloads folder, then:|The key is included in this folder. Copy it to your Downloads folder:|g' "$guide_file"
            rm -f "${guide_file}.bak"

            echo -e "    ${GREEN}✓ Updated SE guide with local key reference${NC}"
        fi
    fi

    return 0
}

tag_se_node_for_ssm() {
    local namespace="$1"
    local node_group_name="${DEPLOYMENT_PREFIX}-${namespace}-node"

    echo "    Checking SE node tagging for SSM access..."
    log "Tagging SE node for SSM: $namespace"

    # Find the instance by node group name
    local instance_id=$(aws ec2 describe-instances \
        --filters "Name=tag:eks:nodegroup-name,Values=$node_group_name" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null)

    if [ -z "$instance_id" ]; then
        log_verbose "No running instance found for node group: $node_group_name"
        echo -e "    ${YELLOW}Node not found for $namespace (may still be launching)${NC}"
        return 1
    fi

    # Check if already tagged with SE-ID
    local existing_tag=$(aws ec2 describe-tags \
        --filters "Name=resource-id,Values=$instance_id" "Name=key,Values=SE-ID" \
        --query "Tags[0].Value" --output text \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null)

    if [ "$existing_tag" = "$namespace" ]; then
        log_verbose "Instance $instance_id already tagged with SE-ID=$namespace"
        echo -e "    ${GREEN}✓ Node already tagged with SE-ID=$namespace${NC}"
        return 0
    fi

    # Tag the instance
    aws ec2 create-tags --resources "$instance_id" \
        --tags Key=SE-ID,Value="$namespace" Key=Name,Value="$node_group_name" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "    ${GREEN}✓ Tagged node $instance_id with SE-ID=$namespace${NC}"
        log "Tagged instance $instance_id with SE-ID=$namespace"
    else
        echo -e "    ${RED}Failed to tag node for $namespace${NC}"
        return 1
    fi

    return 0
}

update_se_guide_with_node_access() {
    local namespace="$1"
    local se_num="${namespace#se-}"
    local guide_file="$BASE_DIR/generated/se-lab-${se_num}/SE-LAB-${se_num}-GUIDE.md"

    if [ ! -f "$guide_file" ]; then
        log_verbose "SE guide not found: $guide_file"
        return 1
    fi

    # Check if node access section already exists
    if grep -q "Dedicated EKS Node Access" "$guide_file" 2>/dev/null; then
        log_verbose "Node access section already exists in $guide_file"
        return 0
    fi

    echo "  Updating SE guide with node access instructions: $guide_file"
    log "Updating SE guide with node access: $guide_file"

    # Append node access section at the end of the file
    cat >> "$guide_file" << NODE_ACCESS_EOF

---

## Dedicated EKS Node Access

### Your Dedicated Node

| Item | Value |
|------|-------|
| **SE ID** | ${namespace} |
| **Node Label** | \`se-id=${namespace}\` |
| **Instance Type** | t3.medium (2 vCPU, 4GB RAM) |

### SSH to Your Node via AWS Session Manager

You can SSH directly to your dedicated Kubernetes node using AWS Session Manager (no SSH keys required):

\`\`\`bash
# Find your node's instance ID
INSTANCE_ID=\$(aws ec2 describe-instances \\
  --filters "Name=tag:SE-ID,Values=${namespace}" "Name=instance-state-name,Values=running" \\
  --query 'Reservations[].Instances[].InstanceId' \\
  --output text --profile cloudlens-lab --region ${AWS_REGION})

# Connect via Session Manager
aws ssm start-session --target \$INSTANCE_ID --profile cloudlens-lab --region ${AWS_REGION}
\`\`\`

> **Note:** You can only access the node tagged with your SE-ID (${namespace}). Access to other SEs' nodes is denied.

### Privileged Container Access

Your namespace is configured with the **privileged** Pod Security Standard, allowing you to:
- Run containers with \`privileged: true\`
- Use \`hostNetwork\`, \`hostPID\`, \`hostIPC\`
- Mount host paths
- Access host devices

#### Example: Debug Pod with Full Host Access

\`\`\`yaml
apiVersion: v1
kind: Pod
metadata:
  name: debug-pod
  namespace: ${namespace}
spec:
  tolerations:
  - key: "se-id"
    operator: "Equal"
    value: "${namespace}"
    effect: "NoSchedule"
  nodeSelector:
    se-id: ${namespace}
  hostNetwork: true
  hostPID: true
  hostIPC: true
  containers:
  - name: debug
    image: ubuntu:latest
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-root
      mountPath: /host
      readOnly: true
  volumes:
  - name: host-root
    hostPath:
      path: /
\`\`\`

**Deploy and access:**
\`\`\`bash
# Deploy the debug pod
kubectl apply -f debug-pod.yaml

# Access the pod
kubectl exec -it debug-pod -- bash

# Inside container - full host access:
ls /host/var/log          # Host filesystem
ps aux                    # Host processes (via hostPID)
cat /host/etc/hostname    # Node hostname
\`\`\`

#### CloudLens Sensor with Host Access

For deploying CloudLens sensors with host-level access:

\`\`\`yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cloudlens-sensor
  namespace: ${namespace}
spec:
  selector:
    matchLabels:
      app: cloudlens-sensor
  template:
    metadata:
      labels:
        app: cloudlens-sensor
    spec:
      tolerations:
      - key: "se-id"
        operator: "Equal"
        value: "${namespace}"
        effect: "NoSchedule"
      nodeSelector:
        se-id: ${namespace}
      hostNetwork: true
      containers:
      - name: cloudlens-sensor
        image: ${ECR_REGISTRY}/cloudlens-sensor:latest
        securityContext:
          privileged: true
        volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
        - name: cgroup
          mountPath: /sys/fs/cgroup
          readOnly: true
      volumes:
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock
      - name: cgroup
        hostPath:
          path: /sys/fs/cgroup
\`\`\`

NODE_ACCESS_EOF

    echo -e "  ${GREEN}✓ Added node access instructions to SE guide${NC}"
    return 0
}

# ============================================================================
# PREREQUISITES CHECK
# ============================================================================
check_prerequisites() {
    echo -e "${BLUE}Checking prerequisites...${NC}"
    local missing=0

    # Check required tools
    for tool in terraform kubectl aws docker jq helm; do
        if command -v $tool &> /dev/null; then
            local version=""
            case $tool in
                kubectl) version=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1) ;;
                helm) version=$(helm version --short 2>/dev/null || helm version 2>&1 | head -1) ;;
                *) version=$($tool --version 2>&1 | head -1) ;;
            esac
            echo -e "  ${GREEN}✓${NC} $tool: $version"
            log_verbose "$tool found: $version"
        else
            echo -e "  ${RED}✗${NC} $tool: NOT FOUND"
            missing=$((missing + 1))
        fi
    done

    # Check terraform state exists
    if [ ! -f "terraform.tfstate" ] && [ ! -d ".terraform" ]; then
        echo -e "  ${YELLOW}!${NC} Warning: No terraform state found. Run 'terraform apply' first."
    fi

    # Check if CloudLens sensor tar exists
    if [ -f "$CLOUDLENS_SENSOR_TAR" ]; then
        local size=$(du -h "$CLOUDLENS_SENSOR_TAR" | cut -f1)
        echo -e "  ${GREEN}✓${NC} CloudLens Sensor Image: $CLOUDLENS_SENSOR_TAR ($size)"
    else
        echo -e "  ${YELLOW}!${NC} CloudLens Sensor tar not found at $CLOUDLENS_SENSOR_TAR"
    fi

    # Check if CloudLens Helm chart exists
    if [ -f "$CLOUDLENS_HELM_CHART" ]; then
        local size=$(du -h "$CLOUDLENS_HELM_CHART" | cut -f1)
        echo -e "  ${GREEN}✓${NC} CloudLens Helm Chart: $CLOUDLENS_HELM_CHART ($size)"
    else
        echo -e "  ${YELLOW}!${NC} CloudLens Helm chart not found at $CLOUDLENS_HELM_CHART"
    fi

    # Check for SSH key file
    if [ -f "$SSH_KEY_FILE" ]; then
        echo -e "  ${GREEN}✓${NC} SSH Key: $SSH_KEY_FILE"
    else
        echo -e "  ${YELLOW}!${NC} SSH Key not found at $SSH_KEY_FILE (SEs won't get SSH key)"
    fi

    # Check for TLS cert files (needed for HTTPS nginx deployment)
    if [ -f "$TLS_CRT_FILE" ] && [ -f "$TLS_KEY_FILE" ]; then
        echo -e "  ${GREEN}✓${NC} TLS Certs: Found (for nginx HTTPS)"
    else
        echo -e "  ${YELLOW}!${NC} TLS certs not found (needed for HTTPS nginx)"
    fi

    # Check Docker daemon
    if docker info &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Docker daemon: Running"
    else
        echo -e "  ${RED}✗${NC} Docker daemon: NOT RUNNING"
        missing=$((missing + 1))
    fi

    echo ""

    if [ $missing -gt 0 ]; then
        echo -e "${RED}Error: $missing required tool(s) missing. Please install them first.${NC}"
        exit 1
    fi
}

# Colors for output (respect --no-color flag)
if [ "$NO_COLOR" = "true" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
fi

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}CloudLens SE Training Lab - Post Deployment${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
log "Script started with args: $*"

# Show mode indicators
[ "$DRY_RUN" = "true" ] && echo -e "${CYAN}>>> DRY-RUN MODE - No changes will be made <<<${NC}" && echo ""
[ "$CLEANUP_MODE" = "true" ] && echo -e "${CYAN}>>> CLEANUP MODE - Resources will be removed <<<${NC}" && echo ""
[ -n "$SELECTED_STEPS" ] && echo -e "${CYAN}>>> Running only steps: $SELECTED_STEPS <<<${NC}" && echo ""

# Show status if requested
if [ "$SHOW_STATUS" = "true" ]; then
    echo -e "${BLUE}Step Status:${NC}"
    show_step_status "kubectl_config" "Step 1: Configure kubectl for Shared EKS"
    show_step_status "ecr_login" "Step 2a: ECR Login"
    show_step_status "push_cloudlens_sensor" "Step 2b: Push CloudLens Sensor Image"
    show_step_status "push_helm_chart" "Step 2c: Push CloudLens Helm Chart"
    show_step_status "create_namespaces" "Step 3: Create SE Namespaces"
    show_step_status "deploy_apps" "Step 4: Deploy nginx app"
    show_step_status "deploy_cyperf_proxy" "Step 4b: Deploy CyPerf reverse proxy"
    show_step_status "generate_kubeconfigs" "Step 5: Generate kubeconfig files"
    echo ""
    echo "State file: $STATE_FILE"
    echo "Log file:   $LOG_FILE"
    echo ""
    echo "Use --force to re-run completed steps"
    echo "Use --reset to clear state and start fresh"
    exit 0
fi

# Check prerequisites (unless in cleanup mode)
if [ "$CLEANUP_MODE" != "true" ]; then
    check_prerequisites
fi

# Read terraform outputs
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-west-2")
AWS_PROFILE=$(terraform output -raw aws_profile 2>/dev/null || echo "cloudlens-lab")
NUM_SE_LABS=$(terraform output -raw num_se_labs 2>/dev/null || echo "1")
SHARED_EKS_ENABLED=$(terraform output -raw shared_eks_enabled 2>/dev/null || echo "false")
CYPERF_ENABLED=$(terraform output -raw cyperf_enabled 2>/dev/null || echo "false")
DEPLOYMENT_PREFIX=$(terraform output -raw deployment_prefix 2>/dev/null || echo "se-lab")
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)

# Get Public ECR registry alias (must query AWS - it's NOT the account ID)
# Public ECR alias is assigned by AWS and is different from account ID
PUBLIC_ECR_ALIAS=$(aws ecr-public describe-registries --region us-east-1 --profile "$AWS_PROFILE" \
    --query 'registries[0].aliases[?primaryRegistryAlias==`true`].name' --output text 2>/dev/null)

if [ -z "$PUBLIC_ECR_ALIAS" ] || [ "$PUBLIC_ECR_ALIAS" = "None" ]; then
    echo -e "${YELLOW}Warning: Could not get Public ECR alias. You may need to create a public repository first.${NC}"
    PUBLIC_ECR_ALIAS="$ACCOUNT_ID"  # Fallback (won't work but shows the issue)
fi

ECR_REGISTRY="public.ecr.aws/${PUBLIC_ECR_ALIAS}"

echo -e "${GREEN}Configuration:${NC}"
echo "  AWS Region:   $AWS_REGION"
echo "  AWS Profile:  $AWS_PROFILE"
echo "  AWS Account:  $ACCOUNT_ID"
echo "  SE Labs:      $NUM_SE_LABS"
echo "  Shared EKS:   $SHARED_EKS_ENABLED"
echo "  CyPerf:       $CYPERF_ENABLED"
echo "  ECR Registry: $ECR_REGISTRY (Public - no auth for pulls)"
echo ""

# ============================================================================
# STEP 1: Configure kubectl for Shared EKS
# ============================================================================
if ! should_run_step 1; then
    echo -e "${YELLOW}Step 1: Skipped (--steps flag)${NC}"
    echo ""
elif [ "$SHARED_EKS_ENABLED" = "true" ]; then
    if is_step_complete "kubectl_config"; then
        echo -e "${GREEN}Step 1: kubectl already configured (skipping)${NC}"
        EKS_CLUSTER_NAME=$(terraform output -raw shared_eks_cluster_name 2>/dev/null || echo "se-lab-shared-eks")
    else
        echo -e "${YELLOW}Step 1: Configuring kubectl for Shared EKS...${NC}"

        EKS_CLUSTER_NAME=$(terraform output -raw shared_eks_cluster_name 2>/dev/null || echo "se-lab-shared-eks")

        aws eks update-kubeconfig \
            --region "$AWS_REGION" \
            --name "$EKS_CLUSTER_NAME" \
            --profile "$AWS_PROFILE" \
            --alias "$EKS_CLUSTER_NAME"

        echo -e "${GREEN}✓ kubectl configured for $EKS_CLUSTER_NAME${NC}"

        # Wait for nodes to be ready
        echo "Waiting for EKS nodes to be ready..."
        kubectl wait --for=condition=Ready nodes --all --timeout=300s 2>/dev/null || echo -e "${YELLOW}Warning: Some nodes may not be ready yet${NC}"

        mark_step_complete "kubectl_config"
    fi
    echo ""
else
    echo -e "${YELLOW}Step 1: Skipped (Shared EKS not enabled)${NC}"
    echo ""
fi

# ============================================================================
# STEP 2: Login to ECR and Push Images
# ============================================================================
if ! should_run_step 2; then
    echo -e "${YELLOW}Step 2: Skipped (--steps flag)${NC}"
    echo ""
elif [ "$SHARED_EKS_ENABLED" = "true" ] && [ "$SKIP_IMAGES" = "false" ]; then
    echo -e "${YELLOW}Step 2: ECR Login and Image Push...${NC}"

    # ECR Login (always do this as tokens expire)
    if is_step_complete "ecr_login"; then
        echo -e "${GREEN}  2a: ECR login (re-authenticating for fresh token)${NC}"
    else
        echo "  2a: Logging into ECR..."
    fi
    # Public ECR login (always uses us-east-1)
    aws ecr-public get-login-password --region us-east-1 --profile "$AWS_PROFILE" | \
        docker login --username AWS --password-stdin public.ecr.aws
    echo -e "${GREEN}  ✓ Logged into Public ECR${NC}"
    mark_step_complete "ecr_login"

    # Load and push CloudLens Sensor from local tar file
    if is_step_complete "push_cloudlens_sensor"; then
        echo -e "${GREEN}  2b: CloudLens Sensor already pushed (skipping)${NC}"
    else
        if [ -f "$CLOUDLENS_SENSOR_TAR" ]; then
            echo "  2b: Loading CloudLens Sensor from $CLOUDLENS_SENSOR_TAR..."
            LOADED_IMAGE=$(docker load -i "$CLOUDLENS_SENSOR_TAR" | grep "Loaded image" | awk '{print $NF}')
            if [ -n "$LOADED_IMAGE" ]; then
                echo "      Loaded: $LOADED_IMAGE"
                docker tag "$LOADED_IMAGE" "${ECR_REGISTRY}/cloudlens-sensor:latest"
                docker tag "$LOADED_IMAGE" "${ECR_REGISTRY}/cloudlens-sensor:6.13.0-359"
                retry_command "docker push '${ECR_REGISTRY}/cloudlens-sensor:latest'"
                retry_command "docker push '${ECR_REGISTRY}/cloudlens-sensor:6.13.0-359'"
                echo -e "${GREEN}  ✓ Pushed CloudLens Sensor to ECR${NC}"
                mark_step_complete "push_cloudlens_sensor"
            else
                echo -e "${YELLOW}  Warning: Could not determine loaded image name. Trying alternative method...${NC}"
                SENSOR_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -i "cloudlens.*sensor" | head -1)
                if [ -n "$SENSOR_IMAGE" ]; then
                    docker tag "$SENSOR_IMAGE" "${ECR_REGISTRY}/cloudlens-sensor:latest"
                    docker tag "$SENSOR_IMAGE" "${ECR_REGISTRY}/cloudlens-sensor:6.13.0-359"
                    retry_command "docker push '${ECR_REGISTRY}/cloudlens-sensor:latest'"
                    retry_command "docker push '${ECR_REGISTRY}/cloudlens-sensor:6.13.0-359'"
                    echo -e "${GREEN}  ✓ Pushed CloudLens Sensor to ECR${NC}"
                    mark_step_complete "push_cloudlens_sensor"
                else
                    echo -e "${RED}  Error: Could not find CloudLens Sensor image after loading${NC}"
                fi
            fi
        else
            echo -e "${YELLOW}  2b: CloudLens Sensor tar not found at $CLOUDLENS_SENSOR_TAR (skipping)${NC}"
            echo "      To push CloudLens Sensor, place the tar file at: $CLOUDLENS_SENSOR_TAR"
        fi
    fi

    # Push Helm chart to public ECR
    if is_step_complete "push_helm_chart"; then
        echo -e "${GREEN}  2c: CloudLens Helm chart already pushed (skipping)${NC}"
    else
        if [ -f "$CLOUDLENS_HELM_CHART" ]; then
            echo "  2c: Pushing CloudLens Helm chart to Public ECR..."

            # Extract chart version from filename (e.g., cloudlens-sensor-6.11.1-302.tgz -> 6.11.1-302)
            CHART_FILENAME=$(basename "$CLOUDLENS_HELM_CHART")
            CHART_VERSION=$(echo "$CHART_FILENAME" | sed -n 's/cloudlens-sensor-\(.*\)\.tgz/\1/p')

            if [ -z "$CHART_VERSION" ]; then
                CHART_VERSION="latest"
            fi

            echo "      Chart: $CHART_FILENAME"
            echo "      Version: $CHART_VERSION"

            # Push Helm chart to ECR using OCI
            if retry_command "helm push '$CLOUDLENS_HELM_CHART' oci://public.ecr.aws/${PUBLIC_ECR_ALIAS}"; then
                echo -e "${GREEN}  ✓ Pushed CloudLens Helm chart to Public ECR${NC}"
                echo -e "    Pull with: ${CYAN}helm pull oci://public.ecr.aws/${PUBLIC_ECR_ALIAS}/cloudlens-sensor --version $CHART_VERSION${NC}"
                mark_step_complete "push_helm_chart"
            else
                echo -e "${RED}  Error: Failed to push Helm chart${NC}"
            fi
        else
            echo -e "${YELLOW}  2c: CloudLens Helm chart not found at $CLOUDLENS_HELM_CHART (skipping)${NC}"
            echo "      To push Helm chart, place the file at: $CLOUDLENS_HELM_CHART"
        fi
    fi

    echo ""
else
    if [ "$SKIP_IMAGES" = "true" ]; then
        echo -e "${YELLOW}Step 2: Skipped (--skip-images flag)${NC}"
    else
        echo -e "${YELLOW}Step 2: Skipped (Shared EKS not enabled)${NC}"
    fi
    echo ""
fi

# ============================================================================
# STEP 3: Create SE Namespaces and RBAC
# ============================================================================
if ! should_run_step 3; then
    echo -e "${YELLOW}Step 3: Skipped (--steps flag)${NC}"
    echo ""
elif [ "$SHARED_EKS_ENABLED" = "true" ]; then
    if is_step_complete "create_namespaces"; then
        echo -e "${GREEN}Step 3: SE Namespaces already created (skipping)${NC}"
    else
        echo -e "${YELLOW}Step 3: Creating SE Namespaces with RBAC...${NC}"

        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            echo "  Creating namespace: $NS"

            # Create namespace
            kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

            # Label namespace for node affinity
            kubectl label namespace "$NS" se-id="$NS" --overwrite 2>/dev/null || true

            # Add Pod Security Standard labels (allow privileged containers)
            kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null || true
            kubectl label namespace "$NS" pod-security.kubernetes.io/enforce-version=latest --overwrite 2>/dev/null || true
            kubectl label namespace "$NS" pod-security.kubernetes.io/warn=privileged --overwrite 2>/dev/null || true
            kubectl label namespace "$NS" pod-security.kubernetes.io/audit=privileged --overwrite 2>/dev/null || true

            # Create ResourceQuota
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: ResourceQuota
metadata:
  name: se-quota
  namespace: $NS
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "20"
    services: "10"
EOF

            # Create LimitRange for defaults
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: LimitRange
metadata:
  name: se-limits
  namespace: $NS
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    type: Container
EOF

            # Create NetworkPolicy for isolation
            # Allows traffic from: same namespace, kube-system, and cyperf-shared (for CyPerf traffic generation)
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-other-namespaces
  namespace: $NS
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          se-id: $NS
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: cyperf-shared
EOF

            # Create ServiceAccount for SE
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NS}-user
  namespace: $NS
EOF

            # Create Role with full access to namespace (including privileged container permissions)
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NS}-full-access
  namespace: $NS
rules:
- apiGroups: ["", "apps", "batch", "extensions", "networking.k8s.io", "policy"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["pods/exec", "pods/log", "pods/portforward", "pods/attach"]
  verbs: ["*"]
EOF

            # Create RoleBinding
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NS}-full-access-binding
  namespace: $NS
subjects:
- kind: ServiceAccount
  name: ${NS}-user
  namespace: $NS
roleRef:
  kind: Role
  name: ${NS}-full-access
  apiGroup: rbac.authorization.k8s.io
EOF

            # Create long-lived token secret for ServiceAccount
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: Secret
metadata:
  name: ${NS}-user-token
  namespace: $NS
  annotations:
    kubernetes.io/service-account.name: ${NS}-user
type: kubernetes.io/service-account-token
EOF

            echo -e "    ${GREEN}✓ Created RBAC for $NS${NC}"
        done

        # Create shared ClusterRoles (node viewing + Helm chart install)
        echo "  Creating shared ClusterRoles..."
        cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
EOF
        cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: se-node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
EOF
        cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: se-helm-cluster-access
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles", "clusterrolebindings"]
  verbs: ["get", "list", "create", "update", "patch", "delete", "escalate", "bind"]
EOF

        # Create ClusterRoleBindings for each SE (node viewing + Helm access)
        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NS}-node-viewer-binding
subjects:
- kind: ServiceAccount
  name: ${NS}-user
  namespace: $NS
- kind: ServiceAccount
  name: ${NS}-admin
  namespace: $NS
roleRef:
  kind: ClusterRole
  name: se-node-viewer
  apiGroup: rbac.authorization.k8s.io
EOF
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NS}-helm-cluster-access
subjects:
- kind: ServiceAccount
  name: ${NS}-admin
  namespace: $NS
- kind: ServiceAccount
  name: ${NS}-user
  namespace: $NS
roleRef:
  kind: ClusterRole
  name: se-helm-cluster-access
  apiGroup: rbac.authorization.k8s.io
EOF
        done
        echo -e "  ${GREEN}✓ SEs can now view nodes and install Helm charts${NC}"

        echo -e "${GREEN}✓ Created $NUM_SE_LABS SE namespaces with RBAC${NC}"
        mark_step_complete "create_namespaces"
    fi
    echo ""
else
    echo -e "${YELLOW}Step 3: Skipped (Shared EKS not enabled)${NC}"
    echo ""
fi

# ============================================================================
# STEP 4: Deploy Sample Apps to Each SE Namespace
# ============================================================================
if ! should_run_step 4; then
    echo -e "${YELLOW}Step 4: Skipped (--steps flag)${NC}"
    echo ""
elif [ "$SHARED_EKS_ENABLED" = "true" ] && [ "$SKIP_APPS" = "false" ]; then
    if is_step_complete "deploy_apps"; then
        echo -e "${GREEN}Step 4: Sample apps already deployed (skipping)${NC}"
        echo "  Checking deployment status..."
        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            NGINX_STATUS=$(kubectl get pods -n "$NS" -l app=nginx-demo -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
            echo "    $NS: nginx=$NGINX_STATUS"
        done
    else
        echo -e "${YELLOW}Step 4: Deploying sample apps to each SE namespace...${NC}"

        # Check for TLS cert files (paths defined at top of script)
        if [ ! -f "$TLS_CRT_FILE" ] || [ ! -f "$TLS_KEY_FILE" ]; then
            echo -e "${RED}  Error: TLS cert files not found (tls.crt, tls.key)${NC}"
            echo "  Please ensure tls.crt and tls.key are in the current directory"
            exit 1
        fi

        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            echo "  Deploying to namespace: $NS"

            # Create TLS secret from cert files
            echo "    Creating TLS secret..."
            kubectl create secret tls nginx-tls-secret \
                --cert="$TLS_CRT_FILE" \
                --key="$TLS_KEY_FILE" \
                -n "$NS" \
                --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

            # Create nginx SSL configuration ConfigMap
            cat <<'NGINXCONF' | sed "s/\$NS/$NS/g" | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-ssl-config
  namespace: $NS
data:
  default.conf: |
    server {
        listen 80;
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
NGINXCONF

            # Create stylish HTML page ConfigMap
            SE_NUM="${NS#se-}"
            cat <<HTMLEOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-html
  namespace: $NS
data:
  index.html: |
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>CloudLens SE Training Lab - $NS</title>
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
            .particles {
                position: absolute; top: 0; left: 0; width: 100%; height: 100%;
                pointer-events: none; z-index: 1;
            }
            .particle {
                position: absolute;
                background: rgba(255, 255, 255, 0.7);
                border-radius: 50%;
                animation: float 6s ease-in-out infinite;
            }
            @keyframes float {
                0% { transform: translateY(0px) translateX(0px) rotate(0deg); opacity: 0.4; }
                50% { transform: translateY(-60px) translateX(-10px) rotate(180deg); opacity: 1; }
                100% { transform: translateY(0px) translateX(0px) rotate(360deg); opacity: 0.4; }
            }
            .container {
                position: relative; z-index: 2;
                display: flex; flex-direction: column; align-items: center; justify-content: center;
                min-height: 100vh; padding: 20px;
            }
            .logo {
                width: 200px; height: auto;
                display: flex; align-items: center; justify-content: center;
                margin-bottom: 40px;
                animation: pulse 2s ease-in-out infinite;
            }
            .logo img { width: 100%; height: auto; filter: drop-shadow(0 10px 20px rgba(0,0,0,0.3)); }
            @keyframes pulse { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.05); } }
            .title {
                font-size: 3.5rem; font-weight: 900;
                background: linear-gradient(45deg, #ff6b6b, #4ecdc4, #45b7d1, #96ceb4, #feca57, #ff9ff3, #54a0ff);
                background-size: 400% 400%;
                -webkit-background-clip: text; -webkit-text-fill-color: transparent;
                background-clip: text; text-align: center; margin-bottom: 20px;
                animation: colorShift 4s ease-in-out infinite;
            }
            @keyframes colorShift { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }
            .subtitle { font-size: 1.4rem; color: rgba(255,255,255,0.95); margin-bottom: 20px; text-align: center; }
            .traffic-status {
                font-size: 1.1rem; color: rgba(255,255,255,0.85); margin-bottom: 40px; text-align: center;
                background: rgba(255,255,255,0.1); backdrop-filter: blur(10px);
                padding: 15px 30px; border-radius: 25px; border: 1px solid rgba(255,255,255,0.2);
                max-width: 600px;
            }
            .pod-info-card {
                background: rgba(255,255,255,0.18); backdrop-filter: blur(25px);
                border-radius: 25px; padding: 40px 50px;
                box-shadow: 0 30px 60px rgba(0,0,0,0.4); border: 1px solid rgba(255,255,255,0.25);
                min-width: 500px; max-width: 700px;
            }
            .pod-info-item {
                display: flex; justify-content: space-between; align-items: center;
                margin-bottom: 20px; padding: 15px 0;
                border-bottom: 1px solid rgba(255,255,255,0.15);
            }
            .pod-info-item:last-child { border-bottom: none; margin-bottom: 0; }
            .pod-label { font-weight: 700; color: #ffd700; font-size: 1.2rem; min-width: 140px; }
            .pod-value { color: white; font-size: 1.2rem; font-weight: 500; text-align: right; flex: 1; }
            .refresh-btn {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white; border: none; padding: 12px 35px; border-radius: 30px;
                font-size: 1.1rem; font-weight: 700; cursor: pointer; margin-top: 30px;
                transition: all 0.3s ease; box-shadow: 0 8px 20px rgba(0,0,0,0.4);
            }
            .refresh-btn:hover { transform: translateY(-3px); box-shadow: 0 12px 30px rgba(0,0,0,0.5); }
            @media (max-width: 768px) {
                .title { font-size: 2.5rem; }
                .logo { width: 150px; }
                .pod-info-card { min-width: 90%; padding: 30px 25px; }
                .pod-info-item { flex-direction: column; align-items: flex-start; gap: 8px; }
                .pod-value { text-align: left; }
            }
        </style>
    </head>
    <body>
        <div class="particles" id="particles"></div>
        <div class="container">
            <div class="logo"><img src="https://www.netpoleons.com/uploads/1/0/7/8/107892225/keysight-logo-01_orig.png" alt="Keysight Logo"></div>
            <h1 class="title">CLOUDLENS S1000 TRAINING LAB</h1>
            <p class="subtitle">Namespace: $NS | Powered by Keysight Technologies</p>
            <p class="traffic-status">If you see this page, your Kubernetes pod traffic is being successfully tapped and monitored by CloudLens</p>
            <div class="pod-info-card">
                <div class="pod-info-item"><span class="pod-label">Lab ID:</span><span class="pod-value">SE-$SE_NUM</span></div>
                <div class="pod-info-item"><span class="pod-label">Namespace:</span><span class="pod-value">$NS</span></div>
                <div class="pod-info-item"><span class="pod-label">Cluster:</span><span class="pod-value">se-lab-shared-eks</span></div>
                <div class="pod-info-item"><span class="pod-label">Platform:</span><span class="pod-value">AWS EKS</span></div>
                <div class="pod-info-item"><span class="pod-label">Status:</span><span class="pod-value" style="color: #00ff88;">Active & Monitored</span></div>
                <button class="refresh-btn" onclick="location.reload()">Refresh Page</button>
            </div>
        </div>
        <script>
            function createParticles() {
                const c = document.getElementById('particles');
                for (let i = 0; i < 50; i++) {
                    const p = document.createElement('div');
                    p.className = 'particle';
                    const size = Math.random() * 8 + 3;
                    p.style.width = size + 'px'; p.style.height = size + 'px';
                    p.style.left = Math.random() * 100 + '%';
                    p.style.top = Math.random() * 100 + '%';
                    p.style.animationDelay = Math.random() * 8 + 's';
                    p.style.animationDuration = (Math.random() * 4 + 4) + 's';
                    c.appendChild(p);
                }
            }
            createParticles();
        </script>
    </body>
    </html>
HTMLEOF

            # Deploy nginx with TLS and custom HTML
            cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: $NS
  labels:
    app: nginx-demo
    se-id: $NS
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-demo
  template:
    metadata:
      labels:
        app: nginx-demo
        se-id: $NS
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: se-id
                operator: In
                values:
                - $NS
      tolerations:
      - key: "se-id"
        operator: "Equal"
        value: "$NS"
        effect: "NoSchedule"
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
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
      volumes:
      - name: nginx-ssl
        secret:
          secretName: nginx-tls-secret
      - name: nginx-config
        configMap:
          name: nginx-ssl-config
      - name: nginx-html
        configMap:
          name: nginx-html
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo
  namespace: $NS
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  selector:
    app: nginx-demo
  ports:
  - port: 80
    targetPort: 80
    name: http
  - port: 443
    targetPort: 443
    name: https
  type: LoadBalancer
EOF
        done

        echo -e "${GREEN}✓ Deployed sample apps to all SE namespaces${NC}"

        # Perform health checks - wait for pods to be Running
        echo ""
        echo -e "${YELLOW}  Performing health checks...${NC}"
        HEALTH_CHECK_FAILED=false
        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            if ! wait_for_all_namespace_pods "$NS" 120; then
                HEALTH_CHECK_FAILED=true
            fi
        done

        if [ "$HEALTH_CHECK_FAILED" = "true" ]; then
            echo -e "${YELLOW}  Warning: Some pods failed health checks. Continuing...${NC}"
            log "Health check warning: some pods not ready"
        else
            echo -e "${GREEN}✓ All pods passed health checks${NC}"
        fi

        # Wait for LoadBalancers and update SE guides
        echo ""
        echo -e "${YELLOW}  Waiting for LoadBalancer endpoints...${NC}"
        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            NGINX_URL=$(wait_for_loadbalancer "$NS" "nginx-demo" 180)
            if [ -n "$NGINX_URL" ] && [ "$NGINX_URL" != "0" ]; then
                update_se_guide_with_nginx_url "$NS" "$NGINX_URL"
            fi
        done

        # Show final deployment status
        echo ""
        echo "  Final deployment status:"
        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            NGINX_STATUS=$(kubectl get pods -n "$NS" -l app=nginx-demo -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
            NGINX_LB=$(kubectl get svc nginx-demo -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
            echo "    $NS: nginx=$NGINX_STATUS"
            echo "        HTTP:  http://$NGINX_LB"
            echo "        HTTPS: https://$NGINX_LB"
        done

        mark_step_complete "deploy_apps"
    fi
    echo ""
else
    if [ "$SKIP_APPS" = "true" ]; then
        echo -e "${YELLOW}Step 4: Skipped (--skip-apps flag)${NC}"
    else
        echo -e "${YELLOW}Step 4: Skipped (Shared EKS not enabled)${NC}"
    fi
    echo ""
fi

# ============================================================================
# STEP 4b: Deploy CyPerf Reverse Proxy (cyperf-shared namespace)
# ============================================================================
# Creates an nginx reverse proxy in cyperf-shared namespace that distributes
# CyPerf traffic to all SE namespaces' nginx-demo services via an NLB.
# CyPerf Client -> NLB -> cyperf-proxy -> nginx-demo.se-XX.svc.cluster.local
# ============================================================================
if [ "$SHARED_EKS_ENABLED" = "true" ] && [ "$CYPERF_ENABLED" = "true" ]; then
    if is_step_complete "deploy_cyperf_proxy"; then
        echo -e "${GREEN}Step 4b: CyPerf proxy already deployed (skipping)${NC}"
    else
        echo -e "${YELLOW}Step 4b: Deploying CyPerf reverse proxy to cyperf-shared namespace...${NC}"
        start_timer

        # Create cyperf-shared namespace with labels
        kubectl create namespace cyperf-shared --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
        kubectl label namespace cyperf-shared purpose=cyperf-traffic --overwrite 2>/dev/null || true
        echo -e "  ${GREEN}✓ Created cyperf-shared namespace${NC}"

        # Build nginx upstream config dynamically for all SE namespaces
        UPSTREAM_SERVERS=""
        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            UPSTREAM_SERVERS="${UPSTREAM_SERVERS}        server nginx-demo.se-${i}.svc.cluster.local:80;\n"
        done

        # Deploy ConfigMap with nginx reverse proxy config
        cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: v1
kind: ConfigMap
metadata:
  name: cyperf-proxy-config
  namespace: cyperf-shared
data:
  nginx.conf: |
    worker_processes auto;
    events {
        worker_connections 4096;
    }
    http {
        upstream se_backends {
$(for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do echo "            server nginx-demo.se-${i}.svc.cluster.local:80;"; done)
        }
        server {
            listen 80;
            location / {
                proxy_pass http://se_backends;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_connect_timeout 5s;
                proxy_read_timeout 30s;
            }
            location /health {
                return 200 'healthy';
                add_header Content-Type text/plain;
            }
        }
    }
EOF
        echo -e "  ${GREEN}✓ Created nginx proxy ConfigMap${NC}"

        # Deploy the reverse proxy (runs on system nodes, not SE dedicated nodes)
        cat <<EOF | kubectl apply -f - 2>/dev/null || true
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cyperf-proxy
  namespace: cyperf-shared
  labels:
    app: cyperf-proxy
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
        image: nginx:latest
        ports:
        - containerPort: 80
        volumeMounts:
        - name: config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
          readOnly: true
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
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
      - name: config
        configMap:
          name: cyperf-proxy-config
---
apiVersion: v1
kind: Service
metadata:
  name: cyperf-proxy
  namespace: cyperf-shared
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
spec:
  selector:
    app: cyperf-proxy
  ports:
  - port: 80
    targetPort: 80
    name: http
  type: LoadBalancer
EOF
        echo -e "  ${GREEN}✓ Deployed cyperf-proxy Deployment + internal NLB Service${NC}"

        # Wait for proxy pods to be ready
        wait_for_pods_ready "cyperf-shared" "app=cyperf-proxy" 120 || true

        # Wait for NLB and display the DUT IP
        echo "  Waiting for CyPerf proxy NLB..."
        CYPERF_NLB=$(wait_for_loadbalancer "cyperf-shared" "cyperf-proxy" 180)
        if [ -n "$CYPERF_NLB" ] && [ "$CYPERF_NLB" != "0" ]; then
            echo -e "  ${GREEN}✓ CyPerf DUT target (NLB): $CYPERF_NLB${NC}"
            echo -e "  ${CYAN}  Use the NLB private IPs as the DUT in CyPerf controller.${NC}"
            echo -e "  ${CYAN}  Resolve NLB hostname to get private IPs: nslookup $CYPERF_NLB${NC}"
        fi

        elapsed=$(get_elapsed)
        mark_step_complete "deploy_cyperf_proxy" "$elapsed"
        echo -e "${GREEN}✓ CyPerf proxy deployed ($(format_duration $elapsed))${NC}"
    fi
    echo ""
fi

# ============================================================================
# STEP 5: Generate SE Kubeconfig Files
# ============================================================================
if ! should_run_step 5; then
    echo -e "${YELLOW}Step 5: Skipped (--steps flag)${NC}"
    echo ""
elif [ "$SHARED_EKS_ENABLED" = "true" ]; then
    if is_step_complete "generate_kubeconfigs"; then
        echo -e "${GREEN}Step 5: Kubeconfig files already generated (skipping)${NC}"
        echo "  Files located in: $BASE_DIR/generated/kubeconfigs/"
    else
        echo -e "${YELLOW}Step 5: Generating SE Kubeconfig Files...${NC}"

        mkdir -p "$BASE_DIR/generated/kubeconfigs"

        EKS_ENDPOINT=$(terraform output -raw shared_eks_cluster_endpoint 2>/dev/null || kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        EKS_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || echo "")

        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            KUBECONFIG_FILE="$BASE_DIR/generated/kubeconfigs/kubeconfig-$NS.yaml"

            # Wait for the ServiceAccount token to be populated
            echo "  Waiting for ServiceAccount token for $NS..."
            for attempt in $(seq 1 30); do
                SA_TOKEN=$(kubectl get secret ${NS}-user-token -n "$NS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
                if [ -n "$SA_TOKEN" ]; then
                    break
                fi
                sleep 1
            done

            if [ -z "$SA_TOKEN" ]; then
                echo -e "  ${YELLOW}Warning: Could not get ServiceAccount token for $NS, using AWS auth fallback${NC}"
                # Fallback to AWS IAM auth
                cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $EKS_CA
    server: $EKS_ENDPOINT
  name: se-lab-shared-eks
contexts:
- context:
    cluster: se-lab-shared-eks
    namespace: $NS
    user: $NS-user
  name: $NS
current-context: $NS
users:
- name: $NS-user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args:
      - eks
      - get-token
      - --region
      - $AWS_REGION
      - --cluster-name
      - se-lab-shared-eks
      - --profile
      - $AWS_PROFILE
EOF
            else
                # Use ServiceAccount token (RBAC isolated)
                cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $EKS_CA
    server: $EKS_ENDPOINT
  name: se-lab-shared-eks
contexts:
- context:
    cluster: se-lab-shared-eks
    namespace: $NS
    user: $NS-user
  name: $NS
current-context: $NS
users:
- name: $NS-user
  user:
    token: $SA_TOKEN
EOF
                echo -e "  ${GREEN}✓ Created RBAC-isolated kubeconfig for $NS${NC}"
            fi

            echo "  Created: $KUBECONFIG_FILE"

            # Also copy kubeconfig to SE's folder for convenience
            cp "$KUBECONFIG_FILE" "$BASE_DIR/generated/se-lab-$i/"
            echo "  Copied kubeconfig to $BASE_DIR/generated/se-lab-$i/"
        done

        echo -e "${GREEN}✓ Generated kubeconfig files in $BASE_DIR/generated/kubeconfigs/${NC}"

        # Copy SSH keys to each SE folder
        echo ""
        echo "  Distributing SSH keys, tagging nodes, and adding node access docs..."
        for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
            NS="se-$i"
            echo "  SE-$i:"
            copy_ssh_key_to_se_folder "$i"
            tag_se_node_for_ssm "$NS"
            update_se_guide_with_node_access "$NS"
        done

        echo -e "${GREEN}✓ Distributed SSH keys, tagged nodes, and added node access docs${NC}"
        mark_step_complete "generate_kubeconfigs"
    fi
    echo ""
else
    # Even if EKS is not enabled, still copy SSH keys to SE folders
    echo -e "${YELLOW}Step 5: Distributing SSH keys to SE folders...${NC}"
    for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
        echo "  SE-$i:"
        copy_ssh_key_to_se_folder "$i"
    done
    echo -e "${GREEN}✓ Distributed SSH keys to SE folders${NC}"
    echo ""
fi

# ============================================================================
# STEP 6: Display Access Information
# ============================================================================
if ! should_run_step 6; then
    echo -e "${YELLOW}Step 6: Skipped (--steps flag)${NC}"
    echo ""
else
    echo -e "${YELLOW}Step 6: Access Information${NC}"
echo ""

echo -e "${BLUE}=== SE Lab Access ===${NC}"
for i in $(seq -f "%02g" 1 $NUM_SE_LABS); do
    LAB="se-lab-$i"
    echo ""
    echo -e "${GREEN}--- $LAB ---${NC}"

    CLMS_IP=$(terraform output -json se_lab_outputs 2>/dev/null | jq -r ".[\"$LAB\"].clms_public_ip // empty" 2>/dev/null || echo "")
    KVO_IP=$(terraform output -json se_lab_outputs 2>/dev/null | jq -r ".[\"$LAB\"].kvo_public_ip // empty" 2>/dev/null || echo "")
    VPB_IP=$(terraform output -json se_lab_outputs 2>/dev/null | jq -r ".[\"$LAB\"].vpb_public_ip // empty" 2>/dev/null || echo "")
    UBUNTU_IP=$(terraform output -json se_lab_outputs 2>/dev/null | jq -r ".[\"$LAB\"].ubuntu_1_public_ip // empty" 2>/dev/null || echo "")
    TOOL_WIN_IP=$(terraform output -json se_lab_outputs 2>/dev/null | jq -r ".[\"$LAB\"].tool_windows_public_ip // empty" 2>/dev/null || echo "")

    if [ -n "$CLMS_IP" ]; then
        echo "  CLMS:         https://$CLMS_IP (admin / <CLMS_PASSWORD>)"
        echo "  KVO:          https://$KVO_IP (admin / admin)"
        [ -n "$VPB_IP" ] && [ "$VPB_IP" != "vPB not deployed" ] && echo "  vPB:          ssh admin@$VPB_IP (admin / <VPB_PASSWORD>)"
        [ -n "$UBUNTU_IP" ] && echo "  Ubuntu:       ssh ubuntu@$UBUNTU_IP"
        [ -n "$TOOL_WIN_IP" ] && echo "  Windows Tool: RDP $TOOL_WIN_IP (Administrator / <WINDOWS_TOOL_PASSWORD>)"
    else
        echo "  (Check ./generated/$LAB/ for access details)"
    fi
done

echo ""
echo -e "${BLUE}=== Documentation ===${NC}"
echo "  SE Guides:    ./generated/se-lab-XX/"
echo "  Kubeconfigs:  ./generated/kubeconfigs/"
echo ""

if [ "$SHARED_EKS_ENABLED" = "true" ]; then
    echo -e "${BLUE}=== Shared EKS Cluster ===${NC}"
    echo "  Cluster:      se-lab-shared-eks"
    echo "  Namespaces:   se-01 through se-$(printf '%02d' $NUM_SE_LABS)"
    echo ""
    echo "  kubectl commands:"
    echo "    kubectl get nodes"
    echo "    kubectl get pods -n se-01"
    echo "    kubectl get all -n se-01"
    echo ""
    echo "  Public ECR Repository (no auth required for pulls):"
    echo "    ${ECR_REGISTRY}/cloudlens-sensor"
    echo ""
fi

echo -e "${BLUE}=== Default Credentials ===${NC}"
echo "  CLMS:              admin / <CLMS_PASSWORD>"
echo "  KVO:               admin / admin"
echo "  vPB:               admin / <VPB_PASSWORD>"
echo "  Ubuntu VMs:        ubuntu / SSH Key"
echo "  Windows Tool VM:   Administrator / <WINDOWS_TOOL_PASSWORD>"
echo ""

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Post-deployment complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Wait 15 minutes for CLMS/KVO to initialize"
echo "  2. Access CLMS at https://<CLMS_IP>"
echo "  3. Distribute SE guides from ./generated/se-lab-XX/"
echo "  4. Each SE can use their kubeconfig: export KUBECONFIG=./generated/kubeconfigs/kubeconfig-se-XX.yaml"
echo ""
echo "To verify deployments:"
echo "  kubectl get pods -A | grep nginx"
echo ""
fi  # End of should_run_step 6

# ============================================================================
# STEP 7: Deploy CyPerf Agents and Configure Test
# ============================================================================
if ! should_run_step 7; then
    echo -e "${YELLOW}Step 7: Skipped (--steps flag)${NC}"
    echo ""
else
    echo -e "${YELLOW}Step 7: Deploy CyPerf Agents and Configure Test${NC}"
    echo ""

    if is_step_complete "deploy_cyperf_agents"; then
        echo -e "  ${GREEN}✓${NC} CyPerf agents already deployed (skipping)"
        echo ""
    else
        if [[ -f "$SCRIPT_DIR/deploy-cyperf-k8s.sh" ]]; then
            log_info "Deploying CyPerf K8s agents and configuring test..."
            bash "$SCRIPT_DIR/deploy-cyperf-k8s.sh"
            mark_step_complete "deploy_cyperf_agents"
        else
            log_warning "deploy-cyperf-k8s.sh not found — skipping CyPerf deployment"
        fi
    fi
fi  # End of should_run_step 7
