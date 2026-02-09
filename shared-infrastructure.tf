# ============================================================================
# SHARED INFRASTRUCTURE
# ============================================================================
# VPC and common resources for shared EKS cluster
# This is separate from the per-SE lab VPCs
# ============================================================================

variable "deployment_prefix" {
  description = "Prefix for shared resources"
  type        = string
  default     = "se-lab"
}

variable "shared_vpc_cidr" {
  description = "CIDR block for shared infrastructure VPC"
  type        = string
  default     = "10.100.0.0/16"
}

locals {
  common_tags = {
    Project     = "CloudLens-SE-Training"
    Environment = "Training"
    ManagedBy   = "Terraform"
  }
}

# ============================================================================
# SHARED VPC (for EKS and shared resources)
# ============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.shared_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-igw"
  })

  # Extend timeout for destroy to handle dependency cleanup
  timeouts {
    create = "10m"
    delete = "20m"
  }

  # Prevent destroy until all dependent resources are gone
  lifecycle {
    create_before_destroy = false
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-shared-rt"
  })
}

# ============================================================================
# SHARED PUBLIC ECR REPOSITORY (accessible by all SEs without authentication)
# ============================================================================
# NOTE: Public ECR must be created in us-east-1 region
# Pull: No authentication required (fully public)
# Push: Requires AWS authentication (aws ecr-public get-login-password)
# ============================================================================

resource "aws_ecrpublic_repository" "cloudlens_sensor" {
  provider = aws.us_east_1
  count    = var.shared_eks_enabled ? 1 : 0

  # Name must be "cloudlens-sensor" to match Helm chart name inside .tgz
  # Helm push uses the chart name from the package, not a custom name
  repository_name = "cloudlens-sensor"

  catalog_data {
    about_text        = "CloudLens Sensor container image and Helm chart for SE Training Labs"
    description       = "Pre-built CloudLens sensor image and Helm chart for Kubernetes deployments. No authentication required to pull."
    operating_systems = ["Linux"]
    architectures     = ["x86-64"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-cloudlens-sensor"
  })
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "shared_vpc_id" {
  description = "Shared VPC ID"
  value       = aws_vpc.main.id
}

output "shared_ecr_urls" {
  description = "Shared Public ECR repository URL (no auth required for pulls)"
  value = var.shared_eks_enabled ? {
    cloudlens_sensor = aws_ecrpublic_repository.cloudlens_sensor[0].repository_uri
  } : {}
}

output "public_ecr_registry_alias" {
  description = "Public ECR registry alias for this account"
  value       = var.shared_eks_enabled ? aws_ecrpublic_repository.cloudlens_sensor[0].registry_id : ""
}

output "public_ecr_base_url" {
  description = "Public ECR base URL (e.g., public.ecr.aws/a1b2c3d4) for Helm commands"
  # Extract base URL by removing the repo name from the full URI
  # repository_uri format: public.ecr.aws/<alias>/<repo-name>
  value = var.shared_eks_enabled ? join("/", slice(split("/", aws_ecrpublic_repository.cloudlens_sensor[0].repository_uri), 0, 2)) : ""
}
