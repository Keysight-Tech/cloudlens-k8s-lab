# ============================================================================
# DOCUMENTATION GENERATOR MODULE
# ============================================================================
# Generates per-SE lab documentation with all access information
# ============================================================================

# Create output directory
resource "null_resource" "create_directory" {
  provisioner "local-exec" {
    command = "mkdir -p '${var.output_directory}'"
  }

  triggers = {
    directory = var.output_directory
  }
}

# Generate SE Guide markdown file
resource "local_file" "se_guide" {
  filename = "${var.output_directory}/${upper(var.deployment_prefix)}-GUIDE.md"
  content  = templatefile("${path.module}/templates/se_guide.md.tpl", {
    deployment_prefix      = var.deployment_prefix
    owner                  = var.owner
    aws_region             = var.aws_region
    aws_profile            = var.aws_profile
    private_key_path       = var.private_key_path
    clms_public_ip         = var.clms_public_ip
    clms_private_ip        = var.clms_private_ip
    kvo_public_ip          = var.kvo_public_ip
    kvo_private_ip         = var.kvo_private_ip
    vpb_enabled            = var.vpb_enabled
    vpb_public_ip          = var.vpb_public_ip
    vpb_mgmt_ip            = var.vpb_interfaces.management
    vpb_ingress_ip         = var.vpb_interfaces.ingress
    vpb_egress_ip          = var.vpb_interfaces.egress
    ubuntu_public_ip       = var.ubuntu_1_public_ip
    windows_public_ip      = var.windows_public_ip
    rhel_enabled           = var.rhel_enabled
    rhel_public_ip         = var.rhel_public_ip
    tool_linux_public_ip    = var.tool_linux_public_ip
    tool_linux_private_ip   = var.tool_linux_private_ip
    tool_windows_public_ip  = var.tool_windows_public_ip
    tool_windows_private_ip = var.tool_windows_private_ip
    eks_cluster_name       = var.eks_cluster_name
    eks_cluster_endpoint   = var.eks_cluster_endpoint
    ecr_repository_urls    = var.ecr_repository_urls
    ecr_public_url         = var.ecr_public_url
    se_namespace           = var.se_namespace
    se_id                  = var.se_id
    generated_date         = timestamp()
  })

  depends_on = [null_resource.create_directory]
}

# Generate credentials file
resource "local_file" "credentials" {
  filename = "${var.output_directory}/credentials.txt"
  content  = templatefile("${path.module}/templates/credentials.txt.tpl", {
    deployment_prefix      = var.deployment_prefix
    owner                  = var.owner
    clms_public_ip         = var.clms_public_ip
    kvo_public_ip          = var.kvo_public_ip
    vpb_enabled            = var.vpb_enabled
    vpb_public_ip          = var.vpb_public_ip
    ubuntu_public_ip       = var.ubuntu_1_public_ip
    windows_public_ip      = var.windows_public_ip
    rhel_enabled           = var.rhel_enabled
    rhel_public_ip         = var.rhel_public_ip
    tool_linux_public_ip    = var.tool_linux_public_ip
    tool_linux_private_ip   = var.tool_linux_private_ip
    tool_windows_public_ip  = var.tool_windows_public_ip
    tool_windows_private_ip = var.tool_windows_private_ip
    private_key_path       = var.private_key_path
    aws_profile            = var.aws_profile
  })

  depends_on = [null_resource.create_directory]
}
