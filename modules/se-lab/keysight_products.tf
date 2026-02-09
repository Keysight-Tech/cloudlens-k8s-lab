# ============================================================================
# KEYSIGHT PRODUCTS - CLMS, KVO, vPB
# ============================================================================

# ============================================================================
# KVO (Vision One) Instance
# ============================================================================

resource "aws_instance" "kvo" {
  ami                         = local.kvo_ami
  instance_type               = var.kvo_instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.management.id
  vpc_security_group_ids      = [aws_security_group.kvo.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 200
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.kvo_name}-root" })
  }

  tags = merge(local.common_tags, { Name = local.kvo_name })

  lifecycle {
    precondition {
      condition     = local.kvo_ami != null
      error_message = "KVO AMI not available in ${var.aws_region}"
    }
  }
}

# ============================================================================
# CLMS (CloudLens Manager) Instance
# ============================================================================

resource "aws_instance" "clms" {
  ami                         = local.clms_ami
  instance_type               = var.clms_instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.management.id
  vpc_security_group_ids      = [aws_security_group.clms.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 200
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.clms_name}-root" })
  }

  tags = merge(local.common_tags, { Name = local.clms_name })

  lifecycle {
    precondition {
      condition     = local.clms_ami != null
      error_message = "CLMS AMI not available in ${var.aws_region}"
    }
  }
}

# ============================================================================
# vPB NETWORK INTERFACES (Conditional - only if vpb_enabled)
# ============================================================================

resource "aws_network_interface" "vpb_management" {
  count             = var.vpb_enabled ? 1 : 0
  subnet_id         = aws_subnet.management.id
  security_groups   = [aws_security_group.vpb_management.id]
  source_dest_check = true
  tags              = merge(local.common_tags, { Name = "${local.vpb_name}-mgmt-eni", Interface = "mgmt0" })
}

resource "aws_network_interface" "vpb_ingress" {
  count             = var.vpb_enabled ? 1 : 0
  subnet_id         = aws_subnet.ingress.id
  security_groups   = [aws_security_group.vpb_traffic.id]
  source_dest_check = false
  tags              = merge(local.common_tags, { Name = "${local.vpb_name}-ingress-eni", Interface = "eth1" })
}

resource "aws_network_interface" "vpb_egress" {
  count             = var.vpb_enabled ? 1 : 0
  subnet_id         = aws_subnet.egress.id
  security_groups   = [aws_security_group.vpb_traffic.id]
  source_dest_check = false
  tags              = merge(local.common_tags, { Name = "${local.vpb_name}-egress-eni", Interface = "eth2" })
}

# ============================================================================
# vPB Instance (Conditional - only if vpb_enabled)
# ============================================================================

resource "aws_instance" "vpb" {
  count         = var.vpb_enabled ? 1 : 0
  ami           = local.vpb_ami
  instance_type = var.vpb_instance_type
  key_name      = var.key_pair_name

  # Attach pre-created network interfaces
  network_interface {
    network_interface_id = aws_network_interface.vpb_management[0].id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.vpb_ingress[0].id
    device_index         = 1
  }

  network_interface {
    network_interface_id = aws_network_interface.vpb_egress[0].id
    device_index         = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.vpb_name}-root" })
  }

  tags = merge(local.common_tags, { Name = local.vpb_name })

  # Explicit dependency to ensure network interfaces exist before instance creation
  depends_on = [
    aws_network_interface.vpb_management,
    aws_network_interface.vpb_ingress,
    aws_network_interface.vpb_egress
  ]

  lifecycle {
    precondition {
      condition     = local.vpb_ami != null
      error_message = "vPB AMI not available in ${var.aws_region}. Please subscribe to Keysight vPB in AWS Marketplace."
    }
  }
}
