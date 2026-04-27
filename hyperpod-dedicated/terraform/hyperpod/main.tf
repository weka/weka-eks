terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "awscc" {
  region = var.region
}

# -----------------------------------------------------------------------------
# EFA-compliant security group (toggle via var.create_efa_security_group;
# see variables.tf for rationale).
# https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-prerequisites.html
# -----------------------------------------------------------------------------
data "aws_subnet" "first" {
  count = var.create_efa_security_group ? 1 : 0
  id    = var.subnet_ids[0]
}

resource "aws_security_group" "hyperpod_efa" {
  count = var.create_efa_security_group ? 1 : 0

  name_prefix = "${var.hyperpod_cluster_name}-efa-"
  description = "EFA-compliant SG for HyperPod nodes (self-only)"
  vpc_id      = data.aws_subnet.first[0].vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "hyperpod_efa_self" {
  count = var.create_efa_security_group ? 1 : 0

  security_group_id            = aws_security_group.hyperpod_efa[0].id
  referenced_security_group_id = aws_security_group.hyperpod_efa[0].id
  ip_protocol                  = "-1"
  description                  = "EFA peer-to-peer (all from self)"
}

resource "aws_vpc_security_group_egress_rule" "hyperpod_efa_self" {
  count = var.create_efa_security_group ? 1 : 0

  security_group_id            = aws_security_group.hyperpod_efa[0].id
  referenced_security_group_id = aws_security_group.hyperpod_efa[0].id
  ip_protocol                  = "-1"
  description                  = "EFA peer-to-peer (all to self)"
}

# -----------------------------------------------------------------------------
# HyperPod cluster + IAM + S3 lifecycle script uploads
# -----------------------------------------------------------------------------
module "hyperpod" {
  source = "../../../modules/hyperpod"

  hyperpod_cluster_name = var.hyperpod_cluster_name
  eks_cluster_arn       = var.eks_cluster_arn
  subnet_ids            = var.subnet_ids
  # Prepend the auto-created EFA SG when create_efa_security_group = true.
  security_group_ids = concat(
    var.create_efa_security_group ? [aws_security_group.hyperpod_efa[0].id] : [],
    var.additional_security_group_ids,
  )

  lifecycle_scripts_path = "${path.module}/../../lifecycle-scripts"

  s3_bucket_name   = var.s3_bucket_name
  create_s3_bucket = var.create_s3_bucket
  s3_key_prefix    = var.s3_key_prefix

  create_sagemaker_execution_role = var.create_sagemaker_execution_role
  sagemaker_execution_role_arn    = var.sagemaker_execution_role_arn

  instance_groups = var.instance_groups

  weka_hugepages_count = var.weka_hugepages_count
  weka_nic_count       = var.weka_nic_count

  auto_node_recovery = var.auto_node_recovery
  tags               = var.tags
}
