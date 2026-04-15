output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks_axon.cluster_name
}

output "cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks_axon.cluster_id
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.eks_axon.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks_axon.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the cluster"
  value       = module.eks_axon.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data"
  value       = module.eks_axon.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "AWS-managed cluster security group ID"
  value       = module.eks_axon.cluster_security_group_id
}

output "node_iam_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = module.eks_axon.node_iam_role_arn
}

output "node_iam_role_name" {
  description = "IAM role name for EKS nodes"
  value       = module.eks_axon.node_iam_role_name
}

output "node_groups" {
  description = "Map of node group details"
  value       = module.eks_axon.node_groups
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for IRSA"
  value       = module.eks_axon.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC Provider"
  value       = module.eks_axon.oidc_provider_url
}

output "weka_operator_irsa_role_arn" {
  description = "IRSA role ARN for WEKA operator/controller"
  value       = module.eks_axon.weka_operator_irsa_role_arn
}

output "weka_nodes_security_group_id" {
  description = "Self-referencing WEKA intra-node SG (if created)"
  value       = module.eks_axon.weka_nodes_security_group_id
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = module.eks_axon.configure_kubectl
}
