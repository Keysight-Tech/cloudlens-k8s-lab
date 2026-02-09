# ============================================================================
# TOOL VMs - Linux and Windows with Analysis Tools
# ============================================================================

# ============================================================================
# Linux Tool VM (Ubuntu + tcpdump, Wireshark, iPerf3, nmap)
# ============================================================================

resource "aws_instance" "tool" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.tool_linux_instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.egress.id
  vpc_security_group_ids      = [aws_security_group.tool.id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y tcpdump wireshark tshark iperf3 nmap netcat net-tools

              # Create analysis directory
              mkdir -p /home/ubuntu/captures
              chown ubuntu:ubuntu /home/ubuntu/captures

              # Create welcome message
              cat > /home/ubuntu/README.txt <<EOL
              ============================================
              CloudLens Training Lab - Tool VM
              Lab: ${var.deployment_prefix}
              Owner: ${var.owner}
              ============================================

              Pre-installed tools:
              - tcpdump: Packet capture
              - tshark: Wireshark CLI
              - iperf3: Network bandwidth testing
              - nmap: Network scanner
              - netcat: Network utility

              Captures directory: /home/ubuntu/captures

              Quick commands:
              - Capture VXLAN: tcpdump -i any port 4789 -w captures/vxlan.pcap
              - Capture all: tcpdump -i any -w captures/all.pcap
              - iPerf3 server: iperf3 -s

              EOL
              chown ubuntu:ubuntu /home/ubuntu/README.txt

              echo "Tool VM setup complete" > /var/log/user-data.log
              EOF

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.tool_name}-root" })
  }

  tags = merge(local.common_tags, { Name = local.tool_name, Role = "tool" })
}

# ============================================================================
# Windows Tool VM (Windows Server 2022 + Wireshark GUI)
# ============================================================================

resource "aws_instance" "tool_windows" {
  ami                         = data.aws_ami.windows.id
  instance_type               = var.tool_windows_instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.egress.id
  vpc_security_group_ids      = [aws_security_group.tool.id]
  associate_public_ip_address = true
  get_password_data           = true

  user_data = <<-EOF
    <powershell>
    # Log start
    $logFile = "C:\install-log.txt"
    "$(Get-Date) - Starting installation" | Out-File -FilePath $logFile

    # Set Administrator password to known value
    $Password = ConvertTo-SecureString "<WINDOWS_TOOL_PASSWORD>" -AsPlainText -Force
    Set-LocalUser -Name "Administrator" -Password $Password
    "$(Get-Date) - Administrator password set to <WINDOWS_TOOL_PASSWORD>" | Out-File -FilePath $logFile -Append

    # Create captures directory
    New-Item -ItemType Directory -Path "C:\Captures" -Force
    "$(Get-Date) - Created C:\Captures" | Out-File -FilePath $logFile -Append

    # Install Chocolatey
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    try {
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        "$(Get-Date) - Chocolatey installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing Chocolatey: $_" | Out-File -FilePath $logFile -Append
    }

    # Refresh environment
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    # Install tools with Chocolatey
    Start-Sleep -Seconds 10

    # Install Npcap first (required for Wireshark packet capture)
    try {
        choco install npcap -y --install-arguments="/winpcap_mode=yes /loopback_support=yes"
        "$(Get-Date) - Npcap installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing Npcap: $_" | Out-File -FilePath $logFile -Append
    }

    try {
        choco install wireshark -y
        "$(Get-Date) - Wireshark installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing Wireshark: $_" | Out-File -FilePath $logFile -Append
    }

    try {
        choco install nmap -y
        "$(Get-Date) - Nmap installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing Nmap: $_" | Out-File -FilePath $logFile -Append
    }

    try {
        choco install putty -y
        "$(Get-Date) - PuTTY installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing PuTTY: $_" | Out-File -FilePath $logFile -Append
    }

    try {
        choco install winscp -y
        "$(Get-Date) - WinSCP installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing WinSCP: $_" | Out-File -FilePath $logFile -Append
    }

    try {
        choco install notepadplusplus -y
        "$(Get-Date) - Notepad++ installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing Notepad++: $_" | Out-File -FilePath $logFile -Append
    }

    try {
        choco install 7zip -y
        "$(Get-Date) - 7-Zip installed" | Out-File -FilePath $logFile -Append
    } catch {
        "$(Get-Date) - Error installing 7-Zip: $_" | Out-File -FilePath $logFile -Append
    }

    # Enable RDP
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    "$(Get-Date) - RDP enabled" | Out-File -FilePath $logFile -Append

    # Enable ICMPv4
    New-NetFirewallRule -DisplayName "Allow ICMPv4-In" -Protocol ICMPv4 -IcmpType 8 -Enabled True -Direction Inbound -Action Allow
    "$(Get-Date) - ICMPv4 enabled" | Out-File -FilePath $logFile -Append

    # Create desktop shortcuts
    $WshShell = New-Object -ComObject WScript.Shell

    # Wireshark shortcut
    $ShortcutPath = "$env:Public\Desktop\Wireshark.lnk"
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = "C:\Program Files\Wireshark\Wireshark.exe"
    $Shortcut.Description = "Wireshark Network Protocol Analyzer"
    $Shortcut.Save()

    # Captures folder shortcut
    $ShortcutPath = "$env:Public\Desktop\Captures.lnk"
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = "C:\Captures"
    $Shortcut.Description = "Packet Capture Storage"
    $Shortcut.Save()

    "$(Get-Date) - Desktop shortcuts created" | Out-File -FilePath $logFile -Append

    # Create README on desktop
    $readme = @"
============================================
CloudLens Training Lab - Windows Tool VM
Lab: ${var.deployment_prefix}
Owner: ${var.owner}
============================================

RDP CREDENTIALS:
  Username: Administrator
  Password: <WINDOWS_TOOL_PASSWORD>

PRE-INSTALLED TOOLS:
  - Wireshark: Packet capture and analysis (Desktop Icon)
  - Npcap: Packet capture driver for Wireshark
  - Nmap: Network scanner
  - PuTTY: SSH client
  - WinSCP: File transfer
  - Notepad++: Text editor
  - 7-Zip: File compression

CAPTURES DIRECTORY: C:\Captures (Desktop Shortcut)

QUICK START - WIRESHARK:
  1. Double-click Wireshark icon on desktop
  2. Select "Ethernet" or "Ethernet 2" interface
  3. Click the blue shark fin button to start capture
  4. Generate traffic from other VMs
  5. Click red square to stop capture
  6. File > Save As > C:\Captures\mycapture.pcapng

COMMON CAPTURE FILTERS:
  - HTTP only: tcp port 80
  - HTTPS only: tcp port 443
  - VXLAN traffic: udp port 4789
  - All traffic from IP: host 10.x.x.x

"@
    $readme | Out-File -FilePath "C:\Users\Public\Desktop\README.txt" -Encoding UTF8

    "$(Get-Date) - Installation complete" | Out-File -FilePath $logFile -Append

    # Schedule restart to complete Npcap installation
    shutdown /r /t 120 /c "Restarting to complete Wireshark/Npcap installation"
    </powershell>
    EOF

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 100  # Larger for capture storage
    delete_on_termination = true
    encrypted             = true
    tags                  = merge(local.common_tags, { Name = "${local.tool_windows_name}-root" })
  }

  tags = merge(local.common_tags, {
    Name = local.tool_windows_name
    Role = "tool"
    OS   = "Windows"
  })
}
