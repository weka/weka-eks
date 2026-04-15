#!/bin/bash
#
# WEKA Axon on EKS Deployment Script
#
# Prerequisites:
#   - AWS CLI configured and authenticated
#   - kubectl, helm, jq installed
#   - EKS cluster deployed via Terraform
#   - Manifests reviewed and configured
#
# Usage:
#   ./deploy.sh <cluster-name> <quay-username> <quay-password>
#   ./deploy.sh --cleanup <cluster-name>

set -e

WEKA_OPERATOR_NS="weka-operator-system"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
do_cleanup() {
    local cluster_name="$1"

    if [[ -z "$cluster_name" ]]; then
        echo "[ERROR] Cluster name required. Usage: $0 --cleanup <cluster-name>"
        exit 1
    fi

    echo "=============================================="
    echo "WEKA Axon Cleanup"
    echo "=============================================="
    echo "  Cluster: $cluster_name"
    echo ""

    aws eks update-kubeconfig --name "$cluster_name" $REGION_FLAG

    echo "Deleting test namespace..."
    kubectl delete namespace weka-axon-test --ignore-not-found=true

    echo "Deleting StorageClass..."
    kubectl delete storageclass storageclass-wekafs-dir-api --ignore-not-found=true

    echo "Deleting WekaClient..."
    kubectl delete wekaclient --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    echo "  Waiting for client pods to terminate..."
    for i in {1..60}; do
        PODS=$(kubectl get pods -n "$WEKA_OPERATOR_NS" -l weka.io/mode=client --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ "$PODS" -eq 0 ]]; then break; fi
        sleep 5
    done

    # Force-delete stuck client resources
    REMAINING=$(kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" -l weka.io/mode=client --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$REMAINING" -gt 0 ]]; then
        echo "  Force-deleting stuck client containers..."
        kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" -l weka.io/mode=client --no-headers -o name 2>/dev/null | \
            xargs -I {} kubectl patch {} -n "$WEKA_OPERATOR_NS" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete wekacontainers -l weka.io/mode=client -n "$WEKA_OPERATOR_NS" --force --grace-period=0 2>/dev/null || true
    fi

    echo "Deleting WekaCluster..."
    kubectl delete wekacluster --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    echo "  Waiting for cluster pods to terminate..."
    for i in {1..120}; do
        PODS=$(kubectl get pods -n "$WEKA_OPERATOR_NS" -l app=weka --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ "$PODS" -eq 0 ]]; then break; fi
        sleep 5
    done

    # Force-delete stuck cluster resources
    REMAINING=$(kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$REMAINING" -gt 0 ]]; then
        echo "  Force-deleting stuck containers..."
        kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" --no-headers -o name 2>/dev/null | \
            xargs -I {} kubectl patch {} -n "$WEKA_OPERATOR_NS" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete wekacontainers --all -n "$WEKA_OPERATOR_NS" --force --grace-period=0 2>/dev/null || true
    fi

    echo "Deleting WekaPolicies..."
    kubectl delete wekapolicy --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    echo "Deleting WEKA Operator..."
    helm uninstall weka-operator --namespace "$WEKA_OPERATOR_NS" 2>/dev/null || true
    kubectl delete namespace "$WEKA_OPERATOR_NS" --ignore-not-found=true

    echo ""
    echo "[OK] Cleanup complete"
    echo "To destroy infrastructure: (cd terraform && terraform destroy)"
    exit 0
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] [cluster-name] [quay-username] [quay-password]

Deploy WEKA Axon on an existing EKS cluster.

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
  AWS_REGION                AWS region (if not set in AWS CLI config)
  WEKA_OPERATOR_VERSION     Operator Helm chart version (default: v1.11.0)

Examples:
  $0 my-eks-cluster myuser mypass
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

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
CLUSTER_NAME="${1:-$CLUSTER_NAME}"
QUAY_USERNAME="${2:-$QUAY_USERNAME}"
QUAY_PASSWORD="${3:-$QUAY_PASSWORD}"

REGION_FLAG=""
if [[ -n "$AWS_REGION" ]]; then
    REGION_FLAG="--region $AWS_REGION"
fi
WEKA_OPERATOR_VERSION="${WEKA_OPERATOR_VERSION:-v1.11.0}"

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "[ERROR] Cluster name required."
    echo "Usage: $0 <cluster-name> <quay-username> <quay-password>"
    exit 1
fi

if [[ -z "$QUAY_USERNAME" || -z "$QUAY_PASSWORD" ]]; then
    echo "[ERROR] Quay.io credentials required."
    exit 1
fi

echo "=============================================="
echo "WEKA Axon on EKS Deployment"
echo "=============================================="
echo "  Cluster:  $CLUSTER_NAME"
echo "  Operator: $WEKA_OPERATOR_VERSION"
echo ""

# Step 1: Configure kubectl
echo "Step 1: Configuring kubectl..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" $REGION_FLAG
kubectl get nodes
echo "[OK] kubectl configured"

# Step 2: Install WEKA Operator (with CSI)
echo ""
echo "Step 2: Installing WEKA Operator..."
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
    --set csi.installationEnabled=true \
    -f "$MANIFESTS_DIR/core/values-weka-operator.yaml" \
    --wait

echo "[OK] WEKA Operator installed"

# Step 3: ensure-nics
echo ""
echo "Step 3: Running ensure-nics..."
kubectl apply -f "$MANIFESTS_DIR/core/ensure-nics.yaml"

