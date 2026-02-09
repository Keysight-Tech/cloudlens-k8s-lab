#!/bin/bash

# Deploy nginx with TLS to all SE namespaces
# Usage: ./deploy-nginx-to-all-namespaces.sh [NUM_SES]

set -e

NUM_SES=${1:-15}
MANIFESTS_DIR="../kubernetes_manifests"
TLS_CERT="/Users/brinketu/CloudlensFIle/Terraform /AKS/tls.crt"
TLS_KEY="/Users/brinketu/CloudlensFIle/Terraform /AKS/tls.key"

echo "============================================================"
echo "Deploying nginx to $NUM_SES SE namespaces"
echo "============================================================"
echo ""

# Verify TLS files exist
if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  echo "ERROR: TLS certificate or key not found"
  echo "Cert: $TLS_CERT"
  echo "Key: $TLS_KEY"
  exit 1
fi

# Create TLS secret in all namespaces
echo "Step 1: Creating TLS secrets..."
for i in $(seq -f "%02g" 1 $NUM_SES); do
  NAMESPACE="se${i}"
  echo "   Creating TLS secret in $NAMESPACE..."
  kubectl create secret tls nginx-tls-secret \
    --cert="$TLS_CERT" \
    --key="$TLS_KEY" \
    -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
done
echo "   ✓ TLS secrets created in all namespaces"
echo ""

# Deploy nginx to each namespace
echo "Step 2: Deploying nginx applications..."
for i in $(seq -f "%02g" 1 $NUM_SES); do
  NAMESPACE="se${i}"
  echo "   [$i/$NUM_SES] Deploying to $NAMESPACE..."

  # Apply nginx deployment
  kubectl apply -f $MANIFESTS_DIR/nginx-simple-deployment.yaml -n $NAMESPACE

  # Wait for deployment to be ready (timeout 60s)
  kubectl wait --for=condition=available --timeout=60s \
    deployment/nginx-https -n $NAMESPACE 2>/dev/null || echo "      Warning: Deployment not ready yet"

  echo "      ✓ Nginx deployed to $NAMESPACE"
done
echo "   ✓ All deployments created"
echo ""

# Wait for all LoadBalancers to be provisioned
echo "Step 3: Waiting for LoadBalancers (this may take 2-3 minutes)..."
sleep 30

echo ""
echo "============================================================"
echo "✅ Nginx deployed to all $NUM_SES namespaces!"
echo "============================================================"
echo ""
echo "LoadBalancer URLs:"
for i in $(seq -f "%02g" 1 $NUM_SES); do
  NAMESPACE="se${i}"
  LB_URL=$(kubectl get svc nginx-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")
  echo "  se${i}: http://$LB_URL"
done
echo ""
echo "To check status: kubectl get svc -A | grep nginx-service"
echo "To test an endpoint: curl http://<loadbalancer-url>"
