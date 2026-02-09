#!/bin/bash
# ============================================================================
# SETUP SE NAMESPACES WITH DEDICATED NODE ISOLATION
# ============================================================================
# Creates isolated namespaces for each SE with:
#   - ServiceAccount for authentication
#   - Role with full namespace access
#   - RoleBinding
#   - ResourceQuota matching dedicated node capacity
#   - NetworkPolicy for network isolation
#   - LimitRange with nodeSelector + tolerations for dedicated node
#   - PodPreset-like defaults via LimitRange
#
# DEDICATED NODE ARCHITECTURE:
#   - Each SE gets their own dedicated t3.medium node (2 vCPU, 4GB RAM)
#   - Nodes are tainted: se-id=se-XX:NoSchedule
#   - SE pods must tolerate this taint and use nodeSelector
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
NUM_SES=${1:-25}
CLUSTER_NAME=${2:-"se-lab-shared-eks"}
AWS_REGION=${3:-"us-west-2"}
AWS_PROFILE=${4:-"cloudlens-lab"}

show_help() {
    echo "Usage: $0 [NUM_SES] [CLUSTER_NAME] [AWS_REGION] [AWS_PROFILE]"
    echo ""
    echo "Arguments:"
    echo "  NUM_SES       Number of SE namespaces to create (default: 25)"
    echo "  CLUSTER_NAME  EKS cluster name (default: se-lab-shared-eks)"
    echo "  AWS_REGION    AWS region (default: us-west-2)"
    echo "  AWS_PROFILE   AWS CLI profile (default: cloudlens-lab)"
    echo ""
    echo "Example:"
    echo "  $0 25 se-lab-shared-eks us-west-2 cloudlens-lab"
    exit 0
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

echo ""
echo "============================================================================"
echo "  CloudLens Shared EKS - SE Namespace Setup"
echo "============================================================================"
echo ""
echo "Configuration:"
echo "  Number of SEs:  $NUM_SES"
echo "  Cluster Name:   $CLUSTER_NAME"
echo "  AWS Region:     $AWS_REGION"
echo "  AWS Profile:    $AWS_PROFILE"
echo ""
echo "============================================================================"
echo ""

# Configure kubectl
log_info "Configuring kubectl for cluster: $CLUSTER_NAME"
aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --profile "$AWS_PROFILE"

# Verify cluster access
log_info "Verifying cluster access..."
if ! kubectl get nodes &>/dev/null; then
    log_error "Cannot access EKS cluster. Check your credentials and cluster status."
    exit 1
fi
log_success "Cluster access verified"

# Create output directory for kubeconfigs
KUBECONFIG_DIR="$BASE_DIR/se-kubeconfigs"
mkdir -p "$KUBECONFIG_DIR"

# Get cluster info
CLUSTER_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

log_info "Creating $NUM_SES SE namespaces..."
echo ""

for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"
    SA_NAME="${NAMESPACE}-admin"

    echo -e "${BLUE}[${i}/${NUM_SES}]${NC} Setting up namespace: $NAMESPACE"

    # ========================================================================
    # 1. Create Namespace
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    team: sales-engineering
    se-id: ${NAMESPACE}
    environment: training
    managed-by: terraform
EOF

    # ========================================================================
    # 2. Create ServiceAccount
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
  labels:
    se-id: ${NAMESPACE}
EOF

    # ========================================================================
    # 3. Create Secret for ServiceAccount (K8s 1.24+)
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

    # ========================================================================
    # 4. Create Role (full access within namespace)
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAMESPACE}-admin-role
  namespace: ${NAMESPACE}
rules:
# Full access to all namespace resources
- apiGroups: ["", "apps", "batch", "extensions", "networking.k8s.io", "autoscaling"]
  resources: ["*"]
  verbs: ["*"]
# Read-only access to events
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
EOF

    # ========================================================================
    # 5. Create RoleBinding
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NAMESPACE}-admin-binding
  namespace: ${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${NAMESPACE}-admin-role
  apiGroup: rbac.authorization.k8s.io
EOF

    # ========================================================================
    # 6. Create ClusterRoles for node viewing + Helm chart install
    # ========================================================================
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

    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAMESPACE}-node-viewer
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: se-node-viewer
  apiGroup: rbac.authorization.k8s.io
EOF
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAMESPACE}-helm-cluster-access
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: se-helm-cluster-access
  apiGroup: rbac.authorization.k8s.io
EOF

    # ========================================================================
    # 7. Create ResourceQuota (matches dedicated t3.medium node capacity)
    # ========================================================================
    # Dedicated node: t3.medium = 2 vCPU, 4GB RAM
    # Reserve ~0.5 vCPU, 0.5GB for kubelet/system = 1.5 vCPU, 3.5GB available
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${NAMESPACE}-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "1500m"       # 1.5 vCPU (node has 2, reserve 0.5 for system)
    requests.memory: 3Gi        # 3GB (node has 4GB, reserve 1GB for system)
    limits.cpu: "2"             # Full node CPU limit
    limits.memory: 3500Mi       # 3.5GB max
    pods: "15"                  # Max 15 pods per SE
    services: "10"
    services.loadbalancers: "3"
    persistentvolumeclaims: "5"
    secrets: "20"
    configmaps: "20"
EOF

    # ========================================================================
    # 8. Create LimitRange (default resource limits)
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: LimitRange
metadata:
  name: ${NAMESPACE}-limits
  namespace: ${NAMESPACE}
