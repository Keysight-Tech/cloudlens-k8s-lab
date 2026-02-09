# CloudLens Kubernetes Visibility Lab Guide

### Complete walkthrough: AWS setup, infrastructure deployment, Keysight product configuration, and hands-on lab exercises

This lab teaches you to deploy and operate **Keysight CloudLens** for Kubernetes network visibility on AWS. You'll provision an EKS cluster, install CloudLens sensors, configure traffic tapping through **Keysight Vision One (KVO)**, and forward mirrored traffic through a **Virtual Packet Broker (vPB)** to analysis tools like Wireshark and tcpdump.

---

## Table of Contents

- [Architecture Diagram](#architecture-diagram)
- **Part 1: Prerequisites**
  - [1.1 AWS Marketplace Subscriptions](#11-aws-marketplace-subscriptions)
  - [1.2 Create an EC2 Key Pair](#12-create-an-ec2-key-pair)
  - [1.3 Check AWS Service Quotas](#13-check-aws-service-quotas)
  - [1.4 Configure AWS CLI](#14-configure-aws-cli)
  - [1.5 Install Required Tools](#15-install-required-tools)
- **Part 2: Deploy the Lab**
  - [2.1 Clone and Configure](#21-clone-and-configure)
  - [2.2 Deploy with Terraform](#22-deploy-with-terraform)
  - [2.3 Wait for Initialization](#23-wait-for-initialization)
  - [2.4 Configure kubectl for EKS](#24-configure-kubectl-for-eks)
  - [2.5 Deploy Sample Applications to EKS](#25-deploy-sample-applications-to-eks)
- **Part 3: Keysight Product Setup**
  - [3.1 Log In to CLMS](#31-log-in-to-clms-cloudlens-manager)
  - [3.2 Create KVO User on CLMS](#32-create-kvo-user-on-clms)
  - [3.3 Log In to KVO](#33-log-in-to-kvo-keysight-vision-one)
  - [3.4 Register CLMS in KVO Inventory](#34-register-clms-in-kvo-inventory)
  - [3.5 Activate Licenses](#35-activate-licenses)
  - [3.6 Connect to vPB](#36-connect-to-vpb-virtual-packet-broker)
- **Part 4: Lab Exercises**
  - [Exercise 1: Install CloudLens Sensor (DaemonSet)](#exercise-1-install-cloudlens-sensor-on-eks-daemonset)
  - [Exercise 2: KVO Visibility Configuration](#exercise-2-kvo-visibility-configuration)
  - [Exercise 3: Verify Mirrored Traffic](#exercise-3-verify-mirrored-traffic-on-tool-vms)
  - [Exercise 4: vPB Traffic Forwarding](#exercise-4-vpb-traffic-forwarding)
  - [Exercise 5: Sidecar Sensor (Advanced)](#exercise-5-sidecar-sensor-installation-advanced)
- **Part 5: Reference**
  - [Troubleshooting](#troubleshooting)
  - [Cost Management](#cost-management)
  - [Uninstall / Cleanup](#uninstall--cleanup)
  - [Lab Environment Summary](#lab-environment-summary)
  - [SSH Quick Reference](#ssh-quick-reference)

---

## Architecture Diagram

![CloudLens Kubernetes Visibility Architecture](docs/images/architecture-diagram.png)

**Traffic Flow:**
1. **Deploy** - KVO pushes monitoring policies to CloudLens Manager
2. **Tap & Mirror** - CloudLens sensors (DaemonSet or Sidecar) capture pod traffic (North-South + East-West)
3. **Encap** - Mirrored traffic is VXLAN-encapsulated and sent to the analysis plane
4. **Filter** - Virtual Packet Broker performs traffic de-duplication, header stripping, and filtering
5. **Deliver** - Filtered traffic is forwarded via VXLAN/GRE to enterprise tools (Wireshark, tcpdump, threat detection)

---

# Part 1: Prerequisites

## 1.1 AWS Marketplace Subscriptions

Before deploying, ensure your AWS account has:

- **AWS Marketplace subscriptions** for these Keysight products:
  - [CloudLens Manager (CLMS)](https://aws.amazon.com/marketplace) - Network visibility management
  - [Keysight Vision One (KVO)](https://aws.amazon.com/marketplace) - Network packet broker
  - [Virtual Packet Broker (vPB)](https://aws.amazon.com/marketplace) - Traffic monitoring appliance

> **How to subscribe:** Go to AWS Marketplace, search for each product, click "Continue to Subscribe", then "Accept Terms". No charges until you launch instances.

### Step 1: Navigate to AWS Marketplace

Open the AWS Console and search for **"AWS Marketplace"** in the search bar.

![AWS Marketplace search](docs/images/01-aws-marketplace-search.png)

### Step 2: Search for Keysight CloudLens

In the Marketplace, click **"Discover products"** and search for **"Keysight CloudLens"**.

![Search for Keysight CloudLens](docs/images/03-marketplace-cloudlens-search.png)

### Step 3: Subscribe to CloudLens Manager

Click on **Keysight CloudLens Manager**, then click **"View purchase options"** > **"Continue to Subscribe"** > **"Accept Terms"**.

![CloudLens Manager product page](docs/images/04-clms-product-detail.png)

![Subscription accepted - $0.00 contract](docs/images/05-clms-subscription-accepted.png)

### Step 4: Verify All Subscriptions

Repeat for KVO and vPB. Go to **"Manage subscriptions"** to verify all products show **Active** status.

![All 6 Keysight subscriptions active](docs/images/06-manage-subscriptions.png)

---

## 1.2 Create an EC2 Key Pair

An EC2 key pair is required for SSH access to all Linux VMs in your lab (CLMS, vPB, Ubuntu workload, and tool VMs). Without it, you won't be able to connect to any of your lab instances.

### Step 1: Navigate to Key Pairs

In the AWS Console, go to **EC2** > **Network & Security** > **Key Pairs** in the left sidebar.

![EC2 Key Pairs page - click Create key pair](docs/images/37-ec2-key-pairs-page.png)

### Step 2: Create the Key Pair

Click **Create key pair** (orange button, top right) and configure:

| Setting | Value |
|---------|-------|
| **Name** | `cloudlens-lab` (or any name you'll remember) |
| **Key pair type** | **RSA** |
| **Private key file format** | **.pem** (for macOS/Linux) or **.ppk** (for PuTTY on Windows) |

![Create key pair form - enter name, select RSA and .pem format](docs/images/38-ec2-create-key-pair.png)

Click **Create key pair**. The `.pem` file will **download automatically to your browser's Downloads folder**.

> **IMPORTANT:** This is the **only time** you can download this private key. AWS does not store it. If you lose it, you must create a new key pair. Save it somewhere safe.

### Step 3: Set Key Permissions

```bash
# Move it to a known location (optional)
mv ~/Downloads/cloudlens-lab.pem ~/.ssh/

# Restrict permissions (required for SSH to accept it)
chmod 400 ~/.ssh/cloudlens-lab.pem
```

---

## 1.3 Check AWS Service Quotas

Your lab requires these resources. Request increases if needed:

| Resource | Required | Check Command |
|----------|----------|---------------|
| Elastic IPs | 7+ | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3` |
| vCPUs (on-demand) | ~25 | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A` |
| VPCs | 1 | Usually 5 per region (default) |

> **Tip:** Service quota increases are free but may take up to 24 hours. Request them before deploying.

---

## 1.4 Configure AWS CLI

```bash
# Install AWS CLI (if not installed)
brew install awscli          # macOS
# or: choco install awscli   # Windows

# Configure a named profile
aws configure --profile cloudlens-lab
# Enter: Access Key ID, Secret Access Key, Region (us-west-2), Output format (json)

# Verify
aws sts get-caller-identity --profile cloudlens-lab
```

![AWS CLI configuration](docs/images/10-aws-cli-configure.png)

---

## 1.5 Install Required Tools

| Tool | Install (macOS) | Install (Windows) | Verify |
|------|----------------|-------------------|--------|
| **Terraform** | `brew install terraform` | `choco install terraform` | `terraform version` |
| **kubectl** | `brew install kubectl` | `choco install kubernetes-cli` | `kubectl version --client` |
| **Helm** | `brew install helm` | `choco install kubernetes-helm` | `helm version` |
| **Docker** | `brew install --cask docker` | `choco install docker-desktop` | `docker --version` |

> Install docs: [Terraform](https://developer.hashicorp.com/terraform/install) | [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | [kubectl](https://kubernetes.io/docs/tasks/tools/) | [Helm](https://helm.sh/docs/intro/install/) | [Docker](https://docs.docker.com/desktop/)

---

# Part 2: Deploy the Lab

## 2.1 Clone and Configure

```bash
# Clone the repo
git clone https://github.com/Keysight-Tech/cloudlens-k8s-lab.git
cd cloudlens-k8s-lab

# Create your configuration file
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
# Required - match your AWS setup from Part 1
aws_profile      = "cloudlens-lab"
aws_region       = "us-west-2"
key_pair_name    = "cloudlens-lab"
private_key_path = "~/Downloads/cloudlens-lab.pem"

# Personalize
deployment_prefix = "cloudlens-lab"
owner             = "Your Name"

# Features
vpb_enabled     = true
eks_enabled     = true
use_elastic_ips = true
```

---

## 2.2 Deploy with Terraform

```bash
# Initialize Terraform (downloads providers)
terraform init

# Preview what will be created
terraform plan

# Deploy everything (type 'yes' when prompted)
terraform apply
```

> **Deployment takes ~15-20 minutes.** Terraform creates a VPC, 6+ EC2 instances, an EKS cluster, security groups, and networking.

### What gets deployed

After `terraform apply` completes, you'll see outputs like:

```
clms_url        = "https://54.xx.xx.xx"
kvo_url         = "https://35.xx.xx.xx"
vpb_ip          = "52.xx.xx.xx"
ubuntu_ip       = "34.xx.xx.xx"
windows_ip      = "44.xx.xx.xx"
tool_linux_ip   = "54.xx.xx.xx"
tool_windows_ip = "35.xx.xx.xx"
eks_cluster_name = "cloudlens-lab-eks-cluster"
```

**Save these IPs** - you'll need them throughout the lab. Run `terraform output` at any time to see them again.

---

## 2.3 Wait for Initialization

Products need time to fully boot after the instances launch:

| Product | Wait Time | How to Check |
|---------|-----------|-------------|
| **CLMS** | ~15 minutes | Browse to `https://<CLMS_IP>` - login page appears |
| **KVO** | ~15 minutes | Browse to `https://<KVO_IP>` - login page appears |
| **vPB** | ~5-10 minutes | `ssh admin@<VPB_IP>` succeeds |
| **EKS** | ~10 minutes | `kubectl get nodes` shows Ready |

---

## 2.4 Configure kubectl for EKS

```bash
# Configure kubectl to connect to your EKS cluster
aws eks update-kubeconfig \
  --region us-west-2 \
  --name cloudlens-lab-eks-cluster \
  --profile cloudlens-lab

# Verify connection
kubectl get nodes
kubectl get pods -A
```

![kubectl get nodes showing 3 nodes Ready](docs/images/11-kubectl-get-nodes.png)

---

## 2.5 Deploy Sample Applications to EKS

Deploy nginx as a sample workload that CloudLens will monitor:

```bash
# Create a namespace for your workloads
kubectl create namespace cloudlens-demo

# Deploy nginx
kubectl apply -n cloudlens-demo -f kubernetes_manifests/nginx-eks-deployment.yaml

# Verify pods are running
kubectl get pods -n cloudlens-demo

# Check the nginx LoadBalancer URL (takes ~2 minutes to provision)
kubectl get svc -n cloudlens-demo
```

Once the LoadBalancer is ready, test it:
```bash
# Get the LoadBalancer URL
NGINX_URL=$(kubectl get svc nginx-demo -n cloudlens-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$NGINX_URL
```

---

# Part 3: Keysight Product Setup

## 3.1 Log In to CLMS (CloudLens Manager)

1. Open your browser and go to: `https://<CLMS_IP>`
2. Accept the self-signed certificate warning
3. You'll see the CLMS landing page:

![CLMS landing page](docs/images/12-clms-landing-page.png)

4. Log in with default credentials:

| Field | Value |
|-------|-------|
| **Username** | `admin` |
| **Password** | `Cl0udLens@dm!n` |

![CLMS login page with credentials](docs/images/13-clms-login-page.png)

5. **Change the default password immediately** when prompted

---

## 3.2 Create KVO User on CLMS

This allows KVO to communicate with CLMS.

1. Log in to CLMS at `https://<CLMS_IP>`
2. On first login, a **"Create KVO User"** dialog appears
3. Create a username and password (e.g., `b@kvo.com` / `YourPassword123`)
4. Save these credentials - you'll use them in the next step

![CLMS Create KVO User dialog](docs/images/14-clms-create-kvo-user.png)

After creating the user, you'll see it in the User Management page:

![CLMS User Management showing admin + KVO user](docs/images/15-clms-user-management.png)

---

## 3.3 Log In to KVO (Keysight Vision One)

1. Open: `https://<KVO_IP>`
2. Accept the self-signed certificate warning
3. Log in:

| Field | Value |
|-------|-------|
| **Username** | `admin` |
| **Password** | `admin` |

![KVO login page](docs/images/16-kvo-login-page.png)

4. **Change the default password** when prompted

---

## 3.4 Register CLMS in KVO Inventory

1. In KVO, go to **Inventory** in the left sidebar
2. Click the **CloudLens Manager** tab
3. Click **Discover CloudLens Manager**
4. Enter:
   - **Name:** Give it a name (e.g., `SE_Lab1_CLMS`)
   - **Hostname / IP:** `<CLMS_PRIVATE_IP>` (from `terraform output`)
   - **Username:** the KVO user created in step 3.2
   - **Password:** the KVO password created in step 3.2
5. Click **Ok**

![KVO Discover CloudLens Manager dialog](docs/images/18-kvo-discover-clms-dialog.png)

After successful registration, you'll see the CLMS with **CONNECTED** status:

![KVO Inventory showing CLMS connected](docs/images/17-kvo-inventory-clms-connected.png)

---

## 3.5 Activate Licenses

License keys are required for KVO, CLMS, and vPB. Contact your Keysight representative to obtain activation codes.

### Activate in KVO

1. In KVO, navigate to the top menu bar and click **PRODUCT LICENSING**
2. Click **Activate licenses** on the left
3. In the **"Enter License Data"** field, paste your activation codes (one per line)
4. Click **Load data** to parse the codes
5. Review the products and quantities, then click **Activate**

![KVO Activate Licenses - step-by-step](docs/images/22-kvo-activate-licenses-steps.png)

After loading, you'll see the products parsed with their descriptions:

| Product | Description |
|---------|------------|
| **VisionOrchestrator** | KVO perpetual license to manage 10 devices |
| **CloudLens** | CloudLens Enterprise Edition - 1 year subscription |
| **CloudLens** | CloudLens Private Virtual Packet Processing - Advanced |

![KVO Activate Licenses with products loaded](docs/images/21-kvo-activate-licenses-loaded.png)

---

## 3.6 Connect to vPB (Virtual Packet Broker)

```bash
# SSH to vPB
ssh admin@<VPB_IP>
# Password: ixia
```

| Field | Value |
|-------|-------|
| **Username** | `admin` |
| **Password** | `ixia` |

The vPB has three network interfaces:

| Interface | Purpose |
|-----------|---------|
| **Management** (eth0) | Admin access - the IP you SSH to |
| **Ingress** (eth1) | Traffic collection from workloads |
| **Egress** (eth2) | Traffic forwarding to monitoring tools |

---

# Part 4: Lab Exercises

## Exercise 1: Install CloudLens Sensor on EKS (DaemonSet)

The CloudLens sensor captures network traffic from Kubernetes pods. A DaemonSet ensures a sensor runs on every worker node.

### Step 1: Download CloudLens Sensor

Obtain the CloudLens sensor container image and Helm chart from your Keysight representative:
- `CloudLens-Sensor-6.13.0-359.tar` (Docker image)
- `cloudlens-sensor-6.13.0-359.tgz` (Helm chart)

### Step 2: Push Sensor Image to ECR

```bash
# Get ECR repository URL from Terraform output
ECR_URL=$(terraform output -json | jq -r '.eks_cluster_name.value' | sed 's/-eks-cluster//')

# Authenticate Docker to ECR
aws ecr get-login-password --region us-west-2 --profile cloudlens-lab | \
  docker login --username AWS --password-stdin $(aws sts get-caller-identity --profile cloudlens-lab --query Account --output text).dkr.ecr.us-west-2.amazonaws.com

# Load and push the sensor image
docker load -i ~/Downloads/CloudLens-Sensor-6.13.0-359.tar
docker tag cloudlens-sensor:sensor-6.13.0-359 <ECR_REPO_URL>:sensor-6.13.0-359
docker push <ECR_REPO_URL>:sensor-6.13.0-359
```

### Step 3: Create a Project in CLMS

1. Log in to CLMS at `https://<CLMS_IP>`
2. Click **Projects** in the left sidebar
3. Click **Create Project**
4. Name it (e.g., `K8s Lab`)
5. Click **Generate Key** to create a Project Key
6. **Copy the key** - you'll use it in the Helm command below

### Step 4: Install the Helm Chart

```bash
helm install cloudlens-agent oci://<ECR_REPO_URL>/cloudlens-sensor \
  --namespace cloudlens-demo \
  --version 6.13.0-359 \
  --set image.repository=<ECR_REPO_URL>/cloudlens-sensor \
  --set image.tag=sensor-6.13.0-359 \
  --set sensor.server=<CLMS_PRIVATE_IP> \
  --set sensor.projectKey=<YOUR_PROJECT_KEY> \
  --set privileged=true \
  --set sensor.debug=false \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=256Mi
```

> Replace `<ECR_REPO_URL>`, `<CLMS_PRIVATE_IP>`, and `<YOUR_PROJECT_KEY>` with your actual values.

### Step 5: Verify Sensor Deployment

```bash
# Check pods are running
kubectl get pods -n cloudlens-demo

# Check the DaemonSet
kubectl get daemonset -n cloudlens-demo

# Check sensor logs
kubectl logs -n cloudlens-demo -l app.kubernetes.io/name=cloudlens-sensor --tail=20
```

Expected output: pods show `Running` status, DaemonSet shows `DESIRED = CURRENT = READY`.

![kubectl get pods showing cloudlens sensor and nginx pods running](docs/images/34-kubectl-pods-sensor.png)

### Step 6: Verify in CLMS

1. Go to CLMS at `https://<CLMS_IP>`
2. Navigate to **Projects > Your Project > Sensors**
3. You should see your EKS worker nodes listed as active sensors

---

## Exercise 2: KVO Visibility Configuration

Now configure KVO to tap traffic from Kubernetes pods and forward it to your tool VMs for analysis.

### Step 1: Create a Kubernetes Cloud Config

1. In KVO, go to **Visibility Fabric > Cloud Configs**
2. Click **New Cloud Config** and select **Kubernetes Cluster**

![KVO Cloud Configs page with New Cloud Config dropdown](docs/images/23-kvo-cloud-configs-page.png)

3. Configure:
   - **Name:** `K8s` (or any name you prefer)
   - **CloudLens Manager:** select `SE_Lab1_CLMS` from the dropdown
   - **Sensor Access Key:** will be auto-generated
   - **Cloud to Device Link:** configure if needed
4. Click **Ok**

![KVO New Cloud Config dialog](docs/images/24-kvo-new-cloud-config.png)

5. **Commit** the change request by clicking the **Commit** button at the top

![KVO Cloud Config with uncommitted changes - click Commit](docs/images/25-kvo-cloud-config-commit.png)

### Step 2: Create a Cloud Collection

1. In KVO, go to **Visibility Fabric > Cloud Collection**

![KVO Cloud Collection page](docs/images/26-kvo-cloud-collection-list.png)

2. Click **New Cloud Collection**
3. Select your Kubernetes Cloud Config (`S1000_EKS`)
4. Use **Workload Selectors** to choose which pods to tap:
   - Select by **app label:** `nginx-demo`
   - Or select by **Namespace**

![KVO New Cloud Collection with workload selector](docs/images/27-kvo-new-cloud-collection.png)

5. Click **Ok** and **Commit**

### Step 3: Create Remote Tools

Before creating a monitoring policy, you need to define your tool destinations.

1. In KVO, go to **Visibility Fabric > Tools**

![KVO Tools page with Ubuntu and Windows tools](docs/images/28-kvo-tools-page.png)

2. Click **New Tool > REMOTE**
3. On the **General** tab, set the tool name (e.g., `Ubuntu_Tool`)

![KVO New Remote Tool - General tab](docs/images/29-kvo-new-remote-tool.png)

4. On the **Remote Configuration** tab:
   - **Traffic Source:** select **"Traffic source is a cloud"**
   - **Encapsulation Protocol:** `VxLAN`
   - **Remote IP:** `<TOOL_VM_PRIVATE_IP>` (use the **private IP**, not public)
   - **VnID:** any value (e.g., `234`)
   - **UDP Destination Port:** `4789`

![KVO Remote Tool - VXLAN configuration](docs/images/30-kvo-remote-tool-vxlan.png)

5. Click **Ok** and repeat for other tool VMs

### Step 4: Create a Monitoring Policy

1. In KVO, go to **Monitoring Policies**
2. Click **Create New** to add a new policy
3. Configure:
   - **Traffic Source:** the Cloud Collection created above
   - **Traffic Destination:** the Remote Tool created above
   - **Run Mode:** Continuously

![KVO Monitoring Policy detail](docs/images/32-kvo-monitoring-policy-detail.png)

4. **Save and Commit** - Click the **Commit** button at the top to apply your changes

After committing, you'll see your complete traffic flow in the **DIAGRAM** view:

![KVO Monitoring Policies diagram - sources to policies to destinations](docs/images/31-kvo-monitoring-policies-diagram.png)

The diagram shows the end-to-end visibility pipeline: **Traffic Sources** (Cloud Collections) on the left, **Monitoring Policies** in the center, and **Traffic Destinations** (Remote Tools) on the right. Each policy connects a source to a destination, running **Active | Continuously**.

![KVO Monitoring Policies complete - all policies committed](docs/images/33-kvo-monitoring-policies-complete.png)

> **Important:** KVO sends mirrored traffic via VXLAN to your tool VM's **private IP** over the internal VPC network.

---

## Exercise 3: Verify Mirrored Traffic on Tool VMs

### Option A: Linux Tool VM (tcpdump)

```bash
# SSH to your Linux Tool VM
ssh -i ~/Downloads/cloudlens-lab.pem ubuntu@<TOOL_LINUX_PUBLIC_IP>

# Verify VXLAN packets are arriving (port 4789 = VXLAN)
sudo tcpdump -i ens5 udp port 4789 -nn -c 20 -q

# Filter for specific traffic (e.g., streaming sites)
sudo tcpdump -i ens5 udp port 4789 -nn -A | grep -iE 'netflix|youtube|openai'

# Capture to file for Wireshark analysis
sudo tcpdump -i ens5 udp port 4789 -nn -w ~/captures/cloudlens-traffic.pcap -c 1000
```

Expected output: You should see UDP packets on port 4789 containing the mirrored traffic from your Kubernetes pods.

![tcpdump showing VXLAN traffic with netflix, youtube, openai hosts](docs/images/36-tcpdump-vxlan-traffic.png)

### Option B: Windows Tool VM (Wireshark)

1. Open an RDP client and connect to `<TOOL_WINDOWS_PUBLIC_IP>:3389`
   - **Username:** `Administrator`
   - **Password:** (from terraform output or set during deployment)
2. Open **Wireshark** (desktop shortcut)
3. Start capture on the **Ethernet** interface
4. Apply display filters:

```
# All VXLAN traffic (mirrored from CloudLens)
vxlan

# HTTP traffic inside VXLAN
vxlan && http

# Specific HTTP hosts
http.host contains "nginx"
```

![Wireshark capturing VXLAN-encapsulated HTTP traffic](docs/images/35-wireshark-vxlan-capture.png)

> **Tip:** Expand the **Virtual eXtensible Local Area Network** layer in packet details to see the VXLAN VNI, then expand inner layers to see the original traffic.

---

## Exercise 4: vPB Traffic Forwarding

Configure the Virtual Packet Broker to forward traffic between its ingress and egress ports.

### Step 1: SSH to vPB

```bash
ssh admin@<VPB_PUBLIC_IP>
# Password: ixia
```

### Step 2: Configure Port Forwarding

```
configure
set port-forward rule 1 source port eth1 destination port eth2
commit
exit
```

This forwards all traffic arriving on the **ingress** interface (eth1) to the **egress** interface (eth2).

### Step 3: Verify

On the Linux Tool VM:
```bash
sudo tcpdump -i any -n -c 20
```

You should see forwarded traffic arriving.

---

## Exercise 5: Sidecar Sensor Installation (Advanced)

Unlike the DaemonSet (which captures all traffic on a node), a **sidecar** sensor captures traffic for **one specific pod**. Both methods can coexist.

### Step 1: Create the Sidecar Deployment

Create a file called `nginx-cloudlens-sidecar.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-cloudlens-sidecar
  namespace: cloudlens-demo
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
        image: <ECR_REPO_URL>/cloudlens-sensor:sensor-6.13.0-359
        args:
        - "--auto_update"
        - "y"
        - "--project_key"
        - "<YOUR_PROJECT_KEY>"
        - "--accept_eula"
        - "yes"
        - "--server"
        - "<CLMS_PRIVATE_IP>"
        - "--ssl_verify"
        - "no"
        - "--custom_tags"
        - "name=nginx-sidecar,source=K8s,namespace=cloudlens-demo"
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

> Replace `<ECR_REPO_URL>`, `<YOUR_PROJECT_KEY>`, and `<CLMS_PRIVATE_IP>` with your actual values.

### Step 2: Deploy and Verify

```bash
kubectl apply -f nginx-cloudlens-sidecar.yaml

# Check pod status (should show 2/2 Ready - nginx + sidecar)
kubectl get pods -n cloudlens-demo -l app=nginx-cloudlens-sidecar

# Check sidecar logs
kubectl logs -n cloudlens-demo -l app=nginx-cloudlens-sidecar -c cloudlens-sidecar --tail=20
```

### Step 3: Configure in KVO

1. Create a **Cloud Collection** targeting the sidecar pod:
   - Workload Selector: `pod-name` = `nginx-cloudlens-sidecar`
2. Create a **Monitoring Policy** with the collection as source and your tool VM as destination

### Step 4: Cleanup

```bash
kubectl delete deployment nginx-cloudlens-sidecar -n cloudlens-demo
```

---

# Part 5: Reference

## Troubleshooting

### Cannot access CLMS/KVO UI
- **Wait 15 minutes** after deployment for initialization
- Check security group allows your IP (update `allowed_https_cidr` in `terraform.tfvars`)
- Verify instance is running: `aws ec2 describe-instance-status --profile cloudlens-lab`

### SSH connection refused
- Verify key permissions: `chmod 400 ~/.ssh/cloudlens-lab.pem`
- Check instance is running
- Verify correct username: `ubuntu` (Ubuntu), `admin` (vPB), `ec2-user` (RHEL)

### Windows RDP not working
- Wait 10 minutes for Windows initialization
- Check security group allows port 3389 from your IP

### Terraform apply fails
- Run `terraform init` first
- Check AWS credentials: `aws sts get-caller-identity --profile cloudlens-lab`
- Check marketplace subscriptions are accepted

### EKS nodes not Ready
- Wait 5-10 minutes for nodes to join the cluster
- Check: `kubectl describe nodes` for errors

### Helm install fails with 403
Re-authenticate to ECR:
```bash
aws ecr get-login-password --region us-west-2 --profile cloudlens-lab | \
  docker login --username AWS --password-stdin <ECR_URL>
```

### Pod stuck in Pending
```bash
kubectl describe pod <POD_NAME> -n cloudlens-demo
```
Check for insufficient resources or scheduling constraints.

### No VXLAN traffic on Tool VM
- Verify the Monitoring Policy is committed in KVO
- Check that the Cloud Collection has active workload matches
- Ensure tool VM private IP is used (not public) in the Monitoring Policy
- Verify security group allows UDP port 4789 (VXLAN)

---

## Cost Management

Stop VMs when not in use to reduce costs:

```bash
# Stop all lab instances
./scripts/stop-all.sh

# Start them back up
./scripts/start-all.sh
```

> **EKS control plane** charges (~$73/month) continue even when nodes are stopped. Use `terraform destroy` if you won't need the lab for an extended period.

---

## Uninstall / Cleanup

### Remove CloudLens Sensor from EKS

```bash
# Remove DaemonSet
helm uninstall cloudlens-agent --namespace cloudlens-demo

# Remove Sidecar (if deployed)
kubectl delete deployment nginx-cloudlens-sidecar -n cloudlens-demo
```

### Destroy All AWS Resources

```bash
# Preview what will be destroyed
terraform plan -destroy

# Destroy everything (type 'yes' when prompted)
terraform destroy
```

> **Warning:** This permanently deletes all lab resources including VMs, EKS cluster, and VPC.

---

## Lab Environment Summary

After deployment, your lab contains:

| Resource | Purpose | Access |
|----------|---------|--------|
| **CLMS** | CloudLens Manager - sensor management | `https://<CLMS_IP>` (admin / Cl0udLens@dm!n) |
| **KVO** | Vision One - visibility orchestration | `https://<KVO_IP>` (admin / admin) |
| **vPB** | Virtual Packet Broker - traffic forwarding | `ssh admin@<VPB_IP>` (admin / ixia) |
| **Ubuntu VM** | Tapped Linux workload | `ssh -i <key> ubuntu@<UBUNTU_IP>` |
| **Windows VM** | Tapped Windows workload (IIS) | RDP to `<WINDOWS_IP>` |
| **Linux Tool VM** | Traffic analysis (tcpdump) | `ssh -i <key> ubuntu@<TOOL_LINUX_IP>` |
| **Windows Tool VM** | Traffic analysis (Wireshark) | RDP to `<TOOL_WINDOWS_IP>` |
| **EKS Cluster** | Kubernetes workloads + CloudLens sensors | `kubectl` via kubeconfig |

> Run `terraform output` at any time to see all IPs and access details.

---

## SSH Quick Reference

```bash
# Set your key path
KEY=~/Downloads/cloudlens-lab.pem

# Linux Tool VM
ssh -i $KEY ubuntu@<TOOL_LINUX_IP>

# Ubuntu Workload VM
ssh -i $KEY ubuntu@<UBUNTU_IP>

# vPB (password: ixia)
ssh admin@<VPB_IP>

# Windows Tool VM - use RDP client
open rdp://Administrator@<TOOL_WINDOWS_IP>
```

---

*This guide is for the [cloudlens-k8s-lab](https://github.com/Keysight-Tech/cloudlens-k8s-lab) repository. For questions or issues, contact your Keysight representative.*
