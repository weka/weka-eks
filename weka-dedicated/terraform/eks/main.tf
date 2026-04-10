terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------
locals {
  eni_tag_value_effective = var.eni_tag_value != null ? var.eni_tag_value : var.cluster_name

  # Launch templates are needed when any of these conditions are true:
  # Per-node-group: imds_hop_limit_2, enable_cpu_manager_static, disable_hyperthreading, hugepages_count
  # Global: additional_node_security_group_ids (SGs are attached via LT)
  node_groups_use_lt = {
    for k, v in var.node_groups : k => v
    if try(v.imds_hop_limit_2, false) ||
       try(v.enable_cpu_manager_static, false) ||
       try(v.disable_hyperthreading, false) ||
       try(v.hugepages_count, 0) > 0 ||
       length(var.additional_node_security_group_ids) > 0
  }
}

# -----------------------------------------------------------------------------
# EKS Cluster IAM Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name_prefix = "${var.cluster_name}-eks-cluster-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

# Required policies for EKS cluster
resource "aws_iam_role_policy_attachment" "cluster_policies" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.cluster.name
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null

    # Let EKS manage the cluster security group with default rules
    security_group_ids = var.additional_cluster_security_group_ids
  }

  access_config {
    authentication_mode = var.authentication_mode
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policies
  ]

  tags = var.tags

  timeouts {
    create = "30m"
    update = "60m"
    delete = "15m"
  }
}

# -----------------------------------------------------------------------------
# OIDC Provider for IRSA (IAM Roles for Service Accounts)
# -----------------------------------------------------------------------------
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Node IAM Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "nodes" {
  name_prefix = "${var.cluster_name}-eks-nodes-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

# Required policies for EKS nodes
resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.nodes.name
}

# Optional: SSM access for debugging
resource "aws_iam_role_policy_attachment" "nodes_ssm" {
  count      = var.enable_ssm_access ? 1 : 0
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -----------------------------------------------------------------------------
# Launch Templates (created only for node groups that need them)
# -----------------------------------------------------------------------------
resource "aws_launch_template" "nodes" {
  for_each    = local.node_groups_use_lt
  name_prefix = "${var.cluster_name}-${each.key}-"

  # IMDS hop limit 2 required for WEKA operator ENI management from pods
  dynamic "metadata_options" {
    for_each = try(each.value.imds_hop_limit_2, false) ? [1] : []
    content {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 2
    }
  }

  # Disable hyperthreading for single-threaded performance (WEKA backends primarily)
  dynamic "cpu_options" {
    for_each = try(each.value.disable_hyperthreading, false) ? [1] : []
    content {
      core_count       = each.value.core_count
      threads_per_core = 1
    }
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  # Attach cluster SG + any additional SGs (e.g., WEKA backend SG)
  vpc_security_group_ids = compact(concat(
    [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id],
    var.additional_node_security_group_ids
  ))

  key_name = var.key_pair_name

  # nodeadm user data for hugepages, CPU manager static policy, or custom cluster DNS
  user_data = (try(each.value.enable_cpu_manager_static, false) || try(each.value.hugepages_count, 0) > 0 || var.cluster_dns_ip != null) ? base64encode(
    templatefile("${path.module}/nodeadm-userdata.yaml.tftpl", {
      hugepages_count              = try(each.value.hugepages_count, 0)
      enable_cpu_manager_static    = try(each.value.enable_cpu_manager_static, false)
      cpu_manager_reconcile_period = var.cpu_manager_reconcile_period
      cluster_dns_ip               = var.cluster_dns_ip
    })
  ) : null

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-${each.key}"
    })
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# EKS Node Groups
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "nodes" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  instance_types = each.value.instance_types
  ami_type       = each.value.ami_type
  capacity_type  = each.value.capacity_type

  # disk_size must be null when a launch template is used (disk defined in LT block_device_mappings)
  disk_size = contains(keys(local.node_groups_use_lt), each.key) ? null : each.value.disk_size

  dynamic "launch_template" {
    for_each = contains(keys(local.node_groups_use_lt), each.key) ? [1] : []
    content {
      id      = aws_launch_template.nodes[each.key].id
      version = "$Latest"
    }
  }

  labels = merge(
    each.value.labels,
    var.enable_cluster_autoscaler ? {
      "k8s.io/cluster-autoscaler/enabled"             = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    } : {}
  )

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-${each.key}"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_policies
  ]

  timeouts {
    create = "30m"
    update = "60m"
    delete = "30m"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# EKS Access Entry - Grant admin access
# -----------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin" {
  count = var.admin_role_arn != null ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_role_arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  count = var.admin_role_arn != null ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_role_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# -----------------------------------------------------------------------------
# IRSA role for WEKA operator/controller (ENI management)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "weka_operator_assume_role" {
  count = var.enable_weka_operator_irsa ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.weka_operator_namespace}:${var.weka_operator_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "weka_operator" {
  count              = var.enable_weka_operator_irsa ? 1 : 0
  name_prefix        = "${var.cluster_name}-weka-operator-"
  assume_role_policy = data.aws_iam_policy_document.weka_operator_assume_role[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "weka_operator_eni" {
  count = var.enable_weka_operator_irsa ? 1 : 0

  statement {
    sid    = "EC2Describe"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
      "ec2:DescribeInstanceTypes"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EC2ManageENIs"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:AttachNetworkInterface",
      "ec2:DetachNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
      "ec2:CreateTags"
    ]
    resources = ["*"]

    dynamic "condition" {
      for_each = var.enforce_eni_tag_conditions ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:RequestTag/${var.eni_tag_key}"
        values   = [local.eni_tag_value_effective]
      }
    }

    dynamic "condition" {
      for_each = var.enforce_eni_tag_conditions ? [1] : []
      content {
        test     = "StringEquals"
        variable = "ec2:ResourceTag/${var.eni_tag_key}"
        values   = [local.eni_tag_value_effective]
      }
    }
  }
}

resource "aws_iam_policy" "weka_operator_eni" {
  count       = var.enable_weka_operator_irsa ? 1 : 0
  name_prefix = "${var.cluster_name}-weka-eni-"
  policy      = data.aws_iam_policy_document.weka_operator_eni[0].json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "weka_operator_eni" {
  count      = var.enable_weka_operator_irsa ? 1 : 0
  role       = aws_iam_role.weka_operator[0].name
  policy_arn = aws_iam_policy.weka_operator_eni[0].arn
}
