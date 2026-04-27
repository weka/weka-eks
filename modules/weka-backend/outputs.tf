output "weka_deployment_output" {
  description = "Full output from the upstream weka/weka/aws module — includes sg_ids, cluster_helper_commands (including get_password), alb_dns_name, and other deployment metadata."
  value       = module.weka_deployment
  sensitive   = false
}
