# ============================================================================
# EKS CLUSTER AND NODE GROUP (Conditional)
# ============================================================================

# ============================================================================
# EKS IAM ROLES
# ============================================================================

resource "aws_iam_role" "eks_cluster" {
  count = var.eks_enabled ? 1 : 0

  name = "${var.deployment_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  count = var.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  count = var.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

resource "aws_iam_role" "eks_node" {
  count = var.eks_enabled ? 1 : 0

  name = "${var.deployment_prefix}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  count = var.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  count = var.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_policy" {
  count = var.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_ssm_policy" {
  count = var.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ============================================================================
# EKS CLUSTER
# ============================================================================

resource "aws_eks_cluster" "main" {
  count = var.eks_enabled ? 1 : 0

  name     = local.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster[0].arn
  version  = var.eks_kubernetes_version

  vpc_config {
    subnet_ids = concat(
      [aws_subnet.eks_private_az1[0].id, aws_subnet.eks_private_az2[0].id],
      [aws_subnet.eks_public_az1[0].id, aws_subnet.eks_public_az2[0].id]
    )
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = merge(local.common_tags, {
    Name = local.eks_cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# ============================================================================
# EKS ADD-ONS
# ============================================================================

resource "aws_eks_addon" "vpc_cni" {
  count = var.eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "vpc-cni"
  addon_version               = "v1.18.1-eksbuild.3"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.eks_cluster_name}-vpc-cni"
  })

  depends_on = [aws_eks_cluster.main]
}

resource "aws_eks_addon" "coredns" {
  count = var.eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "coredns"
  addon_version               = "v1.11.1-eksbuild.9"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.eks_cluster_name}-coredns"
  })

  depends_on = [
    aws_eks_cluster.main,
    aws_eks_node_group.main
  ]
}

resource "aws_eks_addon" "kube_proxy" {
  count = var.eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "kube-proxy"
  addon_version               = "v1.31.0-eksbuild.5"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.eks_cluster_name}-kube-proxy"
  })

  depends_on = [aws_eks_cluster.main]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  count = var.eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.main[0].name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.34.0-eksbuild.1"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.eks_cluster_name}-ebs-csi"
  })

  depends_on = [aws_eks_cluster.main]
}

# ============================================================================
# EKS NODE GROUP
# ============================================================================

resource "aws_eks_node_group" "main" {
  count = var.eks_enabled ? 1 : 0

  cluster_name    = aws_eks_cluster.main[0].name
  node_group_name = "${var.deployment_prefix}-eks-nodes"
  node_role_arn   = aws_iam_role.eks_node[0].arn
  subnet_ids      = [aws_subnet.eks_private_az1[0].id, aws_subnet.eks_private_az2[0].id]

  scaling_config {
    desired_size = var.eks_node_desired_size
    min_size     = var.eks_node_min_size
    max_size     = var.eks_node_max_size
  }

  instance_types = [var.eks_node_instance_type]
  capacity_type  = "ON_DEMAND"
  disk_size      = 30

  update_config {
    max_unavailable = 1
  }

  labels = {
    role        = "worker"
    environment = var.deployment_prefix
    owner       = local.owner_sanitized
    managed-by  = "terraform"
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-nodes"
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy,
    aws_eks_cluster.main
  ]

  lifecycle {
    create_before_destroy = true
  }
}
