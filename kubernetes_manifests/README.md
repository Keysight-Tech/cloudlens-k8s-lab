# Kubernetes Manifests for CloudLens EKS Training Lab

This directory contains Kubernetes manifest files for deploying sample applications with CloudLens sidecar containers in the EKS cluster.

## Files

1. **cloudlens-config.yaml** - ConfigMap with CLMS IP, vPB IP, and configuration
2. **nginx-deployment.yaml** - Nginx deployment with CloudLens sidecar + LoadBalancer service
3. **apache-deployment.yaml** - Apache deployment with CloudLens sidecar + LoadBalancer service

## Prerequisites

Before applying these manifests:

1. **EKS cluster deployed** - Run `terraform apply` to create the cluster
2. **kubectl configured** - Run the command from `terraform output eks_kubeconfig_command`
3. **ECR images pushed** - Docker images must be in ECR (see Phase 1 instructions)
4. **CLMS project created** - Generate project key from CLMS UI

## Setup Instructions

### Step 1: Update Image URLs

After ECR repositories are created, get the repository URLs:

```bash
terraform output ecr_repository_urls
```

Replace `REPLACE_WITH_ECR_URL` in the YAML files with your actual ECR URLs:
- nginx-deployment.yaml: Update both `nginx` and `cloudlens-sensor` image URLs
- apache-deployment.yaml: Update both `apache` and `cloudlens-sensor` image URLs

Example:
```yaml
# Before:
image: REPLACE_WITH_ECR_URL/se-demo-nginx-app:latest

# After:
image: 466778915280.dkr.ecr.us-west-2.amazonaws.com/se-demo-nginx-app:latest
```

### Step 2: Generate CLMS Project Key

1. Access CLMS UI:
   ```bash
   terraform output clms_public_ip
   # Open https://<CLMS-IP> in browser
   ```

2. Login: admin / <CLMS_PASSWORD>

3. Navigate to: **Projects** → **Create Project**
   - Name: "EKS Container Monitoring - se-demo"
   - Click **Create**

4. Copy the **Project Key** (UUID format)

5. Update manifests:
   ```bash
   # Replace REPLACE_WITH_CLMS_PROJECT_KEY with your actual key
   # macOS:
   sed -i '' 's/REPLACE_WITH_CLMS_PROJECT_KEY/<YOUR_PROJECT_KEY>/g' nginx-deployment.yaml
   sed -i '' 's/REPLACE_WITH_CLMS_PROJECT_KEY/<YOUR_PROJECT_KEY>/g' apache-deployment.yaml
   # Linux:
   sed -i 's/REPLACE_WITH_CLMS_PROJECT_KEY/<YOUR_PROJECT_KEY>/g' nginx-deployment.yaml
   sed -i 's/REPLACE_WITH_CLMS_PROJECT_KEY/<YOUR_PROJECT_KEY>/g' apache-deployment.yaml
   ```

### Step 3: Verify CLMS IP

Check the CLMS private IP matches the manifests:

```bash
terraform output clms_private_ip
# Returns the private IP assigned to your CLMS instance (e.g. 10.1.1.x)
```

If different, update the `--server` argument in both deployment files.

### Step 4: Apply Manifests

```bash
# Apply ConfigMap first
kubectl apply -f cloudlens-config.yaml

# Deploy nginx with CloudLens sidecar
kubectl apply -f nginx-deployment.yaml

# Deploy apache with CloudLens sidecar
kubectl apply -f apache-deployment.yaml
```

### Step 5: Verify Deployments

```bash
# Check pods are running
kubectl get pods -l cloudlens=enabled

# Check services and LoadBalancer URLs
kubectl get svc

# View pod logs
NGINX_POD=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
kubectl logs $NGINX_POD -c nginx
kubectl logs $NGINX_POD -c cloudlens-sensor
```

### Step 6: Test Applications

