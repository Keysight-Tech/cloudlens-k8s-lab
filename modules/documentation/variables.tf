# ============================================================================
# DOCUMENTATION MODULE VARIABLES
# ============================================================================

variable "deployment_prefix" {
  description = "Lab deployment prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile"
  type        = string
}

variable "private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

variable "output_directory" {
  description = "Directory to write generated documentation"
  type        = string
}

# CLMS
variable "clms_public_ip" {
  description = "CLMS public IP"
  type        = string
}

variable "clms_private_ip" {
  description = "CLMS private IP"
  type        = string
}

# KVO
variable "kvo_public_ip" {
  description = "KVO public IP"
  type        = string
}

# vPB
variable "vpb_enabled" {
  description = "Whether vPB is deployed"
  type        = bool
  default     = true
}

variable "vpb_public_ip" {
  description = "vPB public IP"
  type        = string
}

variable "vpb_interfaces" {
  description = "vPB interface IPs"
  type = object({
    management = string
    ingress    = string
    egress     = string
  })
}

# Ubuntu VM
variable "ubuntu_public_ip" {
  description = "Ubuntu VM public IP"
  type        = string
}

# Windows
variable "windows_public_ip" {
  description = "Windows VM public IP"
  type        = string
}

# Tool VMs
variable "tool_linux_public_ip" {
  description = "Linux Tool VM public IP"
  type        = string
}

variable "tool_linux_private_ip" {
  description = "Linux Tool VM private IP"
  type        = string
}

variable "tool_windows_public_ip" {
  description = "Windows Tool VM public IP"
  type        = string
}

variable "tool_windows_private_ip" {
  description = "Windows Tool VM private IP"
  type        = string
}

# EKS
variable "eks_enabled" {
  description = "Whether EKS is deployed"
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = ""
}

variable "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  type        = string
  default     = ""
}

variable "eks_kubeconfig_command" {
  description = "Command to configure kubectl"
  type        = string
  default     = ""
}

variable "ecr_repository_urls" {
  description = "ECR repository URLs"
  type        = map(string)
  default     = {}
}

# CyPerf
variable "cyperf_enabled" {
  description = "Whether CyPerf is deployed"
  type        = bool
  default     = false
}

variable "cyperf_controller_public_ip" {
  description = "CyPerf Controller public IP"
  type        = string
  default     = ""
}

variable "cyperf_controller_private_ip" {
  description = "CyPerf Controller private IP"
  type        = string
  default     = ""
}
