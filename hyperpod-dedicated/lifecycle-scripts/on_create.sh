#!/bin/bash
# HyperPod lifecycle entrypoint.
# - Containerd data-root adjustment if /opt/sagemaker is mounted.
# - WEKA hugepages via configure-weka-hugepages.sh, driven by counts in
#   weka-config.env (Terraform-rendered).
# - WEKA DPDK NICs moved out of the SageMaker netns by configure-hyperpod-nics.py.

set -ex
set -o pipefail

LOG_FILE="/var/log/provision/provisioning.log"
mkdir -p "/var/log/provision"
touch "$LOG_FILE"

log() {
  echo "$@" | tee -a "$LOG_FILE"
}

log "[start] on_create.sh"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# ---- containerd data root -------------------------------------------------
CONTAINERD_CONFIG="/etc/eks/containerd/containerd-config.toml"
if mount | grep -q /opt/sagemaker && [[ -f "$CONTAINERD_CONFIG" ]]; then
  log "Found secondary EBS at /opt/sagemaker; pointing containerd data root there"
  if grep -q '^[# ]*root\s*=' "$CONTAINERD_CONFIG"; then
    sed -i -e "/^[# ]*root\s*=/c\root = \"/opt/sagemaker/containerd/data-root\"" "$CONTAINERD_CONFIG"
  else
    log "[warning] no 'root =' line in $CONTAINERD_CONFIG — sed would have been a no-op; AMI may have changed format"
  fi
else
  log "Skipping containerd data-root adjustment (mount or config file not present)"
fi

# ---- WEKA config (Terraform-rendered) -------------------------------------
WEKA_CONFIG="$SCRIPT_DIR/weka-config.env"
if [[ -f "$WEKA_CONFIG" ]]; then
  log "Sourcing WEKA config: $WEKA_CONFIG"
  # shellcheck disable=SC1090
  source "$WEKA_CONFIG"
else
  log "[warning] $WEKA_CONFIG not found — skipping WEKA config"
fi

# ---- WEKA hugepages -------------------------------------------------------
if [[ "${WEKA_HUGEPAGES_COUNT:-0}" -gt 0 ]]; then
  HUGEPAGES_SCRIPT="$SCRIPT_DIR/configure-weka-hugepages.sh"
  if [[ -f "$HUGEPAGES_SCRIPT" ]]; then
    log "Configuring $WEKA_HUGEPAGES_COUNT WEKA hugepages..."
    bash "$HUGEPAGES_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
  else
    log "[warning] $HUGEPAGES_SCRIPT not found — skipping hugepages"
  fi
fi

# ---- WEKA DPDK NICs -------------------------------------------------------
# Moves WEKA NICs from the SageMaker network namespace to the host namespace
# and writes /var/lib/weka/hyperpod-nics.json for the NIC annotator DaemonSet.
# Subnet CIDR is auto-detected from IMDS by the Python script.
if [[ "${WEKA_NIC_COUNT:-0}" -gt 0 ]]; then
  NICS_SCRIPT="$SCRIPT_DIR/configure-hyperpod-nics.py"
  if [[ -f "$NICS_SCRIPT" ]]; then
    log "Moving $WEKA_NIC_COUNT WEKA NICs from SageMaker namespace..."
    python3 "$NICS_SCRIPT" --count "$WEKA_NIC_COUNT" 2>&1 | tee -a "$LOG_FILE"
  else
    log "[warning] $NICS_SCRIPT not found — skipping NIC config"
  fi
fi

log "[stop] on_create.sh"
