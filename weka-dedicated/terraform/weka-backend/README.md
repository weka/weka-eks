# WEKA Backend Storage Module

This module deploys a WEKA storage cluster using the official [WEKA AWS Terraform module](https://registry.terraform.io/modules/weka/weka/aws/latest). It provides a simplified wrapper with sensible defaults for EKS integration.

## Features

- WEKA storage cluster deployment with configurable size
- Application Load Balancer for client access
- Optional S3 tiering for cost-effective capacity expansion
- Integration with existing VPC and security groups
- Support for existing IAM roles or automatic role creation
- Secrets Manager integration for secure credential storage

## Prerequisites

1. **WEKA Token** - Get from [get.weka.io](https://get.weka.io)
2. **VPC & Subnets** - Existing VPC with subnets
3. **IAM Roles** - Either existing roles or permissions to create them
4. **S3 Bucket** - (Optional) For tiering/object store integration

## Usage

```hcl
module "weka_backend" {
  source = "./modules/weka-backend"

  cluster_name = "my-weka-cluster"
  cluster_size = 6
  instance_type = "i3en.2xlarge"
  weka_version = "4.4.21.2"

  get_weka_io_token = var.weka_token
  key_pair_name     = "my-keypair"

  # Network Configuration
  vpc_id             = "vpc-xxxxx"
  subnet_ids         = ["subnet-xxxxx"]
  alb_subnet_ids     = ["subnet-xxxxx", "subnet-yyyyy"]
  security_group_ids = ["sg-xxxxx"]

  create_alb         = true
  assign_public_ip   = false
  create_nat_gateway = false

  # Tiering Configuration
  tiering_enable_obs_integration = true
  tiering_obs_name               = "my-weka-tiering-bucket"
  tiering_enable_ssd_percent     = 20

  # IAM Roles (use existing)
  instance_iam_profile_arn = "arn:aws:iam::123456789012:instance-profile/weka-instance-profile"
  lambda_iam_role_arn      = "arn:aws:iam::123456789012:role/weka-lambda-role"
  sfn_iam_role_arn         = "arn:aws:iam::123456789012:role/weka-state-machine-role"
  event_iam_role_arn       = "arn:aws:iam::123456789012:role/weka-events-role"

  tags = {
    Environment = "production"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| cluster_name | WEKA cluster name | `string` | `"eks-test"` | no |
| cluster_size | Number of backend instances | `number` | `6` | no |
| instance_type | Instance type | `string` | `"i3en.2xlarge"` | no |
| weka_version | WEKA software version | `string` | `"4.4.21.2"` | no |
| get_weka_io_token | WEKA download token | `string` | n/a | yes |
| vpc_id | VPC ID | `string` | n/a | yes |
| subnet_ids | Subnet IDs for WEKA instances | `list(string)` | n/a | yes |
| alb_subnet_ids | Subnet IDs for ALB | `list(string)` | `[]` | no |
| security_group_ids | Existing security group IDs | `list(string)` | `[]` | no |
| create_alb | Create ALB | `bool` | `true` | no |
| key_pair_name | EC2 key pair name | `string` | n/a | yes |
| tiering_enable_obs_integration | Enable S3 tiering | `bool` | `false` | no |
| tiering_obs_name | S3 bucket for tiering | `string` | `""` | no |
| tiering_enable_ssd_percent | SSD tier percentage | `number` | `20` | no |
| instance_iam_profile_arn | IAM instance profile ARN | `string` | `null` | no |
| lambda_iam_role_arn | Lambda IAM role ARN | `string` | `null` | no |
| sfn_iam_role_arn | Step Functions IAM role ARN | `string` | `null` | no |
| event_iam_role_arn | CloudWatch Events IAM role ARN | `string` | `null` | no |
| tags | Resource tags | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| cluster_name | WEKA cluster name |
| alb_dns_name | ALB DNS name (for EKS client connection) |
| alb_arn | ALB ARN |
| security_group_ids | Security group IDs |
| primary_security_group_id | Primary SG ID (for EKS integration) |
| weka_version | WEKA version deployed |
| cluster_size | Number of backend instances |
| tiering_enabled | Tiering enabled status |

## Instance Types

Recommended instance types for WEKA backend:

| Instance Type | vCPUs | Memory | NVMe Storage | Network |
|---------------|-------|--------|--------------|---------|
| i3en.2xlarge  | 8     | 64 GB  | 2 x 2.5 TB   | Up to 25 Gbps |
| i3en.3xlarge  | 12    | 96 GB  | 1 x 7.5 TB   | Up to 25 Gbps |
| i3en.6xlarge  | 24    | 192 GB | 2 x 7.5 TB   | 25 Gbps |
| i3en.12xlarge | 48    | 384 GB | 4 x 7.5 TB   | 50 Gbps |
| i3en.24xlarge | 96    | 768 GB | 8 x 7.5 TB   | 100 Gbps |

## S3 Tiering

WEKA supports tiering cold data to S3 for cost savings:

- **SSD Tier**: Hot data on local NVMe drives
- **Object Store Tier**: Cold data in S3
- **Automatic**: WEKA automatically moves data between tiers

Example configuration:
```hcl
tiering_enable_obs_integration = true
tiering_obs_name               = "my-weka-tiering-bucket"
tiering_enable_ssd_percent     = 20  # 20% SSD, 80% S3
```

## IAM Roles

You can either:

### Option 1: Use Existing Roles (Recommended)
Provide ARNs for existing roles with appropriate permissions.

### Option 2: Let WEKA Module Create Roles
Omit the IAM role ARNs and set `create_iam_roles = true`.

Required permissions for IAM roles are documented in the [WEKA AWS module](https://registry.terraform.io/modules/weka/weka/aws/latest).

## Security Groups

The WEKA module creates security groups automatically. You can also provide existing security group IDs via `security_group_ids`.

Required ports:
- **14000-14999**: WEKA cluster communication
- **3260**: iSCSI (if using block protocol)

## Accessing the WEKA Cluster

After deployment, access the cluster via the ALB:

```bash
# Get ALB DNS name
terraform output weka_backend_alb_dns_name

# Mount from client (example)
mount -t wekafs <ALB_DNS_NAME>/default /mnt/weka
```

For Kubernetes integration, use the ALB DNS name in the WEKA CSI driver configuration.

## Troubleshooting

### Check WEKA Cluster Status

```bash
# SSH to a WEKA instance
ssh -i <key-pair>.pem ec2-user@<instance-ip>

# Check cluster status
weka status

# Check filesystem
weka fs
```

### ALB Health Checks

```bash
# Check ALB target health
aws elbv2 describe-target-health --target-group-arn <target-group-arn>
```

### CloudWatch Logs

The WEKA deployment uses Lambda functions and Step Functions. Check CloudWatch Logs for deployment issues:
- `/aws/lambda/weka-*`
- `/aws/states/weka-*`

## Cost Optimization

1. **Right-size instances** - Start with smaller instances and scale up
2. **Use S3 tiering** - Move cold data to S3 for 90%+ cost savings
3. **Reserved Instances** - For production workloads
4. **Spot Instances** - Not recommended for WEKA storage nodes

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| aws | ~> 6.0 |
| weka/weka/aws | 1.0.23 |

## References

- [WEKA AWS Module Documentation](https://registry.terraform.io/modules/weka/weka/aws/latest)
- [WEKA Installation Guide](https://docs.weka.io)
- [WEKA Best Practices](https://docs.weka.io/planning-and-installation)
