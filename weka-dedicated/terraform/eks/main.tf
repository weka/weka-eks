terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "eks" {
  source = "../../../modules/eks"

  region       = var.region
  cluster_name = var.cluster_name
  subnet_ids   = var.subnet_ids

  kubernetes_version      = var.kubernetes_version
  endpoint_private_access = var.endpoint_private_access
  endpoint_public_access  = var.endpoint_public_access
  public_access_cidrs     = var.public_access_cidrs

  additional_security_group_ids = var.additional_security_group_ids
  authentication_mode           = var.authentication_mode
  enabled_cluster_log_types     = var.enabled_cluster_log_types

  node_groups = var.node_groups

  key_pair_name                = var.key_pair_name
  cpu_manager_reconcile_period = var.cpu_manager_reconcile_period
  cluster_dns_ip               = var.cluster_dns_ip
  enable_cluster_autoscaler    = var.enable_cluster_autoscaler

  enable_ssm_access = var.enable_ssm_access
  admin_role_arn    = var.admin_role_arn

  tags = var.tags
}
