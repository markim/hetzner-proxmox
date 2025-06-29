# Firewall Admin Container

This document describes the firewall admin container setup for the Hetzner Proxmox environment.

## Overview

The firewall admin container is a Fedora 42-based LXC container designed to provide secure administrative access to the pfSense firewall web interface while also having internet connectivity for updates and management tasks.

## Features

- **Fedora 42 Workstation** with desktop environment
- **Firefox Browser** for accessing pfSense web interface
- **Dual Network Interfaces**:
  - LAN interface for pfSense admin access (192.168.1.0/24)
  - WAN interface for internet access (using additional Hetzner IP)
- **Network Tools** for troubleshooting and monitoring
- **Secure Access** with dedicated admin user
- **Quick Access Scripts** for common tasks

## Prerequisites

Before setting up the firewall admin container, ensure that:

1. **Network Configuration** has been completed
   ```bash
   ./install.sh --network
   ```

2. **pfSense VM** has been set up and is running
   ```bash
   ./install.sh --pfsense
   ```

3. **Additional IP Addresses** are configured in `.env` file
4. **Network Bridges** (vmbr0, vmbr1) are operational

## Installation

### Quick Setup

```bash
# Basic setup with defaults
./install.sh --firewalladmin

# Custom configuration
./install.sh --firewalladmin --ct-id 300 --memory 2048
```

### Manual Setup

```bash
# Run the setup script directly
./scripts/setup-firewall-admin.sh

# With custom options
./scripts/setup-firewall-admin.sh --ct-id 200 --wan-ip 203.0.113.12 --memory 1024
```

### Dry Run (Preview)

```bash
# See what would be done without making changes
./install.sh --firewalladmin --dry-run
./scripts/setup-firewall-admin.sh --dry-run
```

## Configuration

### Environment Variables

Configure in `.env` file:

```bash
# Container Settings
FIREWALL_ADMIN_CT_ID=200
FIREWALL_ADMIN_HOSTNAME=firewall-admin
FIREWALL_ADMIN_MEMORY=1024
FIREWALL_ADMIN_CORES=1
FIREWALL_ADMIN_DISK_SIZE=8

# Network Configuration
FIREWALL_ADMIN_WAN_IP=203.0.113.12  # Second additional IP
FIREWALL_ADMIN_LAN_IP=192.168.1.10      # LAN network IP
PFSENSE_LAN_IP=192.168.1.1               # pfSense LAN gateway
```

### Network Configuration

The container is configured with dual network interfaces:

- **eth0 (LAN)**: Connected to vmbr1 bridge
  - IP: 192.168.1.10/24
  - Gateway: 192.168.1.1 (pfSense LAN IP)
  - Purpose: Access pfSense web interface and internal services

- **eth1 (WAN)**: Connected to vmbr0 bridge
  - IP: Second additional IP from Hetzner
  - Gateway: Hetzner gateway for additional IP
  - Purpose: Internet access for updates and external services

## Usage

### Container Management

```bash
# Start container
pct start 200

# Stop container
pct stop 200

# Restart container
pct restart 200

# Access console
pct console 200

# Check status
pct status 200
```

### Accessing the Container

#### Console Access
```bash
# Direct console access
pct console 200

# Login with admin user
# Password available in: config/firewall-admin-credentials.txt
```

#### SSH Access (if configured)
```bash
# SSH to LAN IP
ssh admin@192.168.1.10
```

#### VNC/Desktop Access
Use the Proxmox web interface:
1. Go to Proxmox web interface
2. Navigate to container
3. Click "Console" for terminal or configure VNC for desktop

### pfSense Administration

#### Quick Access Script
```bash
# From within the container
./pfsense-access.sh
```

This script will:
- Display network information
- Show pfSense access URL
- Optionally open Firefox to pfSense interface

#### Manual Access
1. Open Firefox within the container
2. Navigate to `https://192.168.1.1`
3. Login with pfSense credentials (default: admin/pfsense)

### Network Testing

#### Test pfSense Connectivity
```bash
# From within container
ping 192.168.1.1
curl -k https://192.168.1.1
```

