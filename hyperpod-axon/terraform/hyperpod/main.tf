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

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

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

resource "aws_iam_role_policy_attachment" "sagemaker_eks_access" {
  count      = var.create_sagemaker_execution_role ? 1 : 0
  role       = aws_iam_role.sagemaker_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "sagemaker_ecr" {
  count      = var.create_sagemaker_execution_role ? 1 : 0
  role       = aws_iam_role.sagemaker_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

locals {
  execution_role_arn = var.create_sagemaker_execution_role ? aws_iam_role.sagemaker_execution[0].arn : var.sagemaker_execution_role_arn
  s3_lifecycle_uri   = "s3://${var.s3_bucket_name}/${var.s3_key_prefix}"

  # Use the first instance group's WEKA config for the shared env file.
  # All groups share the same lifecycle scripts; per-group overrides can be
  # added later by templating separate env files per group.
  weka_config = var.instance_groups[0]
}

# -----------------------------------------------------------------------------
# Upload lifecycle scripts to S3
# -----------------------------------------------------------------------------
resource "aws_s3_object" "on_create" {
  bucket       = var.s3_bucket_name
  key          = "${var.s3_key_prefix}/on_create.sh"
  source       = "${path.module}/../../scripts/on_create.sh"
  content_type = "text/x-sh"
  etag         = filemd5("${path.module}/../../scripts/on_create.sh")
}

resource "aws_s3_object" "on_create_main" {
  bucket       = var.s3_bucket_name
  key          = "${var.s3_key_prefix}/on_create_main.sh"
  source       = "${path.module}/../../scripts/on_create_main.sh"
  content_type = "text/x-sh"
  etag         = filemd5("${path.module}/../../scripts/on_create_main.sh")
}

resource "aws_s3_object" "configure_hugepages" {
  bucket       = var.s3_bucket_name
  key          = "${var.s3_key_prefix}/configure-weka-hugepages.sh"
  source       = "${path.module}/../../scripts/configure-weka-hugepages.sh"
  content_type = "text/x-sh"
  etag         = filemd5("${path.module}/../../scripts/configure-weka-hugepages.sh")
}

resource "aws_s3_object" "configure_nics" {
  bucket       = var.s3_bucket_name
  key          = "${var.s3_key_prefix}/configure-hyperpod-nics.py"
  source       = "${path.module}/../../scripts/configure-hyperpod-nics.py"
  content_type = "text/x-python"
  etag         = filemd5("${path.module}/../../scripts/configure-hyperpod-nics.py")
}

resource "aws_s3_object" "weka_config_env" {
  bucket       = var.s3_bucket_name
  key          = "${var.s3_key_prefix}/weka-config.env"
  content_type = "text/plain"
  content = templatefile("${path.module}/../../scripts/weka-config.env.tftpl", {
    hugepages_count = local.weka_config.weka_hugepages_count
    nic_count       = local.weka_config.weka_nic_count
    subnet_cidr     = var.subnet_cidr
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
    security_group_ids = [var.security_group_id]
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
    }
  ]

  tags = [for k, v in var.tags : { key = k, value = v }]

  depends_on = [
    aws_s3_object.on_create,
    aws_s3_object.on_create_main,
    aws_s3_object.configure_hugepages,
    aws_s3_object.configure_nics,
    aws_s3_object.weka_config_env,
  ]
}
