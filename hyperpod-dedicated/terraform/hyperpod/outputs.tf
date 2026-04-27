output "cluster_arn" {
  description = "ARN of the SageMaker HyperPod cluster"
  value       = module.hyperpod.cluster_arn
}

output "cluster_name" {
  description = "Name of the SageMaker HyperPod cluster"
  value       = module.hyperpod.cluster_name
}

output "sagemaker_execution_role_arn" {
  description = "SageMaker execution role ARN used by HyperPod instances"
  value       = module.hyperpod.sagemaker_execution_role_arn
}

output "lifecycle_scripts_s3_uri" {
  description = "S3 URI where lifecycle scripts are stored"
  value       = module.hyperpod.lifecycle_scripts_s3_uri
}

output "efa_security_group_id" {
  description = "ID of the EFA-compliant SG (null if create_efa_security_group = false)"
  value       = try(aws_security_group.hyperpod_efa[0].id, null)
}
