#!/bin/bash
#
# WEKA on EKS Deployment Script
#
# Prerequisites:
#   - AWS CLI configured and authenticated
#   - kubectl, helm installed
#   - Manifests configured (weka-client.yaml, csi-wekafs-api-secret.yaml, etc.)
#
# Usage:
#   ./deploy.sh <cluster-name> <quay-username> <quay-password>
#   ./deploy.sh --cleanup <cluster-name>
#
# Or set environment variables:
#   export CLUSTER_NAME=my-eks-cluster
#   export QUAY_USERNAME=your-username
#   export QUAY_PASSWORD=your-password
#   ./deploy.sh

set -e

WEKA_OPERATOR_NS="weka-operator-system"
CSI_NS="csi-wekafs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"

# -----------------------------------------------------------------------------
# Cleanup function
# -----------------------------------------------------------------------------
do_cleanup() {
    local cluster_name="$1"

    if [[ -z "$cluster_name" ]]; then
        echo "[ERROR] Cluster name required for cleanup. Usage: $0 --cleanup <cluster-name>"
        exit 1
    fi

    echo "=============================================="
    echo "WEKA on EKS Cleanup"
    echo "=============================================="
    echo "  Cluster: $cluster_name"
    echo ""

    # Configure kubectl
    echo "Configuring kubectl..."
    aws eks update-kubeconfig --name "$cluster_name"

    # Delete test namespace
    echo "Deleting test namespace..."
    kubectl delete namespace weka-test --ignore-not-found=true

    # Delete CSI plugin
    echo "Deleting CSI plugin..."
    helm uninstall csi-wekafs --namespace "$CSI_NS" 2>/dev/null || true
    kubectl delete namespace "$CSI_NS" --ignore-not-found=true

    # Delete WEKA client
    echo "Deleting WEKA client..."
    kubectl delete wekaclient --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    # Wait for client pods to terminate
    echo "  Waiting for client pods to terminate..."
    for i in {1..30}; do
        PODS=$(kubectl get pods -n "$WEKA_OPERATOR_NS" -l weka.io/mode=client --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ "$PODS" -eq 0 ]]; then
            break
        fi
        sleep 5
    done

    # Delete ensure-nics policy
    echo "Deleting ensure-nics policy..."
    kubectl delete wekapolicy --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    # Delete WEKA operator
    echo "Deleting WEKA operator..."
    helm uninstall weka-operator --namespace "$WEKA_OPERATOR_NS" 2>/dev/null || true
    kubectl delete namespace "$WEKA_OPERATOR_NS" --ignore-not-found=true

    echo ""
    echo "[OK] Cleanup complete"
    echo ""
    echo "Note: EKS cluster and WEKA backend are still running."
    echo "To destroy infrastructure, use terraform destroy in terraform/eks and terraform/weka-backend"
    exit 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
if [[ "$1" == "--cleanup" || "$1" == "-c" ]]; then
    do_cleanup "$2"
fi

# Configuration
CLUSTER_NAME="${1:-$CLUSTER_NAME}"
QUAY_USERNAME="${2:-$QUAY_USERNAME}"
QUAY_PASSWORD="${3:-$QUAY_PASSWORD}"
WEKA_OPERATOR_VERSION="${WEKA_OPERATOR_VERSION:-v1.9.0}"

# Validate inputs
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "[ERROR] Cluster name required."
    echo "Usage: $0 <cluster-name> <quay-username> <quay-password>"
    echo "       $0 --cleanup <cluster-name>"
    exit 1
fi

if [[ -z "$QUAY_USERNAME" || -z "$QUAY_PASSWORD" ]]; then
    echo "[ERROR] Quay.io credentials required."
    echo "Set QUAY_USERNAME and QUAY_PASSWORD environment variables, or pass as arguments."
    exit 1
fi

echo "=============================================="
echo "WEKA on EKS Deployment"
echo "=============================================="
echo "  Cluster: $CLUSTER_NAME"
echo "  Operator: $WEKA_OPERATOR_VERSION"
echo ""

# Check for required manifest files
if [[ ! -f "$MANIFESTS_DIR/core/weka-client.yaml" ]]; then
    echo "[ERROR] manifests/core/weka-client.yaml not found"
    echo "  Copy the example file and edit with your values:"
    echo "  cp manifests/core/weka-client.yaml.example manifests/core/weka-client.yaml"
    exit 1
fi

