# ============================================================================
# CYPERF CONTROLLER EC2 INSTANCE
# ============================================================================
# Keysight CyPerf Controller for L4-7 traffic generation
# K8s-based agents connect to this controller's private IP
# ============================================================================

# ============================================================================
# DATA SOURCES
# ============================================================================

data "aws_ami" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = ["cyperf-mdw-*-releasecyperf70-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================================
# SUBNET FOR CYPERF CONTROLLER (within the lab VPC)
# ============================================================================

resource "aws_subnet" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  vpc_id                  = module.lab.vpc_id
  cidr_block              = "10.1.30.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.deployment_prefix}-cyperf-controller-subnet"
    Type    = "CyPerfController"
    Project = var.deployment_prefix
  }
}

resource "aws_route_table_association" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  subnet_id      = aws_subnet.cyperf_controller[0].id
  route_table_id = module.lab.route_table_id
}

# ============================================================================
# SECURITY GROUP
# ============================================================================

resource "aws_security_group" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  name        = "${var.deployment_prefix}-cyperf-controller-sg"
  description = "Security group for CyPerf Controller"
  vpc_id      = module.lab.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # HTTPS UI + agent communication (from user + entire VPC for K8s agents)
  ingress {
    description = "HTTPS and agent communication"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr, module.lab.vpc_cidr]
  }

  # HTTP from VPC (K8s agent traffic)
  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.lab.vpc_cidr]
  }

  # Allow all outbound
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.deployment_prefix}-cyperf-controller-sg"
    Project = var.deployment_prefix
  }
}

# ============================================================================
# CYPERF CONTROLLER INSTANCE
# ============================================================================

resource "aws_instance" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  ami                    = data.aws_ami.cyperf_controller[0].id
  instance_type          = var.cyperf_controller_instance_type
  key_name               = var.key_pair_name
  subnet_id              = aws_subnet.cyperf_controller[0].id
  vpc_security_group_ids = [aws_security_group.cyperf_controller[0].id]

  root_block_device {
    volume_size           = 256
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.deployment_prefix}-cyperf-controller"
    Role    = "CyPerfController"
    Project = var.deployment_prefix
  }
}

# ============================================================================
# ELASTIC IP
# ============================================================================

resource "aws_eip" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  instance = aws_instance.cyperf_controller[0].id
  domain   = "vpc"

  tags = {
    Name    = "${var.deployment_prefix}-cyperf-controller-eip"
    Project = var.deployment_prefix
  }
}

# ============================================================================
# AUTO-DEPLOY K8S AGENTS (runs after controller + EKS are ready)
# ============================================================================

resource "null_resource" "deploy_cyperf_k8s" {
  count = var.cyperf_enabled && var.eks_enabled ? 1 : 0

  # Re-run if controller or EKS changes
  triggers = {
    controller_id  = aws_instance.cyperf_controller[0].id
    controller_ip  = aws_instance.cyperf_controller[0].private_ip
    controller_eip = aws_eip.cyperf_controller[0].public_ip
    eks_cluster    = module.lab.eks_cluster_name
  }

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/deploy-cyperf-k8s.sh"
    working_dir = path.module

    environment = {
      CYPERF_CONTROLLER_PRIVATE_IP = aws_instance.cyperf_controller[0].private_ip
      CYPERF_CONTROLLER_PUBLIC_IP  = aws_eip.cyperf_controller[0].public_ip
      CYPERF_EKS_CLUSTER_NAME      = module.lab.eks_cluster_name
      CYPERF_AWS_REGION             = var.aws_region
      CYPERF_AWS_PROFILE            = var.aws_profile
      CYPERF_DEPLOYMENT_PREFIX      = var.deployment_prefix
    }
  }

  depends_on = [
    aws_instance.cyperf_controller,
    aws_eip.cyperf_controller,
    module.lab
  ]
}
