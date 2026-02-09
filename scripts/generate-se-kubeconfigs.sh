#!/bin/bash

# Generate kubeconfig files for each SE with namespace isolation
# Usage: ./generate-se-kubeconfigs.sh [NUM_SES]

set -e

CLUSTER_NAME="se-demo-eks-cluster"
REGION="us-west-2"
NUM_SES=${1:-15}
OUTPUT_DIR="../se-kubeconfigs"

echo "============================================================"
echo "Generating kubeconfig files for $NUM_SES SEs"
echo "============================================================"
echo ""

mkdir -p $OUTPUT_DIR

# Get cluster info
CLUSTER_ENDPOINT=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')
CA_CERT=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

echo "Cluster endpoint: $CLUSTER_ENDPOINT"
echo "Output directory: $OUTPUT_DIR"
echo ""

for i in $(seq -f "%02g" 1 $NUM_SES); do
  NAMESPACE="se${i}"
  SA_NAME="${NAMESPACE}-admin"
  KUBECONFIG_FILE="$OUTPUT_DIR/kubeconfig-${NAMESPACE}.yaml"

  echo "[$i/$NUM_SES] Generating kubeconfig for $NAMESPACE..."

  # Create a token for the service account
  TOKEN_SECRET=$(kubectl create token $SA_NAME -n $NAMESPACE --duration=8760h)

  # Generate kubeconfig
  cat > $KUBECONFIG_FILE <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA_CERT
    server: $CLUSTER_ENDPOINT
  name: $CLUSTER_NAME
contexts:
- context:
    cluster: $CLUSTER_NAME
    namespace: $NAMESPACE
    user: $SA_NAME
  name: ${NAMESPACE}-context
current-context: ${NAMESPACE}-context
users:
- name: $SA_NAME
  user:
    token: $TOKEN_SECRET
EOF

  echo "   ✓ Created: $KUBECONFIG_FILE"
done

echo ""
echo "============================================================"
echo "✅ All kubeconfig files generated!"
echo "============================================================"
echo ""
echo "Files created in: $OUTPUT_DIR"
ls -lh $OUTPUT_DIR
echo ""
echo "Distribution Instructions:"
echo ""
echo "1. Send kubeconfig-se01.yaml to SE #1, kubeconfig-se02.yaml to SE #2, etc."
echo ""
echo "2. Each SE should:"
echo "   export KUBECONFIG=/path/to/kubeconfig-seXX.yaml"
echo "   kubectl get pods    # Should only see their namespace"
echo "   kubectl get svc     # Get their LoadBalancer URL"
echo ""
echo "3. SE can test their nginx:"
echo "   LB_URL=\$(kubectl get svc nginx-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "   curl http://\$LB_URL"
echo ""
echo "Token validity: 1 year (8760 hours)"
echo "To regenerate tokens, re-run this script"
