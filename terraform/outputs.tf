# ============================================================================
# OUTPUTS
# ============================================================================

# Keysight Product URLs
output "clms_url" {
  description = "CloudLens Manager UI URL"
  value       = module.lab.clms_ui_url
}

output "kvo_url" {
  description = "KVO (Vision One) UI URL"
  value       = module.lab.kvo_ui_url
}

output "clms_private_ip" {
  description = "CLMS private IP (used for KVO registration and sensor config)"
  value       = module.lab.clms_private_ip
}

output "vpb_ip" {
  description = "vPB public IP"
  value       = module.lab.vpb_public_ip
}

# VM IPs
output "ubuntu_ip" {
  description = "Ubuntu workload VM public IP"
  value       = module.lab.ubuntu_1_public_ip
}

output "windows_ip" {
  description = "Windows workload VM public IP"
  value       = module.lab.windows_public_ip
}

output "tool_linux_ip" {
  description = "Linux tool VM public IP (tcpdump)"
  value       = module.lab.tool_linux_public_ip
}

output "tool_linux_private_ip" {
  description = "Linux tool VM private IP (for KVO remote tool config)"
  value       = module.lab.tool_linux_private_ip
}

output "tool_windows_ip" {
  description = "Windows tool VM public IP (Wireshark)"
  value       = module.lab.tool_windows_public_ip
}

output "tool_windows_private_ip" {
  description = "Windows tool VM private IP (for KVO remote tool config)"
  value       = module.lab.tool_windows_private_ip
}

# EKS
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.lab.eks_cluster_name
}

output "eks_kubeconfig_command" {
  description = "Command to configure kubectl for EKS"
  value       = module.lab.eks_kubeconfig_command
}

# ECR
output "ecr_repository_urls" {
  description = "ECR repository URLs for pushing container images"
  value       = module.lab.ecr_repository_urls
}

# SSH Commands
output "ssh_commands" {
  description = "SSH commands for all VMs"
  value       = module.lab.ssh_commands
}

# Instance IDs (for stop/start)
output "all_instance_ids" {
  description = "All EC2 instance IDs (for stop/start scripts)"
  value       = module.lab.all_instance_ids
}