for i in {1..24}; do
    STATUS=$(kubectl get wekapolicies ensure-nics-policy -n "$WEKA_OPERATOR_NS" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
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

# Step 4: sign-drives
echo ""
echo "Step 4: Signing drives..."
kubectl apply -f "$MANIFESTS_DIR/core/sign-drives.yaml"

for i in {1..36}; do
    STATUS=$(kubectl get wekapolicies sign-drives-policy -n "$WEKA_OPERATOR_NS" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Done" ]]; then
        echo "[OK] sign-drives completed"
        break
    elif [[ "$STATUS" == "Failed" ]]; then
        echo "[ERROR] sign-drives failed"
        kubectl describe wekapolicies sign-drives-policy -n "$WEKA_OPERATOR_NS"
        exit 1
    fi
    sleep 5
done

# Step 5: Deploy WekaCluster
echo ""
echo "Step 5: Deploying WekaCluster..."
kubectl apply -f "$MANIFESTS_DIR/core/weka-cluster.yaml"

# Get desired counts from the spec
DESIRED_CCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].spec.dynamicTemplate.computeContainers}' 2>/dev/null || echo "0")
DESIRED_DCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].spec.dynamicTemplate.driveContainers}' 2>/dev/null || echo "0")

echo "  Waiting for cluster formation (compute=$DESIRED_CCT, drive=$DESIRED_DCT)..."

LAST_MSG=""
for i in {1..180}; do
    CCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.printer.computeContainers}' 2>/dev/null || echo "")
    DCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.printer.driveContainers}' 2>/dev/null || echo "")

    if [[ -n "$CCT" && -n "$DCT" ]]; then
        CCT_ACTIVE=$(echo "$CCT" | cut -d/ -f1)
        DCT_ACTIVE=$(echo "$DCT" | cut -d/ -f1)

        if [[ "$CCT_ACTIVE" == "$DESIRED_CCT" && "$DCT_ACTIVE" == "$DESIRED_DCT" ]]; then
            echo "[OK] WekaCluster active (CCT=$CCT, DCT=$DCT)"
            break
        fi
        MSG="  CCT=$CCT DCT=$DCT"
        if [[ "$MSG" != "$LAST_MSG" ]]; then
            echo "$MSG"
            LAST_MSG="$MSG"
        fi
    fi
    sleep 5
done

# Step 6: Deploy WekaClient
echo ""
echo "Step 6: Deploying WekaClient..."
kubectl apply -f "$MANIFESTS_DIR/core/weka-client.yaml"

echo "  Waiting for all client containers to be active..."

LAST_MSG=""
for i in {1..120}; do
    ACTIVE=$(kubectl get wekaclient -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.printer.containers}' 2>/dev/null || echo "")
    DESIRED=$(kubectl get wekaclient -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.stats.containers.desired}' 2>/dev/null || echo "0")

    if [[ -n "$ACTIVE" && "$DESIRED" -gt 0 ]]; then
        A=$(echo "$ACTIVE" | cut -d/ -f1)
        D=$(echo "$ACTIVE" | cut -d/ -f3)
        if [[ "$A" == "$D" && "$A" -gt 0 ]]; then
            echo "[OK] All $A client containers active ($ACTIVE)"
            break
        fi
        MSG="  Containers: $ACTIVE"
        if [[ "$MSG" != "$LAST_MSG" ]]; then
            echo "$MSG"
            LAST_MSG="$MSG"
        fi
    fi
    sleep 5
done

# Step 7: Apply StorageClass
echo ""
echo "Step 7: Creating StorageClass..."
kubectl apply -f "$MANIFESTS_DIR/core/storageclass-weka.yaml"
echo "[OK] StorageClass created"

# Verification
echo ""
echo "=============================================="
echo "Deployment Verification"
echo "=============================================="
echo ""
echo "WekaCluster:"
kubectl get wekacluster -n "$WEKA_OPERATOR_NS"
echo ""
echo "WekaClient:"
kubectl get wekaclient -n "$WEKA_OPERATOR_NS"
echo ""
echo "StorageClasses:"
kubectl get storageclass | grep weka

# Step 8: Test
echo ""
echo "Step 8: Testing dynamic provisioning..."
kubectl create namespace weka-axon-test --dry-run=client -o yaml | kubectl apply -f -

# Apply PVC and writer pod first
kubectl apply -f "$MANIFESTS_DIR/test/pvc.yaml"
kubectl apply -f "$MANIFESTS_DIR/test/weka-app.yaml"

echo "  Waiting for PVC to bind..."
for i in {1..30}; do
    STATUS=$(kubectl get pvc pvc-wekafs-dir -n weka-axon-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Bound" ]]; then
        echo "[OK] PVC bound"
        break
    fi
    sleep 2
done

echo "  Waiting for writer pod..."
kubectl wait --for=condition=Ready pod/weka-axon-app -n weka-axon-test --timeout=120s 2>/dev/null || true

# Apply reader pod after writer has started
kubectl apply -f "$MANIFESTS_DIR/test/weka-app-reader.yaml"
kubectl wait --for=condition=Ready pod/weka-axon-app-reader -n weka-axon-test --timeout=60s 2>/dev/null || true

echo ""
echo "Test Results:"
kubectl get pvc -n weka-axon-test
kubectl get pods -n weka-axon-test
echo ""
echo "Writer:"
kubectl logs weka-axon-app -n weka-axon-test 2>/dev/null || echo "  (not ready yet)"
echo ""
echo "Reader:"
kubectl logs weka-axon-app-reader -n weka-axon-test 2>/dev/null || echo "  (not ready yet)"

echo ""
echo "=============================================="
echo "Deployment Complete"
echo "=============================================="
echo ""
echo "To check status:"
echo "  kubectl get wekacluster -n $WEKA_OPERATOR_NS"
echo "  kubectl get wekaclient -n $WEKA_OPERATOR_NS"
