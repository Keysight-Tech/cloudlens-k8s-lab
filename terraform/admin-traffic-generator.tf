# ============================================================================
# ADMIN TRAFFIC GENERATOR VM
# ============================================================================
# Central VM for generating traffic to all SE workloads
# Includes comprehensive traffic generation and testing tools
# ============================================================================

variable "admin_traffic_gen_enabled" {
  description = "Enable admin traffic generator VM (disable if CyPerf generates traffic)"
  type        = bool
  default     = false
}

variable "admin_traffic_gen_instance_type" {
  description = "Instance type for traffic generator (needs capacity for high traffic)"
  type        = string
  default     = "t3.xlarge"  # 4 vCPU, 16GB RAM
}

# ============================================================================
# DATA SOURCES
# ============================================================================

data "aws_ami" "ubuntu_traffic_gen" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================================
# SUBNET FOR TRAFFIC GENERATOR
# ============================================================================

resource "aws_subnet" "admin_traffic_gen" {
  count = var.admin_traffic_gen_enabled ? 1 : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.100.50.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-admin-traffic-gen-subnet"
    Type = "AdminTrafficGenerator"
  })
}

resource "aws_route_table_association" "admin_traffic_gen" {
  count = var.admin_traffic_gen_enabled ? 1 : 0

  subnet_id      = aws_subnet.admin_traffic_gen[0].id
  route_table_id = aws_route_table.main.id
}

# ============================================================================
# SECURITY GROUP
# ============================================================================

resource "aws_security_group" "admin_traffic_gen" {
  count = var.admin_traffic_gen_enabled ? 1 : 0

  name        = "${var.deployment_prefix}-admin-traffic-gen-sg"
  description = "Security group for admin traffic generator"
  vpc_id      = aws_vpc.main.id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound (needed for traffic generation)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-admin-traffic-gen-sg"
  })
}

# ============================================================================
# TRAFFIC GENERATOR VM
# ============================================================================

