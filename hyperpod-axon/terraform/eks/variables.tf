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
  description = "Subnet IDs for EKS cluster and nodes (private subnets recommended)"
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

variable "additional_security_group_ids" {
  description = "Additional security group IDs to attach to the EKS cluster (e.g., WEKA backend SG)"
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
# System node group (the only EKS-managed nodes — HyperPod manages workers)
# -----------------------------------------------------------------------------
variable "system_node_instance_types" {
  description = "Instance types for system nodes"
  type        = list(string)
  default     = ["t3.large"]
}

variable "system_node_desired_size" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 5
}

variable "system_node_disk_size" {
  description = "Root volume size (GiB) for system nodes"
  type        = number
  default     = 100
}

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------
variable "enable_ssm_access" {
  description = "Attach AmazonSSMManagedInstanceCore to node IAM role (recommended for private subnets / no SSH)."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Access
# -----------------------------------------------------------------------------
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
