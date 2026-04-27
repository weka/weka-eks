#!/bin/bash
#
# Generate WEKA Kubernetes manifests from backend cluster information.
#
# Queries the WEKA backend EC2 instances and Secrets Manager to produce:
#   <module>/manifests/core/weka-client.yaml
#   <module>/manifests/core/csi-wekafs-api-secret.yaml
#
# Typically invoked via a per-module `generate-manifests.sh` shim that
# supplies --module. Can also be run directly.
#
# Prerequisites:
#   - AWS CLI configured and authenticated
#   - jq installed
#   - WEKA backend cluster deployed (terraform/weka-backend)
#
# Only the dedicated-backend modules (weka-dedicated, hyperpod-dedicated)
# use this script — axon modules ship a self-contained WekaCluster CR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Initialize variables that may be set by argparse or env
MODULE=""
WEKA_BACKEND_NAME="${WEKA_BACKEND_NAME:-}"
WEKA_SECRET_ARN="${WEKA_SECRET_ARN:-}"
AWS_REGION="${AWS_REGION:-}"

# Defaults
WEKA_PORT=14000
WEKA_CORES_NUM=2
WEKA_HUGEPAGES=3072
WEKA_IMAGE="quay.io/weka.io/weka-in-container:4.4.21.2"
WEKA_USERNAME="admin"
WEKA_ORGANIZATION="Root"
WEKA_SCHEME="https"
UDP_MODE="false"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
Usage: $0 --module <name> --backend-name <name> --secret-arn <arn> [OPTIONS]

Generate WEKA Kubernetes manifests from backend cluster information.

Required:
  --module NAME          Module name: weka-dedicated | hyperpod-dedicated
  --backend-name NAME    WEKA backend cluster name tag (or WEKA_BACKEND_NAME)
  --secret-arn ARN       Secrets Manager ARN for WEKA password (or WEKA_SECRET_ARN)

Optional:
  --region REGION        AWS region (default: from AWS CLI config)
  --cores NUM            WEKA client cores (default: 2)
  --hugepages NUM        Hugepages in MiB (default: 3072)
  --image IMAGE          WEKA container image (default: $WEKA_IMAGE)
  --username USER        WEKA admin username (default: admin)
  --udp                  Use UDP mode instead of DPDK
  -h, --help             Show this help message

Environment variables:
  WEKA_BACKEND_NAME      WEKA backend cluster name tag
  WEKA_SECRET_ARN        Secrets Manager ARN for WEKA password
  AWS_REGION             AWS region

Output (written into the selected module's manifests/core/):
  weka-client.yaml
  csi-wekafs-api-secret.yaml
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)       show_help ;;
        --module)        MODULE="$2"; shift 2 ;;
        --backend-name)  WEKA_BACKEND_NAME="$2"; shift 2 ;;
        --secret-arn)    WEKA_SECRET_ARN="$2"; shift 2 ;;
        --region)        AWS_REGION="$2"; shift 2 ;;
        --cores)         WEKA_CORES_NUM="$2"; shift 2 ;;
        --hugepages)     WEKA_HUGEPAGES="$2"; shift 2 ;;
        --image)         WEKA_IMAGE="$2"; shift 2 ;;
        --username)      WEKA_USERNAME="$2"; shift 2 ;;
        --udp)           UDP_MODE="true"; shift ;;
        *)               echo "[ERROR] Unknown option: $1"; echo "Run $0 --help for usage"; exit 1 ;;
    esac
done

# Validate module
case "$MODULE" in
    weka-dedicated|hyperpod-dedicated) ;;
    "")
        echo "[ERROR] --module is required (weka-dedicated | hyperpod-dedicated)"
        exit 1 ;;
    weka-axon)
        echo "[ERROR] axon modules don't use generate-manifests.sh; their WekaCluster CR is self-contained."
        exit 1 ;;
    *)
        echo "[ERROR] Unknown module: $MODULE"
        exit 1 ;;
esac

MODULE_DIR="$REPO_ROOT/$MODULE"
MANIFESTS_DIR="$MODULE_DIR/manifests/core"

if [[ ! -d "$MANIFESTS_DIR" ]]; then
    echo "[ERROR] Module manifests dir not found: $MANIFESTS_DIR"
    exit 1
fi

# Validate backend info
if [[ -z "$WEKA_BACKEND_NAME" ]]; then
    echo "[ERROR] --backend-name or WEKA_BACKEND_NAME required"
    exit 1
fi

if [[ -z "$WEKA_SECRET_ARN" ]]; then
    echo "[ERROR] --secret-arn or WEKA_SECRET_ARN required"
    exit 1
fi

REGION_FLAG=()
if [[ -n "$AWS_REGION" ]]; then
    REGION_FLAG=(--region "$AWS_REGION")
fi

# -----------------------------------------------------------------------------
# Query backend IPs
# -----------------------------------------------------------------------------
echo "Querying WEKA backend instances (tag: *${WEKA_BACKEND_NAME}*)..."

