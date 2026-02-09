# ============================================================================
# CYPERF VM-BASED AGENTS (CLIENT + SERVER)
# ============================================================================
# Two EC2 instances with dual ENIs each: management + test
# Client sends real HTTP through nginx pods to Server
# CloudLens sensors on nginx pods see all traffic
#
# Architecture:
#   CyPerf Client VM (test ENI) -> nginx NLB -> nginx pod -> CyPerf Server VM (test ENI)
#   Both VMs connect to CyPerf Controller via management ENI
# ============================================================================

# ============================================================================
# DATA SOURCES
# ============================================================================

data "aws_ami" "cyperf_agent" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = ["img-cyperf-agent-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================================
# SUBNETS (4 new)
# ============================================================================

# Client management subnet (public, with EIP for SSH)
resource "aws_subnet" "cyperf_client_mgmt" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.100.40.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-client-mgmt-subnet"
    Type = "CyPerfAgentMgmt"
  })
}

resource "aws_route_table_association" "cyperf_client_mgmt" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id      = aws_subnet.cyperf_client_mgmt[0].id
  route_table_id = aws_route_table.main.id
}

# Server management subnet (public, with EIP for SSH)
resource "aws_subnet" "cyperf_server_mgmt" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.100.41.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-server-mgmt-subnet"
    Type = "CyPerfAgentMgmt"
  })
}

resource "aws_route_table_association" "cyperf_server_mgmt" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id      = aws_subnet.cyperf_server_mgmt[0].id
  route_table_id = aws_route_table.main.id
}

# Client test subnet (private, for HTTP to nginx NLBs)
resource "aws_subnet" "cyperf_client_test" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.100.42.0/24"
  availability_zone = "${var.aws_region}a"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-client-test-subnet"
    Type = "CyPerfAgentTest"
  })
}

resource "aws_route_table_association" "cyperf_client_test" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id      = aws_subnet.cyperf_client_test[0].id
  route_table_id = aws_route_table.main.id
}

# Server test subnet (private, receives proxied traffic from nginx pods)
resource "aws_subnet" "cyperf_server_test" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.100.43.0/24"
  availability_zone = "${var.aws_region}a"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-server-test-subnet"
    Type = "CyPerfAgentTest"
  })
}

resource "aws_route_table_association" "cyperf_server_test" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id      = aws_subnet.cyperf_server_test[0].id
  route_table_id = aws_route_table.main.id
}

# ============================================================================
# SECURITY GROUPS (2 new)
# ============================================================================

# Management security group: SSH + HTTPS to controller
resource "aws_security_group" "cyperf_agent_mgmt" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  name        = "${var.deployment_prefix}-cyperf-agent-mgmt-sg"
  description = "Security group for CyPerf Agent management interfaces"
  vpc_id      = aws_vpc.main.id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # HTTPS from controller (agent communication)
  ingress {
    description = "HTTPS agent communication"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.shared_vpc_cidr]
  }

  # Allow all outbound (agents need to reach controller)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-agent-mgmt-sg"
  })
}

# Test security group: VPC-internal test traffic
resource "aws_security_group" "cyperf_agent_test" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  name        = "${var.deployment_prefix}-cyperf-agent-test-sg"
  description = "Security group for CyPerf Agent test interfaces"
  vpc_id      = aws_vpc.main.id

  # All inbound from VPC (test traffic between agents and nginx)
  ingress {
    description = "All VPC-internal test traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.shared_vpc_cidr]
  }

  # All outbound (test traffic)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-agent-test-sg"
  })
}

# ============================================================================
# NETWORK INTERFACES (4 new)
# ============================================================================

# Client management ENI (eth0)
resource "aws_network_interface" "cyperf_client_mgmt" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id       = aws_subnet.cyperf_client_mgmt[0].id
  security_groups = [aws_security_group.cyperf_agent_mgmt[0].id]

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-client-mgmt-eni"
  })
}

# Client test ENI (eth1)
resource "aws_network_interface" "cyperf_client_test" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id         = aws_subnet.cyperf_client_test[0].id
  security_groups   = [aws_security_group.cyperf_agent_test[0].id]
  source_dest_check = false

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-client-test-eni"
  })
}

