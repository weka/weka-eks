# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
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

variable "security_group_ids" {
  description = <<-EOT
    Security groups attached to HyperPod instances. The user is responsible
    for ensuring these allow EKS + WEKA traffic. For EFA-enabled instance
    types (p4d, p5, etc.) at least one attached SG must allow all traffic
    to/from itself (EFA peer-to-peer) and must NOT have a 0.0.0.0/0 egress
    rule, or HyperPod's EFA health check will fail.
  EOT
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Lifecycle Scripts
# -----------------------------------------------------------------------------
variable "lifecycle_scripts_path" {
  description = <<-EOT
    Filesystem path to the directory containing lifecycle scripts. The module
    uploads on_create.sh, configure-weka-hugepages.sh, configure-hyperpod-nics.py,
    and renders weka-config.env from weka-config.env.tftpl in this directory.
  EOT
  type        = string
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

    # Optional advanced fields (all default to null/empty — no change to the
    # CreateCluster request if unset).
    # - training_plan_arn: attach this group to a reserved-capacity
    #   SageMaker training plan.
    # - image_id: custom HyperPod AMI (skip the default DLAMI). Pair with
    #   stripped-down lifecycle scripts if you bake hugepages / NIC setup
    #   into the AMI.
    # - on_start_deep_health_checks: enable deep health checks at node
    #   start; valid values are "InstanceStress" and "InstanceConnectivity".
    #   Only applies to GPU/accelerated instance types.
    # - min_instance_count: lower bound for auto-scaling/auto-recovery.
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
