#!/bin/bash
#
# WEKA on EKS Deployment Script
#
# Prerequisites:
#   - AWS CLI configured and authenticated
#   - kubectl, helm, jq installed
#   - EKS cluster and WEKA backend already deployed via Terraform
#
# Usage:
#   ./deploy.sh <cluster-name> <quay-username> <quay-password>
#   ./deploy.sh --cleanup <cluster-name>
#
# Or set environment variables:
#   export CLUSTER_NAME=my-eks-cluster
#   export QUAY_USERNAME=your-username
#   export QUAY_PASSWORD=your-password
#   export WEKA_BACKEND_NAME=eks-storage-cluster
#   export WEKA_SECRET_ARN=arn:aws:secretsmanager:...
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
    aws eks update-kubeconfig --name "$cluster_name" $REGION_FLAG

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
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] [cluster-name] [quay-username] [quay-password]

Deploy WEKA on an existing EKS cluster. Automatically generates
weka-client.yaml and csi-wekafs-api-secret.yaml from the WEKA
backend if WEKA_BACKEND_NAME and WEKA_SECRET_ARN are set.

Arguments:
  cluster-name      EKS cluster name (or set CLUSTER_NAME)
  quay-username     Quay.io username (or set QUAY_USERNAME)
  quay-password     Quay.io password (or set QUAY_PASSWORD)

Options:
  -h, --help        Show this help message
  -c, --cleanup     Remove all WEKA components from the cluster

Environment variables:
  CLUSTER_NAME              EKS cluster name
  QUAY_USERNAME             Quay.io username
  QUAY_PASSWORD             Quay.io password
  WEKA_BACKEND_NAME         WEKA backend cluster name tag (for auto-generating manifests)
  WEKA_SECRET_ARN           Secrets Manager ARN for WEKA password
  AWS_REGION                AWS region (for backend queries)
  WEKA_OPERATOR_VERSION     Operator Helm chart version (default: v1.11.0)

Examples:
  # Generate manifests automatically and deploy
  WEKA_BACKEND_NAME=eks-storage-cluster \\
  WEKA_SECRET_ARN=arn:aws:secretsmanager:eu-west-1:123456:secret:weka/... \\
  $0 my-eks-cluster myuser mypass

  # Deploy with pre-configured manifests
  $0 my-eks-cluster myuser mypass

  # Cleanup
  $0 --cleanup my-eks-cluster
EOF
    exit 0
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

if [[ "$1" == "--cleanup" || "$1" == "-c" ]]; then
    do_cleanup "$2"
fi

# Configuration
CLUSTER_NAME="${1:-$CLUSTER_NAME}"
QUAY_USERNAME="${2:-$QUAY_USERNAME}"
QUAY_PASSWORD="${3:-$QUAY_PASSWORD}"
WEKA_OPERATOR_VERSION="${WEKA_OPERATOR_VERSION:-v1.11.0}"

REGION_FLAG=""
if [[ -n "$AWS_REGION" ]]; then
    REGION_FLAG="--region $AWS_REGION"
fi

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

# Generate manifests if backend info is provided and files don't exist
if [[ -n "$WEKA_BACKEND_NAME" && -n "$WEKA_SECRET_ARN" ]]; then
    if [[ ! -f "$MANIFESTS_DIR/core/weka-client.yaml" || ! -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml" ]]; then
        echo "Generating manifests from WEKA backend..."
        "$SCRIPT_DIR/generate-manifests.sh" \
            --backend-name "$WEKA_BACKEND_NAME" \
            --secret-arn "$WEKA_SECRET_ARN"
        echo ""
    else
        echo "Manifests already exist, skipping generation."
        echo "  Delete them to regenerate from backend: rm manifests/core/weka-client.yaml manifests/core/csi-wekafs-api-secret.yaml"
        echo ""
    fi
fi

# Check for required manifest files
if [[ ! -f "$MANIFESTS_DIR/core/weka-client.yaml" ]]; then
    echo "[ERROR] manifests/core/weka-client.yaml not found"
    echo "  Either set WEKA_BACKEND_NAME + WEKA_SECRET_ARN to generate automatically,"
    echo "  or copy and edit the example: cp manifests/core/weka-client.yaml.example manifests/core/weka-client.yaml"
    exit 1
fi

if [[ ! -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml" ]]; then
    echo "[ERROR] manifests/core/csi-wekafs-api-secret.yaml not found"
    echo "  Either set WEKA_BACKEND_NAME + WEKA_SECRET_ARN to generate automatically,"
    echo "  or copy and edit the example: cp manifests/core/csi-wekafs-api-secret.yaml.example manifests/core/csi-wekafs-api-secret.yaml"
    exit 1
fi

# Step 1: Configure kubectl
echo "Step 1: Configuring kubectl..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" $REGION_FLAG
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
    -f "$MANIFESTS_DIR/core/values-weka-operator.yaml" \
    --wait

echo "[OK] WEKA Operator installed"

# Step 3: Deploy ensure-nics
# Note: Hugepages are configured at node boot via the launch template user data.
echo ""
echo "Step 3: Running ensure-nics..."
kubectl apply -f "$MANIFESTS_DIR/core/ensure-nics.yaml"
echo "  Waiting for ensure-nics to complete..."

# Wait for initial completion
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

# Step 4: Deploy WEKA Client
echo ""
echo "Step 4: Deploying WEKA Client..."
kubectl apply -f "$MANIFESTS_DIR/core/weka-client.yaml"
echo "  Waiting for all client containers to be active..."

# Get desired container count from the WekaClient spec
DESIRED=$(kubectl get wekaclient weka-client -n "$WEKA_OPERATOR_NS" \
    -o jsonpath='{.status.stats.containers.desired}' 2>/dev/null || echo "0")

# Wait for all containers to reach Running (up to 10 minutes)
for i in {1..120}; do
    ACTIVE=$(kubectl get wekaclient weka-client -n "$WEKA_OPERATOR_NS" \
        -o jsonpath='{.status.printer.containers}' 2>/dev/null || echo "")
    DESIRED=$(kubectl get wekaclient weka-client -n "$WEKA_OPERATOR_NS" \
        -o jsonpath='{.status.stats.containers.desired}' 2>/dev/null || echo "0")

    if [[ -n "$ACTIVE" && "$DESIRED" -gt 0 ]]; then
        # ACTIVE format is "A/C/D" (active/created/desired)
        A=$(echo "$ACTIVE" | cut -d/ -f1)
        D=$(echo "$ACTIVE" | cut -d/ -f3)
        if [[ "$A" == "$D" && "$A" -gt 0 ]]; then
            echo "[OK] All $A client containers active ($ACTIVE)"
            break
        fi
        echo "  Containers: $ACTIVE (waiting for $D active)..."
    else
        echo "  Waiting for client containers to be created..."
    fi
    sleep 5
done

# Step 5: Deploy CSI Plugin
echo ""
echo "Step 5: Deploying WEKA CSI Plugin..."
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

# Step 6: Test dynamic provisioning
echo ""
echo "Step 6: Testing dynamic provisioning..."
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
