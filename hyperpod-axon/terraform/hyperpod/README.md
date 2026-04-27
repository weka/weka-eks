# HyperPod Module (Axon)

Creates a SageMaker HyperPod cluster for converged WEKA Axon workloads
(backends + clients on same nodes). Uploads lifecycle scripts to S3 for
hugepages and NIC configuration at boot.

## Prerequisites

- Terraform >= 1.5
- An existing EKS cluster (from `terraform/eks/`)
- An existing S3 bucket for lifecycle scripts
- A SageMaker execution role (created by default, or bring your own)

## Quick Start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init
terraform apply
```

## Configuration

### Required Variables

| Variable | Type | Description |
| ---------- | ------ | ------------- |
| `region` | string | AWS region |
| `eks_cluster_arn` | string | ARN of the EKS cluster |
| `subnet_ids` | list(string) | Subnets for HyperPod instances |
| `security_group_id` | string | SG for intra-node WEKA + EKS traffic |
| `subnet_cidr` | string | Subnet CIDR for NIC config script |
| `s3_bucket_name` | string | Existing S3 bucket for lifecycle scripts |

### Optional Variables

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `hyperpod_cluster_name` | string | `"weka-axon-hyperpod"` | HyperPod cluster name |
| `s3_key_prefix` | string | `"hyperpod-axon-lifecycle"` | S3 prefix for scripts |
| `create_sagemaker_execution_role` | bool | `true` | Create IAM role |
| `sagemaker_execution_role_arn` | string | `null` | Existing role ARN |
| `auto_node_recovery` | bool | `true` | Auto-recover failed nodes |
| `tags` | map(string) | `{}` | Tags |

### Instance Groups

| Field | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `name` | string | Required | Instance group name |
| `instance_type` | string | Required | SageMaker instance type |
| `instance_count` | number | Required | Number of instances |
| `ebs_volume_size_in_gb` | number | `500` | EBS volume size |
| `threads_per_core` | number | `1` | Threads per core (1 = HT disabled) |
| `weka_nic_count` | number | `7` | NICs to configure for WEKA |
| `weka_hugepages_count` | number | `5376` | 2 MiB hugepages to allocate |

## Resource Sizing

Container counts, cores, and hugepages depend on instance type. See the
main README for formulas. Key guidelines:

- **NICs**: Typically 1 per DPDK core. With 6 compute + 6 drive
  containers at 2 cores each, backend nodes need ~7 NICs.
- **Hugepages**: Compute cores need 3 GiB each (1536 pages), drive
  cores need 1.5 GiB each (768 pages). The operator (v1.11.0)
  auto-calculates compute hugepages from drive capacity, but the
  node must have enough total hugepages pre-allocated.
- **Threads per core**: Set to 1 (disable HT) for consistent DPDK
  performance on WEKA backend nodes.

## Outputs

| Output | Description |
| ---------- | ------------- |
| `cluster_arn` | HyperPod cluster ARN |
| `cluster_name` | HyperPod cluster name |
| `sagemaker_execution_role_arn` | Execution role used by instances |
| `lifecycle_scripts_s3_uri` | S3 URI of uploaded scripts |

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
| awscc     | ~> 1.0  |
