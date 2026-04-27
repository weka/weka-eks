#!/bin/bash
#
# WEKA on EKS deployment orchestrator. Supports three deployment models:
#
#   - weka-axon            converged: WekaCluster + WekaClient, CSI embedded in operator
#   - weka-dedicated       external backend, WekaClient, standalone CSI plugin
#   - hyperpod-dedicated   HyperPod-managed clients, external backend, standalone CSI plugin
#
# Typically invoked via the per-module `deploy.sh` shim which supplies
# `--module`. Can also be run directly.
#
# Prerequisites:
#   - AWS CLI configured and authenticated
#   - kubectl, helm, jq installed
#   - EKS cluster (and for hyperpod: HyperPod cluster joined, plus
#     hyperpod-dependencies Helm chart installed in kube-system)
#   - WEKA backend cluster (for dedicated / hyperpod modules)

set -euo pipefail

WEKA_OPERATOR_NS="weka-operator-system"
CSI_NS="csi-wekafs"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Initialize all variables that may be set by argparse or env
MODULE=""
CLUSTER_NAME="${CLUSTER_NAME:-}"
QUAY_USERNAME="${QUAY_USERNAME:-}"
QUAY_PASSWORD="${QUAY_PASSWORD:-}"
WEKA_BACKEND_NAME="${WEKA_BACKEND_NAME:-}"
WEKA_SECRET_ARN="${WEKA_SECRET_ARN:-}"
AWS_REGION="${AWS_REGION:-}"
WEKA_OPERATOR_VERSION="${WEKA_OPERATOR_VERSION:-}"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: $0 --module <name> [OPTIONS]

Deploy WEKA on an existing EKS cluster.

Required:
  --module NAME             Module: weka-axon | weka-dedicated | hyperpod-dedicated

Core options:
  --cluster-name NAME       EKS cluster name (or CLUSTER_NAME)
  --quay-username USER      Quay.io username (or QUAY_USERNAME)
  --quay-password PASS      Quay.io password (or QUAY_PASSWORD)
  --region REGION           AWS region (or AWS_REGION)
  --operator-version VER    Operator Helm chart version (or WEKA_OPERATOR_VERSION, default: v1.11.0)

External-backend options (weka-dedicated, hyperpod-dedicated):
  --backend-name NAME       WEKA backend cluster name tag (or WEKA_BACKEND_NAME)
  --secret-arn ARN          Secrets Manager ARN for WEKA password (or WEKA_SECRET_ARN)
  --cores NUM               WEKA client cores (passes through to generate-manifests.sh)
  --hugepages NUM           WEKA client hugepages in MiB (passes through to generate-manifests.sh)
  --udp                     UDP mode WekaClient (required on single-ENI instance
                            types, e.g. ml.c5.*, ml.m6i.*). On hyperpod modules
                            also skips NIC annotator deployment since there are
                            no extra ENIs to annotate. Default is DPDK.

Other:
  -c, --cleanup             Remove all WEKA components from the cluster
  -h, --help                Show this help message

Examples:
  # weka-axon (via module shim)
  cd weka-axon && ./deploy.sh --cluster-name my-cluster --quay-username ... --quay-password ...

  # weka-dedicated (via module shim)
  cd weka-dedicated && ./deploy.sh --cluster-name my-cluster --quay-username ... --quay-password ... \\
     --backend-name dedicated-storage --secret-arn arn:aws:secretsmanager:...

  # hyperpod-dedicated on a small single-ENI test instance
  cd hyperpod-dedicated && ./deploy.sh --cluster-name my-cluster --quay-username ... --quay-password ... \\
     --backend-name hyperpod-storage --secret-arn arn:aws:secretsmanager:... \\
     --udp --cores 2 --hugepages 3072

  # Direct invocation (equivalent to shim)
  $0 --module hyperpod-dedicated --cluster-name ... [...]

  # Cleanup
  cd hyperpod-dedicated && ./deploy.sh --cleanup --cluster-name my-cluster
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
CLEANUP=false
UDP_MODE=false
WEKA_CORES_NUM=""
WEKA_HUGEPAGES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)           show_help ;;
        -c|--cleanup)        CLEANUP=true; shift ;;
        --module)            MODULE="$2"; shift 2 ;;
        --cluster-name)      CLUSTER_NAME="$2"; shift 2 ;;
        --quay-username)     QUAY_USERNAME="$2"; shift 2 ;;
        --quay-password)     QUAY_PASSWORD="$2"; shift 2 ;;
        --backend-name)      WEKA_BACKEND_NAME="$2"; shift 2 ;;
        --secret-arn)        WEKA_SECRET_ARN="$2"; shift 2 ;;
        --region)            AWS_REGION="$2"; shift 2 ;;
        --operator-version)  WEKA_OPERATOR_VERSION="$2"; shift 2 ;;
        --udp)               UDP_MODE=true; shift ;;
        --cores)             WEKA_CORES_NUM="$2"; shift 2 ;;
        --hugepages)         WEKA_HUGEPAGES="$2"; shift 2 ;;
        *)                   echo "[ERROR] Unknown option: $1"; echo "Run $0 --help for usage"; exit 1 ;;
    esac