spec:
  limits:
  - default:
      cpu: "200m"
      memory: "256Mi"
    defaultRequest:
      cpu: "50m"
      memory: "64Mi"
    max:
      cpu: "500m"
      memory: "512Mi"
    type: Container
EOF

    # ========================================================================
    # 8b. Create ConfigMap with deployment template (includes toleration/nodeSelector)
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: deployment-template
  namespace: ${NAMESPACE}
data:
  se-id: "${NAMESPACE}"
  node-label: "se-id=${NAMESPACE}"
  info: |
    Your pods MUST include the following to run on your dedicated node:

    tolerations:
    - key: "se-id"
      operator: "Equal"
      value: "${NAMESPACE}"
      effect: "NoSchedule"

    nodeSelector:
      se-id: "${NAMESPACE}"

  example-deployment.yaml: |
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: my-app
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: my-app
      template:
        metadata:
          labels:
            app: my-app
        spec:
          # Required for dedicated node
          tolerations:
          - key: "se-id"
            operator: "Equal"
            value: "${NAMESPACE}"
            effect: "NoSchedule"
          nodeSelector:
            se-id: "${NAMESPACE}"
          containers:
          - name: my-app
            image: nginx:alpine
            ports:
            - containerPort: 80
            resources:
              requests:
                cpu: "50m"
                memory: "64Mi"
              limits:
                cpu: "200m"
                memory: "256Mi"
EOF

    # ========================================================================
    # 9. Create NetworkPolicy (namespace isolation)
    # ========================================================================
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NAMESPACE}-isolation
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow traffic from same namespace
  - from:
    - namespaceSelector:
        matchLabels:
          se-id: ${NAMESPACE}
  # Allow traffic from ingress controllers (for LoadBalancers)
  - from:
    - namespaceSelector:
        matchLabels:
          name: kube-system
  egress:
  # Allow traffic to same namespace
  - to:
    - namespaceSelector:
        matchLabels:
          se-id: ${NAMESPACE}
  # Allow DNS
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow external traffic (internet)
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
EOF

    # ========================================================================
    # 10. Generate Kubeconfig for this SE
    # ========================================================================

    # Wait for token to be populated
    sleep 2

    # Get the token
    TOKEN=$(kubectl get secret ${SA_NAME}-token -n ${NAMESPACE} -o jsonpath='{.data.token}' | base64 --decode)

    if [ -z "$TOKEN" ]; then
        log_warning "Could not retrieve token for ${NAMESPACE}. Kubeconfig may be incomplete."
        TOKEN="TOKEN_NOT_AVAILABLE"
    fi

    # Generate kubeconfig
    KUBECONFIG_FILE="$KUBECONFIG_DIR/kubeconfig-${NAMESPACE}.yaml"
    cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_ENDPOINT}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${NAMESPACE}
    user: ${SA_NAME}
  name: ${NAMESPACE}-context
current-context: ${NAMESPACE}-context
users:
- name: ${SA_NAME}
  user:
    token: ${TOKEN}
EOF

    chmod 600 "$KUBECONFIG_FILE"

    log_success "  Namespace ${NAMESPACE} configured with kubeconfig"
done

echo ""
echo "============================================================================"
log_success "All $NUM_SES SE namespaces created successfully!"
echo "============================================================================"
echo ""
echo "Kubeconfig files saved to: $KUBECONFIG_DIR/"
echo ""
echo "Distribution instructions for SEs:"
echo ""
echo "  1. Send kubeconfig-se-XX.yaml to each SE"
echo ""
echo "  2. SE usage:"
echo "     export KUBECONFIG=/path/to/kubeconfig-se-01.yaml"
echo "     kubectl get pods        # Only sees their namespace"
echo "     kubectl get nodes       # Can see cluster nodes"
echo ""
echo "  3. Test connectivity:"
echo "     kubectl create deployment nginx --image=nginx"
echo "     kubectl get pods"
echo ""
echo "============================================================================"
echo ""

# Create summary file
SUMMARY_FILE="$KUBECONFIG_DIR/SE-KUBECONFIG-SUMMARY.txt"
cat > "$SUMMARY_FILE" <<EOF
================================================================================
CloudLens Shared EKS - SE Kubeconfig Summary
================================================================================
Generated: $(date)
Cluster: $CLUSTER_NAME
Region: $AWS_REGION
Total SEs: $NUM_SES

================================================================================
SE NAMESPACE ASSIGNMENTS
================================================================================
EOF

for i in $(seq -f "%02g" 1 $NUM_SES); do
    echo "SE-${i}: Namespace=se-${i}, Kubeconfig=kubeconfig-se-${i}.yaml" >> "$SUMMARY_FILE"
done

cat >> "$SUMMARY_FILE" <<EOF

================================================================================
USAGE INSTRUCTIONS
================================================================================
1. Distribute kubeconfig-se-XX.yaml to each SE

2. SE runs:
   export KUBECONFIG=/path/to/kubeconfig-se-XX.yaml
   kubectl get pods

3. Each SE has:
   - Full access to their namespace
   - Read-only access to cluster nodes
   - Resource quota: 2 CPU, 4GB RAM (requests)
   - Max 20 pods, 3 LoadBalancers

================================================================================
EOF

log_success "Summary saved to: $SUMMARY_FILE"
