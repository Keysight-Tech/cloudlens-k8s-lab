# ============================================================================
# SE-LAB MODULE - MAIN ORCHESTRATION
# ============================================================================
# Creates a complete isolated lab environment with:
# - VPC with management, ingress, egress subnets
# - Keysight products (CLMS, KVO, vPB)
# - Workload VMs (Ubuntu x2, Windows, RHEL)
# - Tool VMs (Linux, Windows with Wireshark)
# - Optional EKS cluster and ECR repositories
# ============================================================================

locals {
  # Compute availability zone if not provided
  az_primary = var.availability_zone != "" ? var.availability_zone : "${var.aws_region}a"
  az_secondary = "${var.aws_region}b"

  # Sanitize owner name for Kubernetes labels (replace spaces with hyphens)
  owner_sanitized = replace(var.owner, " ", "-")

  # Resource naming
  vpc_name      = "${var.deployment_prefix}-vpc"
  clms_name     = "${var.deployment_prefix}-clms"
  kvo_name      = "${var.deployment_prefix}-kvo"
  vpb_name      = "${var.deployment_prefix}-vpb"
  tapped_1_name = "${var.deployment_prefix}-tapped-ubuntu-1"
  tapped_2_name = "${var.deployment_prefix}-tapped-ubuntu-2"
  windows_name  = "${var.deployment_prefix}-tapped-windows"
  rhel_name     = "${var.deployment_prefix}-tapped-rhel"
  tool_name     = "${var.deployment_prefix}-tool"
  tool_windows_name = "${var.deployment_prefix}-tool-windows"
  eks_cluster_name  = "${var.deployment_prefix}-eks-cluster"

  common_tags = merge(
    {
      Project    = "CloudLens-SE-Training"
      Deployment = var.deployment_prefix
      Owner      = var.owner
      LabIndex   = tostring(var.lab_index)
      ManagedBy  = "Terraform"
      Training   = "CloudLens-SE-Training"
    },
    var.extra_tags
  )

  # AMI mappings for Keysight products (Updated from AWS Marketplace)
  vpb_amis = {
    "ap-south-2"     = "ami-0af8bbac90b4d2947"
    "ap-south-1"     = "ami-08ce739c8bdbf14b0"
    "eu-south-1"     = "ami-07c8f73d364894afc"
    "eu-south-2"     = "ami-01fb036bbf59ab5ab"
    "me-central-1"   = "ami-0c350bd636497cfa0"
    "il-central-1"   = "ami-0141cc48d608101d9"
    "ca-central-1"   = "ami-03bea12d398ff78fd"
    "ca-west-1"      = "ami-0f14b4cff2c21873c"
    "ap-east-2"      = "ami-08a1b73818bfe4bd2"
    "ap-east-1"      = "ami-02cb166cbc36f5436"
    "mx-central-1"   = "ami-07d172adb3d272d48"
    "eu-central-1"   = "ami-0b3a92c2f2358b3c6"
    "eu-central-2"   = "ami-0b0a197be0896946e"
    "us-west-1"      = "ami-0f18517fa7a8deebd"
    "us-west-2"      = "ami-053a7625c955e2ed6"
    "af-south-1"     = "ami-016c32569aa730f43"
    "eu-north-1"     = "ami-0856fa0d04915166e"
    "eu-west-3"      = "ami-072240d3c8e50c5c2"
    "eu-west-2"      = "ami-0b88f498dab70e7be"
    "eu-west-1"      = "ami-001ed8da2c24024ca"
    "ap-northeast-3" = "ami-0031c21db29ac17b5"
    "ap-northeast-2" = "ami-04618122a148c4b8e"
    "ap-northeast-1" = "ami-08f0bfc92f574929e"
    "me-south-1"     = "ami-061288c80fdcf5fcd"
    "sa-east-1"      = "ami-0bffe063bd9e426b5"
    "ap-southeast-1" = "ami-0c0ed1b89e57be428"
    "ap-southeast-2" = "ami-0fbceafa7e0c675b1"
    "ap-southeast-3" = "ami-05083d0108de535cb"
    "ap-southeast-4" = "ami-025ded017bf78973b"
    "ap-southeast-5" = "ami-059945b7a5d807ef9"
    "ap-southeast-6" = "ami-08f74e0c1998458c8"
    "ap-southeast-7" = "ami-05425e6cbd28cbb42"
    "us-east-1"      = "ami-0a561b450552b707d"
    "us-east-2"      = "ami-0ae1d6e9dbd8e4c73"
    "us-gov-east-1"  = "ami-0e5693d7f953ffd39"
    "us-gov-west-1"  = "ami-0e08a3350568c7615"
  }

  kvo_amis = {
    "ap-south-2"     = "ami-0b96bc32cf2af2208"
    "ap-south-1"     = "ami-0e579f93331cd8712"
    "eu-south-1"     = "ami-01837403d8d99f0f5"
    "eu-south-2"     = "ami-0c982dae72c65a4f8"
    "us-gov-east-1"  = "ami-0330506aa21f8dd93"
    "me-central-1"   = "ami-054cbecab08400080"
    "il-central-1"   = "ami-0521481359a9be0c4"
    "ca-central-1"   = "ami-0164ddd77416f2ca2"
    "ap-east-2"      = "ami-09551b378c7c4a593"
    "mx-central-1"   = "ami-001fec5e5e5020ff6"
    "eu-central-1"   = "ami-0fcc45a154c9e0a9c"
    "eu-central-2"   = "ami-0396ee3b5374628fb"
    "us-west-1"      = "ami-078dcfe6ef376cbf8"
    "us-west-2"      = "ami-0461fbb90a12fc90d"
    "af-south-1"     = "ami-0392529d5be56ef0f"
    "eu-north-1"     = "ami-054091974203318bf"
    "eu-west-3"      = "ami-0a714169d86335031"
    "eu-west-2"      = "ami-0f0b3a8233656bee1"
    "eu-west-1"      = "ami-073bf2fb4534dbd7a"
    "ap-northeast-3" = "ami-0369b592c1522dd7b"
    "ap-northeast-2" = "ami-04bcfabedc146003d"
    "me-south-1"     = "ami-03a3da2ef6c86ad44"
    "ap-northeast-1" = "ami-096430c7ccaba7a2c"
    "sa-east-1"      = "ami-034c8abf9114c9c62"
    "ap-east-1"      = "ami-0ba2f9d7944606609"
    "ca-west-1"      = "ami-0bfacd61db3703b0b"
    "us-gov-west-1"  = "ami-0f41ad88e6bfca27e"
    "ap-southeast-1" = "ami-0c9a3935cfbc53ac8"
    "ap-southeast-2" = "ami-0b38af1afe0f11695"
    "ap-southeast-3" = "ami-0cdb607bbbdba40ae"
    "ap-southeast-4" = "ami-09cf887f0f85f0a64"
    "us-east-1"      = "ami-017c0db8981569380"
    "ap-southeast-5" = "ami-04de62ac22a7941e1"
    "us-east-2"      = "ami-09ba4a3a96b404131"
    "ap-southeast-6" = "ami-08d86311079d1f3ec"
    "ap-southeast-7" = "ami-0a11e3bc816e039d3"
  }

  clms_amis = {
    "ap-south-2"     = "ami-0b58a86b447402ebc"
    "ap-south-1"     = "ami-0de9998616b04343e"
    "eu-south-1"     = "ami-08c54eb5627676529"
    "eu-south-2"     = "ami-00fe9ffc05f1c83b9"
    "us-gov-east-1"  = "ami-01885059be96ad228"
    "me-central-1"   = "ami-0fb54089c3036f0cd"
    "il-central-1"   = "ami-071b41ac0cb423b82"
    "ca-central-1"   = "ami-0b4ec2f46fc51cd6d"
    "ap-east-2"      = "ami-088c50e1b751b01e6"
    "mx-central-1"   = "ami-0ad6409352b7419c9"
    "eu-central-1"   = "ami-0e8c6cc855fcfc22"
    "eu-central-2"   = "ami-0514eff795d7588e3"
    "us-west-1"      = "ami-0420c02f2c555a402"
    "us-west-2"      = "ami-0f3fba668617b18f1"
    "af-south-1"     = "ami-0b39c43b5ea96d07d"
    "eu-west-3"      = "ami-0ff96c646488ad267"
    "eu-north-1"     = "ami-051d4022ca7c470b6"
    "eu-west-2"      = "ami-0c8189014261e3c7f"
    "eu-west-1"      = "ami-0bf7638d1e75aac19"
    "ap-northeast-3" = "ami-01c9ec670e4788998"
    "ap-northeast-2" = "ami-099ba3b2908624c03"
    "me-south-1"     = "ami-0e5287f30ce6300ca"
    "ap-northeast-1" = "ami-05383c85ebe460ee6"
    "sa-east-1"      = "ami-0d2c8a03971d49c4b"
    "ap-east-1"      = "ami-023b7fb4377e4c6cc"
    "us-gov-west-1"  = "ami-064ec0e6029f94039"
    "ca-west-1"      = "ami-0022f9cbaa3b726ef"
    "ap-southeast-1" = "ami-04955ec1c6899170d"
    "ap-southeast-2" = "ami-00fb08ffc483a3ea1"
    "ap-southeast-3" = "ami-0527033d7fa838a8d"
    "ap-southeast-4" = "ami-01057ee69eba1ef76"
    "us-east-1"      = "ami-0bebd5e730315337e"
    "ap-southeast-5" = "ami-09f851ed8aae05210"
    "us-east-2"      = "ami-085c6b0cf292a110f"
    "ap-southeast-7" = "ami-0e5aa1deb5728b516"
  }

  vpb_ami  = lookup(local.vpb_amis, var.aws_region, null)
  kvo_ami  = lookup(local.kvo_amis, var.aws_region, null)
  clms_ami = lookup(local.clms_amis, var.aws_region, null)
}

# ============================================================================
# DATA SOURCES
# ============================================================================

data "aws_caller_identity" "current" {}

# Get latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Get latest Windows Server 2022 AMI
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["801119661308"] # Amazon

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Get latest RHEL 9 AMI
data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
