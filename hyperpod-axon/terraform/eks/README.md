# EKS Module (HyperPod Axon)

Deploys an EKS cluster with system nodes only. WEKA Axon nodes are
provisioned by SageMaker HyperPod (see `terraform/hyperpod/`).

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with appropriate credentials
- Existing VPC with subnets (private subnets recommended)

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

### Required Variables

| Variable | Type | Description |
| ---------- | ------ | ------------- |
| `region` | string | AWS region |
| `cluster_name` | string | Name of the EKS cluster |
| `subnet_ids` | list(string) | Subnet IDs for EKS cluster and nodes |

### Cluster Configuration

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `kubernetes_version` | string | `"1.33"` | Kubernetes version |
| `endpoint_private_access` | bool | `true` | Enable private API endpoint |
| `endpoint_public_access` | bool | `true` | Enable public API endpoint |
| `public_access_cidrs` | list(string) | `["0.0.0.0/0"]` | CIDRs for public API access |
| `additional_security_group_ids` | list(string) | `[]` | Additional SGs (e.g., WEKA backend SG) |
| `authentication_mode` | string | `"API"` | EKS auth mode |
| `enabled_cluster_log_types` | list(string) | `["api", "audit", ...]` | Control plane log types |
| `admin_role_arn` | string | `null` | IAM role for cluster admin access |
| `tags` | map(string) | `{}` | Tags for all resources |

### System Node Group

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `system_node_instance_types` | list(string) | `["t3.large"]` | Instance types |
| `system_node_desired_size` | number | `2` | Desired count |
| `system_node_min_size` | number | `2` | Minimum count |
| `system_node_max_size` | number | `5` | Maximum count |
| `system_node_disk_size` | number | `100` | Root volume (GiB) |
| `enable_ssm_access` | bool | `true` | Attach SSM policy |

## Outputs

| Output | Description |
| ---------- | ------------- |
| `cluster_name` | EKS cluster name |
| `cluster_arn` | EKS cluster ARN |
| `cluster_endpoint` | Control plane endpoint |
| `cluster_version` | Kubernetes version |
| `cluster_security_group_id` | AWS-managed cluster SG |
| `node_iam_role_arn` | Node IAM role ARN |
| `configure_kubectl` | kubectl configuration command |

## Architecture

**System nodes only** -- Axon/storage nodes are managed by HyperPod.

- **System nodes**: Run Kubernetes components, WEKA operator, CSI.
- **Axon nodes** (HyperPod): Run WEKA backend + client containers
  and application workloads. Provisioned via `terraform/hyperpod/`.

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
