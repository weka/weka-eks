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
  default     = "1.32"
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS control plane ENIs and worker nodes (recommend private subnets). All subnets must be in the same VPC."
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
  description = "CIDR blocks that can access the public API server endpoint (only used if endpoint_public_access = true)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "additional_cluster_security_group_ids" {
  description = "Additional security groups to attach to the EKS control plane ENIs"
  type        = list(string)
  default     = []
}

variable "authentication_mode" {
  description = "EKS authentication mode. For modern setups, use API (EKS Access Entry)."
  type        = string
  default     = "API"
}

variable "enabled_cluster_log_types" {
  description = "EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "admin_role_arn" {
  description = "IAM role ARN to grant EKS cluster admin access via EKS Access Entry (optional)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Node groups
# -----------------------------------------------------------------------------
variable "node_groups" {
  description = <<EOT
Managed node groups for the EKS cluster. A map is used to template the creation
of different node groups (e.g. system nodes, WEKA Axon nodes)

For WEKA Axon, set:
- labels: weka.io/supports-backends=true AND weka.io/supports-clients=true
- taints: weka.io/axon=true:NoSchedule (recommended)
- imds_hop_limit_2: true (required on AL2023 for WEKA ensure-nics)
EOT

  type = map(object({
    instance_types   = list(string)
    desired_size     = number
    min_size         = number
    max_size         = number
    disk_size        = optional(number, 200) # GiB root volume; WEKA data lives on NVMe
    labels           = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string # NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
    })), [])
    imds_hop_limit_2 = optional(bool)
    capacity_type    = optional(string, "ON_DEMAND") # or SPOT
    ami_type         = optional(string, "AL2023_x86_64_STANDARD")
    enable_cpu_manager_static = optional(bool, false)
    disable_hyperthreading    = optional(bool, false)
    core_count                = optional(number)
  }))
  validation {
    condition = alltrue([
      for ng_name, ng in var.node_groups :
      (!try(ng.disable_hyperthreading, false)) || (try(ng.core_count, null) != null)
    ])
    error_message = "If disable_hyperthreading is true for a node group, core_count must be set."
  }
}

variable "additional_node_security_group_ids" {
  description = "Extra security groups to attach to worker nodes (via launch template)."
  type        = list(string)
  default     = []
}

variable "create_weka_nodes_security_group" {
  description = "Create and attach a self-referencing security group for high-throughput node-to-node WEKA traffic (recommended for a robust walkthrough)."
  type        = bool
  default     = true
}

variable "ssm_access" {
  description = "Attach AmazonSSMManagedInstanceCore to the node IAM role (recommended for private subnets / no SSH)."
  type        = bool
  default     = true
}

variable "key_pair_name" {
  description = "Optional EC2 key pair name for SSH access (not recommended; prefer SSM). Only used if you enable remote access explicitly later."
  type        = string
  default     = null
}

variable "cpu_manager_reconcile_period" {
  description = "Kubelet CPU Manager reconcile period (e.g., 10s)."
  type        = string
  default     = "10s"
}

variable "cluster_dns_ip" {
  description = "Optional explicit Cluster DNS IP for kubelet. If null, EKS/nodeadm will use the default for the cluster service CIDR."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# IRSA role for WEKA operator/controller (ENI management)
# -----------------------------------------------------------------------------
variable "enable_weka_operator_irsa" {
  description = "Create an IRSA role/policy intended for the WEKA operator/controller to perform ENI operations (ensure-nics)."
  type        = bool
  default     = true
}

variable "weka_operator_namespace" {
  description = "Namespace where the WEKA operator/controller service account runs."
  type        = string
  default     = "weka-operator-system"
}

variable "weka_operator_service_account" {
  description = "Service account name for the WEKA operator/controller."
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
