# EKS Module (Dedicated)

Deploys an EKS cluster for running WEKA client workloads against an
external WEKA backend cluster. This is a thin wrapper around the
shared [modules/eks](../../../modules/eks/) module.

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with appropriate credentials
- Existing VPC with subnets (private subnets recommended)
- An existing WEKA backend cluster (deployed separately)
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

### Key settings for dedicated mode

- `additional_security_group_ids`: Add the WEKA backend SG so client
  nodes can reach the backend cluster
- `node_groups`: Define system + clients groups

**For WEKA client nodes, set:**

- `subnet_ids` to the WEKA backend subnet (same AZ / placement group)
- `imds_hop_limit_2 = true` (required for WEKA pod access to IMDS)
- `enable_cpu_manager_static = true` (DPDK CPU allocation)
- `hugepages_count` (~768 pages per WEKA core)
- Label `weka.io/supports-clients = "true"`
- Taint `weka.io/client=true:NO_SCHEDULE` (optional, keeps non-WEKA
  pods off)

## Architecture

**Two-tier node group design:**

1. **System nodes** -- Run Kubernetes components (CoreDNS, kube-proxy,
   VPC CNI), the WEKA operator controller, and CSI controller.
   No special labels or taints.

2. **Client nodes** -- Run WEKA client containers that connect to the
   external backend cluster. Labeled with `weka.io/supports-clients`
   and optionally tainted with `weka.io/client=true:NoSchedule`.
   IMDS hop limit set to 2, CPU manager enabled, hugepages
   pre-allocated.

The WEKA backend security group should be added to
`additional_security_group_ids` so client nodes can reach the
backend cluster.

## Post-Deployment

After `terraform apply`:

1. Install the WEKA Operator via Helm
2. Apply ensure-nics WekaPolicy
3. Apply WekaClient manifest
4. Install CSI plugin and create StorageClass
5. Verify hugepages (allocated at boot via launch template)

See the [main README](../../README.md) for step-by-step instructions.

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