done

WEKA_OPERATOR_VERSION="${WEKA_OPERATOR_VERSION:-v1.11.0}"

REGION_FLAG=()
[[ -n "$AWS_REGION" ]] && REGION_FLAG=(--region "$AWS_REGION")

# -----------------------------------------------------------------------------
# Per-module feature flags — control which steps run for each deployment model
# -----------------------------------------------------------------------------
if [[ -z "$MODULE" ]]; then
    echo "[ERROR] --module is required (weka-axon | weka-dedicated | hyperpod-dedicated)"
    exit 1
fi

MODULE_DIR="$REPO_ROOT/$MODULE"
MANIFESTS_DIR="$MODULE_DIR/manifests"

if [[ ! -d "$MODULE_DIR" ]]; then
    echo "[ERROR] Module directory not found: $MODULE_DIR"
    exit 1
fi

case "$MODULE" in
    weka-axon)
        MODULE_NAME="WEKA Axon on EKS"
        TEST_NS="weka-test"
        TEST_WRITER="weka-writer"
        TEST_READER="weka-reader"
        NEEDS_HYPERPOD_PREFLIGHT=false
        NEEDS_MANIFEST_GENERATION=false
        NEEDS_ENSURE_NICS=true
        NEEDS_SIGN_DRIVES=true
        NEEDS_HYPERPOD_LABEL_VERIFY=false
        NEEDS_NIC_ANNOTATOR=false
        DEPLOYS_WEKACLUSTER=true
        USES_EMBEDDED_CSI=true
        DEPLOYS_STANDALONE_CSI=false
        ;;
    weka-dedicated)
        MODULE_NAME="WEKA Dedicated on EKS"
        TEST_NS="weka-test"
        TEST_WRITER="weka-writer"
        TEST_READER="weka-reader"
        NEEDS_HYPERPOD_PREFLIGHT=false
        NEEDS_MANIFEST_GENERATION=true
        NEEDS_ENSURE_NICS=true
        NEEDS_SIGN_DRIVES=false
        NEEDS_HYPERPOD_LABEL_VERIFY=false
        NEEDS_NIC_ANNOTATOR=false
        DEPLOYS_WEKACLUSTER=false
        USES_EMBEDDED_CSI=false
        DEPLOYS_STANDALONE_CSI=true
        ;;
    hyperpod-dedicated)
        MODULE_NAME="WEKA Dedicated on EKS with SageMaker HyperPod"
        TEST_NS="weka-test"
        TEST_WRITER="weka-writer"
        TEST_READER="weka-reader"
        NEEDS_HYPERPOD_PREFLIGHT=true
        NEEDS_MANIFEST_GENERATION=true
        NEEDS_ENSURE_NICS=false
        NEEDS_SIGN_DRIVES=false
        NEEDS_HYPERPOD_LABEL_VERIFY=true
        NEEDS_NIC_ANNOTATOR=true
        DEPLOYS_WEKACLUSTER=false
        USES_EMBEDDED_CSI=false
        DEPLOYS_STANDALONE_CSI=true
        ;;
    *)
        echo "[ERROR] Unknown module: $MODULE"
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Poll a kubectl jsonpath until it equals an expected value (or a failed value).
# Emits [OK] / [ERROR] to stdout. Returns 0 on success, 1 on timeout, 2 on
# explicit failure. Use to centralize "wait for resource to reach state X"
# patterns and avoid silent timeout fall-through.
#   $1: human-readable description (used in messages)
#   $2: kubectl resource arg(s), e.g. "wekapolicies ensure-nics-policy"
#   $3: namespace ("" for cluster-scoped)
#   $4: jsonpath
#   $5: expected value (success)
#   $6: failed value ("" to skip failed-state detection)
#   $7: max iterations
#   $8: sleep seconds between iterations
wait_for_status() {
    local desc="$1" resource="$2" ns="$3" jsonpath="$4" expected="$5" failed="$6" max="$7" sleep_s="$8"
    local ns_flag=()
    [[ -n "$ns" ]] && ns_flag=(-n "$ns")

    local current=""
    for ((i = 1; i <= max; i++)); do
        # shellcheck disable=SC2086 # $resource may be multi-word
        current=$(kubectl get "${ns_flag[@]}" $resource -o jsonpath="$jsonpath" 2>/dev/null || echo "")
        if [[ "$current" == "$expected" ]]; then
            echo "[OK] $desc"
            return 0
        elif [[ -n "$failed" && "$current" == "$failed" ]]; then
            echo "[ERROR] $desc reached failed state: $current"
            return 2
        fi
        sleep "$sleep_s"
    done
    echo "[ERROR] $desc timed out after $((max * sleep_s))s (last status: '${current:-<empty>}')"
    return 1
}

