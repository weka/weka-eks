# EKS Module (Axon)

Deploys an EKS cluster for running converged WEKA Axon workloads
(backends + clients on the same nodes). This is a thin wrapper
around the shared [modules/eks](../../../modules/eks/) module.

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with appropriate credentials
- Existing VPC with subnets (private subnets recommended)
- IAM permissions to create EKS, EC2, IAM resources

## Quick Start

1. Copy and edit the example configuration:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Initialize and apply:

   ```bash
   terraform init
   terraform apply
   ```

3. Configure kubectl:

   ```bash
   $(terraform output -raw configure_kubectl)
   ```

## Configuration

See the shared module [README](../../../modules/eks/README.md)
for the full variable and output reference.

### Key settings for axon mode

- `node_groups`: define `system` + `axon` groups

**For WEKA axon nodes, set:**

- `imds_hop_limit_2 = true` (required for ENI management)
- `enable_cpu_manager_static = true` (DPDK CPU allocation)
- `disable_hyperthreading = true` with matching `core_count`
- `hugepages_count` (covers backend + client containers per node)
- Labels `weka.io/supports-backends = "true"` and
  `weka.io/supports-clients = "true"`
- Taint `weka.io/axon=true:NO_SCHEDULE`

## Architecture

**Converged design** -- backend and client processes run on the
same nodes:

1. **System nodes** -- Run Kubernetes components (CoreDNS,
   kube-proxy, VPC CNI), the WEKA operator controller, and CSI
   controller. No special labels or taints.

2. **Axon nodes** -- Run WEKA backend containers (drive + compute)
   and client containers. Labeled with
   `weka.io/supports-backends` and `weka.io/supports-clients` and
   tainted with `weka.io/axon=true:NoSchedule`.

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
