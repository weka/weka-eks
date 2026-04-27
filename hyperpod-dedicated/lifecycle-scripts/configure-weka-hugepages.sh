#!/bin/bash
# Configure 2 MiB hugepages for WEKA.
# Expects WEKA_HUGEPAGES_COUNT to be set in the environment (sourced from weka-config.env).
#
# This script is the HyperPod-managed-node counterpart to the hugepages
# section of modules/eks/nodeadm-userdata.yaml.tftpl, which runs on
# EKS-managed node groups. The two share identical systemd-unit logic but
# can't share an implementation because EKS LT user data and HyperPod
# lifecycle scripts are different bootstrap mechanisms. Keep both in
# sync if either changes.

set -euo pipefail

HUGEPAGES="${WEKA_HUGEPAGES_COUNT:?ERROR: WEKA_HUGEPAGES_COUNT not set}"

echo "Configuring $HUGEPAGES hugepages (2 MiB each)..."
echo "$HUGEPAGES" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Persist across reboots via systemd oneshot
cat > /etc/systemd/system/hugepages.service << EOF
[Unit]
Description=Configure Hugepages for WEKA
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $HUGEPAGES > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hugepages.service

echo "Hugepages configured: $(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)"
