output "cluster_name" {
  value       = module.eks_axon.cluster_name
  description = "EKS cluster name"
}

output "configure_kubectl" {
  value       = module.eks_axon.configure_kubectl
  description = "Command to configure kubectl"
}

output "weka_operator_irsa_role_arn" {
  value       = module.eks_axon.weka_operator_irsa_role_arn
  description = "IRSA role ARN for WEKA operator/controller"
}

output "weka_nodes_security_group_id" {
  value       = module.eks_axon.weka_nodes_security_group_id
  description = "Self-referencing WEKA intra-node SG (if created)"
}
