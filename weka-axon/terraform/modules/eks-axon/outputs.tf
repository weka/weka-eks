output "cluster_id" {
  description = "EKS cluster ID"
  value       = aws_eks_cluster.main.id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the cluster"
  value       = aws_eks_cluster.main.version
}

output "cluster_security_group_id" {
  description = "EKS-created cluster security group ID"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_group_names" {
  description = "Managed node group names (keyed by node group key)"
  value       = { for k, ng in aws_eks_node_group.nodes : k => ng.node_group_name }
}

output "node_iam_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = aws_iam_role.nodes.arn
}

output "weka_nodes_security_group_id" {
  description = "WEKA intra-node security group ID (if created)"
  value       = var.create_weka_nodes_security_group ? aws_security_group.weka_nodes[0].id : null
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for IRSA"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "weka_operator_irsa_role_arn" {
  description = "IRSA role ARN for WEKA operator/controller (if enabled)"
  value       = var.enable_weka_operator_irsa ? aws_iam_role.weka_operator[0].arn : null
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.region}"
}
