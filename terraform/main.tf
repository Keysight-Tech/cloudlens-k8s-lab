# ============================================================================
# CLOUDLENS K8s VISIBILITY LAB
# ============================================================================
# Deploys a single lab environment with:
#   - CloudLens Manager (CLMS)
#   - Keysight Vision One (KVO)
#   - Virtual Packet Broker (vPB)
#   - Ubuntu workload VM
#   - Windows workload VM
#   - Linux tool VM (tcpdump)
#   - Windows tool VM (Wireshark)
#   - EKS cluster with worker nodes
#   - ECR repositories for container images
# ============================================================================

module "lab" {
  source = "../modules/se-lab"

  # Identity
  deployment_prefix = var.deployment_prefix
  lab_index         = 1
  owner             = var.deployment_prefix

  # AWS Configuration
  aws_region       = var.aws_region
  aws_profile      = var.aws_profile
  key_pair_name    = var.key_pair_name
  private_key_path = var.private_key_path

  # Network CIDRs
  vpc_cidr                    = "10.1.0.0/16"
  management_subnet_cidr      = "10.1.1.0/24"
  ingress_subnet_cidr         = "10.1.2.0/24"
  egress_subnet_cidr          = "10.1.3.0/24"
  eks_public_subnet_az1_cidr  = "10.1.4.0/24"
  eks_private_subnet_az1_cidr = "10.1.5.0/24"
  eks_public_subnet_az2_cidr  = "10.1.6.0/24"
  eks_private_subnet_az2_cidr = "10.1.7.0/24"

  # Security
  allowed_ssh_cidr   = var.allowed_ssh_cidr
  allowed_https_cidr = var.allowed_https_cidr

  # Features
  eks_enabled             = var.eks_enabled
  vpb_enabled             = var.vpb_enabled
  use_elastic_ips         = var.use_elastic_ips
  ubuntu_workload_enabled = true
  rhel_enabled            = false

  # Instance Types
  clms_instance_type         = var.clms_instance_type
  kvo_instance_type          = var.kvo_instance_type
  vpb_instance_type          = var.vpb_instance_type
  ubuntu_instance_type       = var.ubuntu_instance_type
  windows_instance_type      = var.windows_instance_type
  tool_linux_instance_type   = var.ubuntu_instance_type
  tool_windows_instance_type = "t3.large"

  # Tags
  extra_tags = var.extra_tags
}

# ============================================================================
# DOCUMENTATION GENERATOR
# ============================================================================
# Generates a deployment-specific lab guide and credentials file
# Output: generated/<deployment_prefix>/
# ============================================================================

module "documentation" {
  source = "../modules/documentation"

  deployment_prefix = var.deployment_prefix
  aws_region        = var.aws_region
  aws_profile       = var.aws_profile
  private_key_path  = var.private_key_path

  # Keysight Products
  clms_public_ip  = module.lab.clms_public_ip
  clms_private_ip = module.lab.clms_private_ip
  kvo_public_ip   = module.lab.kvo_public_ip
  vpb_enabled     = var.vpb_enabled
  vpb_public_ip   = module.lab.vpb_public_ip
  vpb_interfaces  = module.lab.vpb_interfaces

  # Workload VMs
  ubuntu_public_ip  = module.lab.ubuntu_1_public_ip
  windows_public_ip = module.lab.windows_public_ip

  # Tool VMs
  tool_linux_public_ip    = module.lab.tool_linux_public_ip
  tool_linux_private_ip   = module.lab.tool_linux_private_ip
  tool_windows_public_ip  = module.lab.tool_windows_public_ip
  tool_windows_private_ip = module.lab.tool_windows_private_ip

  # EKS
  eks_enabled          = var.eks_enabled
  eks_cluster_name     = module.lab.eks_cluster_name
  eks_cluster_endpoint = module.lab.eks_cluster_endpoint
  eks_kubeconfig_command = module.lab.eks_kubeconfig_command
  ecr_repository_urls  = module.lab.ecr_repository_urls

  # CyPerf
  cyperf_enabled              = var.cyperf_enabled
  cyperf_controller_public_ip  = var.cyperf_enabled ? aws_eip.cyperf_controller[0].public_ip : ""
  cyperf_controller_private_ip = var.cyperf_enabled ? aws_instance.cyperf_controller[0].private_ip : ""

  output_directory = "${path.module}/generated/${var.deployment_prefix}"

  depends_on = [module.lab]
}
