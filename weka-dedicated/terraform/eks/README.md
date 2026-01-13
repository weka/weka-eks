# EKS Module

This module creates an Amazon EKS cluster with configurable node groups, optimized for WEKA storage integration.

## Features

- EKS cluster with configurable authentication mode
- OIDC provider for IAM Roles for Service Accounts (IRSA)
- Flexible node group configuration with AL2023 AMIs
- Support for IMDS hop limit (required for WEKA ensure-nics)
- Security group configuration for WEKA cluster access
- Optional SSM access for debugging
- Optional cluster autoscaler labels

## Usage

```hcl
module "eks" {
  source = "./terraform/eks"

  region          = "us-west-2"
  cluster_name    = "my-eks-cluster"
  cluster_version = "1.33"
  subnet_ids      = ["subnet-xxxxx", "subnet-yyyyy"]

  node_groups = {
    system = {
      instance_types = ["t3.large"]
      desired_size   = 2
      min_size       = 2
      max_size       = 5
      disk_size      = 100
      labels = {
        "workload-type" = "system"
      }
    }

    weka_clients = {
      instance_types   = ["c6i.12xlarge"]
      desired_size     = 2
      min_size         = 1
      max_size         = 10
      disk_size        = 100
      imds_hop_limit_2 = true  # Required for ensure-nics
      labels = {
        "weka.io/supports-clients" = "true"
      }
    }
  }

  # Add WEKA backend security group to allow client-backend communication
  additional_node_security_group_ids = ["sg-xxxxx"]

  tags = {
    Environment = "production"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| region | AWS region | `string` | n/a | yes |
| cluster_name | Name of the EKS cluster | `string` | n/a | yes |
| cluster_version | Kubernetes version | `string` | `"1.33"` | no |
| subnet_ids | Subnet IDs for EKS cluster and nodes | `list(string)` | n/a | yes |
| endpoint_private_access | Enable private API server endpoint | `bool` | `true` | no |
| endpoint_public_access | Enable public API server endpoint | `bool` | `true` | no |
| public_access_cidrs | CIDR blocks for public API endpoint | `list(string)` | `["0.0.0.0/0"]` | no |
| additional_cluster_security_group_ids | Additional SGs for EKS cluster | `list(string)` | `[]` | no |
| authentication_mode | EKS auth mode (API, CONFIG_MAP, API_AND_CONFIG_MAP) | `string` | `"API"` | no |
| enabled_cluster_log_types | Control plane log types to enable | `list(string)` | `["api", "audit", ...]` | no |
| node_groups | Node group configurations | `map(object)` | `{}` | no |
| key_pair_name | EC2 key pair for SSH access | `string` | `null` | no |
| additional_node_security_group_ids | Additional SGs for nodes (e.g., WEKA backend) | `list(string)` | `[]` | no |
| enable_ssm_access | Attach SSM policy to nodes | `bool` | `false` | no |
| enable_cluster_autoscaler | Add autoscaler labels to node groups | `bool` | `false` | no |
| admin_role_arn | IAM role ARN for cluster admin access | `string` | `null` | no |
| tags | Tags for all resources | `map(string)` | `{}` | no |

## Node Group Configuration

Each node group supports:

| Field | Description | Default |
|-------|-------------|---------|
| instance_types | List of EC2 instance types | Required |
| desired_size | Desired number of nodes | Required |
| min_size | Minimum number of nodes | Required |
| max_size | Maximum number of nodes | Required |
| disk_size | Root volume size in GB | Required |
| ami_type | AMI type | `"AL2023_x86_64_STANDARD"` |
| capacity_type | ON_DEMAND or SPOT | `"ON_DEMAND"` |
| imds_hop_limit_2 | Set IMDS hop limit to 2 (required for ensure-nics) | `false` |
| labels | Kubernetes labels | `{}` |
| taints | Node taints | `[]` |

### Example: WEKA Client Node Group

```hcl
weka_clients = {
  instance_types   = ["c6i.12xlarge"]
  desired_size     = 2
  min_size         = 1
  max_size         = 10
  disk_size        = 100
  imds_hop_limit_2 = true  # Required for ensure-nics to create ENIs
  labels = {
    "weka.io/supports-clients" = "true"
  }
  taints = []
}
```

## Outputs

| Name | Description |
|------|-------------|
| cluster_name | EKS cluster name |
| cluster_endpoint | EKS control plane endpoint |
| cluster_certificate_authority_data | Cluster CA certificate |
| oidc_provider_arn | OIDC provider ARN for IRSA |

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| aws | ~> 5.0 |

## Notes

- WEKA clients require `imds_hop_limit_2 = true` for the ensure-nics policy to work
- Add the WEKA backend security group to `additional_node_security_group_ids` for client-backend communication
- Use `weka.io/supports-clients = "true"` label for WEKA client node selection
