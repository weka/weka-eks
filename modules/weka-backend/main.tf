terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

module "weka_deployment" {
  source  = "weka/weka/aws"
  version = "1.0.23"

  # Cluster
  cluster_name = var.cluster_name
  cluster_size = var.cluster_size
  prefix       = var.prefix

  # Instance
  instance_type    = var.instance_type
  key_pair_name    = var.key_pair_name
  assign_public_ip = var.assign_public_ip

  # WEKA Software
  weka_version      = var.weka_version
  get_weka_io_token = var.get_weka_io_token

  # Network
  subnet_ids               = var.subnet_ids
  sg_ids                   = var.sg_ids
  create_nat_gateway       = var.create_nat_gateway

  # ALB
  create_alb               = var.create_alb
  alb_additional_subnet_id = var.alb_additional_subnet_id

  # WEKA Options
  set_dedicated_fe_container = var.set_dedicated_fe_container
  data_services_number       = var.data_services_number

  # Tiering
  tiering_enable_obs_integration = var.tiering_enable_obs_integration
  tiering_obs_name               = var.tiering_obs_name
  tiering_enable_ssd_percent     = var.tiering_enable_ssd_percent

  # Secrets Manager
  secretmanager_use_vpc_endpoint    = var.secretmanager_use_vpc_endpoint
  secretmanager_create_vpc_endpoint = var.secretmanager_create_vpc_endpoint

  # IAM (use existing roles)
  instance_iam_profile_arn = var.instance_iam_profile_arn
  lambda_iam_role_arn      = var.lambda_iam_role_arn
  sfn_iam_role_arn         = var.sfn_iam_role_arn
  event_iam_role_arn       = var.event_iam_role_arn

  # Tags
  tags_map = var.tags_map
}
