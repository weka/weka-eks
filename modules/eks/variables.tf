# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS cluster and nodes (private subnets recommended)"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Cluster Settings
# -----------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.33"
}

variable "endpoint_private_access" {
  description = "Enable private API server endpoint"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API server endpoint"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to access public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "additional_security_group_ids" {
  description = "Additional security group IDs (e.g., WEKA backend SG). Attached to the EKS cluster vpc_config and (when launch templates are created) to node launch templates."
  type        = list(string)
  default     = []
}

variable "authentication_mode" {
  description = "EKS authentication mode (API, CONFIG_MAP, or API_AND_CONFIG_MAP)"
  type        = string
  default     = "API"
}

variable "enabled_cluster_log_types" {
  description = "EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

# -----------------------------------------------------------------------------
# Node Groups
# -----------------------------------------------------------------------------
variable "node_groups" {
  description = <<-EOT
    Map of EKS managed node group configurations.

    For hyperpod models, pass only a system group.
    For weka-dedicated, pass system + clients groups.
    For weka-axon, pass system + axon groups.
  EOT

  type = map(object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    subnet_ids     = optional(list(string), null)
    disk_size      = optional(number, 100)
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    capacity_type  = optional(string, "ON_DEMAND")
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
    imds_hop_limit_2          = optional(bool, false)
    enable_cpu_manager_static = optional(bool, false)
    disable_hyperthreading    = optional(bool, false)
    core_count                = optional(number, null)
    hugepages_count           = optional(number, 0)
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.node_groups :
      !try(v.disable_hyperthreading, false) || try(v.core_count, null) != null
    ])
    error_message = "When disable_hyperthreading is true, core_count must be specified."
  }

  validation {
    condition = alltrue([
      for k, v in var.node_groups :
      try(v.core_count, null) == null || try(v.core_count, 0) > 0
    ])
    error_message = "core_count must be greater than 0 when specified."
  }
}

variable "key_pair_name" {
  description = "EC2 Key Pair name for SSH access to nodes (prefer SSM instead)"
  type        = string
  default     = null
}

variable "cpu_manager_reconcile_period" {
  description = "CPU manager reconciliation period (e.g., '10s')"
  type        = string
  default     = "10s"
}

variable "cluster_dns_ip" {
  description = "Kubelet cluster DNS IP. Leave null for EKS defaults."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler
# -----------------------------------------------------------------------------
variable "enable_cluster_autoscaler" {
  description = "Add cluster autoscaler discovery labels to node groups"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Security / Access
# -----------------------------------------------------------------------------
variable "enable_ssm_access" {
  description = "Attach AmazonSSMManagedInstanceCore to node IAM role"
  type        = bool
  default     = true
}

variable "admin_role_arn" {
  description = "IAM role ARN to grant EKS cluster admin access via Access Entry"
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
