# Shared WEKA Backend Module

Deploys a standalone WEKA storage cluster using the official
[WEKA AWS Terraform module](https://registry.terraform.io/modules/weka/weka/aws/latest).
Used by weka-dedicated and hyperpod-dedicated deployment models.

## Usage

Each deployment model calls this module from its
`terraform/weka-backend/` directory.

```hcl
module "weka_backend" {
  source = "../../../modules/weka-backend"

  cluster_name      = var.cluster_name
  cluster_size      = var.cluster_size
  instance_type     = var.instance_type
  weka_version      = var.weka_version
  get_weka_io_token = var.get_weka_io_token
  key_pair_name     = var.key_pair_name
  subnet_ids        = var.subnet_ids

  tags_map = var.tags_map
}
```

## Configuration

### Required Variables

| Variable | Type | Description |
| ---------- | ------ | ------------- |
| `cluster_name` | string | Name of the WEKA cluster |
| `key_pair_name` | string | EC2 Key Pair name for SSH access |
| `get_weka_io_token` | string | Token from [get.weka.io](https://get.weka.io) |
| `subnet_ids` | list(string) | Subnet IDs for WEKA backend instances |

### Cluster Configuration

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `cluster_size` | number | `6` | Number of backend instances (minimum 6) |
| `prefix` | string | `"weka"` | Prefix for WEKA resource names |
| `instance_type` | string | `"i3en.2xlarge"` | EC2 instance type |
| `assign_public_ip` | bool | `false` | Assign public IPs to instances |
| `weka_version` | string | `"4.4.21.2"` | WEKA software version |
| `tags_map` | map(string) | `{}` | Tags for all resources |

### Networking

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `sg_ids` | list(string) | `[]` | Existing security group IDs |
| `create_nat_gateway` | bool | `false` | Create NAT gateway (set true if subnets lack NAT) |
| `create_alb` | bool | `true` | Create Application Load Balancer |
| `alb_additional_subnet_id` | string | `null` | Additional ALB subnet (must be different AZ) |

### WEKA Options

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `set_dedicated_fe_container` | bool | `false` | Use dedicated frontend containers |
| `data_services_number` | number | `0` | Number of data service instances |

### Tiering

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `tiering_enable_obs_integration` | bool | `false` | Enable S3 object store tiering |
| `tiering_obs_name` | string | `""` | S3 bucket name for tiering |
| `tiering_enable_ssd_percent` | number | `20` | Percentage of capacity for SSD tier (0-100) |

### Secrets Manager

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `secretmanager_use_vpc_endpoint` | bool | `true` | Use VPC endpoint for Secrets Manager |
| `secretmanager_create_vpc_endpoint` | bool | `false` | Create VPC endpoint (set true if it doesn't exist) |

### IAM (optional -- use existing roles)

| Variable | Type | Default | Description |
| ---------- | ------ | --------- | ------------- |
| `instance_iam_profile_arn` | string | `null` | Existing IAM instance profile ARN |
| `lambda_iam_role_arn` | string | `null` | Existing IAM role for Lambda |
| `sfn_iam_role_arn` | string | `null` | Existing IAM role for Step Functions |
| `event_iam_role_arn` | string | `null` | Existing IAM role for CloudWatch Events |

## Outputs

| Output | Description |
| ---------- | ------------- |
| `weka_deployment_output` | Full output from the upstream WEKA module (includes SG IDs, ALB DNS, etc.) |

### Useful output queries

```bash
# Security group IDs (use in EKS additional_security_group_ids)
terraform output -json weka_deployment_output | jq -r '.sg_ids[]'

# Secrets Manager ARN for WEKA admin password
terraform output -json weka_deployment_output | jq -r '.weka_deployment_password_secret_id'
```

## Additional Options

This module exposes the most common variables. For the full list of
options (custom AMIs, protocol gateways, advanced networking, etc.),
see the [upstream module inputs](https://registry.terraform.io/modules/weka/weka/aws/latest?tab=inputs)
and add them to `modules/weka-backend/main.tf`.

## Requirements

| Name | Version |
| --------- | ------- |
| terraform | >= 1.5 |
| aws | ~> 6.0 |
| [weka/weka/aws](https://registry.terraform.io/modules/weka/weka/aws/latest) | 1.0.23 |
