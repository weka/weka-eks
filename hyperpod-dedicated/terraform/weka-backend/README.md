# WEKA Backend (HyperPod Dedicated)

Deploys a standalone WEKA storage cluster. This is a thin wrapper
around the shared [modules/weka-backend](../../../modules/weka-backend/)
module.

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

## Configuration

See the shared module [README](../../../modules/weka-backend/README.md)
for the full variable and output reference.

## Post-Deployment

Save these outputs for the EKS module:

```bash
# Security group IDs (use in additional_security_group_ids)
terraform output -json weka_deployment_output | jq -r '.sg_ids[]'

# Secrets Manager ARN for WEKA admin password
terraform output -json weka_deployment_output | jq -r '.cluster_helper_commands.get_password'
```

## Requirements

| Name | Version |
| --------- | ------- |
| terraform | >= 1.5 |
| aws | ~> 6.0 |