BACKEND_IPS=$(aws ec2 describe-instances "${REGION_FLAG[@]}" \
    --filters "Name=tag:Name,Values=*${WEKA_BACKEND_NAME}*" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PrivateIpAddress' \
    --output text | tr '\t' '\n' | sort)

if [[ -z "$BACKEND_IPS" ]]; then
    echo "[ERROR] No running instances found with Name tag containing '${WEKA_BACKEND_NAME}'"
    exit 1
fi

IP_COUNT=$(echo "$BACKEND_IPS" | wc -l | tr -d ' ')
echo "  Found $IP_COUNT backend instances"

# -----------------------------------------------------------------------------
# Query password from Secrets Manager
# -----------------------------------------------------------------------------
echo "Querying WEKA password from Secrets Manager..."

WEKA_PASSWORD=$(aws secretsmanager get-secret-value "${REGION_FLAG[@]}" \
    --secret-id "$WEKA_SECRET_ARN" \
    --query SecretString \
    --output text 2>/dev/null)

if [[ -z "$WEKA_PASSWORD" ]]; then
    echo "[ERROR] Failed to retrieve password from Secrets Manager"
    echo "  ARN: $WEKA_SECRET_ARN"
    exit 1
fi

echo "  Password retrieved"

# -----------------------------------------------------------------------------
# Generate weka-client.yaml
# -----------------------------------------------------------------------------
echo "Generating $MODULE/manifests/core/weka-client.yaml..."

# Build joinIpPorts YAML
JOIN_IP_PORTS=""
while IFS= read -r ip; do
    JOIN_IP_PORTS="${JOIN_IP_PORTS}    - \"${ip}:${WEKA_PORT}\"\n"
done <<< "$BACKEND_IPS"

cat > "$MANIFESTS_DIR/weka-client.yaml" <<EOF
apiVersion: weka.weka.io/v1alpha1
kind: WekaClient
metadata:
  name: weka-client
  namespace: weka-operator-system
spec:
  coresNum: ${WEKA_CORES_NUM}
  driversDistService: "https://drivers.weka.io"
  hugepages: ${WEKA_HUGEPAGES}
  image: ${WEKA_IMAGE}
  imagePullSecret: weka-quay-io-secret
  joinIpPorts:
$(echo -e "$JOIN_IP_PORTS" | sed '/^$/d')
  network:
    udpMode: ${UDP_MODE}
  nodeSelector:
    weka.io/supports-clients: "true"
  portRange:
    basePort: 46000
  rawTolerations:
    - key: "weka.io/client"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule"
EOF

echo "  Created: $MODULE/manifests/core/weka-client.yaml"

# -----------------------------------------------------------------------------
# Generate csi-wekafs-api-secret.yaml
# -----------------------------------------------------------------------------
echo "Generating $MODULE/manifests/core/csi-wekafs-api-secret.yaml..."

# Build comma-separated endpoints
ENDPOINTS=""
while IFS= read -r ip; do
    if [[ -n "$ENDPOINTS" ]]; then
        ENDPOINTS="${ENDPOINTS},"
    fi
    ENDPOINTS="${ENDPOINTS}${ip}:${WEKA_PORT}"
done <<< "$BACKEND_IPS"

# Base64 encode values. `tr -d '\n'` strips the newline GNU base64 inserts
# every 76 chars, which would otherwise produce multi-line YAML scalars
# for long inputs (e.g. endpoints across many backend IPs).
B64_USERNAME=$(echo -n "$WEKA_USERNAME" | base64 | tr -d '\n')
B64_PASSWORD=$(echo -n "$WEKA_PASSWORD" | base64 | tr -d '\n')
B64_SCHEME=$(echo -n "$WEKA_SCHEME" | base64 | tr -d '\n')
B64_ENDPOINTS=$(echo -n "$ENDPOINTS" | base64 | tr -d '\n')
B64_ORG=$(echo -n "$WEKA_ORGANIZATION" | base64 | tr -d '\n')

cat > "$MANIFESTS_DIR/csi-wekafs-api-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: csi-wekafs-api-secret
  namespace: csi-wekafs
type: Opaque
data:
  username: ${B64_USERNAME}
  password: ${B64_PASSWORD}
  scheme: ${B64_SCHEME}
  endpoints: ${B64_ENDPOINTS}
  organization: ${B64_ORG}
EOF

echo "  Created: $MODULE/manifests/core/csi-wekafs-api-secret.yaml"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Manifests Generated"
echo "=============================================="
echo ""
echo "Module:  $MODULE"
echo "Backend: ${WEKA_BACKEND_NAME} (${IP_COUNT} nodes)"
echo "IPs:     $(echo "$BACKEND_IPS" | tr '\n' ' ')"
echo "Cores:   ${WEKA_CORES_NUM}"
echo "Mode:    $([[ "$UDP_MODE" == "true" ]] && echo "UDP" || echo "DPDK")"
echo ""
echo "Files:"
echo "  $MODULE/manifests/core/weka-client.yaml"
echo "  $MODULE/manifests/core/csi-wekafs-api-secret.yaml"
echo ""
echo "Next: review the generated files, then run ./deploy.sh"
