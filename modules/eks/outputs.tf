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

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "AWS-managed cluster security group ID"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_iam_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = aws_iam_role.nodes.arn
}

output "node_iam_role_name" {
  description = "IAM role name for EKS nodes"
  value       = aws_iam_role.nodes.name
}

output "node_groups" {
  description = "Map of node group details"
  value = {
    for name, ng in aws_eks_node_group.nodes : name => {
      id     = ng.id
      arn    = ng.arn
      status = ng.status
    }
  }
}

output "weka_nodes_security_group_id" {
  description = "WEKA intra-node security group ID (null if not created)"
  value       = var.create_weka_nodes_security_group ? aws_security_group.weka_nodes[0].id : null
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.region}"
}
