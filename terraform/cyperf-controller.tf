# ============================================================================
# CYPERF CONTROLLER EC2 INSTANCE
# ============================================================================
# Keysight CyPerf Controller for L4-7 traffic generation
# VM-based CyPerf agents connect to this controller's private IP
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
# SUBNET FOR CYPERF CONTROLLER
# ============================================================================

resource "aws_subnet" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.100.30.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-controller-subnet"
    Type = "CyPerfController"
  })
}

resource "aws_route_table_association" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  subnet_id      = aws_subnet.cyperf_controller[0].id
  route_table_id = aws_route_table.main.id
}

# ============================================================================
# SECURITY GROUP
# ============================================================================

resource "aws_security_group" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  name        = "${var.deployment_prefix}-cyperf-controller-sg"
  description = "Security group for CyPerf Controller"
  vpc_id      = aws_vpc.main.id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # HTTPS UI + agent communication
  ingress {
    description = "HTTPS and agent communication"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr, var.shared_vpc_cidr]
  }

  # Agent test traffic (HTTP, HTTPS, SMTP, PostgreSQL)
  ingress {
    description = "HTTP from agent test subnets"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.100.42.0/24", "10.100.43.0/24"]
  }

  ingress {
    description = "HTTPS from agent test subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.100.42.0/24", "10.100.43.0/24"]
  }

  ingress {
    description = "SMTP from agent test subnets"
    from_port   = 25
    to_port     = 25
    protocol    = "tcp"
    cidr_blocks = ["10.100.42.0/24", "10.100.43.0/24"]
  }

  ingress {
    description = "PostgreSQL from agent test subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.100.42.0/24", "10.100.43.0/24"]
  }

  # Allow all outbound
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-controller-sg"
  })
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

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-controller"
    Role = "CyPerfController"
  })
}

# ============================================================================
# ELASTIC IP
# ============================================================================

resource "aws_eip" "cyperf_controller" {
  count = var.cyperf_enabled ? 1 : 0

  instance = aws_instance.cyperf_controller[0].id
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-controller-eip"
  })
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "cyperf_controller_public_ip" {
  description = "CyPerf Controller public IP"
  value       = var.cyperf_enabled ? aws_eip.cyperf_controller[0].public_ip : null
}

output "cyperf_controller_private_ip" {
  description = "CyPerf Controller private IP (for VM agents)"
  value       = var.cyperf_enabled ? aws_instance.cyperf_controller[0].private_ip : null
}

output "cyperf_controller_ui_url" {
  description = "CyPerf Controller UI URL"
  value       = var.cyperf_enabled ? "https://${aws_eip.cyperf_controller[0].public_ip}" : null
}

output "cyperf_controller_ssh" {
  description = "SSH command for CyPerf Controller"
  value       = var.cyperf_enabled ? "ssh -i ~/path/to/cloudlens-se-training.pem admin@${aws_eip.cyperf_controller[0].public_ip}" : null
}
