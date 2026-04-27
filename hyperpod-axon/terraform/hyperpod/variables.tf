variable "region" {
  description = "AWS region"
  type        = string
}

variable "hyperpod_cluster_name" {
  description = "Name of the SageMaker HyperPod cluster"
  type        = string
  default     = "weka-axon-hyperpod"
}

# -----------------------------------------------------------------------------
# EKS integration
# -----------------------------------------------------------------------------
variable "eks_cluster_arn" {
  description = "ARN of the EKS cluster that HyperPod nodes will join"
  type        = string
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
variable "subnet_ids" {
  description = "Subnet IDs for HyperPod instances (private subnets in the same VPC as EKS)"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID to attach to HyperPod instances (should allow intra-node WEKA + EKS traffic)"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block of the HyperPod subnets (used by NIC configuration script, e.g. 10.0.0.0/22)"
  type        = string
}

# -----------------------------------------------------------------------------
# S3 lifecycle scripts
# -----------------------------------------------------------------------------
variable "s3_bucket_name" {
  description = "Existing S3 bucket for lifecycle scripts (no bucket is created)"
  type        = string
}

variable "s3_key_prefix" {
  description = "S3 key prefix for lifecycle script uploads"
  type        = string
  default     = "hyperpod-axon-lifecycle"
}

# -----------------------------------------------------------------------------
# IAM
# -----------------------------------------------------------------------------
variable "create_sagemaker_execution_role" {
  description = "Create a SageMaker execution role. Set false to use an existing role."
  type        = bool
  default     = true
}

variable "sagemaker_execution_role_arn" {
  description = "ARN of an existing SageMaker execution role (only used if create_sagemaker_execution_role = false)"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Instance groups
# -----------------------------------------------------------------------------
variable "instance_groups" {
  description = <<-EOT
    HyperPod instance groups for WEKA Axon nodes. Each group creates
    instances that run both WEKA backend and client containers.

    Sizing guidance:
    - weka_nic_count: typically 1 per compute core + 1 per drive core
    - weka_hugepages_count: see README for formula based on cores and capacity
    - threads_per_core: set to 1 to disable hyperthreading (recommended for WEKA backends)
  EOT

  type = list(object({
    name                  = string
    instance_type         = string
    instance_count        = number
    ebs_volume_size_in_gb = optional(number, 500)
    threads_per_core      = optional(number, 1)
    weka_nic_count        = optional(number, 7)
    weka_hugepages_count  = optional(number, 5376)
  }))

  default = [{
    name                 = "weka-axon"
    instance_type        = "ml.p5.48xlarge"
    instance_count       = 6
    weka_nic_count       = 7
    weka_hugepages_count = 5376
  }]
}

# -----------------------------------------------------------------------------
# Cluster settings
# -----------------------------------------------------------------------------
variable "auto_node_recovery" {
  description = "Enable automatic node recovery for failed instances"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
