module "eks_axon" {
  source = "./modules/eks-axon"

  region         = var.region
  cluster_name   = var.cluster_name
  cluster_version = var.cluster_version
  subnet_ids     = var.subnet_ids

  endpoint_private_access = var.endpoint_private_access
  endpoint_public_access  = var.endpoint_public_access
  public_access_cidrs     = var.public_access_cidrs

  admin_role_arn = var.admin_role_arn
  ssm_access     = var.ssm_access

  node_groups = var.node_groups

  tags = var.tags

  create_weka_nodes_security_group = var.create_weka_nodes_security_group

  cluster_dns_ip            = var.cluster_dns_ip

  # IRSA for WEKA operator/controller (ensure-nics)
  enable_weka_operator_irsa   = var.enable_weka_operator_irsa

  weka_operator_namespace     = var.weka_operator_namespace
  weka_operator_service_account = var.weka_operator_service_account
  enforce_eni_tag_conditions  = var.enforce_eni_tag_conditions
  eni_tag_key                 = var.eni_tag_key
  eni_tag_value               = var.eni_tag_value
}
