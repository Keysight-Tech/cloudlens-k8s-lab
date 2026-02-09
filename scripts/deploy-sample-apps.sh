#!/bin/bash
# ============================================================================
# DEPLOY SAMPLE APPS TO ALL SE NAMESPACES (DEDICATED NODES)
# ============================================================================
# Deploys nginx to each SE namespace with:
#   - Toleration for SE-specific node taint
#   - NodeSelector for SE-specific node label
#   - Each SE gets their own LoadBalancer URL
#
# DEDICATED NODE ARCHITECTURE:
#   - Each SE has a dedicated t3.medium node (2 vCPU, 4GB RAM)
#   - Nodes are tainted: se-id=se-XX:NoSchedule
#   - Pods must include toleration and nodeSelector to schedule
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
    echo "Deploys sample nginx application to each SE namespace"
    echo ""
    exit 0
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

echo ""
echo "============================================================================"
echo "  Deploy Sample Apps to SE Namespaces"
echo "============================================================================"
echo ""

# Configure kubectl
log_info "Configuring kubectl..."
aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --profile "$AWS_PROFILE"

log_info "Deploying sample apps to $NUM_SES namespaces..."
echo ""

for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"

    echo -e "${BLUE}[${i}/${NUM_SES}]${NC} Deploying to namespace: $NAMESPACE"

    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_warning "Namespace $NAMESPACE does not exist. Skipping."
        continue
    fi

    # Deploy nginx with custom page (includes toleration and nodeSelector for dedicated node)
    cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
        <title>CloudLens Training - ${NAMESPACE}</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
            .container { background: white; padding: 30px; border-radius: 10px; max-width: 600px; margin: 0 auto; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
            h1 { color: #2c3e50; }
            .info { background: #e8f4f8; padding: 15px; border-radius: 5px; margin: 20px 0; }
            .success { color: #27ae60; }
            .node-info { background: #fff3cd; padding: 10px; border-radius: 5px; margin-top: 15px; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>CloudLens Training Lab</h1>
            <h2 class="success">Namespace: ${NAMESPACE}</h2>
            <div class="info">
                <p><strong>SE ID:</strong> ${NAMESPACE}</p>
                <p><strong>Pod:</strong> nginx-${NAMESPACE}</p>
                <p><strong>Cluster:</strong> Shared EKS</p>
            </div>
            <div class="node-info">
                <p><strong>Dedicated Node:</strong> Your pods run on your own dedicated node!</p>
                <p><strong>Node Label:</strong> se-id=${NAMESPACE}</p>
            </div>
            <p>This nginx instance is running on your dedicated node.</p>
            <p>Traffic is being monitored by CloudLens sensors.</p>
        </div>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-${NAMESPACE}
  labels:
    app: nginx
    se-id: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
      se-id: ${NAMESPACE}
  template:
    metadata:
      labels:
        app: nginx
        se-id: ${NAMESPACE}
    spec:
      # REQUIRED: Toleration for dedicated node taint
      tolerations:
      - key: "se-id"
        operator: "Equal"
        value: "${NAMESPACE}"
        effect: "NoSchedule"
      # REQUIRED: NodeSelector for dedicated node
      nodeSelector:
        se-id: "${NAMESPACE}"
      containers:
      - name: nginx
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
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: nginx-config
          items:
          - key: index.html
            path: index.html
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  labels:
    app: nginx
    se-id: ${NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: nginx
    se-id: ${NAMESPACE}
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
EOF

    log_success "  Deployed nginx to $NAMESPACE"
done

echo ""
log_info "Waiting for LoadBalancers to provision (this may take 2-3 minutes)..."
sleep 10

echo ""
echo "============================================================================"
echo "  LoadBalancer URLs"
echo "============================================================================"
echo ""

# Create URLs file
URLS_FILE="$BASE_DIR/se-kubeconfigs/SE-LOADBALANCER-URLS.txt"
echo "# SE LoadBalancer URLs - Generated: $(date)" > "$URLS_FILE"
echo "" >> "$URLS_FILE"

for i in $(seq -f "%02g" 1 $NUM_SES); do
    NAMESPACE="se-${i}"

    LB_URL=$(kubectl get svc nginx-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

    if [ -n "$LB_URL" ] && [ "$LB_URL" != "pending" ]; then
        echo -e "${GREEN}${NAMESPACE}:${NC} http://${LB_URL}"
        echo "${NAMESPACE}: http://${LB_URL}" >> "$URLS_FILE"
    else
        echo -e "${YELLOW}${NAMESPACE}:${NC} LoadBalancer pending..."
        echo "${NAMESPACE}: PENDING" >> "$URLS_FILE"
    fi
done

echo ""
echo "============================================================================"
log_success "Sample apps deployed to all namespaces!"
echo ""
echo "LoadBalancer URLs saved to: $URLS_FILE"
echo ""
echo "To check LoadBalancer status:"
echo "  kubectl get svc -A | grep nginx-service"
echo ""
echo "============================================================================"
