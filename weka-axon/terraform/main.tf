module "eks_axon" {
  source = "./modules/eks-axon"

  region         = var.region
  cluster_name   = var.cluster_name
  kubernetes_version = var.kubernetes_version
  subnet_ids     = var.subnet_ids

  endpoint_private_access           = var.endpoint_private_access
  endpoint_public_access            = var.endpoint_public_access
  public_access_cidrs               = var.public_access_cidrs
  additional_cluster_security_group_ids = var.additional_cluster_security_group_ids
  authentication_mode               = var.authentication_mode
  enabled_cluster_log_types         = var.enabled_cluster_log_types

  admin_role_arn    = var.admin_role_arn
  enable_ssm_access = var.enable_ssm_access
  key_pair_name     = var.key_pair_name

  node_groups = var.node_groups

  tags = var.tags

  create_weka_nodes_security_group    = var.create_weka_nodes_security_group
  additional_node_security_group_ids  = var.additional_node_security_group_ids

  cluster_dns_ip               = var.cluster_dns_ip
  cpu_manager_reconcile_period = var.cpu_manager_reconcile_period

  # IRSA for WEKA operator/controller (ensure-nics)
  enable_weka_operator_irsa   = var.enable_weka_operator_irsa

  weka_operator_namespace     = var.weka_operator_namespace
  weka_operator_service_account = var.weka_operator_service_account
  enforce_eni_tag_conditions  = var.enforce_eni_tag_conditions
  eni_tag_key                 = var.eni_tag_key
  eni_tag_value               = var.eni_tag_value
}
