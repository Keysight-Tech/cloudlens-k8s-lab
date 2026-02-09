# Default Credentials

All products are deployed with default credentials. **Change these immediately after first login.**

## Keysight Products

| Product | URL/Access | Username | Password |
|---------|-----------|----------|----------|
| **CLMS** (CloudLens Manager) | `https://<CLMS_IP>` | `admin` | `<CLMS_PASSWORD>` |
| **KVO** (Vision One) | `https://<KVO_IP>` | `admin` | `admin` |
| **vPB** (Virtual Packet Broker) | `ssh admin@<VPB_IP>` | `admin` | `<VPB_PASSWORD>` |
| **CyPerf Controller** (optional) | `https://<CYPERF_IP>` | `admin` | `<CYPERF_PASSWORD>` |

## VMs

| VM | Access | Username | Password |
|----|--------|----------|----------|
| **Ubuntu** | SSH (key-based) | `ubuntu` | Use SSH key |
| **RHEL** | SSH (key-based) | `ec2-user` | Use SSH key |
| **Windows Tool** (Wireshark) | RDP `:3389` | `Administrator` | `<WINDOWS_TOOL_PASSWORD>` |
| **Windows Tapped** | RDP `:3389` | `Administrator` | Decrypt via AWS CLI |

### Decrypting Windows Tapped VM Password

```bash
aws ec2 get-password-data \
  --instance-id <INSTANCE_ID> \
  --priv-launch-key ~/path/to/your-key.pem \
  --profile your-aws-profile
```

## License Keys

License keys are required for KVO, CLMS, and vPB. Contact your Keysight representative to obtain license keys, then enter them in the product UI after deployment.

| Product | Where to Enter |
|---------|---------------|
| **KVO** | KVO UI > Administration > License |
| **CLMS** | CLMS UI > Settings > License |
| **vPB** | vPB CLI: `set license key <KEY>` |

## Post-Deployment

1. Log in to each product using the default credentials above
2. Change all default passwords immediately
3. Apply license keys
4. Run `./scripts/post-deploy.sh` to generate lab guides with actual IPs
