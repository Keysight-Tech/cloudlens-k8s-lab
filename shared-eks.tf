# ============================================================================
# SHARED EKS CLUSTER WITH DEDICATED NODES PER SE
# ============================================================================
# Single EKS cluster with DEDICATED NODE per SE for full isolation
# Each SE gets:
#   - Their own Kubernetes namespace with RBAC isolation
#   - Their own dedicated worker node (t3.medium)
#   - Node affinity ensuring pods only run on their assigned node
#
# Architecture:
#   - 1 EKS Control Plane (shared)
#   - 25 Node Groups (one per SE, each with 1 node)
#   - Nodes labeled with se-id for pod scheduling
#   - Taints to prevent cross-SE pod scheduling
#
# Capacity (25 SEs):
#   - 25x t3.medium (2 vCPU, 4GB each) = 50 vCPU, 100GB total
#   - Each SE has full access to their dedicated 2 vCPU, 4GB node
#   - Cost: ~$25/node/month = ~$625/month for 25 nodes
# ============================================================================

# ============================================================================
# LOCALS
# ============================================================================

locals {
  shared_eks_cluster_name = "${var.deployment_prefix}-shared-eks"

  # Generate SE namespace names
  se_namespaces = [for i in range(1, var.num_se_namespaces + 1) : format("se-%02d", i)]

  # ============================================================================
  # BATCHED NODE GROUP CREATION
  # ============================================================================
  # To prevent overwhelming the EKS control plane when creating many node groups,
  # we create them in batches with delays between each batch.
  # Each batch contains up to 5 node groups, created sequentially.
  # ============================================================================

  node_group_batch_size = 5  # Create 5 node groups per batch

  # Calculate which batch each SE belongs to (0-indexed)
  se_to_batch = {
    for i in range(1, var.num_se_namespaces + 1) : format("se-%02d", i) => floor((i - 1) / local.node_group_batch_size)
  }

  # Calculate total number of batches needed
  total_batches = ceil(var.num_se_namespaces / local.node_group_batch_size)
}

# ============================================================================
# SHARED EKS VPC SUBNETS
# ============================================================================

# Use existing VPC but create dedicated subnets for shared EKS
resource "aws_subnet" "shared_eks_public_az1" {
  count = var.shared_eks_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.100.20.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                                  = "${var.deployment_prefix}-shared-eks-public-az1"
    "kubernetes.io/role/elb"                              = "1"
    "kubernetes.io/cluster/${local.shared_eks_cluster_name}" = "shared"
    Type                                                  = "SharedEKS-Public"
  })

  # Extend timeout for destroy to handle NAT gateway cleanup
  timeouts {
    create = "10m"
    delete = "20m"
  }
}

resource "aws_subnet" "shared_eks_public_az2" {
  count = var.shared_eks_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.100.21.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                                  = "${var.deployment_prefix}-shared-eks-public-az2"
    "kubernetes.io/role/elb"                              = "1"
    "kubernetes.io/cluster/${local.shared_eks_cluster_name}" = "shared"
    Type                                                  = "SharedEKS-Public"
  })

  # Extend timeout for destroy to handle NAT gateway cleanup
  timeouts {
    create = "10m"
    delete = "20m"
  }
}

resource "aws_subnet" "shared_eks_private_az1" {
  count = var.shared_eks_enabled ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.100.22.0/24"
  availability_zone = "${var.aws_region}a"

  tags = merge(local.common_tags, {
    Name                                                  = "${var.deployment_prefix}-shared-eks-private-az1"
    "kubernetes.io/role/internal-elb"                     = "1"
    "kubernetes.io/cluster/${local.shared_eks_cluster_name}" = "shared"
    Type                                                  = "SharedEKS-Private"
  })
}

resource "aws_subnet" "shared_eks_private_az2" {
  count = var.shared_eks_enabled ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.100.23.0/24"
  availability_zone = "${var.aws_region}b"

  tags = merge(local.common_tags, {
    Name                                                  = "${var.deployment_prefix}-shared-eks-private-az2"
    "kubernetes.io/role/internal-elb"                     = "1"
    "kubernetes.io/cluster/${local.shared_eks_cluster_name}" = "shared"
    Type                                                  = "SharedEKS-Private"
  })
}