# -----------------------------------------------------------------------------
# Cleanup (module-aware)
# -----------------------------------------------------------------------------
do_cleanup() {
    local cluster_name="$1"

    if [[ -z "$cluster_name" ]]; then
        echo "[ERROR] Cluster name required for cleanup (--cluster-name or CLUSTER_NAME)."
        exit 1
    fi

    echo "=============================================="
    echo "$MODULE_NAME Cleanup"
    echo "=============================================="
    echo "  Cluster: $cluster_name"
    echo ""

    # Configure kubectl
    echo "Configuring kubectl..."
    aws eks update-kubeconfig --name "$cluster_name" "${REGION_FLAG[@]}"

    # Delete test namespace
    echo "Deleting test namespace ($TEST_NS)..."
    kubectl delete namespace "$TEST_NS" --ignore-not-found=true

    # Delete standalone StorageClass (all modules use the same name)
    echo "Deleting StorageClass..."
    kubectl delete storageclass storageclass-wekafs-dir-api --ignore-not-found=true

    # Delete standalone CSI plugin (dedicated / hyperpod)
    if [[ "$DEPLOYS_STANDALONE_CSI" == "true" ]]; then
        echo "Deleting CSI plugin..."
        helm uninstall csi-wekafs --namespace "$CSI_NS" 2>/dev/null || true
        kubectl delete namespace "$CSI_NS" --ignore-not-found=true
    fi

    # Delete WekaClient
    echo "Deleting WekaClient..."
    kubectl delete wekaclient --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

    echo "  Waiting for client pods to terminate..."
    local cleared=false
    for i in {1..60}; do
        PODS=$(kubectl get pods -n "$WEKA_OPERATOR_NS" -l weka.io/mode=client --no-headers 2>/dev/null | wc -l)
        if [[ "$PODS" -eq 0 ]]; then cleared=true; break; fi
        sleep 5
    done
    [[ "$cleared" == "false" ]] && echo "[WARN] client pods still terminating after 5min — force delete will follow"

    # Force-delete stuck client resources
    REMAINING=$(kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" -l weka.io/mode=client --no-headers 2>/dev/null | wc -l)
    if [[ "$REMAINING" -gt 0 ]]; then
        echo "  Force-deleting stuck client containers..."
        kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" -l weka.io/mode=client --no-headers -o name 2>/dev/null | \
            xargs -I {} kubectl patch {} -n "$WEKA_OPERATOR_NS" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete wekacontainers -l weka.io/mode=client -n "$WEKA_OPERATOR_NS" --force --grace-period=0 2>/dev/null || true
    fi

    # Delete WekaCluster (axon modules)
    if [[ "$DEPLOYS_WEKACLUSTER" == "true" ]]; then
        echo "Deleting WekaCluster..."
        kubectl delete wekacluster --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true

        echo "  Waiting for cluster pods to terminate..."
        local cluster_cleared=false
        for i in {1..120}; do
            PODS=$(kubectl get pods -n "$WEKA_OPERATOR_NS" -l app=weka --no-headers 2>/dev/null | wc -l)
            if [[ "$PODS" -eq 0 ]]; then cluster_cleared=true; break; fi
            sleep 5
        done
        [[ "$cluster_cleared" == "false" ]] && echo "[WARN] cluster pods still terminating after 10min — force delete will follow"

        REMAINING=$(kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" --no-headers 2>/dev/null | wc -l)
        if [[ "$REMAINING" -gt 0 ]]; then
            echo "  Force-deleting stuck containers..."
            kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" --no-headers -o name 2>/dev/null | \
                xargs -I {} kubectl patch {} -n "$WEKA_OPERATOR_NS" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete wekacontainers --all -n "$WEKA_OPERATOR_NS" --force --grace-period=0 2>/dev/null || true
        fi
    fi

    # Delete WekaPolicies (when ensure-nics or sign-drives was applied)
    if [[ "$NEEDS_ENSURE_NICS" == "true" || "$NEEDS_SIGN_DRIVES" == "true" ]]; then
        echo "Deleting WekaPolicies..."
        kubectl delete wekapolicy --all -n "$WEKA_OPERATOR_NS" 2>/dev/null || true
    fi

    # Delete NIC annotator (hyperpod modules)
    if [[ "$NEEDS_NIC_ANNOTATOR" == "true" ]]; then
        echo "Deleting NIC annotator..."
        kubectl delete -f "$MANIFESTS_DIR/core/nic-annotator-daemonset.yaml" --ignore-not-found=true 2>/dev/null || true
        kubectl delete -f "$MANIFESTS_DIR/core/nic-annotator-rbac.yaml" --ignore-not-found=true 2>/dev/null || true
    fi

    # Delete WEKA operator
    echo "Deleting WEKA operator..."
    helm uninstall weka-operator --namespace "$WEKA_OPERATOR_NS" 2>/dev/null || true
    kubectl delete namespace "$WEKA_OPERATOR_NS" --ignore-not-found=true

    echo ""
    echo "[OK] Cleanup complete"
    echo ""
    echo "Note: EKS cluster and any external infrastructure are still running."
    echo "To destroy, run 'terraform destroy' in the module's terraform/ subdirectories."
    exit 0
}

if [[ "$CLEANUP" == "true" ]]; then
    do_cleanup "$CLUSTER_NAME"
fi

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "[ERROR] Cluster name required (--cluster-name or CLUSTER_NAME)."
    exit 1
fi

if [[ -z "$QUAY_USERNAME" || -z "$QUAY_PASSWORD" ]]; then
    echo "[ERROR] Quay.io credentials required (--quay-username/--quay-password or QUAY_USERNAME/QUAY_PASSWORD)."
    exit 1
fi

echo "=============================================="
echo "$MODULE_NAME Deployment"
echo "=============================================="
echo "  Cluster:  $CLUSTER_NAME"
echo "  Operator: $WEKA_OPERATOR_VERSION"
[[ "$UDP_MODE" == "true" ]] && echo "  Mode:     UDP"
echo ""

# -----------------------------------------------------------------------------
# Manifest generation (dedicated / hyperpod, if backend info supplied)
# -----------------------------------------------------------------------------
if [[ "$NEEDS_MANIFEST_GENERATION" == "true" ]] && [[ -n "$WEKA_BACKEND_NAME" && -n "$WEKA_SECRET_ARN" ]]; then
    if [[ ! -f "$MANIFESTS_DIR/core/weka-client.yaml" || ! -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml" ]]; then
        echo "Generating manifests from WEKA backend..."
        GEN_FLAGS=(--module "$MODULE" --backend-name "$WEKA_BACKEND_NAME" --secret-arn "$WEKA_SECRET_ARN")
        [[ "$UDP_MODE" == "true" ]] && GEN_FLAGS+=(--udp)
        [[ -n "$WEKA_CORES_NUM" ]] && GEN_FLAGS+=(--cores "$WEKA_CORES_NUM")
        [[ -n "$WEKA_HUGEPAGES" ]] && GEN_FLAGS+=(--hugepages "$WEKA_HUGEPAGES")
        [[ -n "$AWS_REGION" ]] && GEN_FLAGS+=(--region "$AWS_REGION")
        "$SCRIPT_DIR/generate-manifests.sh" "${GEN_FLAGS[@]}"
        echo ""
    else
        echo "Manifests already exist, skipping generation."
        echo "  Delete them to regenerate from backend:"
        echo "    rm $MODULE/manifests/core/weka-client.yaml $MODULE/manifests/core/csi-wekafs-api-secret.yaml"
        echo ""
    fi
fi

# Verify required manifest files exist (dedicated / hyperpod)
if [[ "$NEEDS_MANIFEST_GENERATION" == "true" ]]; then
    for f in weka-client.yaml csi-wekafs-api-secret.yaml; do
        if [[ ! -f "$MANIFESTS_DIR/core/$f" ]]; then
            echo "[ERROR] $MODULE/manifests/core/$f not found"
            echo "  Either set WEKA_BACKEND_NAME + WEKA_SECRET_ARN to generate automatically,"
            echo "  or copy and edit the example: cp manifests/core/$f.example manifests/core/$f"
            exit 1
        fi
    done
fi

# -----------------------------------------------------------------------------
# Configure kubectl
# -----------------------------------------------------------------------------
echo "Configuring kubectl..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" "${REGION_FLAG[@]}"
kubectl get nodes
echo "[OK] kubectl configured"

# -----------------------------------------------------------------------------
# Preflight: hyperpod-dependencies Helm chart (hyperpod modules)
# -----------------------------------------------------------------------------
if [[ "$NEEDS_HYPERPOD_PREFLIGHT" == "true" ]]; then
    echo ""
    echo "Preflight: verifying hyperpod-dependencies Helm chart..."
    if ! helm list -n kube-system 2>/dev/null | grep -q '^hyperpod-dependencies[[:space:]]'; then
        echo "[ERROR] hyperpod-dependencies Helm chart not installed in kube-system."
        echo "        HyperPod cluster functionality and resiliency features depend on it."
        echo "        See README §3.1 for installation instructions."
        echo ""
        echo "        Quick install:"
        echo "          git clone https://github.com/aws/sagemaker-hyperpod-cli.git /tmp/sagemaker-hyperpod-cli"
        echo "          helm dependencies update /tmp/sagemaker-hyperpod-cli/helm_chart/HyperPodHelmChart"
        echo "          helm install hyperpod-dependencies \\"
        echo "            /tmp/sagemaker-hyperpod-cli/helm_chart/HyperPodHelmChart \\"
        echo "            --namespace kube-system"
        exit 1
    fi
    echo "[OK] hyperpod-dependencies Helm chart found"
fi

# -----------------------------------------------------------------------------
# Install WEKA Operator
# -----------------------------------------------------------------------------
echo ""
echo "Installing WEKA Operator..."
kubectl create namespace "$WEKA_OPERATOR_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry weka-quay-io-secret \
    --namespace "$WEKA_OPERATOR_NS" \
    --docker-server=quay.io \
    --docker-username="$QUAY_USERNAME" \
    --docker-password="$QUAY_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

HELM_EXTRA_FLAGS=()
[[ "$USES_EMBEDDED_CSI" == "true" ]] && HELM_EXTRA_FLAGS+=(--set "csi.installationEnabled=true")

helm upgrade --install weka-operator \
    oci://quay.io/weka.io/helm/weka-operator \
    --namespace "$WEKA_OPERATOR_NS" \
    --version "$WEKA_OPERATOR_VERSION" \
    --set imagePullSecret=weka-quay-io-secret \
    "${HELM_EXTRA_FLAGS[@]}" \
    -f "$MANIFESTS_DIR/core/values-weka-operator.yaml" \
    --wait

echo "[OK] WEKA Operator installed"

# -----------------------------------------------------------------------------
# ensure-nics (non-hyperpod modules)
# -----------------------------------------------------------------------------
if [[ "$NEEDS_ENSURE_NICS" == "true" ]]; then
    echo ""
    echo "Running ensure-nics..."
    kubectl apply -f "$MANIFESTS_DIR/core/ensure-nics.yaml"

    if ! wait_for_status "ensure-nics completed" \
        "wekapolicies ensure-nics-policy" "$WEKA_OPERATOR_NS" \
        '{.status.status}' "Done" "Failed" 24 5; then
        kubectl describe wekapolicies -n "$WEKA_OPERATOR_NS"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# sign-drives (axon modules)
# -----------------------------------------------------------------------------
if [[ "$NEEDS_SIGN_DRIVES" == "true" ]]; then
    echo ""
    echo "Signing drives..."
    kubectl apply -f "$MANIFESTS_DIR/core/sign-drives.yaml"

    if ! wait_for_status "sign-drives completed" \
        "wekapolicies sign-drives-policy" "$WEKA_OPERATOR_NS" \
        '{.status.status}' "Done" "Failed" 36 5; then
        kubectl describe wekapolicies sign-drives-policy -n "$WEKA_OPERATOR_NS"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# HyperPod label verify (hyperpod modules)
# -----------------------------------------------------------------------------
if [[ "$NEEDS_HYPERPOD_LABEL_VERIFY" == "true" ]]; then
    echo ""
    echo "Verifying HyperPod node labels..."
    HYPERPOD_NODES=$(kubectl get nodes -l sagemaker.amazonaws.com/compute-type=hyperpod \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$HYPERPOD_NODES" ]]; then
        echo "[WARN] No HyperPod nodes found (label sagemaker.amazonaws.com/compute-type=hyperpod)."
        echo "       Continuing anyway -- verify the HyperPod cluster is InService."
    else
        MISSING_LABEL=0
        for node in $HYPERPOD_NODES; do
            if kubectl get node "$node" -o jsonpath='{.metadata.labels.weka\.io/supports-clients}' | grep -q true; then
                echo "  OK: $node (supports-clients=true)"
            else
                echo "  MISSING: $node lacks weka.io/supports-clients=true"
                MISSING_LABEL=1
            fi
        done
        if [[ $MISSING_LABEL -eq 1 ]]; then
            echo "[WARN] Some HyperPod nodes are missing the weka.io/supports-clients label."
            echo "       Check instance_groups[*].labels in terraform/hyperpod/terraform.tfvars"
            echo "       and terraform apply to push updated KubernetesConfig."
        else
            echo "[OK] All HyperPod nodes carry weka.io/supports-clients=true"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# NIC annotator (hyperpod DPDK only)
# -----------------------------------------------------------------------------
# Hugepages and NIC setup happen at node boot via the HyperPod lifecycle
# script. The annotator reads /var/lib/weka/hyperpod-nics.json and publishes
# it as node annotations + capacity. Skipped when --udp is set since
# single-ENI instances have no extra ENIs to annotate.
if [[ "$NEEDS_NIC_ANNOTATOR" == "true" ]]; then
    if [[ "$UDP_MODE" == "true" ]]; then
        echo ""
        echo "Skipping NIC annotator (UDP mode — no extra ENIs to annotate)"
    else
        echo ""
        echo "Deploying NIC annotator..."
        kubectl apply -f "$MANIFESTS_DIR/core/nic-annotator-rbac.yaml"
        kubectl apply -f "$MANIFESTS_DIR/core/nic-annotator-daemonset.yaml"

        echo "  Waiting for NIC annotations on HyperPod nodes..."
        annotated_ok=false
        for i in {1..24}; do
            # grep -c always prints a count to stdout; `|| true` masks its
            # non-zero exit when no lines match (otherwise pipefail would trip).
            ANNOTATED=$(kubectl get nodes -l sagemaker.amazonaws.com/compute-type=hyperpod \
                -o jsonpath='{range .items[*]}{.metadata.annotations.weka\.io/nics-ready}{"\n"}{end}' 2>/dev/null \
                | grep -c "true" || true)
            TOTAL=$(kubectl get nodes -l sagemaker.amazonaws.com/compute-type=hyperpod \
                --no-headers 2>/dev/null | wc -l | tr -d ' ')

            if [[ "$TOTAL" -gt 0 && "$ANNOTATED" -eq "$TOTAL" ]]; then
                echo "[OK] All $TOTAL HyperPod nodes annotated with NIC info"
                annotated_ok=true
                break
            fi
            echo "  Annotated: $ANNOTATED / $TOTAL ..."
            sleep 5
        done
        [[ "$annotated_ok" == "false" ]] && echo "[WARN] NIC annotator timed out — not all nodes annotated. Check 'kubectl logs -n $WEKA_OPERATOR_NS -l app=weka-nic-annotator'"
    fi
fi

# -----------------------------------------------------------------------------
# WekaCluster (axon modules)
# -----------------------------------------------------------------------------
if [[ "$DEPLOYS_WEKACLUSTER" == "true" ]]; then
    echo ""
    echo "Deploying WekaCluster..."
    kubectl apply -f "$MANIFESTS_DIR/core/weka-cluster.yaml"

    DESIRED_CCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].spec.dynamicTemplate.computeContainers}' 2>/dev/null || echo "0")
    DESIRED_DCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].spec.dynamicTemplate.driveContainers}' 2>/dev/null || echo "0")

    echo "  Waiting for cluster formation (compute=$DESIRED_CCT, drive=$DESIRED_DCT)..."

    # operator status.printer.{compute,drive}Containers format: "active/created/desired"
    LAST_MSG=""
    cluster_ok=false
    for i in {1..180}; do
        CCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.printer.computeContainers}' 2>/dev/null || echo "")
        DCT=$(kubectl get wekacluster -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.printer.driveContainers}' 2>/dev/null || echo "")

        if [[ -n "$CCT" && -n "$DCT" ]]; then
            CCT_ACTIVE=$(echo "$CCT" | cut -d/ -f1)
            DCT_ACTIVE=$(echo "$DCT" | cut -d/ -f1)

            if [[ "$CCT_ACTIVE" == "$DESIRED_CCT" && "$DCT_ACTIVE" == "$DESIRED_DCT" ]]; then
                echo "[OK] WekaCluster active (CCT=$CCT, DCT=$DCT)"
                cluster_ok=true
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
    [[ "$cluster_ok" == "false" ]] && echo "[WARN] WekaCluster did not reach active state within 15min — check 'kubectl describe wekacluster -n $WEKA_OPERATOR_NS'"
