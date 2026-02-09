# ============================================================================
# MULTI-SE LAB ORCHESTRATION
# ============================================================================
# Creates 25 isolated SE training lab environments using the se-lab module
# Each SE gets their own VPC, instances, and optionally EKS/ECR
# ============================================================================

locals {
  # Generate SE labs 1-25
  all_se_labs = {
    for i in range(1, var.num_se_labs + 1) :
    format("se-lab-%02d", i) => {
      index             = i
      cidr_second_octet = i
      owner             = format("SE-%02d", i)
      eks_enabled       = var.eks_enabled_for_all
    }
  }

  # Filter to only enabled labs (empty list = all labs)
  enabled_se_labs = length(var.enabled_labs) > 0 ? {
    for k, v in local.all_se_labs : k => v if contains(var.enabled_labs, k)
  } : local.all_se_labs
}

# ============================================================================
# SE LAB MODULES
# ============================================================================

module "se_lab" {
  source   = "./modules/se-lab"
  for_each = var.multi_se_mode ? local.enabled_se_labs : {}

  # Identity
  deployment_prefix = each.key
  lab_index         = each.value.index
  owner             = each.value.owner

  # AWS Configuration
  aws_region       = var.aws_region
  aws_profile      = var.aws_profile
  key_pair_name    = var.key_pair_name
  private_key_path = var.private_key_path

  # Network CIDRs (based on lab index)
  vpc_cidr                    = "10.${each.value.cidr_second_octet}.0.0/16"
  management_subnet_cidr      = "10.${each.value.cidr_second_octet}.1.0/24"
  ingress_subnet_cidr         = "10.${each.value.cidr_second_octet}.2.0/24"
  egress_subnet_cidr          = "10.${each.value.cidr_second_octet}.3.0/24"
  eks_public_subnet_az1_cidr  = "10.${each.value.cidr_second_octet}.4.0/24"
  eks_private_subnet_az1_cidr = "10.${each.value.cidr_second_octet}.5.0/24"
  eks_public_subnet_az2_cidr  = "10.${each.value.cidr_second_octet}.6.0/24"
  eks_private_subnet_az2_cidr = "10.${each.value.cidr_second_octet}.7.0/24"

  # Security
  allowed_ssh_cidr   = var.allowed_ssh_cidr
  allowed_https_cidr = var.allowed_https_cidr

  # Features
  eks_enabled             = each.value.eks_enabled
  use_elastic_ips         = var.use_elastic_ips
  vpb_enabled             = var.vpb_enabled
  rhel_enabled            = var.rhel_enabled
  ubuntu_workload_enabled = var.ubuntu_workload_enabled

  # Shared EKS VPC Peering
  shared_eks_enabled  = var.shared_eks_enabled
  shared_eks_vpc_id   = var.shared_eks_enabled ? aws_vpc.main.id : ""
  shared_eks_vpc_cidr = var.shared_eks_enabled ? var.shared_vpc_cidr : ""

  # Instance Types
  clms_instance_type         = var.clms_instance_type
  kvo_instance_type          = var.kvo_instance_type
  vpb_instance_type          = var.vpb_instance_type
  ubuntu_instance_type       = var.ubuntu_instance_type
  windows_instance_type      = var.windows_instance_type
  rhel_instance_type         = var.rhel_instance_type
  tool_linux_instance_type   = var.ubuntu_instance_type
  tool_windows_instance_type = "t3.large"

  # EKS Configuration
  eks_kubernetes_version = var.eks_kubernetes_version
  eks_node_instance_type = var.eks_node_instance_type
  eks_node_desired_size  = var.eks_node_desired_size
  eks_node_min_size      = var.eks_node_min_size
  eks_node_max_size      = var.eks_node_max_size

  # Tags
  extra_tags = merge(var.extra_tags, {
    MultiSETraining = "true"
    LabNumber       = tostring(each.value.index)
  })
}

# ============================================================================
# DOCUMENTATION GENERATION
# ============================================================================

module "documentation" {
  source   = "./modules/documentation"
  for_each = var.multi_se_mode ? local.enabled_se_labs : {}

  deployment_prefix = each.key
  owner             = each.value.owner

  aws_region       = var.aws_region
  aws_profile      = var.aws_profile
  private_key_path = var.private_key_path

  # Pass outputs from se_lab module
  clms_public_ip         = module.se_lab[each.key].clms_public_ip
  clms_private_ip        = module.se_lab[each.key].clms_private_ip
  kvo_public_ip          = module.se_lab[each.key].kvo_public_ip
  kvo_private_ip         = module.se_lab[each.key].kvo_private_ip
  vpb_enabled            = var.vpb_enabled
  vpb_public_ip          = module.se_lab[each.key].vpb_public_ip
  vpb_interfaces         = module.se_lab[each.key].vpb_interfaces
  ubuntu_1_public_ip     = module.se_lab[each.key].ubuntu_1_public_ip
  windows_public_ip      = module.se_lab[each.key].windows_public_ip
  rhel_enabled           = var.rhel_enabled
  rhel_public_ip         = module.se_lab[each.key].rhel_public_ip
  tool_linux_public_ip    = module.se_lab[each.key].tool_linux_public_ip
  tool_linux_private_ip   = module.se_lab[each.key].tool_linux_private_ip
  tool_windows_public_ip  = module.se_lab[each.key].tool_windows_public_ip
  tool_windows_private_ip = module.se_lab[each.key].tool_windows_private_ip

  eks_cluster_name     = var.shared_eks_enabled ? aws_eks_cluster.shared[0].name : module.se_lab[each.key].eks_cluster_name
  eks_cluster_endpoint = var.shared_eks_enabled ? aws_eks_cluster.shared[0].endpoint : module.se_lab[each.key].eks_cluster_endpoint
  ecr_repository_urls  = var.shared_eks_enabled ? {
    cloudlens_sensor = aws_ecrpublic_repository.cloudlens_sensor[0].repository_uri
  } : module.se_lab[each.key].ecr_repository_urls
  ecr_public_url       = var.shared_eks_enabled ? join("/", slice(split("/", aws_ecrpublic_repository.cloudlens_sensor[0].repository_uri), 0, 2)) : ""

  se_namespace = format("se-%02d", each.value.index)
  se_id        = format("se-%02d", each.value.index)

  output_directory = "${path.module}/generated/${each.key}"

  depends_on = [module.se_lab]
}
