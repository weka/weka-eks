# EKS Module (Dedicated)

Deploys an EKS cluster for running WEKA client workloads against an
external WEKA backend cluster.

## Prerequisites

- Terraform >= 1.6
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
| `additional_cluster_security_group_ids` | list(string) | `[]` | Additional SGs for EKS cluster |
| `authentication_mode` | string | `"API"` | EKS auth mode |
| `enabled_cluster_log_types` | list(string) | `["api", "audit", ...]` | Control plane log types |
| `admin_role_arn` | string | `null` | IAM role for cluster admin access |
| `tags` | map(string) | `{}` | Tags for all resources |

### Node Configuration

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `enable_ssm_access` | bool | `true` | Attach SSM policy to nodes |
| `additional_node_security_group_ids` | list(string) | `[]` | Additional SGs for nodes (e.g., WEKA backend SG) |
| `key_pair_name` | string | `null` | EC2 key pair for SSH (prefer SSM) |
| `enable_cluster_autoscaler` | bool | `false` | Add autoscaler labels to node groups |
| `cpu_manager_reconcile_period` | string | `"10s"` | Kubelet CPU manager reconcile period |
| `cluster_dns_ip` | string | `null` | Custom cluster DNS IP for kubelet |

### WEKA Operator IRSA

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `enable_weka_operator_irsa` | bool | `true` | Create IRSA role for operator ENI management |
| `weka_operator_namespace` | string | `"weka-operator-system"` | Operator service account namespace |
| `weka_operator_service_account` | string | `"weka-operator-controller-manager"` | Operator service account name |
| `enforce_eni_tag_conditions` | bool | `false` | Restrict ENI ops to tagged resources |
| `eni_tag_key` | string | `"weka.io/cluster"` | Tag key for ENI restrictions |
| `eni_tag_value` | string | `null` | Tag value (defaults to `cluster_name`) |

### Node Groups

Node groups are defined as a map. Each supports:

#### Required

| Attribute | Type | Description |
| ----------- | ------ | ------------- |
| `instance_types` | list(string) | EC2 instance types |
| `desired_size` | number | Desired node count |
| `min_size` | number | Minimum node count |
| `max_size` | number | Maximum node count |

#### Optional

| Attribute | Type | Default | Description |
| ----------- | ------ | --------- | ------------- |
| `disk_size` | number | `200` | Root volume (GiB) |
| `ami_type` | string | `"AL2023_x86_64_STANDARD"` | EKS AMI type |
| `capacity_type` | string | `"ON_DEMAND"` | `ON_DEMAND` or `SPOT` |
| `imds_hop_limit_2` | bool | `false` | IMDS hop limit 2 (required for ensure-nics) |
| `enable_cpu_manager_static` | bool | `false` | Kubelet static CPU manager for DPDK |
| `disable_hyperthreading` | bool | `false` | Disable HT (requires `core_count`) |
| `core_count` | number | `null` | Physical cores (required if HT disabled) |
| `hugepages_count` | number | `0` | 2 MiB hugepages allocated at boot |
| `labels` | map(string) | `{}` | Kubernetes labels |
| `taints` | list(object) | `[]` | Kubernetes taints |

**For WEKA client nodes, set:**

- `imds_hop_limit_2 = true` (required for ENI management)
- `enable_cpu_manager_static = true` (DPDK CPU allocation)
- `hugepages_count` (~768 pages per WEKA core)
- Label `weka.io/supports-clients = "true"`
- Taint `weka.io/client=true:NO_SCHEDULE` (optional, keeps non-WEKA pods off)

## Outputs

| Output | Description |
| ---------- | ------------- |
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | Control plane endpoint |
| `cluster_arn` | EKS cluster ARN |
| `cluster_version` | Kubernetes version |
| `cluster_certificate_authority_data` | Cluster CA certificate |
| `cluster_security_group_id` | AWS-managed cluster SG |
| `node_iam_role_arn` | Node IAM role ARN |
| `node_iam_role_name` | Node IAM role name |
| `oidc_provider_arn` | OIDC provider ARN (for IRSA) |
| `oidc_provider_url` | OIDC provider URL |
| `weka_operator_irsa_role_arn` | Operator IRSA role ARN (annotate SA with this) |
| `node_groups` | Node group details (id, arn, status) |
| `configure_kubectl` | kubectl configuration command |

## Architecture

**Two-tier node group design:**

1. **System nodes** -- Run Kubernetes components (CoreDNS, kube-proxy,
   VPC CNI), the WEKA operator controller, and CSI controller.
   No special labels or taints.

2. **Client nodes** -- Run WEKA client containers that connect to the
   external backend cluster. Labeled with `weka.io/supports-clients`
   and optionally tainted with `weka.io/client=true:NoSchedule`.
   IMDS hop limit set to 2, CPU manager enabled, hugepages pre-allocated.

The WEKA backend security group should be added to
`additional_node_security_group_ids` so client nodes can reach the
backend cluster.

## Post-Deployment

After `terraform apply`:

1. Install the WEKA Operator via Helm (with values for node agent tolerations)
2. Apply ensure-nics WekaPolicy
3. Apply WekaClient manifest
4. Install CSI plugin and create StorageClass
5. Verify hugepages (allocated at boot via launch template)

See the [main README](../../README.md) for step-by-step instructions.

## Requirements

| Name      | Version |
| --------- | ------- |
| terraform | >= 1.6  |
| aws       | ~> 6.0  |
| tls       | ~> 4.0  |
