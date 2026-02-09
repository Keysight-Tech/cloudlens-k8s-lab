============================================================
CloudLens Training Lab Credentials
Lab: ${deployment_prefix}
Owner: ${owner}
============================================================

IMPORTANT: SSH KEY REQUIRED
---------------------------
To SSH into Linux VMs, you need this private key file:

  File Name: cloudlens-se-training.pem
  Save To:   ${private_key_path}

After saving, set permissions (Linux/Mac):
  chmod 400 ${private_key_path}

On Windows, use PuTTYgen to convert .pem to .ppk format.

============================================================

KEYSIGHT PRODUCTS
-----------------
CLMS (CloudLens Manager)
  URL:      https://${clms_public_ip}
  Username: admin
  Password: <CLMS_PASSWORD>

KVO (Vision One)
  URL:      https://${kvo_public_ip}
  Username: admin
  Password: admin
%{ if vpb_enabled }

vPB (Virtual Packet Broker)
  SSH:      ssh -i ${private_key_path} admin@${vpb_public_ip}
  Username: admin
  Password: <VPB_PASSWORD>
%{ else }

vPB: Not deployed (vpb_enabled = false)
%{ endif }


LINUX VMs (SSH Key Authentication)
----------------------------------
Ubuntu:
  ssh -i ${private_key_path} ubuntu@${ubuntu_public_ip}
%{ if rhel_enabled }

RHEL:
  ssh -i ${private_key_path} ec2-user@${rhel_public_ip}
%{ endif }

Linux Tool:
  ssh -i ${private_key_path} ubuntu@${tool_linux_public_ip}


WINDOWS VMs (RDP)
-----------------
Windows Tool (Wireshark):
  RDP:      ${tool_windows_public_ip}:3389
  Username: Administrator
  Password: <WINDOWS_TOOL_PASSWORD>

Tapped Windows:
  RDP:      ${windows_public_ip}:3389
  Username: Administrator
  Password: Decrypt with AWS CLI (see below)

To decrypt Windows password:
  aws ec2 get-password-data --instance-id <ID> --priv-launch-key ${private_key_path} --profile ${aws_profile}


AWS PROFILE
-----------
Profile: ${aws_profile}
Key Path: ${private_key_path}

============================================================
IMPORTANT: Change default passwords after first login!
============================================================
