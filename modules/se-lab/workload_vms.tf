# ============================================================================
# WORKLOAD VMs - Ubuntu, Windows, RHEL
# ============================================================================

# ============================================================================
# Ubuntu VM 1 (Tapped - Traffic Generator + iPerf3)
# ============================================================================

resource "aws_instance" "tapped_ubuntu_1" {
  count                       = var.ubuntu_workload_enabled ? 1 : 0
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.ubuntu_instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.management.id
  vpc_security_group_ids      = [aws_security_group.workload.id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y iperf3 stress-ng curl wget netcat-openbsd hping3 nmap tcpdump

              # Start iperf3 server on default port 5201
              iperf3 -s -D

              # Create info file
              cat > /home/ubuntu/README.txt <<EOL
              ============================================
              CloudLens Training Lab - Ubuntu VM 1
              Lab: ${var.deployment_prefix}
              Owner: ${var.owner}
              ============================================

              Traffic Generation Tools:
              - iperf3: Bandwidth testing (server running on port 5201)
              - curl/wget: HTTP traffic generation
              - hping3: Custom packet crafting
              - nmap: Network scanning
              - netcat: TCP/UDP connections
              - tcpdump: Packet capture

              Examples:
              # Test bandwidth to another VM
              iperf3 -c <target-ip> -t 30

              # Generate HTTP traffic
              curl http://<target-ip>

              # TCP SYN scan
              nmap -sS <target-ip>

              EOL
              chown ubuntu:ubuntu /home/ubuntu/README.txt

              echo "Setup complete" > /var/log/userdata.log
              EOF

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.tapped_1_name}-root" })
  }

  tags = merge(local.common_tags, { Name = local.tapped_1_name, Role = "tapped" })
}

# ============================================================================
# Windows Server 2022 VM (Tapped - IIS)
# ============================================================================

resource "aws_instance" "tapped_windows" {
  ami                         = data.aws_ami.windows.id
  instance_type               = var.windows_instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.management.id
  vpc_security_group_ids      = [aws_security_group.workload.id]
  associate_public_ip_address = true
  get_password_data           = true

  user_data = <<-EOF
    <powershell>
    # Install IIS
    Install-WindowsFeature -name Web-Server -IncludeManagementTools

    # Create custom webpage
    $htmlContent = @"
    <html>
    <head><title>Windows Server - ${var.deployment_prefix}</title></head>
    <body>
      <h1>Windows Server 2022 - ${var.deployment_prefix}</h1>
      <p>Lab Owner: ${var.owner}</p>
      <p>Hostname: $env:COMPUTERNAME</p>
      <p>IP: $(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "127.*"} | Select-Object -First 1 -ExpandProperty IPAddress)</p>
    </body>
    </html>
"@
    $htmlContent | Out-File -FilePath C:\inetpub\wwwroot\index.html -Encoding UTF8

    # Enable ICMPv4 for ping
    New-NetFirewallRule -DisplayName "Allow ICMPv4-In" -Protocol ICMPv4 -IcmpType 8 -Enabled True -Direction Inbound -Action Allow

    # Log completion
    "Windows setup complete" | Out-File -FilePath C:\userdata.log
    </powershell>
    EOF

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.windows_name}-root" })
  }

  tags = merge(local.common_tags, { Name = local.windows_name, Role = "tapped", OS = "Windows" })
}

# ============================================================================
# RHEL 9 VM (Tapped - Apache + iPerf3) - Conditional
# ============================================================================

resource "aws_instance" "tapped_rhel" {
  count                       = var.rhel_enabled ? 1 : 0
  ami                         = data.aws_ami.rhel.id
  instance_type               = var.rhel_instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.management.id
  vpc_security_group_ids      = [aws_security_group.workload.id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd iperf3

              # Start Apache
              systemctl enable httpd
              systemctl start httpd

              # Create custom index page
              echo "<h1>RHEL 9 Server - ${var.deployment_prefix}</h1>" > /var/www/html/index.html
              echo "<p>Lab Owner: ${var.owner}</p>" >> /var/www/html/index.html
              echo "<p>Hostname: $(hostname)</p>" >> /var/www/html/index.html
              echo "<p>IP: $(hostname -I)</p>" >> /var/www/html/index.html

              # Start iperf3 server
              iperf3 -s -p 5203 -D

              # Open firewall for HTTP and iperf3
              firewall-cmd --permanent --add-service=http
              firewall-cmd --permanent --add-port=5203/tcp
              firewall-cmd --reload

              echo "Setup complete" > /var/log/userdata.log
              EOF

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.rhel_name}-root" })
  }

  tags = merge(local.common_tags, { Name = local.rhel_name, Role = "tapped", OS = "RHEL" })
}
