# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "region" {
  description = "AWS region"
  type        = string
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
variable "cluster_name" {
  description = "Name of the WEKA cluster"
  type        = string
}

variable "cluster_size" {
  description = "Number of WEKA backend instances (minimum 6)"
  type        = number
  default     = 6
}

variable "prefix" {
  description = "Prefix for WEKA resource names"
  type        = string
  default     = "weka"
}

# -----------------------------------------------------------------------------
# Instances
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type for WEKA backend nodes (i3en recommended)"
  type        = string
  default     = "i3en.2xlarge"
}

variable "key_pair_name" {
  description = "EC2 Key Pair name for SSH access"
  type        = string
}

variable "assign_public_ip" {
  description = "Assign public IP addresses to WEKA instances"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# WEKA Software
# -----------------------------------------------------------------------------
variable "weka_version" {
  description = "WEKA software version"
  type        = string
  default     = "4.4.21.2"
}

variable "get_weka_io_token" {
  description = "Token for downloading WEKA software from get.weka.io"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
variable "subnet_ids" {
  description = "List of subnet IDs for WEKA backend instances"
  type        = list(string)
}

variable "sg_ids" {
  description = "List of security group IDs to attach to WEKA instances"
  type        = list(string)
  default     = []
}

variable "create_nat_gateway" {
  description = "Create NAT gateway (set false if subnets already have NAT)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# ALB
# -----------------------------------------------------------------------------
variable "create_alb" {
  description = "Create Application Load Balancer for WEKA cluster"
  type        = bool
  default     = true
}

variable "alb_additional_subnet_id" {
  description = "Additional subnet ID for ALB (must be in different AZ from subnet_ids)"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# WEKA Options
# -----------------------------------------------------------------------------
variable "set_dedicated_fe_container" {
  description = "Use dedicated frontend containers"
  type        = bool
  default     = false
}

variable "data_services_number" {
  description = "Number of data service instances"
  type        = number
  default     = 0
}

# -----------------------------------------------------------------------------
# Tiering (Object Store)
# -----------------------------------------------------------------------------
variable "tiering_enable_obs_integration" {
  description = "Enable S3 object store integration for tiering"
  type        = bool
  default     = false
}

variable "tiering_obs_name" {
  description = "S3 bucket name for WEKA tiering"
  type        = string
  default     = ""
}

variable "tiering_enable_ssd_percent" {
  description = "Percentage of capacity for SSD tier (0-100)"
  type        = number
  default     = 20

  validation {
    condition     = var.tiering_enable_ssd_percent >= 0 && var.tiering_enable_ssd_percent <= 100
    error_message = "SSD percentage must be between 0 and 100."
  }
}

# -----------------------------------------------------------------------------
# Secrets Manager
# -----------------------------------------------------------------------------
variable "secretmanager_use_vpc_endpoint" {
  description = "Use VPC endpoint for AWS Secrets Manager"
  type        = bool
  default     = true
}

variable "secretmanager_create_vpc_endpoint" {
  description = "Create VPC endpoint for Secrets Manager (set false if it exists)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# IAM (use existing roles)
# -----------------------------------------------------------------------------
variable "instance_iam_profile_arn" {
  description = "ARN of existing IAM instance profile for WEKA instances"
  type        = string
  default     = null
}

variable "lambda_iam_role_arn" {
  description = "ARN of existing IAM role for Lambda functions"
  type        = string
  default     = null
}

variable "sfn_iam_role_arn" {
  description = "ARN of existing IAM role for Step Functions"
  type        = string
  default     = null
}

variable "event_iam_role_arn" {
  description = "ARN of existing IAM role for CloudWatch Events"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------
variable "tags_map" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
