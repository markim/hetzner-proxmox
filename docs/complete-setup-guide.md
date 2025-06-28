# Complete Setup Guide for Hetzner Proxmox with pfSense

This guide walks you through the complete setup process for a Hetzner Proxmox server with pfSense firewall integration.

## Overview

The setup consists of four main phases:

1. **Caddy Setup** - Reverse proxy and SSL termination
2. **Network Configuration** - Bridge configuration for pfSense integration  
3. **pfSense Setup** - Firewall VM creation and configuration
4. **Firewall Admin Container** - Secure administrative access to pfSense

## Prerequisites

- Hetzner dedicated server with Proxmox installed
- Additional IP addresses allocated from Hetzner
- Root access to the server
- SSH connection to the server

## Phase 1: Caddy Setup

Caddy provides reverse proxy and automatic SSL certificates.

```bash
# Run the Caddy installation script
./scripts/install-caddy.sh

# Configure HTTPS
./scripts/setup-https.sh
```

**What this does:**
- Installs Caddy reverse proxy
- Configures automatic SSL certificates
- Sets up basic reverse proxy configuration
- Prepares for pfSense integration

## Phase 2: Network Configuration

This phase sets up the network bridges required for pfSense integration.

### Configure Environment

First, configure your additional IP addresses. You have three options:

#### Option 1: Config File (Recommended)
Create `config/additional-ips.conf`:
```
# Additional IP Configuration
# IMPORTANT: MAC addresses are REQUIRED for Hetzner additional IPs!
IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.11 MAC=00:50:56:00:01:03 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.12 MAC=00:50:56:00:01:04 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
```

**⚠️ Critical:** Replace the MAC addresses with the actual ones from your Hetzner control panel. Without correct MAC addresses, the additional IPs will not work!

#### Option 2: Environment Variables
Set in `.env` file:
```
# IMPORTANT: Include MAC addresses for each additional IP
ADDITIONAL_IP_1=203.0.113.10
ADDITIONAL_MAC_1=00:50:56:00:01:02
ADDITIONAL_GATEWAY_1=203.0.113.1
ADDITIONAL_NETMASK_1=255.255.255.192

ADDITIONAL_IP_2=203.0.113.11
ADDITIONAL_MAC_2=00:50:56:00:01:03
ADDITIONAL_GATEWAY_2=203.0.113.1
ADDITIONAL_NETMASK_2=255.255.255.192
```

**Note:** MAC addresses are obtained from your Hetzner control panel.

### Run Network Configuration

```bash
# Preview changes first (HIGHLY RECOMMENDED)
./scripts/configure-network.sh --dry-run

# Apply the configuration (can interrupt SSH temporarily)
./scripts/configure-network.sh
```

**What this creates:**
- `vmbr0`: WAN bridge connected to your physical interface with additional IPs
- `vmbr1`: LAN bridge (10.0.1.0/24) for internal VMs/containers
- `vmbr2`: DMZ bridge (10.0.2.0/24) for exposed services

## Phase 3: pfSense Setup

This phase creates and configures the pfSense firewall VM.

### Configure pfSense Settings

Set pfSense configuration in `.env` (optional):
```
PFSENSE_VM_ID=100
PFSENSE_MEMORY=2048
PFSENSE_CPU_CORES=2
PFSENSE_DISK_SIZE=32G
PFSENSE_WAN_IP=203.0.113.10  # Will auto-select from additional IPs if not set
```

### Create pfSense VM

```bash
# Preview the pfSense VM configuration
./install.sh --pfsense --dry-run

# Create the pfSense VM
./install.sh --pfsense

# Note: For custom settings, edit .env file before running
# You can set PFSENSE_VM_ID, PFSENSE_MEMORY, PFSENSE_CPU_CORES, etc.
```

**What this creates:**
- pfSense VM with proper network interface configuration
- WAN interface connected to vmbr0 (internet access with additional IP)
- LAN interface connected to vmbr1 (internal network)
- DMZ interface connected to vmbr2 (DMZ network)
- Configuration templates and documentation