# Server management ENI (eth0)
resource "aws_network_interface" "cyperf_server_mgmt" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id       = aws_subnet.cyperf_server_mgmt[0].id
  security_groups = [aws_security_group.cyperf_agent_mgmt[0].id]

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-server-mgmt-eni"
  })
}

# Server test ENI (eth1)
resource "aws_network_interface" "cyperf_server_test" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  subnet_id         = aws_subnet.cyperf_server_test[0].id
  security_groups   = [aws_security_group.cyperf_agent_test[0].id]
  source_dest_check = false

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-server-test-eni"
  })
}

# ============================================================================
# EC2 INSTANCES (2 new)
# ============================================================================

resource "aws_instance" "cyperf_client" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  ami           = data.aws_ami.cyperf_agent[0].id
  instance_type = var.cyperf_agent_instance_type
  key_name      = var.key_pair_name

  # Primary ENI (management)
  network_interface {
    network_interface_id = aws_network_interface.cyperf_client_mgmt[0].id
    device_index         = 0
  }

  # Secondary ENI (test)
  network_interface {
    network_interface_id = aws_network_interface.cyperf_client_test[0].id
    device_index         = 1
  }

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/cyperf-agent-userdata.sh.tpl", {
    controller_ip = aws_instance.cyperf_controller[0].private_ip
    agent_role    = "client"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-client"
    Role = "CyPerfClient"
  })

  depends_on = [aws_instance.cyperf_controller]
}

resource "aws_instance" "cyperf_server" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  ami           = data.aws_ami.cyperf_agent[0].id
  instance_type = var.cyperf_agent_instance_type
  key_name      = var.key_pair_name

  # Primary ENI (management)
  network_interface {
    network_interface_id = aws_network_interface.cyperf_server_mgmt[0].id
    device_index         = 0
  }

  # Secondary ENI (test)
  network_interface {
    network_interface_id = aws_network_interface.cyperf_server_test[0].id
    device_index         = 1
  }

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/cyperf-agent-userdata.sh.tpl", {
    controller_ip = aws_instance.cyperf_controller[0].private_ip
    agent_role    = "server"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-server"
    Role = "CyPerfServer"
  })

  depends_on = [aws_instance.cyperf_controller]
}

# ============================================================================
# ELASTIC IPS (2 new - one per VM for SSH access)
# ============================================================================

resource "aws_eip" "cyperf_client" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  network_interface = aws_network_interface.cyperf_client_mgmt[0].id
  domain            = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-client-eip"
  })

  depends_on = [aws_instance.cyperf_client]
}

resource "aws_eip" "cyperf_server" {
  count = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? 1 : 0

  network_interface = aws_network_interface.cyperf_server_mgmt[0].id
  domain            = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cyperf-server-eip"
  })

  depends_on = [aws_instance.cyperf_server]
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "cyperf_client_public_ip" {
  description = "CyPerf Client VM public IP (SSH)"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? aws_eip.cyperf_client[0].public_ip : null
}

output "cyperf_client_mgmt_ip" {
  description = "CyPerf Client VM management private IP"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? aws_network_interface.cyperf_client_mgmt[0].private_ip : null
}

output "cyperf_client_test_ip" {
  description = "CyPerf Client VM test ENI private IP"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? aws_network_interface.cyperf_client_test[0].private_ip : null
}

output "cyperf_server_public_ip" {
  description = "CyPerf Server VM public IP (SSH)"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? aws_eip.cyperf_server[0].public_ip : null
}

output "cyperf_server_mgmt_ip" {
  description = "CyPerf Server VM management private IP"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? aws_network_interface.cyperf_server_mgmt[0].private_ip : null
}

output "cyperf_server_test_ip" {
  description = "CyPerf Server VM test ENI private IP"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? aws_network_interface.cyperf_server_test[0].private_ip : null
}

output "cyperf_client_ssh" {
  description = "SSH command for CyPerf Client VM"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? "ssh -i ~/path/to/cloudlens-se-training.pem cyperf@${aws_eip.cyperf_client[0].public_ip}" : null
}

output "cyperf_server_ssh" {
  description = "SSH command for CyPerf Server VM"
  value       = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? "ssh -i ~/path/to/cloudlens-se-training.pem cyperf@${aws_eip.cyperf_server[0].public_ip}" : null
}
