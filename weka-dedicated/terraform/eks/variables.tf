variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
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

variable "node_groups" {
  description = "Map of node group configurations"
  type = map(object({
    instance_types   = list(string)
    desired_size     = number
    min_size         = number
    max_size         = number
    disk_size        = number
    ami_type         = optional(string, "AL2023_x86_64_STANDARD")
    capacity_type    = optional(string, "ON_DEMAND")
    imds_hop_limit_2 = optional(bool, false)
    labels           = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  default = {}
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
  description = "Attach SSM managed instance core policy to nodes for debugging"
  type        = bool
  default     = false
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