## Phase 4: Firewall Admin Container

This phase creates a secure Fedora container for administering the pfSense firewall.

### Configure Container Settings

Set container configuration in `.env` (optional):
```
FIREWALL_ADMIN_CT_ID=200
FIREWALL_ADMIN_HOSTNAME=firewall-admin
FIREWALL_ADMIN_MEMORY=1024
FIREWALL_ADMIN_CORES=1
FIREWALL_ADMIN_DISK_SIZE=8
FIREWALL_ADMIN_WAN_IP=203.0.113.11  # Will auto-select second additional IP if not set
FIREWALL_ADMIN_LAN_IP=10.0.1.10      # IP on LAN network for pfSense access
```

### Create Firewall Admin Container

```bash
# Preview the container configuration
./install.sh --firewalladmin --dry-run

# Create the firewall admin container
./install.sh --firewalladmin
```

**What this creates:**
- Fedora 42 LXC container with desktop environment
- Dual network interfaces for LAN and WAN access
- Firefox browser for pfSense web interface access
- Network troubleshooting tools (nmap, tcpdump, etc.)
- Secure admin user with configured access
- Quick access scripts for pfSense management

**Container features:**
- **LAN Interface**: Access to pfSense web interface (10.0.1.0/24 network)
- **WAN Interface**: Internet access for updates and external tools
- **Desktop Environment**: Full Fedora 42 Workstation for GUI access
- **Security Tools**: Pre-installed network and security tools
- **Credentials**: Securely stored in `config/firewall-admin-credentials.txt`

## Network Architecture

After complete setup, your network architecture will look like this:

```
Internet
    ↓
Additional IPs (203.0.113.10, .11, .12) 
    ↓
vmbr0 (WAN Bridge) ← Connected to physical interface
    ↓                    ↓
pfSense VM          Firewall Admin Container
(Firewall)          (WAN: .140 for internet)
    ↓                    ↓
vmbr1 (LAN)         vmbr1 (LAN)
10.0.1.0/24         10.0.1.10 (pfSense access)
    ↓                    
Internal VMs        
Containers          
    ↓
vmbr2 (DMZ)
10.0.2.0/24
    ↓
Exposed Services
(Web servers, etc.)
```

## Post-Setup Configuration

### 1. Complete pfSense Installation

```bash
# Start the pfSense VM
qm start 100

# Access console for installation
qm terminal 100
# OR use Proxmox web interface -> VM 100 -> Console
```

Follow the pfSense installation wizard:
1. **Install pfSense to disk** (select "Install" from boot menu)
2. **Reboot and remove ISO** (VM will boot from disk)
3. **Console interface assignment**:
   - WAN: vtnet0 (connected to vmbr0)
   - LAN: vtnet1 (connected to vmbr1) 
   - DMZ: vtnet2 (connected to vmbr2) - Optional
4. **Configure WAN interface** (option 2 in console menu):
   - Use static IP configuration
   - IP: One of your additional Hetzner IPs
   - Subnet: Check your Hetzner control panel
   - Gateway: Your Hetzner gateway IP
5. **Configure LAN interface** (option 2 in console menu):
   - IP: 10.0.1.1
   - Subnet: 24 (255.255.255.0)
   - Enable DHCP if desired (range: 10.0.1.100-10.0.1.200)

**Important**: pfSense requires manual configuration - there is no automatic setup!

### 2. Access pfSense Web Interface

#### Option A: Using Firewall Admin Container (Recommended)
```bash
# Access the firewall admin container
pct console 200

# Login with admin user (credentials in config/firewall-admin-credentials.txt)
# Run the quick access script
./pfsense-access.sh

# Or manually open Firefox and navigate to https://10.0.1.1
# Note: Accept the SSL certificate warning (pfSense uses self-signed certificate)
```

