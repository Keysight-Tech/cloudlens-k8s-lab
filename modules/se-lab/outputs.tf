# ============================================================================
# SE-LAB MODULE OUTPUTS
# ============================================================================

# Identity
output "deployment_prefix" {
  description = "Deployment prefix for this lab"
  value       = var.deployment_prefix
}

output "owner" {
  description = "Owner of this lab"
  value       = var.owner
}


# VPC
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "route_table_id" {
  description = "Main route table ID"
  value       = aws_route_table.main.id
}

output "vpc_peering_id" {
  description = "VPC peering connection ID to shared EKS VPC"
  value       = var.shared_eks_enabled ? aws_vpc_peering_connection.shared_eks[0].id : ""
}

# CLMS
output "clms_public_ip" {
  description = "CLMS public IP"
  value       = var.use_elastic_ips ? aws_eip.clms[0].public_ip : aws_instance.clms.public_ip
}

output "clms_private_ip" {
  description = "CLMS private IP"
  value       = aws_instance.clms.private_ip
}

output "clms_instance_id" {
  description = "CLMS instance ID"
  value       = aws_instance.clms.id
}

output "clms_ui_url" {
  description = "CLMS UI URL"
  value       = var.use_elastic_ips ? "https://${aws_eip.clms[0].public_ip}" : "https://${aws_instance.clms.public_ip}"
}

# KVO
output "kvo_public_ip" {
  description = "KVO public IP"
  value       = var.use_elastic_ips ? aws_eip.kvo[0].public_ip : aws_instance.kvo.public_ip
}

output "kvo_private_ip" {
  description = "KVO private IP"
  value       = aws_instance.kvo.private_ip
}

output "kvo_instance_id" {
  description = "KVO instance ID"
  value       = aws_instance.kvo.id
}

output "kvo_ui_url" {
  description = "KVO UI URL"
  value       = var.use_elastic_ips ? "https://${aws_eip.kvo[0].public_ip}" : "https://${aws_instance.kvo.public_ip}"
}

# vPB
output "vpb_public_ip" {
  description = "vPB public IP (EIP)"
  value       = var.vpb_enabled ? aws_eip.vpb[0].public_ip : "vPB not deployed"
}

output "vpb_interfaces" {
  description = "vPB interface IPs"
  value = var.vpb_enabled ? {
    management = aws_network_interface.vpb_management[0].private_ip
    ingress    = aws_network_interface.vpb_ingress[0].private_ip
    egress     = aws_network_interface.vpb_egress[0].private_ip
  } : {
    management = "N/A"
    ingress    = "N/A"
    egress     = "N/A"
  }
}

# Ubuntu VMs (Conditional)
output "ubuntu_1_public_ip" {
  description = "Ubuntu VM 1 public IP"
  value       = var.ubuntu_workload_enabled ? (var.use_elastic_ips && length(aws_eip.tapped_ubuntu_1) > 0 ? aws_eip.tapped_ubuntu_1[0].public_ip : aws_instance.tapped_ubuntu_1[0].public_ip) : "Ubuntu not deployed"
}

output "ubuntu_1_private_ip" {
  description = "Ubuntu VM 1 private IP"
  value       = var.ubuntu_workload_enabled ? aws_instance.tapped_ubuntu_1[0].private_ip : "Ubuntu not deployed"
}

# Windows VM
output "windows_public_ip" {
  description = "Windows VM public IP"
  value       = var.use_elastic_ips ? aws_eip.tapped_windows[0].public_ip : aws_instance.tapped_windows.public_ip
}

output "windows_private_ip" {
  description = "Windows VM private IP"
  value       = aws_instance.tapped_windows.private_ip
}

output "windows_password_data" {
  description = "Windows VM encrypted password data"
  sensitive   = true
  value       = aws_instance.tapped_windows.password_data
}

# RHEL VM (Conditional)
output "rhel_public_ip" {
  description = "RHEL VM public IP"
  value       = var.rhel_enabled ? (var.use_elastic_ips && length(aws_eip.tapped_rhel) > 0 ? aws_eip.tapped_rhel[0].public_ip : aws_instance.tapped_rhel[0].public_ip) : "RHEL not deployed"
}

output "rhel_private_ip" {
  description = "RHEL VM private IP"
  value       = var.rhel_enabled ? aws_instance.tapped_rhel[0].private_ip : "RHEL not deployed"
}

# Tool VMs
output "tool_linux_public_ip" {
  description = "Linux Tool VM public IP"
  value       = var.use_elastic_ips ? aws_eip.tool[0].public_ip : aws_instance.tool.public_ip
}

