# CloudLens K8s SE Training Lab

Automated deployment of Keysight CloudLens network visibility training environments on AWS. Each SE (Systems Engineer) gets an isolated lab with CloudLens Manager, KVO, Virtual Packet Broker, workload VMs, and a shared EKS cluster with dedicated Kubernetes namespaces.

## Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │          Shared Infrastructure              │
                         │  ┌─────────────┐  ┌──────────────────────┐  │
                         │  │ Shared VPC   │  │ Shared EKS Cluster   │  │
                         │  │ 10.100.0.0/16│  │ 1 control plane      │  │
                         │  │             │  │ N dedicated nodes    │  │
                         │  │ Public ECR  │  │ (1 per SE)           │  │
                         │  └──────┬──────┘  └──────────┬───────────┘  │
                         │         │    VPC Peering      │             │
                         └─────────┼────────────────────┼─────────────┘
                                   │                    │
             ┌─────────────────────┼────────────────────┼─────────────────┐
             │                     │                    │                  │
    ┌────────▼────────┐   ┌───────▼─────────┐  ┌──────▼──────────┐      │
    │   SE Lab 01     │   │   SE Lab 02     │  │   SE Lab N      │  ... │
    │  VPC 10.1.0.0/16│   │  VPC 10.2.0.0/16│  │  VPC 10.N.0.0/16│      │
    │                 │   │                 │  │                 │      │
    │  CLMS  KVO  vPB │   │  CLMS  KVO  vPB │  │  CLMS  KVO  vPB │      │
    │  Ubuntu Windows │   │  Ubuntu Windows │  │  Ubuntu Windows │      │
    │  Tool VMs       │   │  Tool VMs       │  │  Tool VMs       │      │
    └─────────────────┘   └─────────────────┘  └─────────────────┘      │
             │                                                           │
             └───────────────────────────────────────────────────────────┘
```

**Per SE Lab:**
- **CLMS** (CloudLens Manager) - Network visibility management
- **KVO** (Keysight Vision One) - Network packet broker
- **vPB** (Virtual Packet Broker) - Traffic monitoring appliance
- **Ubuntu VM** - Tapped Linux workload
- **Windows VM** - Tapped Windows workload
- **Tool VMs** - Linux + Windows tool VMs (Wireshark, tcpdump)
- **EKS Namespace** - Dedicated K8s namespace on shared cluster with own worker node

## Prerequisites

- **AWS Account** with marketplace subscriptions for:
  - Keysight CloudLens Manager (CLMS)
  - Keysight Vision One (KVO)
  - Keysight Virtual Packet Broker (vPB)
  - Keysight CyPerf Controller (optional)
- **Tools installed:**
  - Terraform >= 1.0
  - AWS CLI v2 (configured with a named profile)
  - kubectl
  - Docker (for ECR image push)
  - Helm 3
  - jq
- **EC2 Key Pair** created in the target AWS region
- **AWS Service Quotas** (request increases if needed):
  - Elastic IPs: 5 per SE lab
  - vCPUs: ~20 per SE lab (varies by instance types)
  - VPCs: 1 per SE lab + 1 shared

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/Keysight-Tech/cloudlens-k8s-lab.git
cd cloudlens-k8s-lab
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your AWS profile, region, key pair

# 2. Initialize Terraform
terraform init

# 3. Deploy (start with 1 lab to test)
terraform plan
terraform apply

# 4. Deploy K8s components (namespaces, sample apps, nginx)
./scripts/deploy-multi-se-labs.sh

# 5. Generate SE lab guides with dynamic data
./scripts/post-deploy.sh
```

## Variable Reference

