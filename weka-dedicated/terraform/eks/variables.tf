variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.33"
}

variable "subnet_ids" {
  description = "List of subnet IDs for EKS cluster and nodes"
  type        = list(string)
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

variable "additional_cluster_security_group_ids" {
  description = "Additional security group IDs to attach to the EKS cluster"
  type        = list(string)
  default     = []
}

variable "authentication_mode" {
  description = "EKS authentication mode (API, CONFIG_MAP, or API_AND_CONFIG_MAP)"
  type        = string
  default     = "API"
}

variable "enabled_cluster_log_types" {
  description = "List of control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
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

variable "node_groups" {
  description = "Map of node group configurations"
  type = map(object({
    instance_types            = list(string)
    desired_size              = number
    min_size                  = number
    max_size                  = number
    disk_size                 = optional(number, 200)
    ami_type                  = optional(string, "AL2023_x86_64_STANDARD")
    capacity_type             = optional(string, "ON_DEMAND")
    imds_hop_limit_2          = optional(bool, false)
    enable_cpu_manager_static = optional(bool, false)
    disable_hyperthreading    = optional(bool, false)
    core_count                = optional(number, null)
    hugepages_count           = optional(number, 0) # 2 MiB hugepages; 0 = skip
    labels                    = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
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
  description = "EC2 Key Pair name for SSH access to nodes"
  type        = string
  default     = null
}

variable "additional_node_security_group_ids" {
  description = "Additional security group IDs to attach to node launch templates (e.g., WEKA backend SG)"
  type        = list(string)
  default     = []
}

variable "enable_ssm_access" {
  description = "Attach AmazonSSMManagedInstanceCore to node IAM role (recommended for private subnets / no SSH)."
  type        = bool
  default     = true
}

variable "enable_cluster_autoscaler" {
  description = "Add cluster autoscaler labels to node groups"
  type        = bool
  default     = false
}

variable "admin_role_arn" {
  description = "IAM role ARN to grant EKS cluster admin access (e.g., SSO role)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# IRSA for WEKA operator/controller (ENI management)
# -----------------------------------------------------------------------------
variable "enable_weka_operator_irsa" {
  description = "Create an IRSA role/policy for the WEKA operator to perform ENI operations (ensure-nics)."
  type        = bool
  default     = true
}

variable "weka_operator_namespace" {
  description = "Namespace where the WEKA operator controller service account runs."
  type        = string
  default     = "weka-operator-system"
}

variable "weka_operator_service_account" {
  description = "Service account name for the WEKA operator controller."
  type        = string
  default     = "weka-operator-controller-manager"
}

variable "enforce_eni_tag_conditions" {
  description = "If true, restrict ENI mutation actions using tag-based conditions (more secure, but requires the controller to tag ENIs)."
  type        = bool
  default     = false
}

variable "eni_tag_key" {
  description = "Tag key used for ENI restriction conditions (only used if enforce_eni_tag_conditions = true)."
  type        = string
  default     = "weka.io/cluster"
}

variable "eni_tag_value" {
  description = "Tag value used for ENI restriction conditions (only used if enforce_eni_tag_conditions = true). If null, defaults to cluster_name."
  type        = string
  default     = null
}
