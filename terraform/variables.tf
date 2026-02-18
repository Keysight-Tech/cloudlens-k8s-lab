# ============================================================================
# VARIABLES
# ============================================================================

# AWS Configuration
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = "cloudlens-lab"
}

variable "key_pair_name" {
  description = "Name of existing EC2 key pair for SSH access"
  type        = string
  default     = "cloudlens-lab"
}

variable "private_key_path" {
  description = "Local path to SSH private key"
  type        = string
  default     = "~/.ssh/cloudlens-lab.pem"
}

# Identity
variable "deployment_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "cloudlens-lab"
}

# Security
variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_https_cidr" {
  description = "CIDR block allowed for HTTPS access"
  type        = string
  default     = "0.0.0.0/0"
}

# Features
variable "vpb_enabled" {
  description = "Deploy vPB instance (requires AWS Marketplace subscription)"
  type        = bool
  default     = true
}

variable "eks_enabled" {
  description = "Deploy EKS cluster"
  type        = bool
  default     = true
}

variable "use_elastic_ips" {
  description = "Use Elastic IPs for static public IPs (requires EIP quota)"
  type        = bool
  default     = true
}

# Instance Types (uncomment in terraform.tfvars to override)
variable "clms_instance_type" {
  description = "Instance type for CloudLens Manager"
  type        = string
  default     = "t3.xlarge"
}

variable "kvo_instance_type" {
  description = "Instance type for KVO (Vision One)"
  type        = string
  default     = "t3.2xlarge"
}

variable "vpb_instance_type" {
  description = "Instance type for Virtual Packet Broker"
  type        = string
  default     = "t3.xlarge"
}

variable "ubuntu_instance_type" {
  description = "Instance type for Ubuntu VMs"
  type        = string
  default     = "t3.medium"
}

variable "windows_instance_type" {
  description = "Instance type for Windows VMs"
  type        = string
  default     = "t3.medium"
}

# CyPerf
variable "cyperf_enabled" {
  description = "Deploy CyPerf Controller (requires AWS Marketplace subscription)"
  type        = bool
  default     = false
}

variable "cyperf_controller_instance_type" {
  description = "Instance type for CyPerf Controller (8 vCPU, 16GB RAM recommended)"
  type        = string
  default     = "c5.2xlarge"
}

# Network CIDRs
# Defaults match the single-lab deployment (10.1.0.0/16).
# Override in terraform.tfvars if you need a different address space.
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "management_subnet_cidr" {
  description = "CIDR for management subnet (CLMS, KVO, vPB mgmt)"
  type        = string
  default     = "10.1.1.0/24"
}

variable "ingress_subnet_cidr" {
  description = "CIDR for vPB ingress subnet"
  type        = string
  default     = "10.1.2.0/24"
}

variable "egress_subnet_cidr" {
  description = "CIDR for vPB egress subnet"
  type        = string
  default     = "10.1.3.0/24"
}

variable "eks_public_subnet_az1_cidr" {
  description = "CIDR for EKS public subnet in AZ1"
  type        = string
  default     = "10.1.4.0/24"
}

variable "eks_private_subnet_az1_cidr" {
  description = "CIDR for EKS private subnet in AZ1"
  type        = string
  default     = "10.1.5.0/24"
}

variable "eks_public_subnet_az2_cidr" {
  description = "CIDR for EKS public subnet in AZ2"
  type        = string
  default     = "10.1.6.0/24"
}

variable "eks_private_subnet_az2_cidr" {
  description = "CIDR for EKS private subnet in AZ2"
  type        = string
  default     = "10.1.7.0/24"
}

# Tags
variable "extra_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
