#!/bin/bash
#
# WEKA Axon on EKS Deployment Script
#
# Prerequisites:
#   - AWS CLI configured and authenticated
#   - kubectl, helm, jq installed
#   - EKS cluster already deployed via Terraform
#
# Usage:
#   ./deploy.sh --cluster-name <name> --quay-username <user> --quay-password <pass>
#   ./deploy.sh --cleanup --cluster-name <name>

set -e

WEKA_OPERATOR_NS="weka-operator-system"
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
    echo "WEKA Axon on EKS Cleanup"
    echo "=============================================="
    echo "  Cluster: $cluster_name"
    echo ""

    # Configure kubectl
    echo "Configuring kubectl..."
    aws eks update-kubeconfig --name "$cluster_name" $REGION_FLAG

    # Delete test namespace
    echo "Deleting test namespace..."
    kubectl delete namespace weka-axon-test --ignore-not-found=true

    # Delete StorageClass
    echo "Deleting StorageClass..."
    kubectl delete storageclass storageclass-wekafs-dir-api --ignore-not-found=true

    # Delete WekaClient
    echo "Deleting WekaClient..."
    kubectl delete wekaclient --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    # Wait for client pods to terminate
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

    # Delete WekaCluster
    echo "Deleting WekaCluster..."
    kubectl delete wekacluster --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    # Wait for cluster pods to terminate
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

    # Delete WekaPolicies (ensure-nics, sign-drives)
    echo "Deleting WekaPolicies..."
    kubectl delete wekapolicy --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    # Delete WEKA operator
    echo "Deleting WEKA operator..."
    helm uninstall weka-operator --namespace "$WEKA_OPERATOR_NS" 2>/dev/null || true
    kubectl delete namespace "$WEKA_OPERATOR_NS" --ignore-not-found=true

    echo ""
    echo "[OK] Cleanup complete"
    echo ""
    echo "Note: EKS cluster is still running."
    echo "To destroy infrastructure: (cd terraform/eks && terraform destroy)"
    exit 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy WEKA Axon on an existing EKS cluster.

All flags can alternatively be set via environment variables.

Options:
  --cluster-name NAME       EKS cluster name (or CLUSTER_NAME)
  --quay-username USER      Quay.io username (or QUAY_USERNAME)
  --quay-password PASS      Quay.io password (or QUAY_PASSWORD)
  --region REGION           AWS region (or AWS_REGION)
  --operator-version VER    Operator Helm chart version (or WEKA_OPERATOR_VERSION, default: v1.11.0)
  -c, --cleanup             Remove all WEKA components from the cluster
  -h, --help                Show this help message

Examples:
  # Flags
  $0 --cluster-name my-eks-cluster --quay-username myuser --quay-password mypass

  # Environment variables
  export CLUSTER_NAME=my-eks-cluster QUAY_USERNAME=myuser QUAY_PASSWORD=mypass
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
kubectl apply -f "$MANIFESTS_DIR/test/weka-axon-writer.yaml"

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
kubectl wait --for=condition=Ready pod/weka-axon-writer -n weka-axon-test --timeout=120s 2>/dev/null || true

# Apply reader pod after writer has started
kubectl apply -f "$MANIFESTS_DIR/test/weka-axon-reader.yaml"
kubectl wait --for=condition=Ready pod/weka-axon-reader -n weka-axon-test --timeout=60s 2>/dev/null || true

echo ""
echo "Test Results:"
kubectl get pvc -n weka-axon-test
kubectl get pods -n weka-axon-test
echo ""
echo "Writer:"
kubectl logs weka-axon-writer -n weka-axon-test 2>/dev/null || echo "  (not ready yet)"
echo ""
echo "Reader:"
kubectl logs weka-axon-reader -n weka-axon-test 2>/dev/null || echo "  (not ready yet)"

echo ""
echo "=============================================="
echo "Deployment Complete"
echo "=============================================="
echo ""
echo "Test namespace 'weka-axon-test' left running for verification."
echo "To clean up: kubectl delete namespace weka-axon-test"
echo ""
echo "To check status:"
echo "  kubectl get wekacluster -n $WEKA_OPERATOR_NS"
echo "  kubectl get wekaclient -n $WEKA_OPERATOR_NS"