# NAT Gateways for private subnets
resource "aws_eip" "shared_eks_nat_az1" {
  count  = var.shared_eks_enabled ? 1 : 0
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-eks-nat-az1"
  })

  depends_on = [aws_internet_gateway.main]

  # Ensure EIP is released after NAT gateway is deleted
  lifecycle {
    create_before_destroy = false
  }
}

resource "aws_eip" "shared_eks_nat_az2" {
  count  = var.shared_eks_enabled ? 1 : 0
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-eks-nat-az2"
  })

  depends_on = [aws_internet_gateway.main]

  # Ensure EIP is released after NAT gateway is deleted
  lifecycle {
    create_before_destroy = false
  }
}

resource "aws_nat_gateway" "shared_eks_az1" {
  count = var.shared_eks_enabled ? 1 : 0

  allocation_id = aws_eip.shared_eks_nat_az1[0].id
  subnet_id     = aws_subnet.shared_eks_public_az1[0].id

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-eks-nat-az1"
  })

  depends_on = [aws_internet_gateway.main]

  # Explicit timeouts for NAT gateway operations
  timeouts {
    create = "10m"
    delete = "15m"
  }
}

resource "aws_nat_gateway" "shared_eks_az2" {
  count = var.shared_eks_enabled ? 1 : 0

  allocation_id = aws_eip.shared_eks_nat_az2[0].id
  subnet_id     = aws_subnet.shared_eks_public_az2[0].id

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-eks-nat-az2"
  })

  depends_on = [aws_internet_gateway.main]

  # Explicit timeouts for NAT gateway operations
  timeouts {
    create = "10m"
    delete = "15m"
  }
}

# Private route tables (inline routes removed to allow adding peering routes)
resource "aws_route_table" "shared_eks_private_az1" {
  count = var.shared_eks_enabled ? 1 : 0

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-eks-private-az1-rt"
  })
}

resource "aws_route_table" "shared_eks_private_az2" {
  count = var.shared_eks_enabled ? 1 : 0

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-eks-private-az2-rt"
  })
}