**Note:** pfSense generates its own self-signed SSL certificate on first boot. You'll need to accept the browser's security warning when first accessing the web interface.

#### Option B: Traditional Method
- Connect a VM/container to vmbr1 (LAN network)
- Access: `https://10.0.1.1` (or configured LAN IP)
- Default login: `admin` / `pfsense`
- **CHANGE THE DEFAULT PASSWORD IMMEDIATELY**

### 3. Configure Firewall Admin Container Access

```bash
# Start the container (should auto-start)
pct start 200

# Check container status
pct status 200

# Access container console
pct console 200

# Check network connectivity from within container
ping 10.0.1.1    # pfSense LAN IP
ping 8.8.8.8     # Internet connectivity
```

### 4. Configure Firewall Rules

Essential firewall configuration:
1. **WAN Rules**: Block all inbound by default, allow specific services
2. **LAN Rules**: Allow LAN to any (default)
3. **Port Forwarding**: Configure NAT rules for services
4. **DMZ Rules**: Configure appropriate access restrictions

### 5. Container/VM Setup

Create containers and VMs on appropriate networks:

#### For Internal Services (LAN)
```bash
# Connect to vmbr1 (LAN bridge)
# IP range: 10.0.1.0/24
# Gateway: 10.0.1.1 (pfSense LAN IP)
```

#### For Exposed Services (DMZ)
```bash
# Connect to vmbr2 (DMZ bridge)  
# IP range: 10.0.2.0/24
# Gateway: 10.0.2.1 (pfSense DMZ IP)
```

## Integration Examples

### Web Server in DMZ
1. Create VM/container on vmbr2 (DMZ)
2. Assign static IP (e.g., 10.0.2.10)
3. Configure pfSense port forwarding: WAN:80 → 10.0.2.10:80
4. Configure Caddy reverse proxy if needed

### Database Server in LAN
1. Create VM/container on vmbr1 (LAN)
2. Assign static IP (e.g., 10.0.1.20)
3. Configure pfSense rules for database access
4. No direct internet access (secured)

## Troubleshooting

### Network Issues
```bash
# Check bridge status
ip link show vmbr0 vmbr1 vmbr2

# Check bridge IPs
ip addr show vmbr1

# Test connectivity
ping 10.0.1.1  # pfSense LAN IP
```

### pfSense Issues
```bash
# Check VM status
qm status 100

# Access console
qm terminal 100

# View VM config
qm config 100
```

### SSH Access Issues
If you lose SSH access during network configuration:
1. Use Hetzner rescue system
2. Mount your disk
3. Restore `/etc/network/interfaces` from backup
4. Restart networking

Emergency restore script is created at `/root/restore-network.sh`

## Security Considerations

1. **Change Default Passwords**: pfSense, Proxmox, any services
2. **Firewall Rules**: Start restrictive, open only what's needed
3. **SSH Access**: Consider moving SSH to non-standard port
4. **Updates**: Keep Proxmox, pfSense, and all services updated
5. **Monitoring**: Set up logging and monitoring
6. **Backups**: Regular backups of VM configurations and data

## Maintenance

### Regular Tasks
- Update pfSense packages
- Monitor firewall logs
- Check resource usage
- Backup VM configurations
- Update SSL certificates (automatic with Caddy)

### VM Management
```bash
# List all VMs
qm list

# Backup VM
qm backup 100 /backup/location/

# Clone VM
qm clone 100 101 --name pfsense-backup
```

## Support and Documentation

- pfSense Documentation: https://docs.netgate.com/pfsense/
- Proxmox Documentation: https://pve.proxmox.com/wiki/
- Caddy Documentation: https://caddyserver.com/docs/
- Hetzner Docs: https://docs.hetzner.com/

For script-specific issues, check the generated documentation:
- `docs/pfsense-setup.md` - pfSense configuration guide
- `docs/installation.md` - General installation guide
- `docs/network-configuration.md` - Network setup details
- `docs/troubleshooting.md` - Common issues and solutions
