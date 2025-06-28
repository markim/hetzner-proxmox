# Network Configuration Guide

This guide explains how to configure additional IP addresses from Hetzner for use with Proxmox containers and VMs.

## Overview

The network configuration script safely adds additional IP addresses to your Proxmox server while preserving SSH connectivity. It's designed specifically for Hetzner dedicated servers with additional IP addresses.

## Safety Features

- **SSH Preservation**: The script preserves your current SSH connection and main IP configuration
- **Automatic Backup**: Creates backups of network configuration before making changes
- **Emergency Restore**: Creates an emergency restore script at `/root/restore-network.sh`
- **Dry Run Mode**: Test configuration without applying changes
- **Rollback Protection**: Validates configuration before applying

## Prerequisites

1. Fresh Proxmox installation on Hetzner server
2. Additional IP addresses ordered from Hetzner
3. SSH access to the server
4. Root privileges

## Configuration

### 1. Configure Environment

Copy the example configuration:
```bash
cp .env.example .env
```

Edit the `.env` file with your specific configuration:

```bash
# Your Hetzner IP configuration
ADDITIONAL_IPS=YOUR_ADDITIONAL_IP:YOUR_MAC_ADDRESS:YOUR_GATEWAY_IP:YOUR_NETMASK,YOUR_ADDITIONAL_IP2::YOUR_GATEWAY_IP:YOUR_NETMASK
```

### Format Explanation

The `ADDITIONAL_IPS` format is: `IP:MAC:GATEWAY:NETMASK,IP:MAC:GATEWAY:NETMASK`

For your Hetzner server example:
- `YOUR_ADDITIONAL_IP` - The additional IP address
- `YOUR_MAC_ADDRESS` - **REQUIRED** MAC address from Hetzner
- `YOUR_GATEWAY_IP` - Gateway IP
- `YOUR_NETMASK` - Netmask

**⚠️ CRITICAL: MAC addresses are REQUIRED for Hetzner additional IPs!**

Without the correct MAC addresses, Hetzner's network infrastructure will not route traffic properly to your additional IPs. This will cause:
- VMs with additional IPs unable to communicate with the internet
- Firewall/pfSense WAN interface not working
- Network routing failures

**How to get MAC addresses:**
1. Login to Hetzner Cloud Console or Robot interface
2. Navigate to your server's network configuration
3. Each additional IP should show an associated MAC address
4. If no MAC address is displayed, contact Hetzner support

**Example configuration:**
```
# Method 1: Config file format
IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.11 MAC=00:50:56:00:01:03 GATEWAY=203.0.113.1 NETMASK=255.255.255.192

# Method 2: Environment variable format  
ADDITIONAL_IPS=203.0.113.10:00:50:56:00:01:02:203.0.113.1:255.255.255.192,203.0.113.11:00:50:56:00:01:03:203.0.113.1:255.255.255.192
```

### 2. Test Configuration (Recommended)

Always test first with dry-run mode:

```bash
sudo ./install.sh --network --dry-run
```

This will show you what changes would be made without actually applying them.

### 3. Apply Network Configuration

When ready, apply the configuration:

```bash
sudo ./install.sh --network
```

**⚠️ Important**: This will temporarily restart networking services. SSH connectivity should be preserved, but there may be a brief interruption.

## Usage Examples

### Basic Commands

```bash
# Show available commands
./install.sh

# Configure network interfaces (dry run)
sudo ./install.sh --network --dry-run

# Configure network interfaces
sudo ./install.sh --network

# Install Caddy with HTTPS
sudo ./install.sh --caddy

# Use custom configuration file
sudo ./install.sh --network -c production.env

# Enable verbose logging
sudo ./install.sh --network -v
```

## What the Script Does

1. **Backup Current Configuration**
   - Backs up `/etc/network/interfaces`
   - Saves current routing table
   - Creates emergency restore script

2. **Configure Additional IPs**
   - Adds additional IP addresses as interface aliases
   - Preserves main interface configuration
   - Configures proper routing

3. **Proxmox Integration**
   - Creates bridge interface `vmbr1` for containers
   - Enables IP forwarding
   - Prepares for pfSense/firewall integration

4. **Safety Measures**
   - Tests configuration before applying
   - Creates restore scripts
   - Validates network connectivity

## Emergency Recovery

If something goes wrong and you lose connectivity:

### Via Console (Hetzner Robot)

1. Access server via Hetzner's rescue system or console
2. Run the emergency restore script:
   ```bash
   bash /root/restore-network.sh
   ```

### Manual Recovery

If the restore script doesn't work:

1. Access via console
2. Restore the backup manually:
   ```bash
   cp /root/network-backups/interfaces.backup.* /etc/network/interfaces
   systemctl restart networking
   ```

## Integration with pfSense

After configuring the additional IPs, you can:

1. **Create pfSense VM/Container**
   - Assign one additional IP to pfSense WAN interface
   - Use internal IP range for LAN

2. **Configure DNS**
   - Point domain records to additional IPs
   - Configure pfSense to handle incoming traffic

3. **Firewall Rules**
   - Configure pfSense firewall rules
   - Set up port forwarding to internal containers

## Troubleshooting

### Check Network Status

```bash
# View current network configuration
ip addr show

# Check routing table
ip route

# Test connectivity
ping -c 3 8.8.8.8
```

### View Logs

```bash
# View setup logs
tail -f /var/log/hetzner-proxmox-setup.log

# View system network logs
journalctl -u networking -f
```

### Common Issues

1. **SSH Connection Lost**
   - Use Hetzner console access
   - Run emergency restore script

2. **IP Not Responding**
   - Check if IP is properly configured: `ip addr show`
   - Verify routing: `ip route`
   - Check Hetzner control panel configuration

3. **DNS Not Resolving**
   - Check `/etc/resolv.conf`
   - Verify DNS servers are accessible

## Network Architecture

After configuration, your network will look like:

```
Internet
    ↓
YOUR_MAIN_IP (Main IP - SSH, Management)
YOUR_ADDITIONAL_IP (pfSense WAN)
YOUR_ADDITIONAL_IP2 (Additional services)
    ↓
Proxmox Host (eth0)
    ↓
vmbr1 (Container Bridge)
    ↓
Containers/VMs with private IPs
```

## Security Considerations

1. **Firewall**: Configure proper firewall rules after setup
2. **SSH**: Consider changing SSH port or restricting access
3. **Updates**: Keep system updated regularly
4. **Monitoring**: Set up monitoring for network interfaces
5. **Backup**: Regular backup of network configuration

## Next Steps

After network configuration:

1. Set up pfSense container/VM
2. Configure firewall rules
3. Set up DNS entries
4. Test connectivity from external sources
5. Configure monitoring and alerting
