# EKS Axon Terraform Module

This Terraform configuration deploys an Amazon EKS cluster optimized for WEKA Axon deployments. The root module is a thin wrapper around the [eks-axon](modules/eks-axon) module, which creates all the necessary AWS infrastructure for running WEKA storage and application workloads on the same Kubernetes nodes.

## Overview

The deployment creates:

- EKS cluster with configurable Kubernetes version
- Multiple managed node groups (system nodes and storage/Axon nodes)
- IAM roles and policies for EKS cluster and worker nodes
- Optional IRSA (IAM Roles for Service Accounts) for WEKA operator
- Optional self-referencing security group for WEKA node-to-node traffic
- Launch templates with customizable configurations (IMDS, CPU Manager, hyperthreading)
- EKS Access Entry for cluster administration

## Module Structure

```bash
terraform/
├── main.tf                    # Root module - instantiates eks-axon module
├── variables.tf               # Root-level input variables
├── outputs.tf                 # Outputs (cluster name, kubectl config, IRSA role ARN)
├── providers.tf               # AWS provider configuration
├── versions.tf                # Terraform version constraints
├── terraform.tfvars.example   # Example configuration template
└── modules/
    └── eks-axon/              # Core EKS infrastructure module
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── nodeadm-userdata.yaml.tftpl
```

## Prerequisites

- Terraform >= 1.6.0
- AWS CLI configured with appropriate credentials
- Existing VPC with subnets (private subnets recommended)
- IAM permissions to create EKS, EC2, IAM resources

## Quick Start

