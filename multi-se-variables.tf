# ============================================================================
# MULTI-SE LAB VARIABLES
# ============================================================================
# These variables control the deployment of 25 SE training lab environments
# ============================================================================

variable "num_se_labs" {
  description = "Number of SE lab environments to create (1-25)"
  type        = number
  default     = 1

  validation {
    condition     = var.num_se_labs >= 1 && var.num_se_labs <= 25
    error_message = "num_se_labs must be between 1 and 25"
  }
}

variable "enabled_labs" {
  description = "List of specific labs to deploy (empty = all). E.g., [\"se-lab-01\", \"se-lab-05\"]"
  type        = list(string)
  default     = []
}

variable "eks_enabled_for_all" {
  description = "Enable EKS for all SE labs (expensive - $72/month per cluster)"
  type        = bool
  default     = false
}

variable "shared_eks_enabled" {
  description = "Enable shared EKS cluster accessible by all SEs"
  type        = bool
  default     = true
}

variable "shared_eks_node_instance_type" {
  description = "Instance type for dedicated SE worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "shared_eks_dedicated_node_per_se" {
  description = "Enable dedicated node per SE (true) or shared nodes (false)"
  type        = bool
  default     = true
}

variable "shared_eks_kubernetes_version" {
  description = "Kubernetes version for shared EKS"
  type        = string
  default     = "1.31"
}

variable "num_se_namespaces" {
  description = "Number of SE namespaces to create (should match num_se_labs)"
  type        = number
  default     = 1
}

variable "multi_se_mode" {
  description = "Enable multi-SE lab mode (creates isolated environments per SE)"
  type        = bool
  default     = false
}

variable "use_elastic_ips" {
  description = "Use Elastic IPs for static public IPs (requires EIP quota increase)"
  type        = bool
  default     = true
}

variable "vpb_enabled" {
  description = "Deploy vPB instances (requires AWS Marketplace subscription to Keysight vPB)"
  type        = bool
  default     = true
}

variable "rhel_enabled" {
  description = "Deploy RHEL VMs in each SE lab"
  type        = bool
  default     = false
}

variable "cyperf_enabled" {
  description = "Deploy CyPerf Controller and VM-based agents (requires AWS Marketplace subscription)"
  type        = bool
  default     = false
}

variable "cyperf_vm_agents_enabled" {
  description = "Deploy CyPerf VM-based agents (disabled: ENA AF_PACKET is broken on AWS). K8s agents are used instead."
  type        = bool
  default     = false
}

variable "ubuntu_workload_enabled" {
  description = "Deploy Ubuntu workload VMs in each SE lab (disable if CyPerf generates traffic)"
  type        = bool
  default     = true
}

# ============================================================================
# AWS CONFIGURATION
# ============================================================================

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = "your-aws-profile"
}

variable "key_pair_name" {
  description = "Name of existing EC2 key pair for SSH access"
  type        = string
  default     = "your-key-pair"
}

variable "private_key_path" {
  description = "Local path to SSH private key (for documentation)"
  type        = string
  default     = "~/path/to/cloudlens-se-training.pem"
}

# ============================================================================
# SECURITY
# ============================================================================

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

# ============================================================================
# INSTANCE TYPES
# ============================================================================

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

variable "rhel_instance_type" {
  description = "Instance type for RHEL VMs"
  type        = string
  default     = "t3.medium"
}

variable "cyperf_controller_instance_type" {
  description = "Instance type for CyPerf Controller (8 vCPU, 16GB RAM recommended)"
  type        = string
  default     = "c5.2xlarge"
}

variable "cyperf_agent_instance_type" {
  description = "Instance type for CyPerf Agent VMs (client + server)"
  type        = string
  default     = "c5.2xlarge"
}

# ============================================================================
# EKS CONFIGURATION
# ============================================================================

variable "eks_kubernetes_version" {
  description = "Kubernetes version for EKS clusters"
  type        = string
  default     = "1.28"
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
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 3
}

# ============================================================================
# TAGS
# ============================================================================

variable "extra_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
