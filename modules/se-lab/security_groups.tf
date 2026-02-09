# ============================================================================
# SECURITY GROUPS
# ============================================================================

# KVO Security Group
resource "aws_security_group" "kvo" {
  name_prefix = "${local.kvo_name}-"
  description = "Security group for ${local.kvo_name}"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_https_cidr]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_https_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${local.kvo_name}-sg" })
  lifecycle { create_before_destroy = true }
}

# CLMS Security Group
resource "aws_security_group" "clms" {
  name_prefix = "${local.clms_name}-"
  description = "Security group for ${local.clms_name}"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_https_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${local.clms_name}-sg" })
  lifecycle { create_before_destroy = true }
}

# vPB Management Security Group
resource "aws_security_group" "vpb_management" {
  name_prefix = "${local.vpb_name}-mgmt-"
  description = "Security group for ${local.vpb_name} management"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${local.vpb_name}-mgmt-sg" })
  lifecycle { create_before_destroy = true }
}

# vPB Traffic Security Group
resource "aws_security_group" "vpb_traffic" {
  name_prefix = "${local.vpb_name}-traffic-"
  description = "Security group for ${local.vpb_name} traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "GRE/ERSPAN"
    from_port   = 0
    to_port     = 0
    protocol    = "47"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "VXLAN"
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "VPC traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  # All traffic from shared EKS VPC (when shared EKS is enabled)
  dynamic "ingress" {
    for_each = var.shared_eks_enabled ? [1] : []
    content {
      description = "All traffic from shared EKS VPC"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = [var.shared_eks_vpc_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${local.vpb_name}-traffic-sg" })
  lifecycle { create_before_destroy = true }
}

# Workload VMs Security Group (Ubuntu, Windows, RHEL)
resource "aws_security_group" "workload" {
  name_prefix = "${var.deployment_prefix}-workload-"
  description = "Security group for workload VMs (Ubuntu, Windows, RHEL)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  ingress {
    description = "RDP for Windows"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "iPerf3"
    from_port   = 5201
    to_port     = 5210
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "ICMP"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "All VPC traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.deployment_prefix}-workload-sg" })
  lifecycle { create_before_destroy = true }
}

# Tool VM Security Group (for traffic capture)
resource "aws_security_group" "tool" {
  name_prefix = "${var.deployment_prefix}-tool-"
  description = "Security group for Tool VM (traffic capture/analysis)"
  vpc_id      = aws_vpc.main.id

  # SSH Access
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # RDP for Windows Tool VM
  ingress {
    description = "RDP access"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # VXLAN from entire VPC (CloudLens sensors on VMs)
  ingress {
    description = "VXLAN from VPC - CloudLens sensor tunnels"
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # GRE/ERSPAN from VPC
  ingress {
    description = "GRE/ERSPAN from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "47"
    cidr_blocks = [var.vpc_cidr]
  }

  # GENEVE (UDP 6081)
  ingress {
    description = "GENEVE from VPC - tunnel protocol"
    from_port   = 6081
    to_port     = 6081
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # All traffic from management subnet (tapped VMs)
  ingress {
    description = "All traffic from management subnet (tapped VMs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.management_subnet_cidr]
  }

  # All traffic from ingress subnet
  ingress {
    description = "All traffic from ingress subnet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.ingress_subnet_cidr]
  }

  # All traffic from egress subnet
  ingress {
    description = "All traffic from egress subnet (vPB egress)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.egress_subnet_cidr]
  }

  # ICMP for connectivity testing
  ingress {
    description = "ICMP ping"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # iPerf3 for bandwidth testing
  ingress {
    description = "iPerf3"
    from_port   = 5201
    to_port     = 5210
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # VXLAN from shared EKS VPC (when shared EKS is enabled)
  dynamic "ingress" {
    for_each = var.shared_eks_enabled ? [1] : []
    content {
      description = "VXLAN from shared EKS VPC - CloudLens sensor tunnels"
      from_port   = 4789
      to_port     = 4789
      protocol    = "udp"
      cidr_blocks = [var.shared_eks_vpc_cidr]
    }
  }

  # GRE from shared EKS VPC (when shared EKS is enabled)
  dynamic "ingress" {
    for_each = var.shared_eks_enabled ? [1] : []
    content {
      description = "GRE from shared EKS VPC"
      from_port   = 0
      to_port     = 0
      protocol    = "47"
      cidr_blocks = [var.shared_eks_vpc_cidr]
    }
  }

  # All traffic from shared EKS VPC (when shared EKS is enabled)
  dynamic "ingress" {
    for_each = var.shared_eks_enabled ? [1] : []
    content {
      description = "All traffic from shared EKS VPC"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = [var.shared_eks_vpc_cidr]
    }
  }

  # Allow all outbound
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-tool-sg"
    Role = "Traffic Capture"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# EKS-specific ingress rules for tool SG (conditional)
resource "aws_security_group_rule" "tool_vxlan_eks_az1" {
  count = var.eks_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 4789
  to_port           = 4789
  protocol          = "udp"
  cidr_blocks       = [var.eks_private_subnet_az1_cidr]
  security_group_id = aws_security_group.tool.id
  description       = "VXLAN from EKS AZ1 - CloudLens sensor tunnels"
}

resource "aws_security_group_rule" "tool_vxlan_eks_az2" {
  count = var.eks_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 4789
  to_port           = 4789
  protocol          = "udp"
  cidr_blocks       = [var.eks_private_subnet_az2_cidr]
  security_group_id = aws_security_group.tool.id
  description       = "VXLAN from EKS AZ2 - CloudLens sensor tunnels"
}

resource "aws_security_group_rule" "tool_gre_eks_az1" {
  count = var.eks_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "47"
  cidr_blocks       = [var.eks_private_subnet_az1_cidr]
  security_group_id = aws_security_group.tool.id
  description       = "GRE from EKS AZ1"
}

resource "aws_security_group_rule" "tool_gre_eks_az2" {
  count = var.eks_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "47"
  cidr_blocks       = [var.eks_private_subnet_az2_cidr]
  security_group_id = aws_security_group.tool.id
  description       = "GRE from EKS AZ2"
}

resource "aws_security_group_rule" "tool_all_eks_az1" {
  count = var.eks_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.eks_private_subnet_az1_cidr]
  security_group_id = aws_security_group.tool.id
  description       = "All traffic from EKS AZ1 pods"
}

resource "aws_security_group_rule" "tool_all_eks_az2" {
  count = var.eks_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.eks_private_subnet_az2_cidr]
  security_group_id = aws_security_group.tool.id
  description       = "All traffic from EKS AZ2 pods"
}

