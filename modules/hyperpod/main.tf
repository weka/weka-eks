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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  execution_role_arn = var.create_sagemaker_execution_role ? aws_iam_role.sagemaker_execution[0].arn : var.sagemaker_execution_role_arn
  s3_bucket_name     = var.create_s3_bucket ? aws_s3_bucket.lifecycle_scripts[0].id : var.s3_bucket_name
  s3_lifecycle_uri   = "s3://${local.s3_bucket_name}/${var.s3_key_prefix}"
}

# -----------------------------------------------------------------------------
# SageMaker Execution Role (optional — created by default)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "sagemaker_execution" {
  count       = var.create_sagemaker_execution_role ? 1 : 0
  name_prefix = "${var.hyperpod_cluster_name}-sagemaker-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "sagemaker.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "sagemaker_hyperpod" {
  count      = var.create_sagemaker_execution_role ? 1 : 0
  role       = aws_iam_role.sagemaker_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSageMakerClusterInstanceRolePolicy"
}

# Inline policy recommended by AWS for HyperPod on EKS:
# https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-prerequisites-iam.html
resource "aws_iam_role_policy" "sagemaker_hyperpod_eks" {
  count = var.create_sagemaker_execution_role ? 1 : 0
  name  = "hyperpod-eks-access"
  role  = aws_iam_role.sagemaker_execution[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AssignPrivateIpAddresses",
          "ec2:AttachNetworkInterface",
          "ec2:CreateNetworkInterface",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DeleteNetworkInterfacePermission",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:DescribeVpcs",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DetachNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:UnassignPrivateIpAddresses",
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
          "ecr:GetDownloadUrlForLayer",
          "eks-auth:AssumeRoleForPodIdentity",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:*:*:network-interface/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${local.s3_bucket_name}",
          "arn:${data.aws_partition.current.partition}:s3:::${local.s3_bucket_name}/*",
        ]
      },
    ]
  })
}

# Wait out IAM eventual consistency before SageMaker tries to assume the
# fresh execution role. Without this, CreateCluster can fail with
# "cannot assume the execution role". Only relevant when we create it.
resource "time_sleep" "wait_for_execution_role" {
  count           = var.create_sagemaker_execution_role ? 1 : 0
  create_duration = "30s"
  depends_on = [
    aws_iam_role.sagemaker_execution,
    aws_iam_role_policy_attachment.sagemaker_hyperpod,
    aws_iam_role_policy.sagemaker_hyperpod_eks,
  ]
}

# -----------------------------------------------------------------------------
# S3 bucket for lifecycle scripts (optional — created by default)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "lifecycle_scripts" {
  count         = var.create_s3_bucket ? 1 : 0
  bucket        = var.s3_bucket_name
  force_destroy = true
  tags          = var.tags
}

# -----------------------------------------------------------------------------
# Upload lifecycle scripts to S3
# -----------------------------------------------------------------------------
resource "aws_s3_object" "on_create" {
  bucket       = local.s3_bucket_name
  key          = "${var.s3_key_prefix}/on_create.sh"
  source       = "${var.lifecycle_scripts_path}/on_create.sh"
  content_type = "text/x-sh"
  etag         = filemd5("${var.lifecycle_scripts_path}/on_create.sh")
}

resource "aws_s3_object" "configure_hugepages" {
  bucket       = local.s3_bucket_name
  key          = "${var.s3_key_prefix}/configure-weka-hugepages.sh"
  source       = "${var.lifecycle_scripts_path}/configure-weka-hugepages.sh"
  content_type = "text/x-sh"
  etag         = filemd5("${var.lifecycle_scripts_path}/configure-weka-hugepages.sh")
}

resource "aws_s3_object" "configure_nics" {
  bucket       = local.s3_bucket_name
  key          = "${var.s3_key_prefix}/configure-hyperpod-nics.py"
  source       = "${var.lifecycle_scripts_path}/configure-hyperpod-nics.py"
  content_type = "text/x-python"
  etag         = filemd5("${var.lifecycle_scripts_path}/configure-hyperpod-nics.py")
}

resource "aws_s3_object" "weka_config_env" {
  bucket       = local.s3_bucket_name
  key          = "${var.s3_key_prefix}/weka-config.env"
  content_type = "text/plain"
  content = templatefile("${var.lifecycle_scripts_path}/weka-config.env.tftpl", {
    hugepages_count = var.weka_hugepages_count
    nic_count       = var.weka_nic_count
  })
}

# -----------------------------------------------------------------------------
# SageMaker HyperPod Cluster
# -----------------------------------------------------------------------------
resource "awscc_sagemaker_cluster" "main" {
  cluster_name = var.hyperpod_cluster_name

  orchestrator = {
    eks = {
      cluster_arn = var.eks_cluster_arn
    }
  }

  vpc_config = {
    security_group_ids = var.security_group_ids
    subnets            = var.subnet_ids
  }

  node_recovery = var.auto_node_recovery ? "Automatic" : "None"

  instance_groups = [
    for ig in var.instance_groups : {
      instance_group_name = ig.name
      instance_type       = ig.instance_type
      instance_count      = ig.instance_count

      execution_role = local.execution_role_arn

      life_cycle_config = {
        source_s3_uri = local.s3_lifecycle_uri
        on_create     = "on_create.sh"
      }

      instance_storage_configs = [{
        ebs_volume_config = {
          volume_size_in_gb = ig.ebs_volume_size_in_gb
        }
      }]

      threads_per_core = ig.threads_per_core

      kubernetes_config = {
        labels = ig.labels
        taints = [for t in ig.taints : {
          key    = t.key
          value  = t.value
          effect = t.effect
        }]
      }

      # Optional advanced settings (null/empty = unset).
      training_plan_arn           = ig.training_plan_arn
      image_id                    = ig.image_id
      on_start_deep_health_checks = ig.on_start_deep_health_checks
      min_instance_count          = ig.min_instance_count
    }
  ]

  tags = [for k, v in var.tags : { key = k, value = v }]

  depends_on = [
    aws_s3_object.on_create,
    aws_s3_object.configure_hugepages,
    aws_s3_object.configure_nics,
    aws_s3_object.weka_config_env,
    time_sleep.wait_for_execution_role,
  ]
}
