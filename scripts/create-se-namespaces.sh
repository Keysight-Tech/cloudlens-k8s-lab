#!/bin/bash

# Create namespaces and RBAC for 15 SEs
# Usage: ./create-se-namespaces.sh [NUM_SES]

set -e

CLUSTER_NAME="se-demo-eks-cluster"
REGION="us-west-2"
NUM_SES=${1:-15}

echo "============================================================"
echo "Creating namespaces and RBAC for $NUM_SES SEs"
echo "============================================================"
echo ""

for i in $(seq -f "%02g" 1 $NUM_SES); do
  NAMESPACE="se${i}"

  echo "[$i/$NUM_SES] Creating namespace: $NAMESPACE"

  # Create namespace
  kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

  # Label namespace
  kubectl label namespace $NAMESPACE \
    team=sales-engineering \
    se-id=se${i} \
    environment=training \
    --overwrite

  # Create RBAC - ServiceAccount
  kubectl create serviceaccount ${NAMESPACE}-admin -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

  # Create RBAC - Role (full access within namespace)
  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAMESPACE}-admin-role
  namespace: $NAMESPACE
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
EOF

  # Create RBAC - RoleBinding
  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NAMESPACE}-admin-binding
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: ${NAMESPACE}-admin
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: ${NAMESPACE}-admin-role
  apiGroup: rbac.authorization.k8s.io
EOF

  # Create resource quotas to prevent runaway usage
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${NAMESPACE}-quota
  namespace: $NAMESPACE
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    limits.cpu: "2"
    limits.memory: 4Gi
    persistentvolumeclaims: "2"
    services.loadbalancers: "2"
    pods: "10"
EOF

  # Create network policy to isolate namespace traffic
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NAMESPACE}-isolation
  namespace: $NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          se-id: se${i}
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          se-id: se${i}
  - to:
    - podSelector: {}
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443
EOF

  echo "   ✓ Namespace $NAMESPACE created with RBAC and quotas"
  echo ""
done

echo ""
echo "============================================================"
echo "✅ All $NUM_SES namespaces created successfully!"
echo "============================================================"
echo ""
echo "Summary:"
kubectl get namespaces -l team=sales-engineering
echo ""
echo "Next steps:"
echo "1. Run: ./deploy-nginx-to-all-namespaces.sh"
echo "2. Run: ./generate-se-kubeconfigs.sh"
echo "3. Distribute kubeconfig files to each SE"
