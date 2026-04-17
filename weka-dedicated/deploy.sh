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
        echo "[ERROR] Cluster name required for cleanup (--cluster-name or CLUSTER_NAME)."
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
Usage: $0 [OPTIONS]

Deploy WEKA on an existing EKS cluster. Automatically generates
weka-client.yaml and csi-wekafs-api-secret.yaml from the WEKA
backend if --backend-name and --secret-arn are provided.

All flags can alternatively be set via environment variables.

Options:
  --cluster-name NAME       EKS cluster name (or CLUSTER_NAME)
  --quay-username USER      Quay.io username (or QUAY_USERNAME)
  --quay-password PASS      Quay.io password (or QUAY_PASSWORD)
  --backend-name NAME       WEKA backend cluster name tag (or WEKA_BACKEND_NAME)
  --secret-arn ARN          Secrets Manager ARN for WEKA password (or WEKA_SECRET_ARN)
  --region REGION           AWS region (or AWS_REGION)
  --operator-version VER    Operator Helm chart version (or WEKA_OPERATOR_VERSION, default: v1.11.0)
  -c, --cleanup             Remove all WEKA components from the cluster
  -h, --help                Show this help message

Examples:
  # Flags
  $0 --cluster-name my-eks-cluster --quay-username myuser --quay-password mypass \\
     --backend-name eks-storage-cluster \\
     --secret-arn arn:aws:secretsmanager:eu-west-1:123456:secret:weka/...

  # Environment variables
  export CLUSTER_NAME=my-eks-cluster QUAY_USERNAME=myuser QUAY_PASSWORD=mypass
  export WEKA_BACKEND_NAME=eks-storage-cluster
  export WEKA_SECRET_ARN=arn:aws:secretsmanager:...
  $0

  # Cleanup
  $0 --cleanup --cluster-name my-eks-cluster
EOF
    exit 0
}

CLEANUP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)           show_help ;;
        -c|--cleanup)        CLEANUP=true; shift ;;
        --cluster-name)      CLUSTER_NAME="$2"; shift 2 ;;
        --quay-username)     QUAY_USERNAME="$2"; shift 2 ;;
        --quay-password)     QUAY_PASSWORD="$2"; shift 2 ;;
        --backend-name)      WEKA_BACKEND_NAME="$2"; shift 2 ;;
        --secret-arn)        WEKA_SECRET_ARN="$2"; shift 2 ;;
        --region)            AWS_REGION="$2"; shift 2 ;;
        --operator-version)  WEKA_OPERATOR_VERSION="$2"; shift 2 ;;
        *)                   echo "[ERROR] Unknown option: $1"; echo "Run $0 --help for usage"; exit 1 ;;
    esac
done

WEKA_OPERATOR_VERSION="${WEKA_OPERATOR_VERSION:-v1.11.0}"

REGION_FLAG=""
if [[ -n "$AWS_REGION" ]]; then
    REGION_FLAG="--region $AWS_REGION"
fi

if [[ "$CLEANUP" == "true" ]]; then
    do_cleanup "$CLUSTER_NAME"
fi

# Validate inputs
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "[ERROR] Cluster name required (--cluster-name or CLUSTER_NAME)."
    echo "Run $0 --help for usage"
    exit 1
fi

if [[ -z "$QUAY_USERNAME" || -z "$QUAY_PASSWORD" ]]; then
    echo "[ERROR] Quay.io credentials required (--quay-username/--quay-password or QUAY_USERNAME/QUAY_PASSWORD)."
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
kubectl wait --for=condition=Ready pod/weka-writer -n weka-test --timeout=60s 2>/dev/null || true

echo ""
echo "Test Results:"
kubectl get pvc -n weka-test
kubectl get pods -n weka-test
echo ""
kubectl logs weka-writer -n weka-test 2>/dev/null || echo "  (pod not ready yet)"

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