#### Test Internet Connectivity
```bash
# From within container
ping 8.8.8.8
curl -I https://www.google.com
```

#### Network Troubleshooting
```bash
# Check network interfaces
ip addr show

# Check routing
ip route show

# Network configuration tool
nmtui

# Check which interface is used for specific destinations
ip route get 192.168.1.1    # Should use LAN interface
ip route get 8.8.8.8     # Should use WAN interface
```

## Security Considerations

### Access Control
- Container runs as unprivileged LXC container
- Dedicated admin user with sudo access
- Strong random passwords generated during setup
- Credentials stored securely in `config/firewall-admin-credentials.txt`

### Network Security
- Only necessary network access configured
- pfSense access restricted to LAN network
- Internet access through dedicated WAN interface
- No direct access from internet to container

### Best Practices
1. **Change Default Passwords**: Both container and pfSense passwords
2. **Regular Updates**: Keep Fedora and packages updated
3. **Firewall Rules**: Configure pfSense rules appropriately
4. **Monitor Access**: Review container and pfSense logs regularly
5. **Backup Configuration**: Regular backups of container and pfSense configs

## Troubleshooting

### Container Won't Start
```bash
# Check container configuration
pct config 200

# Check for errors
pct start 200
journalctl -f

# Check resource availability
df -h  # Disk space
free -h  # Memory
```

### Network Issues
```bash
# Check bridge status
ip link show vmbr0 vmbr1

# Check container network config
pct config 200 | grep net

# Test from Proxmox host
ping 192.168.1.10  # Container LAN IP
```

### pfSense Access Issues
```bash
# Check pfSense VM status
qm status 100

# Check pfSense network configuration
qm config 100 | grep net

# Test pfSense connectivity
ping 192.168.1.1
```

### DNS Resolution Issues
```bash
# Check DNS configuration
cat /etc/resolv.conf

# Test DNS resolution
nslookup google.com
dig google.com
```

## Advanced Configuration

### Custom Network Routing
If you need custom routing rules, modify the network configuration:

```bash
# Edit routing configuration
/etc/NetworkManager/dispatcher.d/99-firewall-admin
```

### Additional Software
Install additional tools as needed:

```bash
# Security tools
dnf install nmap wireshark-cli

# Development tools
dnf install git vim code

# Monitoring tools
dnf install htop iotop ss
```

### Desktop Environment
The container includes Fedora 42 Workstation by default. To access:

1. Configure VNC in Proxmox
2. Or use X11 forwarding via SSH
3. Or use web-based VNC tools

## Backup and Recovery

### Container Backup
```bash
# Create backup
vzdump 200 --mode snapshot --storage local

# Restore backup
pct restore 200 /var/lib/vz/dump/vzdump-lxc-200-*.tar.gz
```

### Configuration Backup
Important files to backup:
- `/etc/NetworkManager/` - Network configuration
- `/home/admin/` - User configurations
- Container configuration: `pct config 200`

## Integration Examples

### Monitoring Setup
```bash
# Install monitoring tools
dnf install nagios-plugins-all

# Create monitoring scripts for pfSense
# Monitor pfSense services, CPU, memory, etc.
```

### Automated Administration
```bash
# Create scripts for common pfSense tasks
# Backup pfSense configuration
# Update pfSense packages
# Monitor firewall logs
```

## Files and Directories

### Configuration Files
- `config/firewall-admin-credentials.txt` - Container credentials
- `.env` - Environment configuration
- `/etc/NetworkManager/conf.d/99-firewall-admin.conf` - Network config

### Scripts
- `scripts/setup-firewall-admin.sh` - Main setup script
- `/home/admin/pfsense-access.sh` - Quick access script

### Logs
- `/var/log/hetzner-proxmox-setup.log` - Setup logs
- Container logs via `journalctl`

## Support

For issues or questions:
1. Check this documentation
2. Review setup logs
3. Check Proxmox and container status
4. Test network connectivity step by step
5. Review pfSense logs and status

Remember to always test changes in a non-production environment first.
