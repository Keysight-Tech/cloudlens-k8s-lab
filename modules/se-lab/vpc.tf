# ============================================================================
# VPC AND NETWORKING
# ============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = local.vpc_name })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${local.vpc_name}-igw" })
}

# Management Subnet
resource "aws_subnet" "management" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.management_subnet_cidr
  availability_zone       = local.az_primary
  map_public_ip_on_launch = true
  tags                    = merge(local.common_tags, { Name = "${local.vpc_name}-mgmt-subnet", Type = "Management" })
}

# vPB Ingress Subnet
resource "aws_subnet" "ingress" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.ingress_subnet_cidr
  availability_zone       = local.az_primary
  map_public_ip_on_launch = true
  tags                    = merge(local.common_tags, { Name = "${local.vpc_name}-ingress-subnet", Type = "Ingress" })
}

# vPB Egress Subnet
resource "aws_subnet" "egress" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.egress_subnet_cidr
  availability_zone       = local.az_primary
  map_public_ip_on_launch = true
  tags                    = merge(local.common_tags, { Name = "${local.vpc_name}-egress-subnet", Type = "Egress" })
}

# Main Route Table
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${local.vpc_name}-rt" })
}

# Default route to IGW (extracted from inline to allow adding peering routes)
resource "aws_route" "default" {
  route_table_id         = aws_route_table.main.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# ============================================================================
# VPC PEERING TO SHARED EKS VPC (conditional)
# ============================================================================

resource "aws_vpc_peering_connection" "shared_eks" {
  count = var.shared_eks_enabled ? 1 : 0

  vpc_id      = aws_vpc.main.id
  peer_vpc_id = var.shared_eks_vpc_id
  auto_accept = true

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-to-shared-eks"
    Side = "Requester"
  })
}

# Route from SE VPC to shared EKS VPC via peering
resource "aws_route" "shared_eks_peering" {
  count = var.shared_eks_enabled ? 1 : 0

  route_table_id            = aws_route_table.main.id
  destination_cidr_block    = var.shared_eks_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_eks[0].id
}

resource "aws_route_table_association" "management" {
  subnet_id      = aws_subnet.management.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "ingress" {
  subnet_id      = aws_subnet.ingress.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "egress" {
  subnet_id      = aws_subnet.egress.id
  route_table_id = aws_route_table.main.id
}

# ============================================================================
# EKS SUBNETS (conditional)
# ============================================================================

# Public Subnet in AZ1
resource "aws_subnet" "eks_public_az1" {
  count = var.eks_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.eks_public_subnet_az1_cidr
  availability_zone       = local.az_primary
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                             = "${var.deployment_prefix}-eks-public-az1"
    "kubernetes.io/role/elb"                         = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
    Type                                             = "EKS-Public"
  })
}

# Public Subnet in AZ2
resource "aws_subnet" "eks_public_az2" {
  count = var.eks_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.eks_public_subnet_az2_cidr
  availability_zone       = local.az_secondary
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                             = "${var.deployment_prefix}-eks-public-az2"
    "kubernetes.io/role/elb"                         = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
    Type                                             = "EKS-Public"
  })
}

# Private Subnet in AZ1
resource "aws_subnet" "eks_private_az1" {
  count = var.eks_enabled ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.eks_private_subnet_az1_cidr
  availability_zone = local.az_primary

  tags = merge(local.common_tags, {
    Name                                             = "${var.deployment_prefix}-eks-private-az1"
    "kubernetes.io/role/internal-elb"                = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
    Type                                             = "EKS-Private"
  })
}

# Private Subnet in AZ2
resource "aws_subnet" "eks_private_az2" {
  count = var.eks_enabled ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.eks_private_subnet_az2_cidr
  availability_zone = local.az_secondary

  tags = merge(local.common_tags, {
    Name                                             = "${var.deployment_prefix}-eks-private-az2"
    "kubernetes.io/role/internal-elb"                = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
    Type                                             = "EKS-Private"
  })
}

# ============================================================================
# NAT GATEWAYS FOR EKS
# ============================================================================

resource "aws_eip" "eks_nat_az1" {
  count  = var.eks_enabled ? 1 : 0
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-nat-az1"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "eks_nat_az2" {
  count  = var.eks_enabled ? 1 : 0
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-nat-az2"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "eks_az1" {
  count = var.eks_enabled ? 1 : 0

  allocation_id = aws_eip.eks_nat_az1[0].id
  subnet_id     = aws_subnet.eks_public_az1[0].id

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-nat-az1"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "eks_az2" {
  count = var.eks_enabled ? 1 : 0

  allocation_id = aws_eip.eks_nat_az2[0].id
  subnet_id     = aws_subnet.eks_public_az2[0].id

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-nat-az2"
  })

  depends_on = [aws_internet_gateway.main]
}

# Private Route Tables for EKS
resource "aws_route_table" "eks_private_az1" {
  count = var.eks_enabled ? 1 : 0

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks_az1[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-private-az1-rt"
    Type = "EKS-Private"
  })
}

resource "aws_route_table" "eks_private_az2" {
  count = var.eks_enabled ? 1 : 0

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks_az2[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-private-az2-rt"
    Type = "EKS-Private"
  })
}

# Route Table Associations for EKS
resource "aws_route_table_association" "eks_private_az1" {
  count = var.eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.eks_private_az1[0].id
  route_table_id = aws_route_table.eks_private_az1[0].id
}

resource "aws_route_table_association" "eks_private_az2" {
  count = var.eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.eks_private_az2[0].id
  route_table_id = aws_route_table.eks_private_az2[0].id
}

resource "aws_route_table_association" "eks_public_az1" {
  count = var.eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.eks_public_az1[0].id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "eks_public_az2" {
  count = var.eks_enabled ? 1 : 0

  subnet_id      = aws_subnet.eks_public_az2[0].id
  route_table_id = aws_route_table.main.id
}
