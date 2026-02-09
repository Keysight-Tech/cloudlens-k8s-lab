# CloudLens S1K Training for Kubernetes Tap (K8s): ${upper(deployment_prefix)}

## Lab Owner: ${owner}

**Lab Repo:** https://github.com/Keysight-Tech/cloudlens-k8s-lab

---

# Part 1: Before You Begin

---

## Prerequisites

| Tool | Install (macOS) | Install (Windows) | Verify |
|------|----------------|-------------------|--------|
| **AWS CLI** | `brew install awscli` | `choco install awscli` | `aws --version` |
| **kubectl** | `brew install kubectl` | `choco install kubernetes-cli` | `kubectl version --client` |
| **Docker** | `brew install --cask docker` | `choco install docker-desktop` | `docker --version` |
| **Helm** | `brew install helm` | `choco install kubernetes-helm` | `helm version` |

> Install docs: [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | [kubectl](https://kubernetes.io/docs/tasks/tools/) | [Docker](https://docs.docker.com/desktop/) | [Helm](https://helm.sh/docs/intro/install/)

---

## SSH Key

The SSH private key (`cloudlens-se-training.pem`) is included in your SE folder.

```bash
# Linux/Mac - Use directly from your SE folder:
ssh -i ./cloudlens-se-training.pem ubuntu@<VM_IP>

# Windows - Use PuTTYgen to convert .pem to .ppk format
```

---

%{ if eks_cluster_name != "" }
## Configure kubectl

A pre-built kubeconfig file is included in your SE folder. No AWS CLI or SSO login needed.

```bash
export KUBECONFIG=./kubeconfig-${se_namespace}.yaml

# Verify connection
kubectl get nodes
kubectl get pods
```

> **Note:** The kubeconfig is scoped to your namespace (`${se_namespace}`). Use `kubectl get pods` (not `kubectl get pods -A`).

---

%{ endif }
# Part 2: Your Lab Environment

---

## Keysight Products

| Product | URL | Credentials |
|---------|-----|-------------|
| **CLMS** | https://${clms_public_ip} | admin / <CLMS_PASSWORD> |
| **KVO** | https://${kvo_public_ip} | admin / admin |
%{ if vpb_enabled }| **vPB** | ssh admin@${vpb_public_ip} | admin / <VPB_PASSWORD> |
%{ else }| **vPB** | Not deployed | - |
%{ endif }

---

## Tool VMs (Traffic Receivers)

| VM | Public IP | Private IP (for KVO Remote Tool) | Access |
|----|-----------|----------------------------------|--------|
| **Linux Tool** | ${tool_linux_public_ip} | ${tool_linux_private_ip} | `ssh -i ./cloudlens-se-training.pem ubuntu@${tool_linux_public_ip}` |
| **Windows Tool** | ${tool_windows_public_ip} | ${tool_windows_private_ip} | RDP: Administrator / <WINDOWS_TOOL_PASSWORD> |

> **KVO Remote Tool:** When adding a Remote Tool destination in KVO, use the **Private IP** (not the Public IP). KVO communicates with tool VMs over the internal VPC network.

---

## Windows RDP Access

### Windows Tool VM (Packet Analysis)

| Item | Value |
|------|-------|
| **IP Address** | ${tool_windows_public_ip} |
| **Username** | Administrator |
| **Password** | <WINDOWS_TOOL_PASSWORD> |
| **Port** | 3389 |

```bash
# Mac/Linux
open rdp://Administrator@${tool_windows_public_ip}
```

**Pre-installed Tools:** Wireshark, Nmap, PuTTY, WinSCP, Notepad++

### Windows Tapped VM (IIS Server)

| Item | Value |
|------|-------|
| **IP Address** | ${windows_public_ip} |
| **Username** | Administrator |
| **Password** | *Encrypted - see below* |

```bash
aws ec2 get-password-data \
  --instance-id <INSTANCE_ID> \
  --priv-launch-key ~/Downloads/cloudlens-se-training.pem \
  --profile ${aws_profile} \
  --region ${aws_region} \
  --query 'PasswordData' --output text
```

---

%{ if vpb_enabled }
## vPB Network Interfaces

| Interface | IP Address | Purpose |
|-----------|------------|---------|
| Management | ${vpb_mgmt_ip} | Admin access (Public: ${vpb_public_ip}) |
| Ingress | ${vpb_ingress_ip} | Traffic collection |
| Egress | ${vpb_egress_ip} | Traffic forwarding |

---

%{ endif }
## SSH Quick Reference

```bash
%{ if vpb_enabled }
# vPB (password: <VPB_PASSWORD>)
ssh -i ~/Downloads/cloudlens-se-training.pem admin@${vpb_public_ip}
%{ endif }

# Linux Tool VM (key auth)
ssh -i ~/Downloads/cloudlens-se-training.pem ubuntu@${tool_linux_public_ip}
```

---

%{ if eks_cluster_name != "" }
## Kubernetes Cluster

| Item | Value |
|------|-------|
| **Cluster Name** | ${eks_cluster_name} |
| **Endpoint** | ${eks_cluster_endpoint} |
| **Region** | ${aws_region} |
| **Your Namespace** | `${se_namespace}` |
| **ECR Repository** | `${ecr_public_url}/cloudlens-sensor` |

---

%{ endif }
## Nginx LoadBalancer URL

<!-- NGINX_URL_PLACEHOLDER_START -->
*Pending - run post-deploy.sh after terraform apply to deploy nginx and populate the LoadBalancer URL.*
<!-- NGINX_URL_PLACEHOLDER_END -->

---

## Architecture Diagram

**[View Architecture Diagram](https://www.cheap-you.com/)**

The architecture diagram (`cloudlens-kubernetes-architecture.html`) is available in the training materials folder.

> **Lab Components:** CLMS (CloudLens Manager), KVO (Vision Orchestrator), vPB (Virtual Packet Broker), shared EKS cluster with dedicated nodes per SE, and workload VMs for traffic generation and analysis.

---

# Part 3: Lab Exercises

---

## Exercise 1: License Activation & KVO Setup

**KVO URL:** https://${kvo_public_ip}

### Step 1: Activate Licenses in KVO

Navigate to **Settings > Licensing** in KVO and enter these activation codes:

| Product | Activation Code | Max Activations |
|---------|-----------------|-----------------|
| **KVO** | `<KVO_LICENSE>` | **10** |
| **CloudLens (CLMS)** | `<CLMS_LICENSE>` | **5** |
| **vPB** | `<VPB_LICENSE>` | **5** |

> **Important:** These are shared codes. Do not exceed the maximum activations.

### Step 2: Create KVO User on CLM

1. Log in to CLM at https://${clms_public_ip} (admin / <CLMS_PASSWORD>)
2. A "Create KVO User" dialog appears at first login. Fill in a unique username and password.

### Step 3: Register CLM in KVO Inventory

1. In KVO, go to **Inventory > Devices > Add Device**
2. Choose **CloudLens Manager** as device type
3. Enter CLM IP address and the KVO credentials created above

---

%{ if eks_cluster_name != "" }
## Exercise 2: Install CloudLens Sensor (DaemonSet)

### Step 1: ECR Authentication

```bash
aws ecr-public get-login-password --region us-east-1 --profile ${aws_profile} | \
  helm registry login --username AWS --password-stdin public.ecr.aws
```

> **Tip:** If you get a `403 Forbidden` error during Helm install, re-run this command.

### Step 2: Create a Project in CLMS

1. Login to CLMS at https://${clms_public_ip}
2. Create a new Project
3. Generate a Project Key
4. Copy the key — you'll use it in the Helm command below

### Step 3: Install the Helm chart

```bash
helm install cloudlens-agent-${se_id} oci://${ecr_public_url}/cloudlens-sensor \
  --namespace ${se_namespace} \
  --version 6.13.0-359 \
  --insecure-skip-tls-verify \
  --set image.repository=${ecr_public_url}/cloudlens-sensor \
  --set image.tag=sensor-6.13.0-359 \
  --set sensor.server=${clms_private_ip} \
  --set sensor.projectKey=<YOUR_PROJECT_KEY> \
  --set privileged=true \
  --set sensor.debug=false \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=256Mi
```

### Step 4: Patch to run on your dedicated node

```bash
kubectl patch daemonset cloudlens-agent-${se_id}-cloudlens-sensor -n ${se_namespace} --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/tolerations", "value": [{"key": "se-id", "operator": "Equal", "value": "${se_id}", "effect": "NoSchedule"}]},
  {"op": "add", "path": "/spec/template/spec/nodeSelector", "value": {"se-id": "${se_id}"}}
]'
```

### Step 5: Verify

```bash
kubectl get pods -n ${se_namespace}
kubectl get daemonset -n ${se_namespace}
# Check sensor in CLMS: https://${clms_public_ip} -> Projects -> Your Project -> Sensors
```

**Single-line version (copy as one line):**
```bash
helm install cloudlens-agent-${se_id} oci://${ecr_public_url}/cloudlens-sensor --namespace ${se_namespace} --version 6.13.0-359 --insecure-skip-tls-verify --set image.repository=${ecr_public_url}/cloudlens-sensor --set image.tag=sensor-6.13.0-359 --set sensor.server=${clms_private_ip} --set sensor.projectKey=<YOUR_PROJECT_KEY> --set privileged=true --set sensor.debug=false --set resources.requests.cpu=50m --set resources.requests.memory=128Mi --set resources.limits.cpu=100m --set resources.limits.memory=256Mi && kubectl patch daemonset cloudlens-agent-${se_id}-cloudlens-sensor -n ${se_namespace} --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"se-id","operator":"Equal","value":"${se_id}","effect":"NoSchedule"}]},{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"se-id":"${se_id}"}}]'
```

---

## Exercise 3: KVO Visibility Configuration

### Step 1: Create a Kubernetes Cloud Config

In KVO, go to **Visibility Fabric > Cloud Configs**:

1. Click **Create Cloud Config**
2. Select **Kubernetes Cluster Cloud Config (K8s)**
3. Configure:
   - **Name** — give it a name
   - **CloudLens Manager** — select the CLM from Inventory
   - **Cloud-to-Device Link** — select the tapped traffic path link
4. Commit the change request

### Step 2: Create a Cloud Collection

In KVO, go to **Visibility Fabric > Cloud Collection**:

1. Select your Kubernetes Cloud Config
2. Use **Workload Selectors** (e.g., namespace-based) to choose which pods to tap

### Step 3: Create a Monitoring Policy

1. Create a new Monitoring Policy:
   - **Source** = Cloud Collection (created above)
   - **Destination** = Tool VM (use **Private IP**: Linux `${tool_linux_private_ip}` or Windows `${tool_windows_private_ip}`)
2. Traffic mirrored via VXLAN will now arrive on your tool VMs

---

## Exercise 4: Verify Traffic on Tool VMs

### Linux Tool VM — tcpdump

```bash
# SSH to your Linux Tool VM
ssh -i ~/Downloads/cloudlens-se-training.pem ubuntu@${tool_linux_public_ip}

# Verify VXLAN packets are arriving
sudo tcpdump -i ens5 udp port 4789 -nn -c 20 -q

# View HTTP Host headers inside VXLAN packets (Netflix, YouTube, ChatGPT, Discord)
sudo tcpdump -i ens5 udp port 4789 -nn -A | grep -iE 'netflix|openai|chatgpt|youtube|discord|Host:'

# Capture to file for Wireshark analysis
sudo tcpdump -i ens5 udp port 4789 -nn -w ~/captures/cyperf-vxlan.pcap
```

### Windows Tool VM — Wireshark

1. RDP to Windows Tool VM: `${tool_windows_public_ip}` (Administrator / <WINDOWS_TOOL_PASSWORD>)
2. Open Wireshark (desktop icon)
3. Start capture on the **Ethernet** interface
4. Apply one of these display filters:

```
# All CyPerf app traffic
http.host contains "netflix" or http.host contains "openai" or http.host contains "youtube" or http.host contains "discord"

# All HTTP traffic inside VXLAN
vxlan && http

# All VXLAN traffic
vxlan

# Specific app
http.host contains "netflix"
http.host contains "youtube"
http.host contains "openai"
http.host contains "discord"
```

> **Tip:** Expand **Virtual eXtensible Local Area Network** in packet details to see VXLAN VNI, then expand **Hypertext Transfer Protocol** for HTTP headers.

---

%{ if vpb_enabled }
## Exercise 5: vPB Traffic Forwarding

1. SSH to vPB: `ssh -i ~/Downloads/cloudlens-se-training.pem admin@${vpb_public_ip}`
2. Configure port forwarding:
```
configure
set port-forward rule 1 source port eth1 destination port eth2
commit
exit
```
3. Verify on Linux Tool VM:
```bash
sudo tcpdump -i any -n
```

---

%{ endif }
## Exercise 6: Sidecar Installation (Advanced)

Deploys CloudLens sensor as a **sidecar container** alongside your application pod. Unlike the DaemonSet (all node traffic), the sidecar captures traffic for **one specific pod**.

> **DaemonSet** = broad visibility | **Sidecar** = targeted per-pod monitoring. Both can coexist.

### Step 1: Save the sidecar deployment YAML

Create a file called `nginx-cloudlens-sidecar.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-cloudlens-sidecar
  namespace: ${se_namespace}
  labels:
    app: nginx-cloudlens-sidecar
    se-id: ${se_id}
spec:
  selector:
    matchLabels:
      app: nginx-cloudlens-sidecar
  replicas: 1
  template:
    metadata:
      labels:
        app: nginx-cloudlens-sidecar
        se-id: ${se_id}
    spec:
      tolerations:
      - key: se-id
        operator: Equal
        value: ${se_id}
        effect: NoSchedule
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: se-id
                operator: In
                values:
                - ${se_id}
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
      - name: cloudlens-sidecar
        image: ${lookup(ecr_repository_urls, "cloudlens_sensor", "public.ecr.aws/n4s8a3s0/cloudlens-sensor")}:sensor-6.13.0-359
        args:
        - "--auto_update"
        - "y"
        - "--project_key"
        - "<YOUR_PROJECT_KEY>"
        - "--accept_eula"
        - "yes"
        - "--server"
        - "${clms_private_ip}"
        - "--ssl_verify"
        - "no"
        - "--custom_tags"
        - "name=nginx-sidecar,source=K8s,namespace=${se_namespace}"
        securityContext:
          allowPrivilegeEscalation: true
          privileged: true
          capabilities:
            add: ["SYS_RAWIO", "SYS_RESOURCE", "SYS_ADMIN", "NET_ADMIN", "NET_RAW"]
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 100m
            memory: 256Mi
```

### Step 2: Deploy and verify

```bash
kubectl apply -f nginx-cloudlens-sidecar.yaml

# Check pod status (should show 2/2 Ready)
kubectl get pods -n ${se_namespace} -l app=nginx-cloudlens-sidecar

# Check sidecar logs
kubectl logs -n ${se_namespace} -l app=nginx-cloudlens-sidecar -c cloudlens-sidecar --tail=20
```

### Step 3: Configure in KVO

1. Create a **Cloud Collection** targeting the sidecar pod (Workload Selector: `pod-name` = `nginx-cloudlens-sidecar`)
2. Create a **Monitoring Policy** with the collection as source and your tool VM as destination

### Step 4: Cleanup

```bash
kubectl delete deployment nginx-cloudlens-sidecar -n ${se_namespace}
```

%{ endif }

---

# Part 4: Reference

---

%{ if eks_cluster_name != "" }
## Uninstall CloudLens Sensor

```bash
# Remove DaemonSet
helm uninstall cloudlens-agent-${se_id} --namespace ${se_namespace}

# Remove Sidecar
kubectl delete deployment nginx-cloudlens-sidecar -n ${se_namespace}
```

---

%{ endif }
## Troubleshooting

### Cannot access CLMS/KVO UI
- Wait 15 minutes after deployment for initialization
- Check security group allows your IP
- Verify instance is running

### SSH connection refused
- Verify key permissions: `chmod 400 ~/Downloads/cloudlens-se-training.pem`
- Check instance state
- Verify correct username (ubuntu/ec2-user/admin)

### Windows RDP not working
- Wait 10 minutes for Windows setup
- Windows Tool VM uses password: **<WINDOWS_TOOL_PASSWORD>**

### Pod stuck in Pending
```bash
kubectl describe pod <POD_NAME> -n ${se_namespace}
```
Check for taint/toleration or resource quota issues.

### Helm install fails with 403
Re-run ECR authentication:
```bash
aws ecr-public get-login-password --region us-east-1 --profile ${aws_profile} | \
  helm registry login --username AWS --password-stdin public.ecr.aws
```
