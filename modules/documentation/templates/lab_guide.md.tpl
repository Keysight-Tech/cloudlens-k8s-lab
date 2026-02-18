# CloudLens K8s Visibility Lab: ${upper(deployment_prefix)}

> **Generated:** ${generated_date}
> **Region:** ${aws_region} | **Profile:** ${aws_profile}

---

# Part 1: Before You Begin

---

## Prerequisites

### License Activation Codes

You must have your own Keysight license activation codes before starting this lab:

| Product | License Required |
|---------|-----------------|
| **KVO** | VisionOrchestrator perpetual license |
| **CloudLens (CLMS)** | CloudLens Enterprise Edition subscription |
| **CyPerf** | CyPerf license (if using traffic generator) |

> **Important:** Contact your Keysight representative or SE manager to obtain your license codes before starting.

### Tools

| Tool | Install (macOS) | Install (Windows) | Verify |
|------|----------------|-------------------|--------|
| **kubectl** | `brew install kubectl` | `choco install kubernetes-cli` | `kubectl version --client` |
| **Helm** | `brew install helm` | `choco install kubernetes-helm` | `helm version` |
| **AWS CLI** | `brew install awscli` | `choco install awscli` | `aws --version` |

> Install docs: [kubectl](https://kubernetes.io/docs/tasks/tools/) | [Helm](https://helm.sh/docs/intro/install/) | [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)

---

%{~ if eks_enabled ~}

## Configure kubectl

```bash
# Configure kubectl for the EKS cluster
${eks_kubeconfig_command}

# Verify connection
kubectl get nodes
kubectl get pods --all-namespaces
```

---
%{~ endif ~}

# Part 2: Your Lab Environment

---

## Keysight Products

| Product | URL | Credentials |
|---------|-----|-------------|
| **CLMS** (CloudLens Manager) | https://${clms_public_ip} | admin / Cl0udLens@dm!n |
| **KVO** (Vision One) | https://${kvo_public_ip} | admin / admin |
%{~ if vpb_enabled ~}
| **vPB** (Virtual Packet Broker) | SSH: `ssh -i ${private_key_path} admin@${vpb_public_ip}` | admin / ixia |
%{~ endif ~}
%{~ if cyperf_enabled ~}
| **CyPerf Controller** | https://${cyperf_controller_public_ip} | admin / CyPerf&Keysight#1 |
%{~ endif ~}

> **CLMS Private IP** (for sensor config): `${clms_private_ip}`

---

## Workload VMs

| VM | Public IP | SSH/RDP Command |
|----|-----------|-----------------|
| **Ubuntu** | ${ubuntu_public_ip} | `ssh -i ${private_key_path} ubuntu@${ubuntu_public_ip}` |
| **Windows** | ${windows_public_ip} | RDP to `${windows_public_ip}:3389` (Administrator) |

---

## Tool VMs (Traffic Receivers)

| VM | Public IP | Private IP (for KVO Remote Tool) | Access |
|----|-----------|----------------------------------|--------|
| **Linux Tool** (tcpdump) | ${tool_linux_public_ip} | ${tool_linux_private_ip} | `ssh -i ${private_key_path} ubuntu@${tool_linux_public_ip}` |
| **Windows Tool** (Wireshark) | ${tool_windows_public_ip} | ${tool_windows_private_ip} | RDP: Administrator / CloudLens2024! |

> **KVO Remote Tool:** When adding a Remote Tool destination in KVO, use the **Private IP** (not the Public IP). KVO communicates with tool VMs over the internal VPC network.

---

%{~ if vpb_enabled ~}

## Virtual Packet Broker (vPB)

| Interface | Private IP | Purpose |
|-----------|-----------|---------|
| **Management** | ${vpb_mgmt_ip} | Admin access (public: ${vpb_public_ip}) |
| **Ingress** | ${vpb_ingress_ip} | Traffic collection from sources |
| **Egress** | ${vpb_egress_ip} | Traffic forwarding to tools |

---
%{~ endif ~}

%{~ if eks_enabled ~}

## Kubernetes Cluster

| Item | Value |
|------|-------|
| **Cluster Name** | ${eks_cluster_name} |
| **Endpoint** | ${eks_cluster_endpoint} |
| **Region** | ${aws_region} |
%{~ for name, url in ecr_repository_urls ~}
| **ECR: ${name}** | `${url}` |
%{~ endfor ~}

---
%{~ endif ~}

%{~ if cyperf_enabled ~}

## CyPerf Traffic Generator

| Item | Value |
|------|-------|
| **Controller UI** | https://${cyperf_controller_public_ip} |
| **Controller Private IP** | ${cyperf_controller_private_ip} |
| **Login** | admin / CyPerf&Keysight#1 |
| **SSH** | `ssh -i ${private_key_path} admin@${cyperf_controller_public_ip}` |

**Traffic Path:**
```
CyPerf Client Pod -> cyperf-proxy (ClusterIP) -> nginx-demo pods
                                                  (CloudLens captures here)
```

**Monitor CyPerf traffic on nginx pods:**
```bash
# All traffic (live)
kubectl logs -f -l app=nginx-demo

# Filter by app
kubectl logs -f -l app=nginx-demo | grep -i "netflix"
kubectl logs -f -l app=nginx-demo | grep -i "youtube"
kubectl logs -f -l app=nginx-demo | grep -i "discord"
kubectl logs -f -l app=nginx-demo | grep -i "openai"

# All apps with color
kubectl logs -f -l app=nginx-demo | grep -iE "netflix|youtube|discord|openai|chatgpt|keysight" --color
```

---
%{~ endif ~}

## Nginx LoadBalancer URL

<!-- NGINX_URL_PLACEHOLDER_START -->
*Pending - deploy nginx workload and update this section with the LoadBalancer URL.*
<!-- NGINX_URL_PLACEHOLDER_END -->

---

# Part 3: Lab Exercises

---

## Exercise 1: License Activation & KVO Setup

**KVO URL:** https://${kvo_public_ip}

### Step 1: Activate Licenses in KVO

Navigate to **Settings > Licensing** in KVO and activate your licenses:

1. Click **PRODUCT LICENSING** in the top menu bar
2. Click **Activate licenses** on the left
3. In the **"Enter License Data"** field, paste your activation codes (one per line)
4. Click **Load data** to parse the codes
5. Review the products and quantities, then click **Activate**

| Product | License Required |
|---------|-----------------|
| **KVO** | VisionOrchestrator perpetual license |
| **CloudLens (CLMS)** | CloudLens Enterprise Edition subscription |

> **Prerequisite:** You must have your own KVO and CloudLens license activation codes. Contact your Keysight representative or SE manager if you do not have them.

### Step 2: Create KVO User on CLM

1. Log in to CLM at https://${clms_public_ip} (admin / Cl0udLens@dm!n)
2. A "Create KVO User" dialog appears at first login. Fill in a unique username and password.

### Step 3: Register CLM in KVO Inventory

1. In KVO, go to **Inventory > Devices > Add Device**
2. Choose **CloudLens Manager** as device type
3. Enter CLM IP address and the KVO credentials created above

---

%{~ if eks_enabled ~}

## Exercise 2: Install CloudLens Sensor (DaemonSet)

### Step 1: Get the Sensor Access Key from KVO

1. In KVO (https://${kvo_public_ip}), go to **Visibility Fabric > Cloud Configs**
2. Click **New Cloud Config**
3. Select **Kubernetes Cluster** type
4. Fill in a **Name**, select the **CloudLens Manager**, and add a **Cloud to Device Link**
5. Click **Ok** -- the **Sensor Access Key** will be generated
6. Copy the Sensor Access Key -- you'll use it as the project key in the Helm command below

### Step 2: Install the Helm chart

```bash
helm install cloudlens-agent \
  oci://${lookup(ecr_repository_urls, "cloudlens_sensor", "REPLACE_WITH_ECR_URL")}/cloudlens-sensor \
  --version 6.13.0-359 \
  --insecure-skip-tls-verify \
  --set image.repository=${lookup(ecr_repository_urls, "cloudlens_sensor", "REPLACE_WITH_ECR_URL")} \
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

### Step 3: Verify sensor is running

```bash
kubectl get pods -l app.kubernetes.io/name=cloudlens-sensor
kubectl logs -l app.kubernetes.io/name=cloudlens-sensor --tail=20
```

---

## Exercise 3: KVO Visibility Configuration

### Step 1: Create a Kubernetes Cloud Config

In KVO, go to **Visibility Fabric > Cloud Configs**:

1. Click **Create Cloud Config**
2. Select **Kubernetes Cluster Cloud Config (K8s)**
3. Configure:
   - **Name** -- give it a name
   - **CloudLens Manager** -- select the CLM from Inventory
   - **Cloud-to-Device Link** -- select the tapped traffic path link
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

### Linux Tool VM -- tcpdump

```bash
ssh -i ${private_key_path} ubuntu@${tool_linux_public_ip}

# Verify VXLAN packets are arriving
sudo tcpdump -i ens5 udp port 4789 -nn -c 20 -q

# View HTTP Host headers inside VXLAN packets
sudo tcpdump -i ens5 udp port 4789 -nn -A | grep -iE 'netflix|openai|chatgpt|youtube|discord|Host:'

# Decode inner packets for actual HTTP traffic
sudo tcpdump -i any -nn udp port 4789 -A | grep -iE "netflix|youtube|chatgpt|openai|discord|keysight"

# Capture to file for Wireshark analysis
sudo tcpdump -i ens5 udp port 4789 -nn -w ~/captures/cyperf-vxlan.pcap
```

### Windows Tool VM -- Wireshark

1. RDP to Windows Tool VM: `${tool_windows_public_ip}` (Administrator / CloudLens2024!)
2. Open Wireshark (desktop icon)
3. Start capture on the **Ethernet** interface
4. Apply display filters:

```
# All CyPerf app traffic
http.host contains "netflix" or http.host contains "openai" or http.host contains "youtube" or http.host contains "discord"

# All HTTP traffic inside VXLAN
vxlan && http

# Specific app
http.host contains "netflix"
http.host contains "youtube"
http.host contains "openai"
http.host contains "discord"
```

---

## Exercise 5: Sidecar Installation (Advanced)

Deploys CloudLens sensor as a **sidecar container** alongside your application pod. Unlike the DaemonSet (all node traffic), the sidecar captures traffic for **one specific pod**.

> **DaemonSet** = broad visibility | **Sidecar** = targeted per-pod monitoring. Both can coexist.

### Step 1: Save the sidecar deployment YAML

Create a file called `nginx-cloudlens-sidecar.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-cloudlens-sidecar
  labels:
    app: nginx-cloudlens-sidecar
spec:
  selector:
    matchLabels:
      app: nginx-cloudlens-sidecar
  replicas: 1
  template:
    metadata:
      labels:
        app: nginx-cloudlens-sidecar
    spec:
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
        image: ${lookup(ecr_repository_urls, "cloudlens_sensor", "REPLACE_WITH_ECR_URL")}:sensor-6.13.0-359
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
        - "name=nginx-sidecar,source=K8s"
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
kubectl get pods -l app=nginx-cloudlens-sidecar

# Check sidecar logs
kubectl logs -l app=nginx-cloudlens-sidecar -c cloudlens-sidecar --tail=20
```

### Step 3: Configure in KVO

1. Create a **Cloud Collection** targeting the sidecar pod (Workload Selector: `pod-name` = `nginx-cloudlens-sidecar`)
2. Create a **Monitoring Policy** with the collection as source and your tool VM as destination

### Step 4: Cleanup

```bash
kubectl delete deployment nginx-cloudlens-sidecar
```

%{~ endif ~}

---

# Part 4: Reference

---

%{~ if eks_enabled ~}

## Uninstall CloudLens Sensor

```bash
# Remove DaemonSet
helm uninstall cloudlens-agent

# Remove Sidecar
kubectl delete deployment nginx-cloudlens-sidecar
```

---
%{~ endif ~}

## Useful Commands

### kubectl Quick Reference

```bash
# Configure kubectl
${eks_kubeconfig_command}

# View all pods
kubectl get pods --all-namespaces

# View nginx-demo pods
kubectl get pods -l app=nginx-demo -o wide

# View CyPerf pods
kubectl get pods -n cyperf -o wide

# View services
kubectl get svc --all-namespaces

# View nodes
kubectl get nodes -o wide
```

### SSH Quick Reference

```bash
# Ubuntu workload
ssh -i ${private_key_path} ubuntu@${ubuntu_public_ip}

# Linux tool (tcpdump)
ssh -i ${private_key_path} ubuntu@${tool_linux_public_ip}
%{~ if vpb_enabled ~}

# vPB
ssh -i ${private_key_path} admin@${vpb_public_ip}
%{~ endif ~}
%{~ if cyperf_enabled ~}

# CyPerf Controller
ssh -i ${private_key_path} admin@${cyperf_controller_public_ip}
%{~ endif ~}
```

---

## Troubleshooting

### Cannot access CLMS/KVO UI
- Wait 15 minutes after deployment for initialization
- Check security group allows your IP
- Verify instance is running: `aws ec2 describe-instance-status --instance-ids <ID> --profile ${aws_profile}`

### SSH connection refused
- Verify key permissions: `chmod 400 ${private_key_path}`
- Check instance state
- Verify correct username (ubuntu / ec2-user / admin)

### Windows RDP not working
- Wait 10 minutes for Windows setup
- Windows Tool VM uses password: **CloudLens2024!**
- Windows Workload VM: decrypt password with AWS CLI

### Pod stuck in Pending
```bash
kubectl describe pod <POD_NAME>
```
Check for resource quota or node capacity issues.

%{~ if cyperf_enabled ~}

### CyPerf test won't start
- Verify license is activated in CyPerf Controller UI
- Check agents are registered: both agents must show as online with `role:client` and `role:server` tags
- Check iptables fixer is running: `kubectl exec cyperf-agent-client -n cyperf -- iptables -L INPUT`
- Verify proxy connectivity: `kubectl exec cyperf-agent-client -n cyperf -- curl -s http://<proxy-pod-ip>/`
%{~ endif ~}

---

## Cost Management

```bash
# Stop all instances (save costs when not in use)
./scripts/stop-all.sh

# Start all instances
./scripts/start-all.sh
```

---

*Generated by Terraform documentation module. Re-run `terraform apply` to regenerate with updated IPs.*