| Variable | Type | Default | Required | Description |
|----------|------|---------|----------|-------------|
| `aws_profile` | string | `"your-aws-profile"` | **Yes** | AWS CLI profile name |
| `aws_region` | string | `"us-west-2"` | No | AWS region for deployment |
| `key_pair_name` | string | `"your-key-pair"` | **Yes** | EC2 key pair name |
| `num_se_labs` | number | `1` | No | Number of SE labs to create (1-25) |
| `multi_se_mode` | bool | `false` | No | Enable multi-SE lab mode |
| `vpb_enabled` | bool | `true` | No | Deploy vPB instances |
| `rhel_enabled` | bool | `false` | No | Deploy RHEL VMs per lab |
| `cyperf_enabled` | bool | `false` | No | Deploy CyPerf controller |
| `cyperf_vm_agents_enabled` | bool | `false` | No | Deploy CyPerf VM agents |
| `ubuntu_workload_enabled` | bool | `true` | No | Deploy Ubuntu workload VMs |
| `shared_eks_enabled` | bool | `true` | No | Deploy shared EKS cluster |
| `use_elastic_ips` | bool | `true` | No | Use Elastic IPs for static addresses |
| `clms_instance_type` | string | `"t3.xlarge"` | No | CLMS instance type |
| `kvo_instance_type` | string | `"t3.2xlarge"` | No | KVO instance type |
| `vpb_instance_type` | string | `"t3.xlarge"` | No | vPB instance type |
| `ubuntu_instance_type` | string | `"t3.medium"` | No | Ubuntu VM instance type |
| `windows_instance_type` | string | `"t3.medium"` | No | Windows VM instance type |

## Default Credentials

See [CREDENTIALS.md](CREDENTIALS.md) for all default product credentials.

## Post-Deployment Steps

1. **Wait for initialization**: CLMS needs ~15 minutes, vPB needs ~5 minutes after deploy
2. **Run deployment scripts**:
   ```bash
   # Deploy K8s namespaces, sample apps, nginx LBs
   ./scripts/deploy-multi-se-labs.sh

   # Generate SE-specific lab guides
   ./scripts/post-deploy.sh
   ```
3. **Change default passwords** on all products immediately
4. **Distribute lab guides** from `generated/` directory to each SE

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `deploy-multi-se-labs.sh` | Full deployment: namespaces, apps, ECR images |
| `deploy-multi-se.sh` | Terraform apply wrapper for multi-SE |
| `post-deploy.sh` | Generate SE lab guides with dynamic data |
| `setup-se-namespaces.sh` | Create K8s namespaces with RBAC |
| `deploy-sample-apps.sh` | Deploy sample apps to EKS |
| `deploy-nginx-to-all-namespaces.sh` | Deploy nginx to all SE namespaces |
| `push-ecr-images.sh` | Push CloudLens sensor images to ECR |
| `generate-se-kubeconfigs.sh` | Generate per-SE kubeconfig files |
| `show-access-info.sh` | Display all lab access information |
| `configure-cyperf-test.sh` | Configure CyPerf test (optional) |
| `deploy-cyperf-k8s.sh` | Deploy CyPerf K8s agents (optional) |
| `start-all.sh` / `stop-all.sh` | Start/stop all lab VMs |
| `start-multi-se.sh` / `smart-stop-multi-se.sh` | Start/stop multi-SE VMs |
| `destroy-all.sh` / `destroy-multi-se.sh` | Destroy all resources |

## Cost Estimates

Approximate monthly costs per SE lab (us-west-2, on-demand pricing):

| Resource | Instance | Monthly Cost |
|----------|----------|-------------|
| CLMS | t3.xlarge | ~$120 |
| KVO | t3.2xlarge | ~$240 |
| vPB | t3.xlarge | ~$120 |
| Ubuntu VM | t3.medium | ~$30 |
| Windows VM | t3.medium | ~$30 |
| Tool VMs (2) | t3.medium/large | ~$60 |
| EKS Node | t3.medium | ~$25 |
| EKS Control Plane | (shared) | ~$73 (split) |
| Elastic IPs | 5 per lab | ~$18 |
| **Total per lab** | | **~$650/month** |

Use `stop-all.sh` or `smart-stop-multi-se.sh` to stop VMs when not in use and reduce costs.

## Troubleshooting

**Terraform init fails**: Ensure AWS CLI is configured and you have the correct marketplace subscriptions.

**EIP limit exceeded**: Request an AWS service quota increase for Elastic IPs in your region.

**vPB not accessible**: Wait 5-10 minutes after deployment. vPB initializes slowly.

**CLMS UI not loading**: Wait 15 minutes after deployment. Check security group allows HTTPS from your IP.

**EKS nodes not joining**: Check that the shared VPC CIDR doesn't conflict with SE lab VPC CIDRs.

**Generated docs show placeholders**: Run `./scripts/post-deploy.sh` after `terraform apply` to fill in dynamic data.

## License

Copyright Keysight Technologies. All rights reserved.
