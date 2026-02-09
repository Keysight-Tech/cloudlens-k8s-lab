# ============================================================================
# ELASTIC IPS - Static public IPs for all instances (CONDITIONAL)
# ============================================================================
# Only created when var.use_elastic_ips = true
# When false, instances use dynamic public IPs assigned by AWS
# ============================================================================

# ============================================================================
# KEYSIGHT PRODUCTS
# ============================================================================

resource "aws_eip" "kvo" {
  count  = var.use_elastic_ips ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.kvo_name}-eip", SE = var.deployment_prefix })
}

resource "aws_eip_association" "kvo" {
  count         = var.use_elastic_ips ? 1 : 0
  instance_id   = aws_instance.kvo.id
  allocation_id = aws_eip.kvo[0].id
}

resource "aws_eip" "clms" {
  count  = var.use_elastic_ips ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.clms_name}-eip", SE = var.deployment_prefix })
}

resource "aws_eip_association" "clms" {
  count         = var.use_elastic_ips ? 1 : 0
  instance_id   = aws_instance.clms.id
  allocation_id = aws_eip.clms[0].id
}

# vPB always gets an EIP for stable management access (required for multi-NIC instances)
resource "aws_eip" "vpb" {
  count  = var.vpb_enabled ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.vpb_name}-eip", SE = var.deployment_prefix })
}

# Wait for vPB instance to fully initialize before EIP association
resource "time_sleep" "wait_for_vpb" {
  count = var.vpb_enabled ? 1 : 0

  depends_on      = [aws_instance.vpb]
  create_duration = "30s"  # Wait for network interface to be fully attached
}

resource "aws_eip_association" "vpb" {
  count                = var.vpb_enabled ? 1 : 0
  allocation_id        = aws_eip.vpb[0].id
  network_interface_id = aws_network_interface.vpb_management[0].id

  # Wait for instance and network interface to be fully ready
  depends_on = [
    aws_instance.vpb,
    time_sleep.wait_for_vpb
  ]

  # Handle transient errors during large deployments
  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# WORKLOAD VMs
# ============================================================================

resource "aws_eip" "tapped_ubuntu_1" {
  count  = var.use_elastic_ips && var.ubuntu_workload_enabled ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.tapped_1_name}-eip", SE = var.deployment_prefix })
}

resource "aws_eip_association" "tapped_ubuntu_1" {
  count         = var.use_elastic_ips && var.ubuntu_workload_enabled ? 1 : 0
  instance_id   = aws_instance.tapped_ubuntu_1[0].id
  allocation_id = aws_eip.tapped_ubuntu_1[0].id
}

resource "aws_eip" "tapped_windows" {
  count  = var.use_elastic_ips ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.windows_name}-eip", SE = var.deployment_prefix })
}

resource "aws_eip_association" "tapped_windows" {
  count         = var.use_elastic_ips ? 1 : 0
  instance_id   = aws_instance.tapped_windows.id
  allocation_id = aws_eip.tapped_windows[0].id
}

resource "aws_eip" "tapped_rhel" {
  count  = var.use_elastic_ips && var.rhel_enabled ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.rhel_name}-eip", SE = var.deployment_prefix })
}

resource "aws_eip_association" "tapped_rhel" {
  count         = var.use_elastic_ips && var.rhel_enabled ? 1 : 0
  instance_id   = aws_instance.tapped_rhel[0].id
  allocation_id = aws_eip.tapped_rhel[0].id
}

# ============================================================================
# TOOL VMs
# ============================================================================

resource "aws_eip" "tool" {
  count  = var.use_elastic_ips ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.tool_name}-eip", SE = var.deployment_prefix })
}

resource "aws_eip_association" "tool" {
  count         = var.use_elastic_ips ? 1 : 0
  instance_id   = aws_instance.tool.id
  allocation_id = aws_eip.tool[0].id
}

resource "aws_eip" "tool_windows" {
  count  = var.use_elastic_ips ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.tool_windows_name}-eip", SE = var.deployment_prefix })
}

resource "aws_eip_association" "tool_windows" {
  count         = var.use_elastic_ips ? 1 : 0
  instance_id   = aws_instance.tool_windows.id
  allocation_id = aws_eip.tool_windows[0].id
}