resource "aws_instance" "admin_traffic_gen" {
  count = var.admin_traffic_gen_enabled ? 1 : 0

  ami                    = data.aws_ami.ubuntu_traffic_gen.id
  instance_type          = var.admin_traffic_gen_instance_type
  key_name               = var.key_pair_name
  subnet_id              = aws_subnet.admin_traffic_gen[0].id
  vpc_security_group_ids = [aws_security_group.admin_traffic_gen[0].id]

  root_block_device {
    volume_size           = 100  # 100GB for pcap storage
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
#!/bin/bash
set -e

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ============================================================================
# TRAFFIC GENERATION TOOLS
# ============================================================================

# Network testing and bandwidth
apt-get install -y iperf3 iperf netperf

# Packet crafting and manipulation
apt-get install -y hping3 nmap netcat-openbsd socat

# HTTP traffic generation
apt-get install -y curl wget httpie apache2-utils wrk siege

# Packet capture and replay
apt-get install -y tcpdump tshark tcpreplay wireshark-common

# Python tools for custom traffic
apt-get install -y python3-pip python3-scapy python3-requests

# DNS tools
apt-get install -y dnsutils bind9-utils

# SSL/TLS tools
apt-get install -y openssl sslscan

# Stress testing
apt-get install -y stress-ng

# Network utilities
apt-get install -y traceroute mtr-tiny arping fping

# Install additional Python traffic tools
pip3 install locust requests aiohttp httpx

# ============================================================================
# KUBERNETES TOOLS (to interact with K8s workloads)
# ============================================================================

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# AWS CLI
apt-get install -y awscli

# ============================================================================
# TRAFFIC SCRIPTS DIRECTORY
# ============================================================================

mkdir -p /opt/traffic-scripts
cat > /opt/traffic-scripts/README.md << 'README'
# Traffic Generation Scripts

## Quick Commands

### HTTP Traffic
# Single request
curl http://<target>

# Load test (Apache Bench) - 1000 requests, 10 concurrent
ab -n 1000 -c 10 http://<target>/

# Sustained load (wrk) - 30 seconds, 10 connections
wrk -t4 -c10 -d30s http://<target>/

# HTTP flood (siege)
siege -c 50 -t 60S http://<target>/

### TCP/UDP Traffic
# iperf3 bandwidth test (run server on target first: iperf3 -s)
iperf3 -c <target> -t 60 -P 10

# UDP flood
iperf3 -c <target> -u -b 100M -t 60

# TCP SYN packets (hping3)
hping3 -S -p 80 --flood <target>

### Network Scanning
# Port scan
nmap -sT -p 1-65535 <target>

# Service detection
nmap -sV <target>

### Packet Replay
# Replay pcap at original speed
tcpreplay -i eth0 capture.pcap

# Replay at 10x speed
tcpreplay -i eth0 -x 10 capture.pcap

### Custom Python Traffic (scapy)
python3 -c "from scapy.all import *; send(IP(dst='<target>')/ICMP())"

### DNS Queries
dig @<dns-server> example.com
dnsperf -s <dns-server> -d queries.txt

### Kubernetes Pod Traffic
# Get pod IPs
kubectl get pods -A -o wide

# Generate traffic to pod
curl http://<pod-ip>:<port>
README

# ============================================================================
# SAMPLE TRAFFIC SCRIPTS
# ============================================================================

cat > /opt/traffic-scripts/http-load-test.sh << 'SCRIPT'
#!/bin/bash
# HTTP Load Test Script
TARGET=$1
DURATION=$${2:-60}
CONNECTIONS=$${3:-10}

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target-url> [duration-seconds] [connections]"
    exit 1
fi

echo "Starting HTTP load test to $TARGET"
echo "Duration: $${DURATION}s, Connections: $CONNECTIONS"
wrk -t4 -c$CONNECTIONS -d$${DURATION}s $TARGET
SCRIPT
chmod +x /opt/traffic-scripts/http-load-test.sh

cat > /opt/traffic-scripts/bandwidth-test.sh << 'SCRIPT'
#!/bin/bash
# Bandwidth Test Script (requires iperf3 server on target)
TARGET=$1
DURATION=$${2:-30}
PARALLEL=$${3:-5}

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target-ip> [duration-seconds] [parallel-streams]"
    exit 1
fi

echo "Starting bandwidth test to $TARGET"
echo "Duration: $${DURATION}s, Parallel streams: $PARALLEL"
iperf3 -c $TARGET -t $DURATION -P $PARALLEL
SCRIPT
chmod +x /opt/traffic-scripts/bandwidth-test.sh

cat > /opt/traffic-scripts/generate-all-traffic.sh << 'SCRIPT'
#!/bin/bash
# Generate traffic to all SE workloads
# Usage: ./generate-all-traffic.sh <se-lab-count> [duration]

SE_COUNT=$${1:-5}
DURATION=$${2:-30}

echo "========================================"
echo "Traffic Generator - All SE Labs"
echo "========================================"
echo "SE Labs:  1 to $SE_COUNT"
echo "Duration: $${DURATION}s per target"
echo "========================================"
echo ""

for i in $(seq 1 $SE_COUNT); do
    SE_NUM=$(printf "%02d" $i)
    echo "--- SE-$SE_NUM ---"

    # Get nginx LoadBalancer URL from kubectl if available
    LB_URL=$(kubectl get svc nginx-demo -n se-$SE_NUM -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

    if [ -n "$LB_URL" ]; then
        echo "Testing nginx at http://$LB_URL"
        wrk -t2 -c5 -d$${DURATION}s http://$LB_URL/ &
    else
        echo "LoadBalancer URL not found for se-$SE_NUM"
    fi
done

echo ""
echo "Waiting for all tests to complete..."
wait
echo ""
echo "========================================"
echo "All traffic generation complete!"
echo "========================================"
SCRIPT
chmod +x /opt/traffic-scripts/generate-all-traffic.sh

cat > /opt/traffic-scripts/continuous-traffic.sh << 'SCRIPT'
#!/bin/bash
# Continuous traffic generator (background)
# Usage: ./continuous-traffic.sh <url> [requests_per_second]

URL=$${1:?Usage: $0 <url> [rps]}
RPS=$${2:-10}
DELAY=$(echo "scale=3; 1/$RPS" | bc)

echo "Generating continuous traffic to $URL"
echo "Rate: $RPS requests/second"
echo "Press Ctrl+C to stop"
echo ""

COUNT=0
while true; do
    curl -s -o /dev/null -w "Request $COUNT: %%{http_code} (%%{time_total}s)\n" "$URL"
    COUNT=$((COUNT + 1))
    sleep $DELAY
done
SCRIPT
chmod +x /opt/traffic-scripts/continuous-traffic.sh

cat > /opt/traffic-scripts/siege-test.sh << 'SCRIPT'
#!/bin/bash
# Siege load test (simulates multiple concurrent users)
# Usage: ./siege-test.sh <url> [concurrent_users] [duration]

URL=$${1:?Usage: $0 <url> [users] [duration]}
USERS=$${2:-25}
DURATION=$${3:-60S}

echo "========================================"
echo "Siege Load Test"
echo "========================================"
echo "Target:      $URL"
echo "Users:       $USERS concurrent"
echo "Duration:    $DURATION"
echo "========================================"
echo ""

siege -c $USERS -t $DURATION "$URL"
SCRIPT
chmod +x /opt/traffic-scripts/siege-test.sh

# ============================================================================
# LOCUST LOAD TESTING FRAMEWORK
# ============================================================================

cat > /opt/traffic-scripts/locustfile.py << 'LOCUST'
from locust import HttpUser, task, between

class WebsiteUser(HttpUser):
    wait_time = between(1, 3)

    @task(3)
    def get_homepage(self):
        self.client.get("/")

    @task(1)
    def get_health(self):
        self.client.get("/health")
LOCUST

# ============================================================================
# MOTD
# ============================================================================

cat > /etc/motd << 'MOTD'
╔═══════════════════════════════════════════════════════════════════════════╗
║           CLOUDLENS S1000 - ADMIN TRAFFIC GENERATOR                       ║
╠═══════════════════════════════════════════════════════════════════════════╣
║  Traffic Generation Tools:                                                ║
║    • iperf3, netperf     - Bandwidth testing                              ║
║    • wrk, siege, ab      - HTTP load testing                              ║
║    • hping3, nmap        - Packet crafting & scanning                     ║
║    • tcpreplay, scapy    - Packet replay & manipulation                   ║
║    • locust              - Python load testing framework                  ║
║                                                                           ║
║  Scripts: /opt/traffic-scripts/                                           ║
║    • http-load-test.sh <url> [duration] [connections]                     ║
║    • bandwidth-test.sh <ip> [duration] [parallel]                         ║
║    • generate-all-traffic.sh <se-count> [duration]                        ║
║    • continuous-traffic.sh <url> [requests_per_second]                    ║
║    • siege-test.sh <url> [concurrent_users] [duration]                    ║
║                                                                           ║
║  Quick Examples:                                                          ║
║    wrk -t4 -c10 -d30s http://<target>/                                    ║
║    iperf3 -c <target> -t 60 -P 10                                         ║
║    siege -c 50 -t 60S http://<target>/                                    ║
║    /opt/traffic-scripts/generate-all-traffic.sh 5 30                      ║
╚═══════════════════════════════════════════════════════════════════════════╝
MOTD

# Create captures directory
mkdir -p /home/ubuntu/captures
chown ubuntu:ubuntu /home/ubuntu/captures

# Set permissions
chown -R ubuntu:ubuntu /opt/traffic-scripts

echo "Traffic generator setup complete!"
EOF

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-admin-traffic-gen"
    Role = "AdminTrafficGenerator"
  })
}

# ============================================================================
# ELASTIC IP
# ============================================================================

resource "aws_eip" "admin_traffic_gen" {
  count = var.admin_traffic_gen_enabled ? 1 : 0

  instance = aws_instance.admin_traffic_gen[0].id
  domain   = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-admin-traffic-gen-eip"
  })
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "admin_traffic_gen_public_ip" {
  description = "Admin traffic generator public IP"
  value       = var.admin_traffic_gen_enabled ? aws_eip.admin_traffic_gen[0].public_ip : null
}

output "admin_traffic_gen_private_ip" {
  description = "Admin traffic generator private IP"
  value       = var.admin_traffic_gen_enabled ? aws_instance.admin_traffic_gen[0].private_ip : null
}

output "admin_traffic_gen_ssh" {
  description = "SSH command for admin traffic generator"
  value       = var.admin_traffic_gen_enabled ? "ssh -i ~/path/to/cloudlens-se-training.pem ubuntu@${aws_eip.admin_traffic_gen[0].public_ip}" : null
}
