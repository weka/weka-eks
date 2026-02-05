variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs (recommend private subnets). All subnets must be in the same VPC."
  type        = list(string)
}

variable "admin_role_arn" {
  description = "IAM role ARN to grant EKS cluster admin access via EKS Access Entry (optional)"
  type        = string
  default     = null
}

variable "ssm_access" {
  description = "Attach AmazonSSMManagedInstanceCore to node IAM role (recommended for private subnets / no SSH)."
  type        = bool
  default     = true
}

variable "node_groups" {
  description = "Managed node groups (map). Map is used to template creation of different groups"
  type = map(object({
    instance_types   = list(string)
    desired_size     = number
    min_size         = number
    max_size         = number
    disk_size        = optional(number)
    labels           = optional(map(string))
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })))
    imds_hop_limit_2 = optional(bool)
    capacity_type    = optional(string)
    ami_type         = optional(string)
    enable_cpu_manager_static = optional(bool, false)
    disable_hyperthreading = optional(bool, false)
    core_count             = optional(number)
  }))
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------
# Optional cluster settings
# -----------------------------
variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "endpoint_private_access" {
  description = "Enable private API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API endpoint"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Allowed CIDRs for public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "create_weka_nodes_security_group" {
  description = "Create and attach a self-referencing WEKA intra-node SG"
  type        = bool
  default     = true
}

variable "cluster_dns_ip" {
  description = "Optional explicit Cluster DNS IP for kubelet. If null, EKS/nodeadm uses the default."
  type        = string
  default     = null
}

variable "enable_weka_operator_irsa" {
  description = "Create IRSA role/policy for WEKA operator/controller ENI ops."
  type        = bool
  default     = true
}

variable "weka_operator_namespace" {
  description = "Namespace for operator controller service account"
  type        = string
  default     = "weka-operator-system"
}

variable "weka_operator_service_account" {
  description = "Service account name for operator controller"
  type        = string
  default     = "weka-operator-controller-manager"
}

variable "enforce_eni_tag_conditions" {
  description = "Restrict ENI mutation actions to tagged resources (requires controller tagging)."
  type        = bool
  default     = false
}

variable "eni_tag_key" {
  description = "Tag key used for ENI restriction conditions"
  type        = string
  default     = "weka.io/cluster"
}

variable "eni_tag_value" {
  description = "Tag value used for ENI restriction conditions; defaults to cluster_name if null."
  type        = string
  default     = null
}
