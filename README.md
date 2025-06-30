# Hetzner Proxmox Setup

Automated setup scripts for configuring a Hetzner server with Proxmox, pfSense firewall, and Caddy reverse proxy with HTTPS.

## 🚀 Quick Start

1. **Clone and configure:**
   ```bash
   git clone https://github.com/yourusername/hetzner-proxmox.git
   cd hetzner-proxmox
   cp .env.example .env
   nano .env  # Configure your domain, email, and network settings
   ```

2. **⚠️ CRITICAL: Verify MAC addresses first:**
   ```bash
   sudo ./install.sh --check-mac
   ```
   *MAC addresses are REQUIRED for Hetzner additional IPs. Without them, additional IPs won't work!*

3. **Run setup components in order:**
   ```bash
   # ALWAYS start with MAC address verification
   sudo ./install.sh --check-mac
   
   # Optional: Scan drives and configure RAID arrays (interactive)
   sudo ./install.sh --setup-mirrors
   
   # Install reverse proxy with HTTPS
   sudo ./install.sh --caddy
   
   # Configure network bridges for server and pfsense
   sudo ./install.sh --network
   
   # Create pfSense firewall VM
   sudo ./install.sh --pfsense
   
   # Create admin container for pfSense management
   sudo ./install.sh --firewalladmin
   ```

## 📖 Documentation

- **[Setup Guide](docs/setup-guide.md)** - Complete installation walkthrough
- **[Quick Reference](docs/quick-reference.md)** - Commands and common tasks
- **[Troubleshooting](docs/troubleshooting.md)** - Common issues and solutions

## ⚙️ Available Commands

| Command | Description |
|---------|-------------|
| `./install.sh --check-mac` | **START HERE** - Verify MAC address configuration |
| `./install.sh --setup-system` | Optimizes system for Proxmox and adds /var/lib/vz as "data" storage within Proxmox |
| `./install.sh --setup-mirrors` | Interactive drive and RAID configuration (optional) |
| `./install.sh --caddy` | Install Caddy reverse proxy with HTTPS |
| `./install.sh --network` | Configure network bridges for additional IPs |
| `./install.sh --pfsense` | Create pfSense firewall VM |
| `./install.sh --firewalladmin` | Create Fedora container for pfSense admin access |

## 🏗️ What This Creates

### Network Architecture
```
Internet → Additional IPs → vmbr0 (WAN) → pfSense → vmbr1 (LAN) / vmbr2 (DMZ)
                                              ↓
                                        VMs/Containers
```

### Components

**Drive Preparation** (Optional)
- Interactive drive and RAID configuration with multiple options
- Safety checks and confirmations before making any changes
- Supports any drive combination and sizes with user choice
- Creates backups and emergency restore information
- Scan-only mode to preview configurations without changes

**Caddy Reverse Proxy**
- HTTPS termination with automatic Let's Encrypt certificates
- Secures Proxmox behind your custom domain
- Proper logging and monitoring setup

**Network Configuration**
- Configures additional Hetzner IPs with proper MAC addresses
- Creates network bridges (vmbr0=WAN, vmbr1=LAN, vmbr2=DMZ)
- Preserves SSH connectivity during changes
- Emergency rollback scripts

**pfSense Firewall VM**
- Router/firewall VM with dual network interfaces
- Separates internet traffic from internal network
- Professional-grade firewall and routing capabilities

**Firewall Admin Container**
- Puppy linux container with desktop environment and Firefox
- Secure access to pfSense web interface
- Network troubleshooting tools included

## 📋 Prerequisites

- **Hetzner Server**: Fresh Proxmox installation via Hetzner installimage
- **Domain**: Domain name pointing to your server's main IP
- **Additional IPs**: Additional IP addresses from Hetzner with their MAC addresses
- **Access**: Root SSH access to the server

## ⚙️ Configuration

### Required Configuration (.env file)

```bash
# Domain and SSL
DOMAIN=proxmox.example.com
EMAIL=your-email@example.com
PUBLIC_IP=mainproxmoxserverIP
# Additional IP Configuration (Method 1: Environment Variables)
ADDITIONAL_IP_1=203.0.113.10
ADDITIONAL_MAC_1=00:50:56:00:01:02
ADDITIONAL_GATEWAY_1=203.0.113.1
ADDITIONAL_NETMASK_1=255.255.255.192

ADDITIONAL_IP_2=203.0.113.11
ADDITIONAL_MAC_2=00:50:56:00:01:03
# ... continue for each additional IP
```

### Alternative: Config File (Method 2)
This is an alternative method for the additional IP's. The .env file still needs the other values if you want to use caddy, etc.

Create `config/additional-ips.conf`:
```
IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.11 MAC=00:50:56:00:01:03 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
```

**⚠️ Critical**: MAC addresses are mandatory! Get them from your Hetzner control panel.

## 🔒 Security Features

- **HTTPS Everywhere**: All traffic encrypted with automatic SSL certificates
- **Firewall Protection**: pfSense isolates and protects internal network
- **Secure Admin Access**: Dedicated container for firewall management
- **Network Isolation**: Proper VLAN separation between WAN/LAN/DMZ
- **SSH Preservation**: Network changes preserve SSH connectivity

## 🛡️ Safety Features

- **Interactive Drive Setup**: User confirms all drive operations with detailed previews
- **Multiple Safety Checks**: Verifies system state before making destructive changes
- **Emergency Restore Info**: Creates detailed backup information before any changes
- **Scan-Only Mode**: Preview drive configurations without making any changes
- **Force Confirmation**: Requires explicit confirmation for destructive operations
- **Automatic Rollback**: Network changes include automatic restore capabilities

## 🐛 Getting Help

1. **Check the setup guide**: [docs/setup-guide.md](docs/setup-guide.md)
2. **Review troubleshooting**: [docs/troubleshooting.md](docs/troubleshooting.md)
3. **Verify MAC addresses**: Run `./install.sh --check-mac`
4. **Check logs**: `journalctl -u caddy -f`

---

⚠️ **Always test in a development environment first!** This script makes system-level changes.