# Default routes to NAT gateways (extracted from inline)
resource "aws_route" "shared_eks_default_az1" {
  count = var.shared_eks_enabled ? 1 : 0

  route_table_id         = aws_route_table.shared_eks_private_az1[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.shared_eks_az1[0].id
}

resource "aws_route" "shared_eks_default_az2" {
  count = var.shared_eks_enabled ? 1 : 0

  route_table_id         = aws_route_table.shared_eks_private_az2[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.shared_eks_az2[0].id
}

# ============================================================================
# VPC PEERING ROUTES: SHARED EKS → PER-SE LAB VPCs
# ============================================================================
# Add routes from shared EKS private subnets to each SE lab VPC via peering
# ============================================================================

resource "aws_route" "shared_eks_to_se_az1" {
  for_each = var.shared_eks_enabled && var.multi_se_mode ? module.se_lab : {}

  route_table_id            = aws_route_table.shared_eks_private_az1[0].id
  destination_cidr_block    = each.value.vpc_cidr
  vpc_peering_connection_id = each.value.vpc_peering_id
}

resource "aws_route" "shared_eks_to_se_az2" {
  for_each = var.shared_eks_enabled && var.multi_se_mode ? module.se_lab : {}

  route_table_id            = aws_route_table.shared_eks_private_az2[0].id
  destination_cidr_block    = each.value.vpc_cidr
  vpc_peering_connection_id = each.value.vpc_peering_id
}

# ============================================================================
# VPC PEERING ROUTES: SHARED VPC MAIN RT → PER-SE LAB VPCs
# ============================================================================
# The main route table is used by EKS public subnets, CyPerf controller,
# CyPerf agent management/test subnets. Without these routes, resources on
# the main RT cannot reach SE lab VPCs via peering.
# ============================================================================

resource "aws_route" "shared_main_to_se" {
  for_each = var.shared_eks_enabled && var.multi_se_mode ? module.se_lab : {}

  route_table_id            = aws_route_table.main.id
  destination_cidr_block    = each.value.vpc_cidr
  vpc_peering_connection_id = each.value.vpc_peering_id
}

# Route table associations
resource "aws_route_table_association" "shared_eks_public_az1" {
  count = var.shared_eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.shared_eks_public_az1[0].id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "shared_eks_public_az2" {
  count = var.shared_eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.shared_eks_public_az2[0].id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "shared_eks_private_az1" {
  count = var.shared_eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.shared_eks_private_az1[0].id
  route_table_id = aws_route_table.shared_eks_private_az1[0].id
}

resource "aws_route_table_association" "shared_eks_private_az2" {
  count = var.shared_eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.shared_eks_private_az2[0].id
  route_table_id = aws_route_table.shared_eks_private_az2[0].id
}

# ============================================================================
# IAM ROLES FOR SHARED EKS
# ============================================================================

resource "aws_iam_role" "shared_eks_cluster" {
  count = var.shared_eks_enabled ? 1 : 0

  name = "${var.deployment_prefix}-shared-eks-cluster-role"

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
    Name = "${var.deployment_prefix}-shared-eks-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "shared_eks_cluster_policy" {
  count = var.shared_eks_enabled ? 1 : 0

  role       = aws_iam_role.shared_eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "shared_eks_vpc_resource_controller" {
  count = var.shared_eks_enabled ? 1 : 0

  role       = aws_iam_role.shared_eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

resource "aws_iam_role" "shared_eks_node" {
  count = var.shared_eks_enabled ? 1 : 0

  name = "${var.deployment_prefix}-shared-eks-node-role"

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
    Name = "${var.deployment_prefix}-shared-eks-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "shared_eks_node_policy" {
  count = var.shared_eks_enabled ? 1 : 0

  role       = aws_iam_role.shared_eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "shared_eks_cni_policy" {
  count = var.shared_eks_enabled ? 1 : 0

  role       = aws_iam_role.shared_eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "shared_eks_ecr_policy" {
  count = var.shared_eks_enabled ? 1 : 0

  role       = aws_iam_role.shared_eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "shared_eks_ssm_policy" {
  count = var.shared_eks_enabled ? 1 : 0

  role       = aws_iam_role.shared_eks_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ============================================================================
# SHARED EKS CLUSTER
# ============================================================================

resource "aws_eks_cluster" "shared" {
  count = var.shared_eks_enabled ? 1 : 0

  name     = local.shared_eks_cluster_name
  role_arn = aws_iam_role.shared_eks_cluster[0].arn
  version  = var.shared_eks_kubernetes_version

  vpc_config {
    subnet_ids = concat(
      [aws_subnet.shared_eks_private_az1[0].id, aws_subnet.shared_eks_private_az2[0].id],
      [aws_subnet.shared_eks_public_az1[0].id, aws_subnet.shared_eks_public_az2[0].id]
    )
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = [var.allowed_ssh_cidr]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = merge(local.common_tags, {
    Name        = local.shared_eks_cluster_name
    Description = "Shared EKS cluster for all SE training labs"
    Type        = "SharedEKS"
  })

  depends_on = [
    aws_iam_role_policy_attachment.shared_eks_cluster_policy,
    aws_iam_role_policy_attachment.shared_eks_vpc_resource_controller
  ]
}

# ============================================================================
# OIDC PROVIDER FOR IRSA (IAM Roles for Service Accounts)
# ============================================================================

data "tls_certificate" "shared_eks" {
  count = var.shared_eks_enabled ? 1 : 0
  url   = aws_eks_cluster.shared[0].identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "shared_eks" {
  count = var.shared_eks_enabled ? 1 : 0

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.shared_eks[0].certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.shared[0].identity[0].oidc[0].issuer

  tags = merge(local.common_tags, {
    Name = "${local.shared_eks_cluster_name}-oidc-provider"
  })
}

# ============================================================================
# EBS CSI DRIVER IAM ROLE (for IRSA)
# ============================================================================

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  count = var.shared_eks_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.shared_eks[0].url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.shared_eks[0].url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.shared_eks[0].arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  count = var.shared_eks_enabled ? 1 : 0

  name               = "${local.shared_eks_cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role[0].json

  tags = merge(local.common_tags, {
    Name = "${local.shared_eks_cluster_name}-ebs-csi-driver-role"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  count = var.shared_eks_enabled ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver[0].name
}

# ============================================================================
# EKS ADD-ONS
# ============================================================================

resource "aws_eks_addon" "shared_vpc_cni" {
  count = var.shared_eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.shared[0].name
  addon_name                  = "vpc-cni"
  addon_version               = "v1.21.1-eksbuild.1"  # Latest stable
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.shared_eks_cluster_name}-vpc-cni"
  })

  depends_on = [aws_eks_cluster.shared]
}

resource "aws_eks_addon" "shared_coredns" {
  count = var.shared_eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.shared[0].name
  addon_name                  = "coredns"
  addon_version               = "v1.11.4-eksbuild.24"  # Latest stable
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.shared_eks_cluster_name}-coredns"
  })

  depends_on = [
    aws_eks_cluster.shared,
    aws_eks_node_group.system  # CoreDNS runs on system nodes (not tainted)
  ]
}

resource "aws_eks_addon" "shared_kube_proxy" {
  count = var.shared_eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.shared[0].name
  addon_name                  = "kube-proxy"
  addon_version               = "v1.31.14-eksbuild.2"  # Latest stable
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.shared_eks_cluster_name}-kube-proxy"
  })

  depends_on = [aws_eks_cluster.shared]
}

resource "aws_eks_addon" "shared_ebs_csi_driver" {
  count = var.shared_eks_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.shared[0].name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.54.0-eksbuild.1"  # Latest stable
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi_driver[0].arn

  tags = merge(local.common_tags, {
    Name = "${local.shared_eks_cluster_name}-ebs-csi"
  })

  # EBS CSI driver requires running nodes and IRSA role to become ACTIVE
  depends_on = [
    aws_eks_cluster.shared,
    aws_eks_node_group.system,                  # Must have nodes for addon to become ACTIVE
    aws_iam_role_policy_attachment.ebs_csi_driver  # IAM role must be ready
  ]

  # Extended timeout for addon to become ACTIVE
  timeouts {
    create = "30m"  # Extended from default 20m
    update = "30m"
    delete = "20m"
  }
}

# ============================================================================
# SYSTEM NODE GROUP (for CoreDNS, kube-system pods)
# ============================================================================
# Dedicated node(s) for system components without SE taints
# ============================================================================

resource "aws_eks_node_group" "system" {
  count = var.shared_eks_enabled ? 1 : 0

  cluster_name    = aws_eks_cluster.shared[0].name
  node_group_name = "${var.deployment_prefix}-system-nodes"
  node_role_arn   = aws_iam_role.shared_eks_node[0].arn
  subnet_ids      = [aws_subnet.shared_eks_private_az1[0].id, aws_subnet.shared_eks_private_az2[0].id]

  scaling_config {
    desired_size = 2  # 2 system nodes for HA
    min_size     = 2
    max_size     = 3
  }

  instance_types = ["t3.small"]  # Small nodes for system pods
  capacity_type  = "ON_DEMAND"
  disk_size      = 20

  update_config {
    max_unavailable = 1
  }

  labels = {
    "role"        = "system"
    "environment" = var.deployment_prefix
    "type"        = "system-services"
    "managed-by"  = "terraform"
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-system-nodes"
    Type = "SystemNode"
  })

  depends_on = [
    aws_iam_role_policy_attachment.shared_eks_node_policy,
    aws_iam_role_policy_attachment.shared_eks_cni_policy,
    aws_iam_role_policy_attachment.shared_eks_ecr_policy,
    aws_eks_cluster.shared,
    time_sleep.wait_for_eks_cluster  # Wait for cluster API to stabilize
  ]

  # Extended timeouts for node group creation
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# EKS CONTROL PLANE STABILIZATION
# ============================================================================
# Wait for the EKS cluster and system nodes to fully stabilize before
# creating SE dedicated node groups. This prevents overwhelming the
# control plane with too many concurrent node registrations.
#
# IMPORTANT: When deploying many SEs (10+), use:
#   terraform apply -parallelism=5
# This limits concurrent node group creation to 5 at a time.
# ============================================================================

# Wait for system nodes to be fully ready before starting SE node groups
resource "time_sleep" "wait_for_system_nodes" {
  count = var.shared_eks_enabled && var.shared_eks_dedicated_node_per_se ? 1 : 0

  depends_on      = [aws_eks_node_group.system]
  create_duration = "180s"  # Wait 3 minutes for system nodes to fully stabilize
}

# Wait for EKS cluster to be fully ready (API server responsive)
resource "time_sleep" "wait_for_eks_cluster" {
  count = var.shared_eks_enabled ? 1 : 0

  depends_on      = [aws_eks_cluster.shared]
  create_duration = "60s"  # Wait 1 minute for cluster API to stabilize
}

# ============================================================================
# LAUNCH TEMPLATES FOR SE DEDICATED NODES
# ============================================================================
# Launch templates ensure EC2 instances are tagged with SE-ID for SSM filtering
# This allows SE-specific access control via AWS Session Manager
# ============================================================================

resource "aws_launch_template" "se_dedicated_node" {
  for_each = var.shared_eks_enabled && var.shared_eks_dedicated_node_per_se ? {
    for i in range(1, var.num_se_namespaces + 1) : format("se-%02d", i) => {
      index = i
      name  = format("se-%02d", i)
    }
  } : {}

  name_prefix = "${var.deployment_prefix}-${each.key}-lt-"

  # Instance configuration
  instance_type = var.shared_eks_node_instance_type

  # Allow non-hostNetwork pods to access IMDS (needed for CloudLens sidecar sensor)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  # Tag the EC2 instances with SE-ID for SSM access filtering
  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name    = "${var.deployment_prefix}-${each.key}-node"
      "SE-ID" = each.key
      Type    = "DedicatedSENode"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name    = "${var.deployment_prefix}-${each.key}-volume"
      "SE-ID" = each.key
    })
  }

  tags = merge(local.common_tags, {
    Name    = "${var.deployment_prefix}-${each.key}-launch-template"
    "SE-ID" = each.key
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# DEDICATED NODE GROUPS (ONE PER SE)
# ============================================================================
# Each SE gets their own dedicated node with:
#   - Label: se-id=se-XX (for nodeSelector/affinity)
#   - Taint: se-id=se-XX:NoSchedule (prevents other SEs from using node)
#   - EC2 Instance tagged with SE-ID for SSM access control
# ============================================================================

resource "aws_eks_node_group" "se_dedicated" {
  for_each = var.shared_eks_enabled && var.shared_eks_dedicated_node_per_se ? {
    for i in range(1, var.num_se_namespaces + 1) : format("se-%02d", i) => {
      index = i
      name  = format("se-%02d", i)
    }
  } : {}

  cluster_name    = aws_eks_cluster.shared[0].name
  node_group_name = "${var.deployment_prefix}-${each.key}-node"
  node_role_arn   = aws_iam_role.shared_eks_node[0].arn

  # Distribute nodes across AZs based on SE number (odd = az1, even = az2)
  subnet_ids = each.value.index % 2 == 1 ? [aws_subnet.shared_eks_private_az1[0].id] : [aws_subnet.shared_eks_private_az2[0].id]

  scaling_config {
    desired_size = 1  # One dedicated node per SE
    min_size     = 0  # Allow scaling to 0 for cost savings when stopped
    max_size     = 1  # Fixed size - no auto-scaling per SE
  }

  # Use launch template for EC2 instance SE-ID tagging (enables SSM access control)
  launch_template {
    id      = aws_launch_template.se_dedicated_node[each.key].id
    version = aws_launch_template.se_dedicated_node[each.key].latest_version
  }

  # Note: instance_types and disk_size are configured in launch template
  capacity_type = "ON_DEMAND"

  update_config {
    max_unavailable = 1
  }

  # Labels for node selection
  labels = {
    "se-id"       = each.key
    "role"        = "se-dedicated-worker"
    "environment" = var.deployment_prefix
    "type"        = "se-training"
    "managed-by"  = "terraform"
  }

  # Taint to prevent other SEs' pods from scheduling on this node
  taint {
    key    = "se-id"
    value  = each.key
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.common_tags, {
    Name     = "${var.deployment_prefix}-${each.key}-node"
    Type     = "DedicatedSENode"
    "SE-ID"  = each.key
    "SE-Num" = each.value.index
    "Batch"  = local.se_to_batch[each.key]  # Track which batch this node belongs to
  })

  # Wait for system nodes to fully stabilize before creating SE node groups
  # This prevents overwhelming the EKS control plane
  depends_on = [
    aws_iam_role_policy_attachment.shared_eks_node_policy,
    aws_iam_role_policy_attachment.shared_eks_cni_policy,
    aws_iam_role_policy_attachment.shared_eks_ecr_policy,
    aws_eks_cluster.shared,
    aws_launch_template.se_dedicated_node,
    time_sleep.wait_for_system_nodes  # Critical: wait for system nodes first
  ]

  # Extended timeouts to handle EKS control plane throttling
  timeouts {
    create = "45m"  # Extended from default 25m for large deployments
    update = "30m"
    delete = "30m"
  }

  lifecycle {
    create_before_destroy = true
    # Ignore changes to scaling config to allow manual scaling if needed
    # This prevents conflicts when nodes are stopped (desired_size=0)
    ignore_changes = [scaling_config[0].desired_size, scaling_config[0].min_size]
  }
}

# ============================================================================
# KUBERNETES PROVIDER FOR SHARED EKS
# ============================================================================

data "aws_eks_cluster_auth" "shared" {
  count = var.shared_eks_enabled ? 1 : 0
  name  = aws_eks_cluster.shared[0].name
}

# ============================================================================
# OUTPUTS (additional - main outputs in multi-se-outputs.tf)
# ============================================================================

output "shared_eks_cluster_version" {
  description = "Shared EKS Kubernetes version"
  value       = var.shared_eks_enabled ? aws_eks_cluster.shared[0].version : "Shared EKS not enabled"
}

output "shared_eks_kubeconfig_command" {
  description = "Command to configure kubectl for shared EKS cluster"
  value       = var.shared_eks_enabled ? "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.shared[0].name} --profile ${var.aws_profile}" : "Shared EKS not enabled"
}

output "shared_eks_node_group_status" {
  description = "Status of SE dedicated node groups"
  value = var.shared_eks_enabled && var.shared_eks_dedicated_node_per_se ? {
    for k, ng in aws_eks_node_group.se_dedicated : k => ng.status
  } : { message = "Dedicated nodes not enabled" }
}

output "shared_eks_capacity" {
  description = "Shared EKS cluster capacity with dedicated nodes per SE"
  value = var.shared_eks_enabled ? {
    architecture        = var.shared_eks_dedicated_node_per_se ? "dedicated-node-per-se" : "shared-nodes"
    node_count          = var.shared_eks_dedicated_node_per_se ? var.num_se_namespaces : 5
    instance_type       = var.shared_eks_node_instance_type
    vcpu_per_se         = 2  # t3.medium = 2 vCPU
    memory_per_se       = "4GB"  # t3.medium = 4GB
    total_vcpu          = var.num_se_namespaces * 2
    total_memory        = "${var.num_se_namespaces * 4}GB"
    estimated_cost_mo   = "$${var.num_se_namespaces * 25}"  # ~$25/node/month
    max_ses             = var.num_se_namespaces
  } : {}
}

output "shared_eks_namespaces" {
  description = "SE namespaces to be created"
  value       = var.shared_eks_enabled ? local.se_namespaces : []
}

output "shared_eks_se_node_assignments" {
  description = "Node assignments per SE"
  value = var.shared_eks_enabled && var.shared_eks_dedicated_node_per_se ? {
    for k, ng in aws_eks_node_group.se_dedicated : k => {
      node_group = ng.node_group_name
      status     = ng.status
      labels     = ng.labels
    }
  } : {}
}