fi

# -----------------------------------------------------------------------------
# WekaClient (all modules)
# -----------------------------------------------------------------------------
echo ""
echo "Deploying WekaClient..."
kubectl apply -f "$MANIFESTS_DIR/core/weka-client.yaml"
echo "  Waiting for all client containers to be active..."

# operator status.printer.containers format: "active/created/desired"
LAST_MSG=""
client_ok=false
for i in {1..120}; do
    ACTIVE=$(kubectl get wekaclient -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.printer.containers}' 2>/dev/null || echo "")
    DESIRED=$(kubectl get wekaclient -n "$WEKA_OPERATOR_NS" -o jsonpath='{.items[0].status.stats.containers.desired}' 2>/dev/null || echo "0")

    if [[ -n "$ACTIVE" && "$DESIRED" -gt 0 ]]; then
        ACTIVE_CT=$(echo "$ACTIVE" | cut -d/ -f1)
        DESIRED_CT=$(echo "$ACTIVE" | cut -d/ -f3)
        if [[ "$ACTIVE_CT" == "$DESIRED_CT" && "$ACTIVE_CT" -gt 0 ]]; then
            echo "[OK] All $ACTIVE_CT client containers active ($ACTIVE)"
            client_ok=true
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
[[ "$client_ok" == "false" ]] && echo "[WARN] WekaClient did not reach active state within 10min — check 'kubectl describe wekaclient -n $WEKA_OPERATOR_NS'"

