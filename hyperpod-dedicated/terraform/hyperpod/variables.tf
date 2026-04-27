# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "region" {
  description = "AWS region"
  type        = string
}

variable "hyperpod_cluster_name" {
  description = "Name of the SageMaker HyperPod cluster"
  type        = string
  default     = "weka-hyperpod"
}

# -----------------------------------------------------------------------------
# EKS Integration
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

variable "create_efa_security_group" {
  description = <<-EOT
    Create an EFA-compliant security group (self-only ingress/egress) and
    attach it to HyperPod instances. Required for EFA-enabled instance types
    (p4d, p5, etc.) to pass HyperPod's EFA health check. Harmless on non-EFA
    instances. Set false if you're providing an EFA-compliant SG yourself
    via additional_security_group_ids.
  EOT
  type        = bool
  default     = true
}

variable "additional_security_group_ids" {
  description = "Security group IDs to attach to HyperPod instances. Typically the same SG attached to your EKS nodes and WEKA backend so cluster-wide traffic works via shared-SG self-rules."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# S3 Lifecycle Scripts
# -----------------------------------------------------------------------------
variable "s3_bucket_name" {
  description = "S3 bucket for lifecycle scripts. Created by this module if create_s3_bucket = true, otherwise must already exist. Bucket names are globally unique across all AWS accounts."
  type        = string
}

variable "create_s3_bucket" {
  description = "Create the S3 bucket for lifecycle scripts. Set false to use an existing bucket. Created buckets have force_destroy = true so terraform destroy can reclaim them."
  type        = bool
  default     = true
}

variable "s3_key_prefix" {
  description = "S3 key prefix for lifecycle script uploads"
  type        = string
  default     = "hyperpod-lifecycle"
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
# Instance Groups
# -----------------------------------------------------------------------------
variable "instance_groups" {
  description = <<-EOT
    HyperPod instance groups. Each group creates a set of instances that join
    the EKS cluster as worker nodes. All groups in a single hyperpod module
    invocation share the same WEKA configuration (hugepages + NIC count) —
    use separate module invocations for heterogeneous WEKA requirements.
  EOT

  type = list(object({
    name                  = string
    instance_type         = string
    instance_count        = number
    ebs_volume_size_in_gb = optional(number, 100)
    threads_per_core      = optional(number, 2)
    labels                = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])

    # Optional advanced fields — see modules/hyperpod/variables.tf or
    # terraform/hyperpod/README.md for descriptions.
    training_plan_arn           = optional(string, null)
    image_id                    = optional(string, null)
    on_start_deep_health_checks = optional(list(string), [])
    min_instance_count          = optional(number, null)
  }))

  default = [{
    name           = "weka-clients"
    instance_type  = "ml.c5.12xlarge"
    instance_count = 2
    labels = {
      "weka.io/supports-clients" = "true"
    }
    taints = [{
      key    = "weka.io/client"
      value  = "true"
      effect = "NoSchedule"
    }]
  }]
}

# -----------------------------------------------------------------------------
# WEKA Per-Node Configuration (shared across all instance groups)
# -----------------------------------------------------------------------------
variable "weka_hugepages_count" {
  description = "2 MiB hugepages per HyperPod node (configured at boot by lifecycle script)"
  type        = number
  default     = 2048
}

variable "weka_nic_count" {
  description = "Number of WEKA DPDK NICs per HyperPod node (moved from SageMaker namespace by lifecycle script). Default 0 = UDP mode (works on single-ENI types). Raise for DPDK on multi-ENI types like ml.p4d/p5/p6."
  type        = number
  default     = 0
}

# -----------------------------------------------------------------------------
# Cluster Settings
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
