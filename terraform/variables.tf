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

# Tags
variable "extra_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