# -----------------------------------------------------------------------------
# Standalone CSI plugin (dedicated modules)
# -----------------------------------------------------------------------------
if [[ "$DEPLOYS_STANDALONE_CSI" == "true" ]]; then
    echo ""
    echo "Deploying WEKA CSI Plugin..."
    kubectl create namespace "$CSI_NS" --dry-run=client -o yaml | kubectl apply -f -

    if [[ -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml" ]]; then
        kubectl apply -f "$MANIFESTS_DIR/core/csi-wekafs-api-secret.yaml"
        echo "  API secret created"
    else
        echo "  [WARN] csi-wekafs-api-secret.yaml not found — CSI dynamic provisioning won't work"
    fi

    helm repo add csi-wekafs https://weka.github.io/csi-wekafs 2>/dev/null || true
    helm repo update

    helm upgrade --install csi-wekafs csi-wekafs/csi-wekafsplugin \
        --namespace "$CSI_NS" \
        -f "$MANIFESTS_DIR/core/values-csi-wekafs.yaml" \
        --wait

    echo "[OK] CSI Plugin installed"
fi

# -----------------------------------------------------------------------------
# StorageClass (all modules)
# -----------------------------------------------------------------------------
if [[ -f "$MANIFESTS_DIR/core/storageclass-weka.yaml" ]]; then
    echo ""
    echo "Applying StorageClass..."
    kubectl apply -f "$MANIFESTS_DIR/core/storageclass-weka.yaml"
    echo "[OK] StorageClass created"
fi

# -----------------------------------------------------------------------------
# Verification summary
# -----------------------------------------------------------------------------
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
if [[ "$DEPLOYS_WEKACLUSTER" == "true" ]]; then
    echo "WekaCluster Status:"
    kubectl get wekacluster -n "$WEKA_OPERATOR_NS"
    echo ""
fi
echo "WekaClient Status:"
kubectl get wekaclient -n "$WEKA_OPERATOR_NS" 2>/dev/null || echo "  (not ready yet)"
echo ""
echo "WekaContainer Status:"
kubectl get wekacontainers -n "$WEKA_OPERATOR_NS" 2>/dev/null || echo "  (not ready yet)"
echo ""
if [[ "$DEPLOYS_STANDALONE_CSI" == "true" ]]; then
    echo "CSI Pods:"
    kubectl get pods -n "$CSI_NS"
    echo ""
fi
echo "StorageClasses:"
kubectl get storageclass | grep weka || echo "  (none)"

# -----------------------------------------------------------------------------
# Test dynamic provisioning
# -----------------------------------------------------------------------------
echo ""
echo "Testing dynamic provisioning..."
kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$MANIFESTS_DIR/test/pvc.yaml"

# Apply writer + reader individually (module uses distinct filenames)
WRITER_YAML="$MANIFESTS_DIR/test/${TEST_WRITER}.yaml"
READER_YAML="$MANIFESTS_DIR/test/${TEST_READER}.yaml"

if [[ -f "$WRITER_YAML" ]]; then
    kubectl apply -f "$WRITER_YAML"
fi

echo "  Waiting for PVC to bind..."
wait_for_status "PVC bound" \
    "pvc pvc-wekafs-dir" "$TEST_NS" \
    '{.status.phase}' "Bound" "" 30 2 || true

echo "  Waiting for writer pod..."
kubectl wait --for=condition=Ready "pod/${TEST_WRITER}" -n "$TEST_NS" --timeout=120s 2>/dev/null || true

# Reader pod (applied after writer to exercise the RWX access mode)
if [[ -f "$READER_YAML" ]]; then
    kubectl apply -f "$READER_YAML"
    kubectl wait --for=condition=Ready "pod/${TEST_READER}" -n "$TEST_NS" --timeout=60s 2>/dev/null || true
fi

echo ""
echo "Test Results:"
kubectl get pvc -n "$TEST_NS"
kubectl get pods -n "$TEST_NS"
echo ""
echo "Writer logs:"
kubectl logs "$TEST_WRITER" -n "$TEST_NS" 2>/dev/null || echo "  (not ready yet)"
if [[ -f "$READER_YAML" ]]; then
    echo ""
    echo "Reader logs:"
    kubectl logs "$TEST_READER" -n "$TEST_NS" 2>/dev/null || echo "  (not ready yet)"
fi

echo ""
echo "=============================================="
echo "Deployment Complete"
echo "=============================================="
echo ""
echo "Test namespace '$TEST_NS' left running for verification."
echo "To clean up: kubectl delete namespace $TEST_NS"
echo ""
echo "To check status:"
[[ "$DEPLOYS_WEKACLUSTER" == "true" ]] && echo "  kubectl get wekacluster -n $WEKA_OPERATOR_NS"
echo "  kubectl get wekaclient -n $WEKA_OPERATOR_NS"
echo "  kubectl get wekacontainers -n $WEKA_OPERATOR_NS"
