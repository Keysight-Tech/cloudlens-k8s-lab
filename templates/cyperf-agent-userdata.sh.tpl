#!/bin/bash
# CyPerf Agent VM User Data
# Configures the agent to connect to the controller and sets role tag
# Uses cyperfagent CLI (CyPerf 7.0+)

# Wait for portmanager service to be ready
sleep 60

# ============================================================================
# NETWORK FIXES FOR DUAL-ENI (required for AWS secondary ENI traffic)
# ============================================================================

# Get test ENI IP and gateway
TEST_IP=$(ip -4 addr show ens6 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
TEST_GW=$(ip route show dev ens6 | grep default | awk '{print $3}')
if [ -z "$TEST_GW" ]; then
    # Derive gateway from IP (first IP in subnet)
    TEST_GW=$(echo "$TEST_IP" | sed 's/\.[0-9]*$/.1/')
fi

# 1. Disable reverse path filter (strict mode drops traffic on secondary ENI)
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/ens6/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/ens5/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/default/rp_filter

# 2. Policy routing: traffic sourced from test ENI routes through test ENI
ip route add 10.100.0.0/16 via $TEST_GW dev ens6 table 1000 2>/dev/null
ip route add default via $TEST_GW dev ens6 table 1000 2>/dev/null
ip rule add from $TEST_IP/32 table 1000 2>/dev/null

# 3. iptables: allow all traffic on test interface (ens6)
iptables -I INPUT 3 -i ens6 -j ACCEPT 2>/dev/null

# ============================================================================
# CYPERF AGENT CONFIGURATION
# ============================================================================

# Configure controller IP (skip identity verification for automated setup)
cyperfagent controller set ${controller_ip} --skip-identity-verification -s

# Set management interface (ens5 = eth0 = first ENI)
cyperfagent interface management set ens5 -s

# Set test interface (ens6 = eth1 = second ENI)
cyperfagent interface test set ens6 -s

# Set agent role tag (triggers portmanager restart)
cyperfagent tag set role=${agent_role}
