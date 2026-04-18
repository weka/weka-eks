#!/bin/bash
#
# Generate WEKA manifests from backend cluster information.
#
# Queries the WEKA backend EC2 instances and Secrets Manager to produce:
#   - manifests/core/weka-client.yaml
#   - manifests/core/csi-wekafs-api-secret.yaml
#
# Prerequisites:
#   - AWS CLI configured and authenticated
#   - jq installed
#   - WEKA backend cluster deployed (terraform/weka-backend)
#
# Usage:
#   ./generate-manifests.sh --backend-name <name> --secret-arn <arn> [OPTIONS]
#
# Or set environment variables:
#   export WEKA_BACKEND_NAME=eks-storage-cluster
#   export WEKA_SECRET_ARN=arn:aws:secretsmanager:...
#   ./generate-manifests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/manifests/core"

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
Usage: $0 [OPTIONS]

Generate WEKA Kubernetes manifests from backend cluster information.

Required (via flags or environment variables):
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

Output:
  manifests/core/weka-client.yaml
  manifests/core/csi-wekafs-api-secret.yaml

Examples:
  $0 --backend-name eks-storage-cluster \\
     --secret-arn arn:aws:secretsmanager:us-west-2:123456:secret:weka/...

  WEKA_BACKEND_NAME=eks-storage-cluster \\
  WEKA_SECRET_ARN=arn:aws:secretsmanager:... \\
  $0
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)       show_help ;;
        --backend-name)  WEKA_BACKEND_NAME="$2"; shift 2 ;;
        --secret-arn)    WEKA_SECRET_ARN="$2"; shift 2 ;;
        --region)        AWS_REGION="$2"; shift 2 ;;
        --cores)         WEKA_CORES_NUM="$2"; shift 2 ;;
        --hugepages)     WEKA_HUGEPAGES="$2"; shift 2 ;;
        --image)         WEKA_IMAGE="$2"; shift 2 ;;
        --username)      WEKA_USERNAME="$2"; shift 2 ;;
        --udp)           UDP_MODE="true"; shift ;;
        *)               echo "[ERROR] Unknown option: $1"; show_help ;;
    esac
done

# Validate
if [[ -z "$WEKA_BACKEND_NAME" ]]; then
    echo "[ERROR] --backend-name or WEKA_BACKEND_NAME required"
    echo "Run $0 --help for usage"
    exit 1
fi

if [[ -z "$WEKA_SECRET_ARN" ]]; then
    echo "[ERROR] --secret-arn or WEKA_SECRET_ARN required"
    echo "Run $0 --help for usage"
    exit 1
fi

REGION_FLAG=""
if [[ -n "$AWS_REGION" ]]; then
    REGION_FLAG="--region $AWS_REGION"
fi

# -----------------------------------------------------------------------------
# Query backend IPs
# -----------------------------------------------------------------------------
echo "Querying WEKA backend instances (tag: *${WEKA_BACKEND_NAME}*)..."

BACKEND_IPS=$(aws ec2 describe-instances $REGION_FLAG \
    --filters "Name=tag:Name,Values=*${WEKA_BACKEND_NAME}*" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PrivateIpAddress' \
    --output text | tr '\t' '\n' | sort)

if [[ -z "$BACKEND_IPS" ]]; then
    echo "[ERROR] No running instances found with tag matching *${WEKA_BACKEND_NAME}*"
    exit 1
fi

IP_COUNT=$(echo "$BACKEND_IPS" | wc -l | tr -d ' ')
echo "  Found $IP_COUNT backend instances"

# -----------------------------------------------------------------------------
# Query password from Secrets Manager
# -----------------------------------------------------------------------------
echo "Querying WEKA password from Secrets Manager..."

WEKA_PASSWORD=$(aws secretsmanager get-secret-value $REGION_FLAG \
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
echo "Generating manifests/core/weka-client.yaml..."

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

echo "  Created: manifests/core/weka-client.yaml"

# -----------------------------------------------------------------------------
# Generate csi-wekafs-api-secret.yaml
# -----------------------------------------------------------------------------
echo "Generating manifests/core/csi-wekafs-api-secret.yaml..."

# Build comma-separated endpoints
ENDPOINTS=""
while IFS= read -r ip; do
    if [[ -n "$ENDPOINTS" ]]; then
        ENDPOINTS="${ENDPOINTS},"
    fi
    ENDPOINTS="${ENDPOINTS}${ip}:${WEKA_PORT}"
done <<< "$BACKEND_IPS"

# Base64 encode values
B64_USERNAME=$(echo -n "$WEKA_USERNAME" | base64)
B64_PASSWORD=$(echo -n "$WEKA_PASSWORD" | base64)
B64_SCHEME=$(echo -n "$WEKA_SCHEME" | base64)
B64_ENDPOINTS=$(echo -n "$ENDPOINTS" | base64)
B64_ORG=$(echo -n "$WEKA_ORGANIZATION" | base64)

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

echo "  Created: manifests/core/csi-wekafs-api-secret.yaml"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Manifests Generated"
echo "=============================================="
echo ""
echo "Backend: ${WEKA_BACKEND_NAME} (${IP_COUNT} nodes)"
echo "IPs:     $(echo "$BACKEND_IPS" | tr '\n' ' ')"
echo "Cores:   ${WEKA_CORES_NUM}"
echo "Mode:    $([ "$UDP_MODE" = "true" ] && echo "UDP" || echo "DPDK")"
echo ""
echo "Files:"
echo "  manifests/core/weka-client.yaml"
echo "  manifests/core/csi-wekafs-api-secret.yaml"
echo ""
echo "Next: review the generated files, then run ./deploy.sh"
