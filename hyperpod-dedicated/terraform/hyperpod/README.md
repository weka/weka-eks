# HyperPod Module

Creates a SageMaker HyperPod cluster that joins an existing EKS cluster.
Uploads WEKA lifecycle scripts (hugepages + NIC configuration) to S3
and references them in the HyperPod cluster config.

## Prerequisites

- Terraform >= 1.5
- An existing EKS cluster (from `terraform/eks/`)
- An S3 bucket for lifecycle scripts (created by default, or bring your own)
- A SageMaker execution role (created by default, or bring your own)

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

## How It Works

1. Terraform uploads lifecycle scripts to your S3 bucket
2. HyperPod creates instances and runs `on_create.sh` at boot
3. The script configures hugepages, moves NICs from the SageMaker
   network namespace, and writes NIC metadata to
   `/var/lib/weka/hyperpod-nics.json`
4. After nodes join EKS, the NIC annotator DaemonSet reads the JSON
   and annotates nodes for the WEKA operator

## Configuration

### Required Variables

| Variable | Type | Description |
| ---------- | ------ | ------------- |
| `region` | string | AWS region |
| `eks_cluster_arn` | string | ARN of the EKS cluster |
| `subnet_ids` | list(string) | Subnets for HyperPod instances |
| `s3_bucket_name` | string | S3 bucket for lifecycle scripts (created by this module by default) |

### Optional Variables

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `hyperpod_cluster_name` | string | `"weka-hyperpod"` | HyperPod cluster name |
| `create_efa_security_group` | bool | `true` | Create + attach an EFA-compliant SG (self-only ingress/egress). Required for p4d/p5/etc. to pass HyperPod's EFA health check; harmless on non-EFA instances |
| `additional_security_group_ids` | list(string) | `[]` | Extra SGs to attach to HyperPod instances. Typically the SGs used by your EKS nodes and WEKA backend |
| `create_s3_bucket` | bool | `true` | Create the S3 bucket (false = use existing). Created buckets have `force_destroy = true` |
| `s3_key_prefix` | string | `"hyperpod-lifecycle"` | S3 prefix for scripts |
| `create_sagemaker_execution_role` | bool | `true` | Create IAM role (false = use existing) |
| `sagemaker_execution_role_arn` | string | `null` | Existing role ARN |
| `auto_node_recovery` | bool | `true` | Auto-recover failed nodes |
| `tags` | map(string) | `{}` | Tags for all resources |

### Instance Groups

`instance_groups` is a list of objects. Each entry creates a HyperPod
instance group whose nodes join the EKS cluster as workers.

#### Required per group

| Attribute | Type | Description |
| ----------- | ------ | ------------- |
| `name` | string | Instance group name |
| `instance_type` | string | SageMaker instance type (e.g. `ml.p5.48xlarge`) |
| `instance_count` | number | Number of instances |

#### Optional per group

| Attribute | Type | Default | Description |
| ----------- | ------ | --------- | ------------- |
| `ebs_volume_size_in_gb` | number | `100` | Secondary EBS volume size (mounted at `/opt/sagemaker`) |
| `threads_per_core` | number | `2` | Threads per core |
| `labels` | map(string) | `{}` | Kubernetes node labels applied via `KubernetesConfig.Labels` |
| `taints` | list(object) | `[]` | Kubernetes node taints applied via `KubernetesConfig.Taints`. Each entry: `{key, value, effect}` |
| `training_plan_arn` | string | `null` | ARN of a reserved-capacity [SageMaker training plan](https://docs.aws.amazon.com/sagemaker/latest/dg/reserve-capacity-with-training-plans.html) to attach this group to |
| `image_id` | string | `null` | Custom [HyperPod AMI](https://docs.aws.amazon.com/sagemaker/latest/dg/hyperpod-custom-ami-support.html) ID. Skip the DLAMI default; pair with stripped-down lifecycle scripts if hugepages / NIC setup is baked into the AMI |
| `on_start_deep_health_checks` | list(string) | `[]` | Deep health checks to run at node start; values: `"InstanceStress"`, `"InstanceConnectivity"`. GPU/accelerated instance types only |
| `min_instance_count` | number | `null` | Lower bound for auto-scaling / auto-recovery |

### WEKA Per-Node Configuration

Shared across all instance groups in a single module invocation.
Use separate hyperpod modules for heterogeneous WEKA requirements.

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `weka_hugepages_count` | number | `2048` | 2 MiB hugepages allocated per node at boot |
| `weka_nic_count` | number | `0` | WEKA DPDK NICs per node. `0` = UDP mode (single-ENI types); raise for DPDK on multi-ENI types like `ml.p4d.*` / `ml.p5.*` / `ml.p6.*` (should match the WekaClient CR's `coresNum` — one NIC per WEKA core) |

## Outputs

| Output | Description |
| ---------- | ------------- |
| `cluster_arn` | HyperPod cluster ARN |
| `cluster_name` | HyperPod cluster name |
| `sagemaker_execution_role_arn` | Execution role used by instances |
| `lifecycle_scripts_s3_uri` | S3 URI of uploaded scripts |
| `efa_security_group_id` | ID of the auto-created EFA-compliant SG (`null` if `create_efa_security_group = false`) |

## Lifecycle Script Flow

```text
on_create.sh (entrypoint)
  1. Configure containerd data root if /opt/sagemaker is mounted
  2. Source weka-config.env (Terraform-generated)
  3. Run configure-weka-hugepages.sh           (if WEKA_HUGEPAGES_COUNT > 0)
  4. Run configure-hyperpod-nics.py --count N  (if WEKA_NIC_COUNT > 0)
       -> writes /var/lib/weka/hyperpod-nics.json
```

After the node joins EKS, the NIC annotator DaemonSet reads the JSON
and annotates the node with `weka.io/weka-nics` and `weka.io/nics`
capacity.

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
| awscc     | ~> 1.0  |
