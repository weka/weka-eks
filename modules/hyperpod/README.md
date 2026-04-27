# Shared HyperPod Module

Deploys a SageMaker HyperPod cluster that joins an existing EKS cluster.
Uploads lifecycle scripts (e.g. WEKA hugepages + NIC configuration) to S3
and references them in the HyperPod cluster config. Used by
hyperpod-dedicated and hyperpod-axon deployment models.

## Usage

Each deployment model calls this module from its `terraform/hyperpod/`
directory. The wrapper is responsible for any deployment-specific
extras (e.g. an EFA-compliant security group) and passes the resulting
SG list through `security_group_ids`.

```hcl
module "hyperpod" {
  source = "../../../modules/hyperpod"

  hyperpod_cluster_name = var.hyperpod_cluster_name
  eks_cluster_arn       = var.eks_cluster_arn
  subnet_ids            = var.subnet_ids
  security_group_ids    = var.security_group_ids

  lifecycle_scripts_path = "${path.module}/../../lifecycle-scripts"

  s3_bucket_name = var.s3_bucket_name

  instance_groups = [{
    name           = "weka-clients"
    instance_type  = "ml.p4d.24xlarge"
    instance_count = 2
    labels         = { "weka.io/supports-clients" = "true" }
    taints = [{
      key    = "weka.io/client"
      value  = "true"
      effect = "NoSchedule"
    }]
  }]

  weka_hugepages_count = 4096
  weka_nic_count       = 3

  tags = var.tags
}
```

## Configuration

### Required Variables

| Variable | Type | Description |
| ---------- | ------ | ------------- |
| `eks_cluster_arn` | string | ARN of the EKS cluster that HyperPod nodes will join |
| `subnet_ids` | list(string) | Subnet IDs for HyperPod instances (private subnets in the same VPC as EKS) |
| `security_group_ids` | list(string) | Security groups attached to HyperPod instances. For EFA-enabled instance types (p4d, p5, etc.) at least one attached SG must allow all traffic to/from itself and must NOT have a 0.0.0.0/0 egress rule |
| `lifecycle_scripts_path` | string | Filesystem path to the directory containing lifecycle scripts |
| `s3_bucket_name` | string | S3 bucket for lifecycle scripts (created by this module by default) |

### Cluster Configuration

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `hyperpod_cluster_name` | string | `"weka-hyperpod"` | HyperPod cluster name |
| `auto_node_recovery` | bool | `true` | Auto-recover failed nodes |
| `tags` | map(string) | `{}` | Tags for all resources |

### S3 Lifecycle Scripts

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `create_s3_bucket` | bool | `true` | Create the S3 bucket (false = use existing). Created buckets have `force_destroy = true` |
| `s3_key_prefix` | string | `"hyperpod-lifecycle"` | S3 key prefix for uploaded scripts |

### IAM

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `create_sagemaker_execution_role` | bool | `true` | Create a SageMaker execution role |
| `sagemaker_execution_role_arn` | string | `null` | Existing role ARN (used when `create_sagemaker_execution_role = false`) |

### Instance Groups

`instance_groups` is a list of objects. Each entry creates a HyperPod
instance group whose nodes join the EKS cluster as workers. All groups
in a single module invocation share the same WEKA per-node configuration
(hugepages + NIC count); use separate module invocations for
heterogeneous requirements.

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
| `labels` | map(string) | `{}` | Kubernetes labels applied via `KubernetesConfig.Labels` |
| `taints` | list(object) | `[]` | Kubernetes taints applied via `KubernetesConfig.Taints`. Each entry: `{key, value, effect}` |
| `training_plan_arn` | string | `null` | ARN of a reserved-capacity [SageMaker training plan](https://docs.aws.amazon.com/sagemaker/latest/dg/reserve-capacity-with-training-plans.html) to attach this group to |
| `image_id` | string | `null` | Custom [HyperPod AMI](https://docs.aws.amazon.com/sagemaker/latest/dg/hyperpod-custom-ami-support.html) ID. Skip the DLAMI default; pair with stripped-down lifecycle scripts if hugepages / NIC setup is baked into the AMI |
| `on_start_deep_health_checks` | list(string) | `[]` | Deep health checks to run at node start; values: `"InstanceStress"`, `"InstanceConnectivity"`. GPU/accelerated instance types only |
| `min_instance_count` | number | `null` | Lower bound for auto-scaling / auto-recovery |

### WEKA Per-Node Configuration

Shared across all instance groups in a single module invocation.

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `weka_hugepages_count` | number | `2048` | 2 MiB hugepages allocated per node at boot |
| `weka_nic_count` | number | `0` | WEKA DPDK NICs per node. `0` = UDP mode (single-ENI types); raise for DPDK on multi-ENI types |

## Outputs

| Output | Description |
| ---------- | ------------- |
| `cluster_arn` | HyperPod cluster ARN |
| `cluster_name` | HyperPod cluster name |
| `sagemaker_execution_role_arn` | Execution role used by instances |
| `lifecycle_scripts_s3_uri` | S3 URI of uploaded scripts |

## Lifecycle Script Flow

The module uploads four files from `lifecycle_scripts_path` to S3:

| File | Purpose |
| ---- | ------- |
| `on_create.sh` | Entrypoint invoked by SageMaker at boot |
| `configure-weka-hugepages.sh` | Allocates 2 MiB hugepages, persists across reboots |
| `configure-hyperpod-nics.py` | Moves WEKA DPDK NICs from the SageMaker netns to the host |
| `weka-config.env.tftpl` | Terraform-rendered env file with `WEKA_HUGEPAGES_COUNT` and `WEKA_NIC_COUNT` |

After the cluster is created, HyperPod runs `on_create.sh` on each
instance at boot. The script sources `weka-config.env` and conditionally
invokes the hugepages and NIC scripts based on the variables it sets.

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
| awscc     | ~> 1.0  |
| time      | ~> 0.11 |
