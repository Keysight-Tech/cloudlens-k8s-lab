# ============================================================================
# SE-LAB MODULE VARIABLES
# ============================================================================

# Identity
variable "deployment_prefix" {
  description = "Unique prefix for this lab environment"
  type        = string
}

variable "lab_index" {
  description = "Numeric index of this lab (1-25)"
  type        = number
}

variable "owner" {
  description = "Owner name for this lab (e.g., 'SE-01')"
  type        = string
}

# AWS Configuration
variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile"
  type        = string
}

variable "availability_zone" {
  description = "Primary availability zone"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair name"
  type        = string
}

variable "private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

# Network CIDRs
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "management_subnet_cidr" {
  description = "CIDR for management subnet"
  type        = string
}

variable "ingress_subnet_cidr" {
  description = "CIDR for vPB ingress subnet"
  type        = string
}

variable "egress_subnet_cidr" {
  description = "CIDR for vPB egress subnet"
  type        = string
}

variable "eks_public_subnet_az1_cidr" {
  description = "CIDR for EKS public subnet AZ1"
  type        = string
}

variable "eks_private_subnet_az1_cidr" {
  description = "CIDR for EKS private subnet AZ1"
  type        = string
}

variable "eks_public_subnet_az2_cidr" {
  description = "CIDR for EKS public subnet AZ2"
  type        = string
}

variable "eks_private_subnet_az2_cidr" {
  description = "CIDR for EKS private subnet AZ2"
  type        = string
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
variable "eks_enabled" {
  description = "Enable EKS cluster for this lab"
  type        = bool
  default     = false
}

variable "vpb_enabled" {
  description = "Enable vPB deployment (requires AWS Marketplace subscription)"
  type        = bool
  default     = true
}

variable "rhel_enabled" {
  description = "Enable RHEL VM deployment"
  type        = bool
  default     = false
}

variable "ubuntu_workload_enabled" {
  description = "Enable Ubuntu workload VM (disable if CyPerf generates traffic)"
  type        = bool
  default     = true
}

# Instance Types
variable "clms_instance_type" {
  description = "Instance type for CLMS"
  type        = string
  default     = "t3.xlarge"
}

variable "kvo_instance_type" {
  description = "Instance type for KVO"
  type        = string
  default     = "t3.2xlarge"
}

variable "vpb_instance_type" {
  description = "Instance type for vPB"
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

variable "rhel_instance_type" {
  description = "Instance type for RHEL VM"
  type        = string
  default     = "t3.medium"
}

variable "tool_linux_instance_type" {
  description = "Instance type for Linux tool VM"
  type        = string
  default     = "t3.medium"
}

variable "tool_windows_instance_type" {
  description = "Instance type for Windows tool VM"
  type        = string
  default     = "t3.large"
}

# EKS Configuration
variable "eks_kubernetes_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_type" {
  description = "Instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "eks_node_desired_size" {
  description = "Desired number of EKS worker nodes"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 2
}

variable "eks_node_max_size" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 4
}

# Elastic IPs
variable "use_elastic_ips" {
  description = "Use Elastic IPs for static public IPs (requires EIP quota)"
  type        = bool
  default     = true
}

# Shared EKS VPC Peering
variable "shared_eks_enabled" {
  description = "Whether shared EKS VPC peering is enabled"
  type        = bool
  default     = false
}

variable "shared_eks_vpc_id" {
  description = "VPC ID of the shared EKS cluster (for peering)"
  type        = string
  default     = ""
}

variable "shared_eks_vpc_cidr" {
  description = "CIDR of the shared EKS VPC (for security groups and routing)"
  type        = string
  default     = ""
}

# Tags
variable "extra_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
