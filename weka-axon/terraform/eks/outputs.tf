output "cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the cluster"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "AWS-managed cluster security group ID"
  value       = module.eks.cluster_security_group_id
}

output "node_iam_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = module.eks.node_iam_role_arn
}

output "node_iam_role_name" {
  description = "IAM role name for EKS nodes"
  value       = module.eks.node_iam_role_name
}

output "node_groups" {
  description = "Map of node group details"
  value       = module.eks.node_groups
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = module.eks.configure_kubectl
}