if [[ ! -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml" ]]; then
    echo "[ERROR] manifests/core/csi-wekafs-api-secret.yaml not found"
    echo "  Copy the example file and edit with your values:"
    echo "  cp manifests/core/csi-wekafs-api-secret.yaml.example manifests/core/csi-wekafs-api-secret.yaml"
    exit 1
fi

# Step 1: Configure kubectl
echo "Step 1: Configuring kubectl..."
aws eks update-kubeconfig --name "$CLUSTER_NAME"
kubectl get nodes
echo "[OK] kubectl configured"

# Step 2: Deploy WEKA Operator
echo ""
echo "Step 2: Deploying WEKA Operator..."
kubectl create namespace "$WEKA_OPERATOR_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry weka-quay-io-secret \
    --namespace "$WEKA_OPERATOR_NS" \
    --docker-server=quay.io \
    --docker-username="$QUAY_USERNAME" \
    --docker-password="$QUAY_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install weka-operator \
    oci://quay.io/weka.io/helm/weka-operator \
    --namespace "$WEKA_OPERATOR_NS" \
    --version "$WEKA_OPERATOR_VERSION" \
    --set imagePullSecret=weka-quay-io-secret \
    --wait

echo "[OK] WEKA Operator installed"

# Step 3: Configure hugepages
echo ""
echo "Step 3: Configuring hugepages..."
kubectl apply -f "$MANIFESTS_DIR/core/hugepages-daemonset.yaml"
echo "[OK] Hugepages DaemonSet deployed"
echo "  Waiting 30s for kubelet restart..."
sleep 30

# Step 4: Deploy ensure-nics
echo ""
echo "Step 4: Running ensure-nics..."
kubectl apply -f "$MANIFESTS_DIR/core/ensure-nics.yaml"
echo "  Waiting for ensure-nics to complete..."

# Poll for completion (max 2 minutes)
for i in {1..24}; do
    STATUS=$(kubectl get wekapolicies -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.status}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Done" ]]; then
        echo "[OK] ensure-nics completed"
        break
    elif [[ "$STATUS" == "Failed" ]]; then
        echo "[ERROR] ensure-nics failed"
        kubectl describe wekapolicies -n "$WEKA_OPERATOR_NS"
        exit 1
    fi
    sleep 5
done

# Step 5: Deploy WEKA Client
echo ""
echo "Step 5: Deploying WEKA Client..."
kubectl apply -f "$MANIFESTS_DIR/core/weka-client.yaml"
echo "[OK] WekaClient deployed"
echo "  Waiting 30s for client pods to start..."
sleep 30

# Step 6: Deploy CSI Plugin
echo ""
echo "Step 6: Deploying WEKA CSI Plugin..."
kubectl create namespace "$CSI_NS" --dry-run=client -o yaml | kubectl apply -f -

# Apply API secret if it exists
if [[ -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml" ]]; then
    kubectl apply -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml"
    echo "  API secret created"
else
    echo "  [WARN] csi-wekafs-api-secret.yaml not found - CSI dynamic provisioning won't work"
fi

helm repo add csi-wekafs https://weka.github.io/csi-wekafs 2>/dev/null || true
helm repo update

helm upgrade --install csi-wekafs csi-wekafs/csi-wekafsplugin \
    --namespace "$CSI_NS" \
    -f "$MANIFESTS_DIR/core/values-csi-wekafs.yaml" \
    --wait

kubectl apply -f "$MANIFESTS_DIR/core/storageclass-weka.yaml"
echo "[OK] CSI Plugin installed"

# Verification
echo ""
echo "=============================================="
echo "Deployment Verification"
echo "=============================================="
echo ""
echo "EKS Nodes:"
kubectl get nodes
echo ""
echo "WEKA Operator Pods:"
kubectl get pods -n "$WEKA_OPERATOR_NS"
echo ""
echo "WekaClient Status:"
kubectl get wekaclient -n "$WEKA_OPERATOR_NS" 2>/dev/null || echo "  (not ready yet)"
echo ""
echo "WekaContainer Status:"
kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" 2>/dev/null || echo "  (not ready yet)"
echo ""
echo "CSI Pods:"
kubectl get pods -n "$CSI_NS"

# Step 7: Test dynamic provisioning
echo ""
echo "Step 7: Testing dynamic provisioning..."
kubectl create namespace weka-test --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$MANIFESTS_DIR/test/"

echo "  Waiting for PVC to bind..."
for i in {1..30}; do
    STATUS=$(kubectl get pvc pvc-wekafs-dir -n weka-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Bound" ]]; then
        echo "[OK] PVC bound successfully"
        break
    fi
    sleep 2
done

echo "  Waiting for test pod to run..."
kubectl wait --for=condition=Ready pod/weka-pvc-test -n weka-test --timeout=60s 2>/dev/null || true

echo ""
echo "Test Results:"
kubectl get pvc -n weka-test
kubectl get pods -n weka-test
echo ""
kubectl logs weka-pvc-test -n weka-test 2>/dev/null || echo "  (pod not ready yet)"

echo ""
echo "=============================================="
echo "Deployment Complete"
echo "=============================================="
echo ""
echo "Test namespace 'weka-test' left running for verification."
echo "To clean up: kubectl delete namespace weka-test"
echo ""
echo "To check WEKA client status:"
echo "  kubectl get wekaclient -n $WEKA_OPERATOR_NS"
echo "  kubectl get wekacontainers -n $WEKA_OPERATOR_NS"
