# ============================================================================
# DOCUMENTATION GENERATOR MODULE
# ============================================================================
# Generates lab documentation with all deployment-specific access information
# ============================================================================

# Create output directory (destroyed with infrastructure)
resource "null_resource" "create_directory" {
  provisioner "local-exec" {
    command = "mkdir -p '${var.output_directory}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -rf '${self.triggers.directory}'"
  }

  triggers = {
    directory = var.output_directory
  }
}

# Generate Lab Guide markdown file
resource "local_file" "lab_guide" {
  filename = "${var.output_directory}/${upper(var.deployment_prefix)}-GUIDE.md"
  content = templatefile("${path.module}/templates/lab_guide.md.tpl", {
    deployment_prefix           = var.deployment_prefix
    aws_region                  = var.aws_region
    aws_profile                 = var.aws_profile
    private_key_path            = var.private_key_path
    clms_public_ip              = var.clms_public_ip
    clms_private_ip             = var.clms_private_ip
    kvo_public_ip               = var.kvo_public_ip
    vpb_enabled                 = var.vpb_enabled
    vpb_public_ip               = var.vpb_public_ip
    vpb_mgmt_ip                 = var.vpb_interfaces.management
    vpb_ingress_ip              = var.vpb_interfaces.ingress
    vpb_egress_ip               = var.vpb_interfaces.egress
    ubuntu_public_ip            = var.ubuntu_public_ip
    windows_public_ip           = var.windows_public_ip
    tool_linux_public_ip        = var.tool_linux_public_ip
    tool_linux_private_ip       = var.tool_linux_private_ip
    tool_windows_public_ip      = var.tool_windows_public_ip
    tool_windows_private_ip     = var.tool_windows_private_ip
    eks_enabled                 = var.eks_enabled
    eks_cluster_name            = var.eks_cluster_name
    eks_cluster_endpoint        = var.eks_cluster_endpoint
    eks_kubeconfig_command      = var.eks_kubeconfig_command
    ecr_repository_urls         = var.ecr_repository_urls
    cyperf_enabled              = var.cyperf_enabled
    cyperf_controller_public_ip = var.cyperf_controller_public_ip
    cyperf_controller_private_ip = var.cyperf_controller_private_ip
    generated_date              = timestamp()
  })

  depends_on = [null_resource.create_directory]
}

# Generate credentials file
resource "local_file" "credentials" {
  filename = "${var.output_directory}/credentials.txt"
  content = templatefile("${path.module}/templates/credentials.txt.tpl", {
    deployment_prefix           = var.deployment_prefix
    clms_public_ip              = var.clms_public_ip
    kvo_public_ip               = var.kvo_public_ip
    vpb_enabled                 = var.vpb_enabled
    vpb_public_ip               = var.vpb_public_ip
    ubuntu_public_ip            = var.ubuntu_public_ip
    windows_public_ip           = var.windows_public_ip
    tool_linux_public_ip        = var.tool_linux_public_ip
    tool_linux_private_ip       = var.tool_linux_private_ip
    tool_windows_public_ip      = var.tool_windows_public_ip
    tool_windows_private_ip     = var.tool_windows_private_ip
    private_key_path            = var.private_key_path
    aws_profile                 = var.aws_profile
    cyperf_enabled              = var.cyperf_enabled
    cyperf_controller_public_ip = var.cyperf_controller_public_ip
  })

  depends_on = [null_resource.create_directory]
}
