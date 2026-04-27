output "cluster_arn" {
  description = "ARN of the SageMaker HyperPod cluster"
  value       = awscc_sagemaker_cluster.main.cluster_arn
}

output "cluster_name" {
  description = "Name of the SageMaker HyperPod cluster"
  value       = var.hyperpod_cluster_name
}

output "sagemaker_execution_role_arn" {
  description = "SageMaker execution role ARN used by HyperPod instances"
  value       = local.execution_role_arn
}

output "lifecycle_scripts_s3_uri" {
  description = "S3 URI where lifecycle scripts are stored"
  value       = local.s3_lifecycle_uri
}