output "tool_linux_private_ip" {
  description = "Linux Tool VM private IP"
  value       = aws_instance.tool.private_ip
}

output "tool_windows_public_ip" {
  description = "Windows Tool VM public IP"
  value       = var.use_elastic_ips ? aws_eip.tool_windows[0].public_ip : aws_instance.tool_windows.public_ip
}

output "tool_windows_private_ip" {
  description = "Windows Tool VM private IP"
  value       = aws_instance.tool_windows.private_ip
}

output "tool_windows_password_data" {
  description = "Windows Tool VM encrypted password data"
  sensitive   = true
  value       = aws_instance.tool_windows.password_data
}

# EKS (conditional)
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = var.eks_enabled ? aws_eks_cluster.main[0].name : ""
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = var.eks_enabled ? aws_eks_cluster.main[0].endpoint : ""
}

output "eks_cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = var.eks_enabled ? aws_eks_cluster.main[0].vpc_config[0].cluster_security_group_id : ""
}

output "eks_kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = var.eks_enabled ? "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main[0].name} --profile ${var.aws_profile}" : ""
}

# ECR (conditional)
output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value = var.eks_enabled ? {
    cloudlens_sensor = aws_ecr_repository.cloudlens_sensor[0].repository_url
    nginx_app        = aws_ecr_repository.nginx_app[0].repository_url
    apache_app       = aws_ecr_repository.apache_app[0].repository_url
  } : {}
}

# All Instance IDs (for stop/start scripts)
output "all_instance_ids" {
  description = "All EC2 instance IDs in this lab"
  value = concat(
    [
      aws_instance.clms.id,
      aws_instance.kvo.id,
      aws_instance.tapped_windows.id,
      aws_instance.tool.id,
      aws_instance.tool_windows.id
    ],
    var.ubuntu_workload_enabled ? [aws_instance.tapped_ubuntu_1[0].id] : [],
    var.vpb_enabled ? [aws_instance.vpb[0].id] : [],
    var.rhel_enabled ? [aws_instance.tapped_rhel[0].id] : []
  )
}

output "vpb_instance_id" {
  description = "vPB instance ID"
  value       = var.vpb_enabled ? aws_instance.vpb[0].id : "vPB not deployed"
}

# SSH Commands
output "ssh_commands" {
  description = "SSH commands for all VMs"
  value = {
    vpb          = var.vpb_enabled ? "ssh -i ${var.private_key_path} admin@${aws_eip.vpb[0].public_ip}" : "vPB not deployed"
    ubuntu       = var.ubuntu_workload_enabled ? (var.use_elastic_ips && length(aws_eip.tapped_ubuntu_1) > 0 ? "ssh -i ${var.private_key_path} ubuntu@${aws_eip.tapped_ubuntu_1[0].public_ip}" : "ssh -i ${var.private_key_path} ubuntu@${aws_instance.tapped_ubuntu_1[0].public_ip}") : "Ubuntu not deployed"
    rhel         = var.rhel_enabled ? (var.use_elastic_ips && length(aws_eip.tapped_rhel) > 0 ? "ssh -i ${var.private_key_path} ec2-user@${aws_eip.tapped_rhel[0].public_ip}" : "ssh -i ${var.private_key_path} ec2-user@${aws_instance.tapped_rhel[0].public_ip}") : "RHEL not deployed"
    tool_linux   = var.use_elastic_ips && length(aws_eip.tool) > 0 ? "ssh -i ${var.private_key_path} ubuntu@${aws_eip.tool[0].public_ip}" : "ssh -i ${var.private_key_path} ubuntu@${aws_instance.tool.public_ip}"
    windows      = var.use_elastic_ips && length(aws_eip.tapped_windows) > 0 ? "RDP to ${aws_eip.tapped_windows[0].public_ip}:3389" : "RDP to ${aws_instance.tapped_windows.public_ip}:3389"
    tool_windows = var.use_elastic_ips && length(aws_eip.tool_windows) > 0 ? "RDP to ${aws_eip.tool_windows[0].public_ip}:3389" : "RDP to ${aws_instance.tool_windows.public_ip}:3389"
  }
}

# Default credentials
output "credentials" {
  description = "Default credentials for all products"
  sensitive   = true
  value = {
    clms    = { user = "admin", pass = "<CLMS_PASSWORD>" }
    kvo     = { user = "admin", pass = "admin" }
    vpb     = { user = "admin", pass = "<VPB_PASSWORD>" }
    ubuntu  = { user = "ubuntu", pass = "Use SSH key" }
    rhel    = { user = "ec2-user", pass = "Use SSH key" }
    windows = { user = "Administrator", pass = "Decrypt from terraform output" }
  }
}