1. Copy the example configuration:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your configuration (see [Configuration](#configuration) below)

3. Initialize and apply:

   ```bash
   terraform init
   terraform apply
   ```

4. Configure kubectl:

   ```bash
   $(terraform output -raw configure_kubectl)
   # or manually:
   # aws eks update-kubeconfig --name <cluster-name> --region <region>
   ```

## Configuration

### Required Variables

| Variable | Type | Description |
| ---------- | ------ | ------------- |
| `region` | string | AWS region for all resources |
| `cluster_name` | string | Name of the EKS cluster |
| `subnet_ids` | list(string) | List of subnet IDs for EKS control plane and worker nodes. All subnets must be in the same VPC. Private subnets recommended. |
| `node_groups` | map(object) | Map of node group configurations (see [Node Groups](#node-groups) below) |

### Optional Variables

#### Cluster Configuration

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `cluster_version` | string | `"1.33"` | Kubernetes version for EKS cluster |
| `endpoint_private_access` | bool | `true` | Enable private API server endpoint |
| `endpoint_public_access` | bool | `true` | Enable public API server endpoint |
| `public_access_cidrs` | list(string) | `["0.0.0.0/0"]` | CIDR blocks allowed to access public API endpoint |
| `admin_role_arn` | string | `null` | IAM role ARN to grant cluster-admin access via EKS Access Entry |
| `tags` | map(string) | `{}` | Tags to apply to all resources |

#### Node Configuration

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `ssm_access` | bool | `true` | Attach AmazonSSMManagedInstanceCore policy to node IAM role for SSM access |
| `create_weka_nodes_security_group` | bool | `true` | Create self-referencing security group for WEKA intra-node traffic |
| `cluster_dns_ip` | string | `null` | Explicit Cluster DNS IP for kubelet. If null, uses EKS default derived from service CIDR |

#### WEKA Operator IRSA

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `enable_weka_operator_irsa` | bool | `true` | Create IRSA role/policy for WEKA operator to perform ENI operations |
| `weka_operator_namespace` | string | `"weka-operator-system"` | Namespace where WEKA operator service account runs |
| `weka_operator_service_account` | string | `"weka-operator-controller-manager"` | Service account name for WEKA operator |
| `enforce_eni_tag_conditions` | bool | `false` | Restrict ENI operations to tagged resources (requires controller to tag ENIs) |
| `eni_tag_key` | string | `"weka.io/cluster"` | Tag key for ENI restriction conditions (only used if `enforce_eni_tag_conditions = true`) |
| `eni_tag_value` | string | `null` | Tag value for ENI restrictions. Defaults to `cluster_name` if null |

### Node Groups

Node groups are defined as a map, allowing multiple groups with different configurations. Each node group supports the following attributes:

#### Required Node Group Attributes

| Attribute | Type | Description |
| ----------- | ------ | ------------- |
| `instance_types` | list(string) | List of EC2 instance types |
| `desired_size` | number | Desired number of nodes |
| `min_size` | number | Minimum number of nodes |
| `max_size` | number | Maximum number of nodes |

#### Optional Node Group Attributes

| Attribute | Type | Default | Description |
| ----------- | ------ | --------- | ------------- |
| `disk_size` | number | `200` | Root EBS volume size in GiB (WEKA data lives on local NVMe) |
| `labels` | map(string) | `{}` | Kubernetes labels to apply to nodes |
| `taints` | list(object) | `[]` | Kubernetes taints (each with `key`, `value`, `effect`) |
| `imds_hop_limit_2` | bool | `false` | Set IMDS hop limit to 2 (required for WEKA ensure-nics on AL2023) |
| `capacity_type` | string | `"ON_DEMAND"` | Capacity type: `ON_DEMAND` or `SPOT` |
| `ami_type` | string | `"AL2023_x86_64_STANDARD"` | EKS AMI type |
| `enable_cpu_manager_static` | bool | `false` | Enable kubelet CPU Manager static policy via nodeadm |
| `disable_hyperthreading` | bool | `false` | Disable hyperthreading via CPU core count |
| `core_count` | number | `null` | Number of CPU cores (required if `disable_hyperthreading = true`) |

**Important Notes for WEKA Axon Nodes:**

- Set `labels` to include `"weka.io/supports-backends" = "true"` and `"weka.io/supports-clients" = "true"`
- Add taint `weka.io/axon=true:NoSchedule` to prevent non-WEKA workloads from scheduling
- Set `imds_hop_limit_2 = true` (required for WEKA operator's ensure-nics policy on AL2023)
- Set `enable_cpu_manager_static = true` for DPDK and dedicated CPU allocation
- For disabling hyperthreading, set both `disable_hyperthreading = true` and specify `core_count`

## Outputs

| Output | Description |
| -------- | ------------- |
| `cluster_name` | Name of the EKS cluster |
| `cluster_endpoint` | EKS cluster API endpoint |
| `cluster_certificate_authority_data` | Base64 encoded certificate data |
| `configure_kubectl` | Command to configure kubectl for cluster access |
| `weka_operator_irsa_role_arn` | ARN of the IRSA role for WEKA operator (if `enable_weka_operator_irsa = true`) |
| `weka_nodes_security_group_id` | ID of the WEKA nodes security group (if `create_weka_nodes_security_group = true`) |

## Example Configuration

This example creates an EKS cluster with two node groups: a small system node group for Kubernetes control plane components, and a storage node group for WEKA Axon workloads.

```hcl
# Core Configuration
region       = "us-west-2"
cluster_name = "weka-axon-eks"

# IAM role ARN to grant cluster-admin via EKS Access Entry
admin_role_arn = "arn:aws:iam::123456789012:role/MyAdminRole"

# Networking - Use private subnets for worker nodes (recommended)
subnet_ids = [
  "subnet-06642a31e7fa6e576",
  "subnet-011568261cfd7311b",
  "subnet-06bbea6cb1bb7be01"
]

# Enable SSM access instead of SSH
ssm_access = true

# Node Groups
node_groups = {
  # Small system nodes for Kubernetes control plane components
  system = {
    instance_types = ["m6i.large"]
    desired_size   = 2
    min_size       = 2
    max_size       = 2
    labels = {
      "node-role" = "system"
    }
    ami_type = "AL2023_x86_64_STANDARD"
  }

  # Large storage nodes for WEKA Axon
  storage = {
    instance_types = ["i3en.12xlarge"]
    desired_size   = 6
    min_size       = 6
    max_size       = 6

    # Root volume size (WEKA data uses local NVMe)
    disk_size = 200

    # Required for WEKA ensure-nics to access IMDS from pods
    imds_hop_limit_2 = true

    # Enable kubelet CPU Manager static policy for DPDK
    enable_cpu_manager_static = true

    # Disable hyperthreading for consistent CPU performance
    disable_hyperthreading = true
    core_count             = 24

    # AMI type
    ami_type = "AL2023_x86_64_STANDARD"

    # Labels for WEKA operator scheduling
    labels = {
      "weka.io/supports-backends" = "true"
      "weka.io/supports-clients"  = "true"
    }

    # Prevent non-WEKA workloads from scheduling on these nodes
    taints = [{
      key    = "weka.io/axon"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }
}

# Tags
tags = {
  Environment = "dev"
  Project     = "weka-eks"
  Owner       = "Platform Team"
}

# Optional Cluster Settings
cluster_version         = "1.33"
endpoint_private_access = true
endpoint_public_access  = true
public_access_cidrs     = ["0.0.0.0/0"]

# Create self-referencing security group for WEKA traffic
create_weka_nodes_security_group = true

# Cluster DNS (usually not needed; leave null to use EKS defaults)
cluster_dns_ip = null

# WEKA Operator IRSA Configuration
enable_weka_operator_irsa     = true
weka_operator_namespace       = "weka-operator-system"
weka_operator_service_account = "weka-operator-controller-manager"

# Optional ENI tag-based restrictions (more secure)
enforce_eni_tag_conditions = false
```

## Architecture

### Node Group Design

This configuration supports a **two-tier node group architecture**:

1. **System Node Group**
   - Smaller instance types (e.g., m6i.large)
   - Runs Kubernetes control plane components (CoreDNS, kube-proxy, AWS VPC CNI)
   - Runs WEKA operator controller
   - Runs CSI controller pods
   - No special taints or labels required

2. **Storage/Axon Node Group**
   - Large instances with local NVMe storage (e.g., i3en.12xlarge, p5.48xlarge)
   - Runs WEKA backend pods (drive + compute containers)
   - Runs WEKA client pods (frontend)
   - Runs application workloads that mount WEKA volumes
   - Labeled with `weka.io/supports-backends` and `weka.io/supports-clients`
   - Tainted with `weka.io/axon=true:NoSchedule` to prevent unwanted scheduling
   - IMDS hop limit set to 2 for ENI access from pods
   - CPU Manager static policy enabled for DPDK support

### Security Groups

When `create_weka_nodes_security_group = true` (default), a self-referencing security group is created and attached to nodes with the `weka.io/axon` taint. This allows unrestricted communication between WEKA nodes for high-throughput storage traffic.

### IRSA for WEKA Operator

When `enable_weka_operator_irsa = true` (default), an IAM role is created that allows the WEKA operator to:

- Describe EC2 instances and network interfaces
- Create, attach, and delete ENIs for WEKA DPDK networking
- Optionally restrict operations to tagged resources when `enforce_eni_tag_conditions = true`

The role uses OIDC federation to allow the WEKA operator's Kubernetes service account to assume it without long-lived credentials.

## Post-Deployment Steps

After deploying the infrastructure with Terraform, you'll need to:

1. Install the WEKA Operator and CSI plugin via Helm
2. Apply WEKA custom resources (WekaCluster, WekaClient)
3. Configure hugepages via DaemonSet
4. Apply WEKA policies for ENI creation and drive signing

See the [main project README](../README.md) for detailed post-deployment instructions.

## Cleanup

To destroy all resources:

```bash
# From the terraform directory
terraform destroy
```

**Warning:** This will delete the EKS cluster and all associated resources. Ensure you've backed up any important data before proceeding.

## Additional Resources

- [WEKA Kubernetes Operator Documentation](https://docs.weka.io/kubernetes/weka-operator-deployments)
- [WEKA CSI Plugin Documentation](https://docs.weka.io/appendices/weka-csi-plugin)
- [Amazon EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Kubernetes CPU Manager](https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/)