```bash
# Get LoadBalancer URLs
NGINX_LB=$(kubectl get svc nginx-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
APACHE_LB=$(kubectl get svc apache-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Wait for LoadBalancers to provision (3-5 minutes)
kubectl get svc -w

# Test HTTP access
curl http://$NGINX_LB
curl http://$APACHE_LB
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ EKS Cluster (10.0.5.0/24, 10.0.7.0/24)                     │
│                                                              │
│  ┌────────────────────────┐  ┌────────────────────────┐   │
│  │ nginx-cloudlens Pod    │  │ apache-cloudlens Pod   │   │
│  │                        │  │                        │   │
│  │ ┌────────┐ ┌─────────┐│  │ ┌────────┐ ┌─────────┐│   │
│  │ │ nginx  │ │CloudLens││  │ │ apache │ │CloudLens││   │
│  │ │        │ │ Sensor  ││  │ │        │ │ Sensor  ││   │
│  │ └────────┘ └─────────┘│  │ └────────┘ └─────────┘│   │
│  └───────│────────│───────┘  └───────│────────│───────┘   │
│          │        │                  │        │            │
│          │        └──────────────────┼────────┘            │
│          │           Traffic to vPB  │                     │
└──────────│────────────────────────────│─────────────────────┘
           │                            │
           │ HTTP Traffic               │ Mirrored Traffic
           ↓                            ↓
    LoadBalancer                  vPB Ingress (10.0.2.x)
    (Internet)                          │
                                        ↓
                                   vPB Processing
                                        │
                                        ↓
                                   vPB Egress (10.0.3.x)
                                        │
                                        ↓
                                   Tool VM / CLMS UI
```

## CloudLens Sidecar Container Details

The CloudLens sensor sidecar requires:

### Privileged Capabilities
```yaml
capabilities:
  add:
  - SYS_MODULE      # Load kernel modules for eBPF
  - SYS_RESOURCE    # Resource management
  - NET_RAW         # Raw socket access for packet capture
  - NET_ADMIN       # Network administration
```

### Volume Mounts
```yaml
- /host              # Host filesystem (read-only)
- /lib/modules       # Kernel modules (read-only)
- /var/log/cloudlens # Sensor logs (emptyDir)
- /var/run/containerd/containerd.sock # Container runtime socket
```

### Environment Variables
The sensor automatically discovers:
- Pod name, namespace, IP from Kubernetes downward API
- Node information from host mount

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod <pod-name>

# Common issues:
# 1. ImagePullBackOff - ECR authentication issue
# 2. CrashLoopBackOff - CLMS connection failed
# 3. Pending - Node resources exhausted
```

### CloudLens Sensor Not Connecting

```bash
# Check sensor logs
kubectl logs <pod-name> -c cloudlens-sensor

# Verify CLMS connectivity from pod
kubectl exec <pod-name> -c nginx -- curl -k https://10.0.1.106

# Check security group allows EKS → CLMS
aws ec2 describe-security-groups --group-ids <clms-sg-id>
```

### LoadBalancer Not Provisioning

```bash
# Check service events
kubectl describe svc nginx-service

# Verify EKS has permissions to create LoadBalancers
# Check AWS Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

## Scaling Applications

```bash
# Scale nginx to 4 replicas
kubectl scale deployment nginx-cloudlens --replicas=4

# Scale apache to 3 replicas
kubectl scale deployment apache-cloudlens --replicas=3

# Watch pods scaling
kubectl get pods -l cloudlens=enabled -w
```

## Cleanup

```bash
# Delete deployments and services
kubectl delete -f nginx-deployment.yaml
kubectl delete -f apache-deployment.yaml
kubectl delete -f cloudlens-config.yaml

# Or delete all at once
kubectl delete -f .
```

## Integration with CLMS

After pods are running, verify in CLMS UI:

1. Navigate to: **Sensors** → **Active Sensors**
2. You should see sensors with names like:
   - `nginx-cloudlens-<pod-hash>`
   - `apache-cloudlens-<pod-hash>`
3. Click on a sensor to see:
   - Pod name, namespace, IP
   - Container information
   - Network traffic statistics
   - Captured packets (if forwarded to vPB)

## Next Steps

After deployment:

1. **Generate HTTP Traffic**:
   ```bash
   while true; do curl http://$NGINX_LB; sleep 1; done
   ```

2. **View Traffic in vPB/Tool VM**:
   ```bash
   ssh ubuntu@<tool-vm-ip>
   sudo tcpdump -i any -w /home/ubuntu/captures/eks-traffic.pcap
   ```

3. **Compare EC2 vs Container Traffic**:
   - Generate traffic from both EC2 VMs and EKS pods
   - Analyze patterns in Tool VM
   - Compare visibility in CLMS UI

## References

- Main Training Guide: `../TRAINING-LAB-GUIDE.md`
- EKS README: `../README-EKS.md` (to be created)
- Deployment Summary: `../DEPLOYMENT-SUMMARY.md`
