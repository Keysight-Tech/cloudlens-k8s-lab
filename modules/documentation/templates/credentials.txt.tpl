============================================================
CloudLens K8s Visibility Lab Credentials
Lab: ${deployment_prefix}
============================================================

IMPORTANT: SSH KEY REQUIRED
---------------------------
To SSH into Linux VMs, you need this private key file:

  Key Path: ${private_key_path}

After saving, set permissions (Linux/Mac):
  chmod 400 ${private_key_path}

On Windows, use PuTTYgen to convert .pem to .ppk format.

============================================================

KEYSIGHT PRODUCTS
-----------------
CLMS (CloudLens Manager)
  URL:      https://${clms_public_ip}
  Username: admin
  Password: Cl0udLens@dm!n

KVO (Vision One)
  URL:      https://${kvo_public_ip}
  Username: admin
  Password: admin
%{ if vpb_enabled }
vPB (Virtual Packet Broker)
  SSH:      ssh -i ${private_key_path} admin@${vpb_public_ip}
  Username: admin
  Password: ixia
%{ else }
vPB: Not deployed (vpb_enabled = false)
%{ endif }
%{ if cyperf_enabled }
CyPerf Controller
  URL:      https://${cyperf_controller_public_ip}
  Username: admin
  Password: CyPerf&Keysight#1
%{ endif }


LINUX VMs (SSH Key Authentication)
----------------------------------
Ubuntu Workload:
  ssh -i ${private_key_path} ubuntu@${ubuntu_public_ip}

Linux Tool (tcpdump):
  ssh -i ${private_key_path} ubuntu@${tool_linux_public_ip}
  Private IP (for KVO): ${tool_linux_private_ip}


WINDOWS VMs (RDP)
-----------------
Windows Tool (Wireshark):
  RDP:      ${tool_windows_public_ip}:3389
  Username: Administrator
  Password: CloudLens2024!
  Private IP (for KVO): ${tool_windows_private_ip}

Windows Workload:
  RDP:      ${windows_public_ip}:3389
  Username: Administrator
  Password: Decrypt with AWS CLI (see below)

To decrypt Windows password:
  aws ec2 get-password-data --instance-id <ID> --priv-launch-key ${private_key_path} --profile ${aws_profile}


AWS PROFILE
-----------
Profile:  ${aws_profile}
Key Path: ${private_key_path}

============================================================
IMPORTANT: Change default passwords after first login!
============================================================
