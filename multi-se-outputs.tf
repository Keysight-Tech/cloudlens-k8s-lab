# ============================================================================
# MULTI-SE LAB OUTPUTS
# ============================================================================

output "multi_se_labs" {
  description = "All SE lab environments (when multi_se_mode=true)"
  value = var.multi_se_mode ? {
    for k, v in module.se_lab : k => {
      owner              = v.owner
      vpc_id             = v.vpc_id
      clms_url           = v.clms_ui_url
      kvo_url            = v.kvo_ui_url
      vpb_ip             = v.vpb_public_ip
      eks_cluster        = v.eks_cluster_name
      documentation_path = "${path.module}/generated/${k}"
    }
  } : {}
}

output "multi_se_summary" {
  description = "Summary of deployed SE labs"
  value = var.multi_se_mode ? {
    total_labs    = length(module.se_lab)
    eks_enabled   = var.eks_enabled_for_all
    documentation = "${path.module}/generated/"
  } : { message = "Multi-SE mode not enabled. Set multi_se_mode=true to deploy." }
}

output "multi_se_all_clms_urls" {
  description = "All CLMS URLs for quick reference"
  value = var.multi_se_mode ? {
    for k, v in module.se_lab : k => v.clms_ui_url
  } : {}
}

output "multi_se_all_kvo_urls" {
  description = "All KVO URLs for quick reference"
  value = var.multi_se_mode ? {
    for k, v in module.se_lab : k => v.kvo_ui_url
  } : {}
}

output "multi_se_all_vpb_ips" {
  description = "All vPB IPs for quick reference"
  value = var.multi_se_mode ? {
    for k, v in module.se_lab : k => v.vpb_public_ip
  } : {}
}

output "multi_se_documentation_paths" {
  description = "Paths to generated documentation for each SE lab"
  value = var.multi_se_mode ? {
    for k, v in module.se_lab : k => "${path.module}/generated/${k}"
  } : {}
}

output "multi_se_all_instance_ids" {
  description = "All instance IDs grouped by lab (for stop/start scripts)"
  value = var.multi_se_mode ? {
    for k, v in module.se_lab : k => v.all_instance_ids
  } : {}
}

# ============================================================================
# OUTPUTS FOR POST-DEPLOY SCRIPT
# ============================================================================

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "aws_profile" {
  description = "AWS CLI profile"
  value       = var.aws_profile
}

output "num_se_labs" {
  description = "Number of SE labs deployed"
  value       = var.num_se_labs
}

output "shared_eks_enabled" {
  description = "Whether shared EKS is enabled"
  value       = var.shared_eks_enabled
}

output "shared_eks_cluster_name" {
  description = "Shared EKS cluster name"
  value       = var.shared_eks_enabled ? "${var.deployment_prefix}-shared-eks" : ""
}

output "shared_eks_cluster_endpoint" {
  description = "Shared EKS cluster endpoint"
  value       = var.shared_eks_enabled ? aws_eks_cluster.shared[0].endpoint : ""
}

output "se_lab_outputs" {
  description = "All SE lab outputs for script access"
  value = var.multi_se_mode ? {
    for k, v in module.se_lab : k => {
      clms_public_ip         = v.clms_public_ip
      kvo_public_ip          = v.kvo_public_ip
      vpb_public_ip          = v.vpb_public_ip
      ubuntu_1_public_ip     = v.ubuntu_1_public_ip
      windows_public_ip      = v.windows_public_ip
      tool_linux_public_ip    = v.tool_linux_public_ip
      tool_linux_private_ip   = v.tool_linux_private_ip
      tool_windows_public_ip  = v.tool_windows_public_ip
      tool_windows_private_ip = v.tool_windows_private_ip
    }
  } : {}
}

# ============================================================================
# CYPERF OUTPUTS
# ============================================================================

output "cyperf_enabled" {
  description = "Whether CyPerf Controller is deployed"
  value       = var.cyperf_enabled
}

output "cyperf_controller_info" {
  description = "CyPerf Controller connection details"
  value = var.cyperf_enabled ? {
    public_ip  = aws_eip.cyperf_controller[0].public_ip
    private_ip = aws_instance.cyperf_controller[0].private_ip
    ui_url     = "https://${aws_eip.cyperf_controller[0].public_ip}"
  } : {}
}

output "cyperf_agent_info" {
  description = "CyPerf Agent VM connection details (only when VM agents enabled)"
  value = var.cyperf_enabled && var.cyperf_vm_agents_enabled ? {
    client_public_ip = aws_eip.cyperf_client[0].public_ip
    client_test_ip   = aws_network_interface.cyperf_client_test[0].private_ip
    server_public_ip = aws_eip.cyperf_server[0].public_ip
    server_test_ip   = aws_network_interface.cyperf_server_test[0].private_ip
  } : {}
}
