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

# Discover VPC ID from the first subnet (all subnets must be in the same VPC)
data "aws_subnet" "first" {
  id = var.subnet_ids[0]
}

# -----------------------------------------------------------------------------
# IAM roles for EKS cluster and nodes
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

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.nodes.name
}

resource "aws_iam_role_policy_attachment" "nodes_ssm" {
  count      = var.enable_ssm_access ? 1 : 0
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -----------------------------------------------------------------------------
# EKS cluster
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
# OIDC provider (IRSA)
# -----------------------------------------------------------------------------
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# -----------------------------------------------------------------------------
# EKS access entry for cluster admin (optional)
# -----------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin" {
  count        = var.admin_role_arn != null ? 1 : 0
  cluster_name = aws_eks_cluster.main.name
  principal_arn = var.admin_role_arn

  type = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  count        = var.admin_role_arn != null ? 1 : 0
  cluster_name = aws_eks_cluster.main.name
  principal_arn = var.admin_role_arn

  policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# -----------------------------------------------------------------------------
# Optional WEKA intra-node security group (self-referencing)
# -----------------------------------------------------------------------------
resource "aws_security_group" "weka_nodes" {
  count       = var.create_weka_nodes_security_group ? 1 : 0
  name_prefix = "${var.cluster_name}-weka-nodes-"
  description = "WEKA intra-node traffic (self-referencing)"
  vpc_id      = data.aws_subnet.first.vpc_id
  tags        = var.tags
}

resource "aws_security_group_rule" "weka_nodes_ingress_self" {
  count             = var.create_weka_nodes_security_group ? 1 : 0
  type              = "ingress"
  security_group_id = aws_security_group.weka_nodes[0].id

  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.weka_nodes[0].id
  description              = "Allow all traffic within WEKA nodes SG"
}

resource "aws_security_group_rule" "weka_nodes_egress_all" {
  count             = var.create_weka_nodes_security_group ? 1 : 0
  type              = "egress"
  security_group_id = aws_security_group.weka_nodes[0].id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  description = "Allow all egress"
}

# -----------------------------------------------------------------------------
# Launch templates + managed node groups
# -----------------------------------------------------------------------------
locals {
  # Security groups applied to node ENIs via launch template.
  vpc_security_group_ids = compact(concat(
    [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id],
    var.create_weka_nodes_security_group ? [aws_security_group.weka_nodes[0].id] : [],
    var.additional_node_security_group_ids
  ))

  nodeadm_user_data_by_ng = {
    for ng_name, ng in var.node_groups :
    ng_name => (
      (try(ng.enable_cpu_manager_static, false) || try(ng.hugepages_count, 0) > 0 || var.cluster_dns_ip != null)
      ? templatefile("${path.module}/nodeadm-userdata.yaml.tftpl", {
          hugepages_count              = try(ng.hugepages_count, 0)
          enable_cpu_manager_static    = try(ng.enable_cpu_manager_static, false)
          cpu_manager_reconcile_period = var.cpu_manager_reconcile_period
          cluster_dns_ip               = var.cluster_dns_ip
        })
      : null
    )
  }

  node_groups_use_lt = {
    for ng_name, ng in var.node_groups :
    ng_name => (
      try(ng.imds_hop_limit_2, false)
      || try(ng.disable_hyperthreading, false)
      || local.nodeadm_user_data_by_ng[ng_name] != null
      || var.create_weka_nodes_security_group
      || length(var.additional_node_security_group_ids) > 0
    )
  }

  eni_tag_value_effective = var.eni_tag_value != null ? var.eni_tag_value : var.cluster_name
}

resource "aws_launch_template" "nodes" {
  for_each = {
    for ng_name, ng in var.node_groups :
    ng_name => ng if local.node_groups_use_lt[ng_name]
  }

  name_prefix = "${var.cluster_name}-${each.key}-"

  # IMDS hop limit 2 required for WEKA operator ENI management from pods
  dynamic "metadata_options" {
    for_each = each.value.imds_hop_limit_2 ? [1] : []
    content {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 2
    }
  }

  # Disable hyperthreading for consistent single-threaded performance
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

  network_interfaces {
    delete_on_termination       = true
    associate_public_ip_address = false
    security_groups             = local.vpc_security_group_ids
  }

  key_name = var.key_pair_name

  user_data = local.nodeadm_user_data_by_ng[each.key] != null ? base64encode(local.nodeadm_user_data_by_ng[each.key]) : null

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-${each.key}"
    })
  }

  tags = var.tags
}

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

  # disk_size must be null when a launch template is used
  disk_size = contains(keys(local.node_groups_use_lt), each.key) ? null : each.value.disk_size

  dynamic "launch_template" {
    for_each = local.node_groups_use_lt[each.key] ? [1] : []
    content {
      id      = aws_launch_template.nodes[each.key].id
      version = "$Latest"
    }
  }

  labels = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  update_config {
    max_unavailable = 1
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
    sid     = "EC2Describe"
    effect  = "Allow"
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
    sid     = "EC2ManageENIs"
    effect  = "Allow"
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
