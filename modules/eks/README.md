# Shared EKS Module

Deploys an EKS cluster with configurable node groups, optional launch
templates. Used by all deployment models.

## Usage

Each deployment model calls this module from its `terraform/eks/` directory.
Below are examples of how the EKS module can be used with different WEKA
deployment types.

### weka-dedicated (system + client nodes)

```hcl
module "eks" {
  source = "../../../modules/eks"

  region       = var.region
  cluster_name = var.cluster_name
  subnet_ids   = var.subnet_ids

  additional_security_group_ids = var.additional_security_group_ids

  node_groups = {
    system = {
      instance_types = ["m6i.large"]
      desired_size   = 2
      min_size       = 1
      max_size       = 3
      disk_size      = 50
    }

    clients = {
      instance_types            = ["c6i.12xlarge"]
      desired_size              = 2
      min_size                  = 1
      max_size                  = 4
      subnet_ids                = ["subnet-xxx"] # Same AZ as WEKA backend
      imds_hop_limit_2          = true
      enable_cpu_manager_static = true
      hugepages_count           = 2048
      labels = {
        "weka.io/supports-clients" = "true"
      }
      taints = [{
        key    = "weka.io/client"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  tags = var.tags
}
```

### weka-axon (system + storage nodes)

```hcl
module "eks" {
  source = "../../../modules/eks"

  region       = var.region
  cluster_name = var.cluster_name
  subnet_ids   = var.subnet_ids

  create_weka_nodes_security_group = true

  node_groups = {
    system = {
      instance_types = ["m6i.large"]
      desired_size   = 2
      min_size       = 2
      max_size       = 2
      labels         = { "node-role" = "system" }
    }

    axon = {
      instance_types            = ["i3en.12xlarge"]
      desired_size              = 6
      min_size                  = 6
      max_size                  = 6
      disk_size                 = 200
      imds_hop_limit_2          = true
      enable_cpu_manager_static = true
      disable_hyperthreading    = true
      core_count                = 24
      hugepages_count           = 2048
      labels = {
        "weka.io/supports-backends" = "true"
        "weka.io/supports-clients"  = "true"
      }
      taints = [{
        key    = "weka.io/axon"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  tags = var.tags
}
```

### hyperpod-dedicated / hyperpod-axon (system nodes only)

```hcl
module "eks" {
  source = "../../../modules/eks"

  region       = var.region
  cluster_name = var.cluster_name
  subnet_ids   = var.subnet_ids

  additional_security_group_ids = var.additional_security_group_ids

  node_groups = {
    system = {
      instance_types = ["t3.large"]
      desired_size   = 2
      min_size       = 2
      max_size       = 5
      labels         = { "node-role" = "system" }
    }
  }

  tags = var.tags
}
```

Worker nodes are added by SageMaker HyperPod, not this module.

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

### Node Groups

Node groups are defined as a map. Each entry creates an EKS managed
node group with an optional launch template (auto-created when needed).

#### Required per group

| Attribute | Type | Description |
| ----------- | ------ | ------------- |
| `instance_types` | list(string) | EC2 instance types |
| `desired_size` | number | Desired node count |
| `min_size` | number | Minimum node count |
| `max_size` | number | Maximum node count |

#### Optional per group

| Attribute | Type | Default | Description |
| ----------- | ------ | --------- | ------------- |
| `subnet_ids` | list(string) | `null` | Override subnets for this group (defaults to cluster subnets) |
| `disk_size` | number | `100` | Root volume (GiB) |
| `ami_type` | string | `"AL2023_x86_64_STANDARD"` | EKS AMI type |
| `capacity_type` | string | `"ON_DEMAND"` | `ON_DEMAND` or `SPOT` |
| `imds_hop_limit_2` | bool | `false` | IMDS hop limit 2 (required for ensure-nics) |
| `enable_cpu_manager_static` | bool | `false` | Kubelet static CPU manager for DPDK |
| `disable_hyperthreading` | bool | `false` | Disable HT (requires `core_count`) |
| `core_count` | number | `null` | Physical cores (required if HT disabled) |
| `hugepages_count` | number | `0` | 2 MiB hugepages allocated at boot |
| `labels` | map(string) | `{}` | Kubernetes labels |
| `taints` | list(object) | `[]` | Kubernetes taints |

A launch template is automatically created for any node group that
sets `imds_hop_limit_2`, `enable_cpu_manager_static`,
`disable_hyperthreading`, `hugepages_count > 0`, or when
`additional_security_group_ids` or `create_weka_nodes_security_group`
are set.

**For WEKA client nodes (dedicated mode):**

- `subnet_ids` to the WEKA backend subnet (same AZ / placement group)
- `imds_hop_limit_2 = true` (required for ENI management)
- `enable_cpu_manager_static = true` (DPDK CPU allocation)
- `hugepages_count` (~768 pages per WEKA core)
- Label `weka.io/supports-clients = "true"`
- Taint `weka.io/client=true:NO_SCHEDULE` (optional)

**For WEKA axon nodes (converged mode):**

- All of the above, plus:
- `disable_hyperthreading = true` with `core_count` set
- Label `weka.io/supports-backends = "true"`
- Taint `weka.io/axon=true:NO_SCHEDULE` (recommended)

### Node Configuration

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `enable_ssm_access` | bool | `true` | Attach SSM policy to nodes |
| `key_pair_name` | string | `null` | EC2 key pair for SSH (prefer SSM) |
| `enable_cluster_autoscaler` | bool | `false` | Add autoscaler labels to node groups |
| `cpu_manager_reconcile_period` | string | `"10s"` | Kubelet CPU manager reconcile period |
| `cluster_dns_ip` | string | `null` | Custom cluster DNS IP for kubelet |
| `create_weka_nodes_security_group` | bool | `false` | Self-referencing SG for WEKA intra-node traffic (axon mode) |

## Outputs

| Output | Description |
| ---------- | ------------- |
| `cluster_id` | EKS cluster ID |
| `cluster_name` | EKS cluster name |
| `cluster_arn` | EKS cluster ARN |
| `cluster_endpoint` | Control plane endpoint |
| `cluster_version` | Kubernetes version |
| `cluster_certificate_authority_data` | Cluster CA certificate |
| `cluster_security_group_id` | AWS-managed cluster SG |
| `node_iam_role_arn` | Node IAM role ARN |
| `node_iam_role_name` | Node IAM role name |
| `node_groups` | Node group details (id, arn, status) |
| `weka_nodes_security_group_id` | WEKA intra-node SG (null if not created) |
| `configure_kubectl` | kubectl configuration command |

## Launch Templates

Launch templates are created automatically for node groups that need
custom configuration. When a launch template is present, the module
attaches:

- The EKS cluster security group
- The WEKA intra-node SG (if `create_weka_nodes_security_group = true`)
- Any `additional_security_group_ids`

The nodeadm user data template configures (when applicable):

- **Hugepages**: Shell script that allocates 2 MiB hugepages and
  creates a systemd service to persist across reboots
- **CPU manager**: Kubelet static CPU manager policy for DPDK
- **Cluster DNS**: Custom kubelet cluster DNS IP

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.5  |
| aws       | ~> 6.0  |
