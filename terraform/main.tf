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
