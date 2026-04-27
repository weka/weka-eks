# EKS Module (HyperPod)

Deploys an EKS cluster with system-only node groups. Worker nodes
are provisioned separately by SageMaker HyperPod (see
[terraform/hyperpod/](../hyperpod/)). This is a thin wrapper around
the shared [modules/eks](../../../modules/eks/) module.

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

### Key settings for HyperPod mode

- `additional_security_group_ids`: Add the WEKA backend SG so
  HyperPod nodes (joined to this cluster) can reach the backend
- `node_groups`: Only a `system` group is needed — HyperPod manages
  all WEKA client workers

## Architecture

**Single-tier node group design:**

- **System nodes** — Run Kubernetes components (CoreDNS, kube-proxy,
  VPC CNI), the WEKA operator controller, and CSI controller.
  No special labels or taints.

HyperPod-provisioned worker nodes join the cluster automatically
via the lifecycle scripts in `lifecycle-scripts/` and are labeled
`sagemaker.amazonaws.com/compute-type=hyperpod` by SageMaker.

The WEKA backend security group should be added to
`additional_security_group_ids` so HyperPod nodes can reach the
backend cluster.

## Post-Deployment

After `terraform apply`:

1. Deploy the HyperPod cluster (see `terraform/hyperpod/`)
2. Install the WEKA Operator via Helm
3. Apply NIC annotator DaemonSet (replaces ensure-nics for HyperPod)
4. Apply WekaClient manifest
5. Install CSI plugin and create StorageClass

See the [main README](../../README.md) for step-by-step instructions.

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
