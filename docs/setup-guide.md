# Complete Setup Guide

This guide walks you through setting up a Hetzner Proxmox server with pfSense firewall, Caddy reverse proxy, and secure admin access.

## 🏗️ Architecture Overview

The final setup creates this network architecture:

```
Internet → Hetzner IPs → vmbr0 (WAN) → pfSense VM → vmbr1 (LAN) / vmbr2 (DMZ)
                                           ↓
                                   VMs and Containers
```

## 📋 Prerequisites

### Server Requirements
- **Hetzner Server**: VPS or dedicated server with Proxmox installed via Hetzner's `installimage`
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Storage**: 50GB+ available space
- **Access**: Root SSH access

### Network Requirements
- **Domain**: Domain name pointing to your server's main IP
- **Additional IPs**: Additional IP addresses from Hetzner (optional but recommended)
- **MAC Addresses**: MAC addresses for each additional IP (from Hetzner control panel)
- **Ports**: 80, 443, and 22 accessible from internet

## 🚀 Step-by-Step Installation

### Step 1: Server Preparation

After installing Proxmox via Hetzner's installimage:

```bash
# Update system
apt update && apt upgrade -y

# Clone repository
git clone https://github.com/yourusername/hetzner-proxmox.git
cd hetzner-proxmox

# Copy and configure environment
cp .env.example .env
nano .env
```

### Step 2: Configure Environment

Edit `.env` with your specific settings:

```bash
# Required: Domain and email for SSL certificates
DOMAIN=proxmox.example.com
EMAIL=your-email@example.com

# Required if using additional IPs: Network configuration
ADDITIONAL_IP_1=203.0.113.10
ADDITIONAL_MAC_1=00:50:56:00:01:02
ADDITIONAL_GATEWAY_1=203.0.113.1
ADDITIONAL_NETMASK_1=255.255.255.192

# Add more IPs as needed
ADDITIONAL_IP_2=203.0.113.11
ADDITIONAL_MAC_2=00:50:56:00:01:03
# ... etc
```

**Alternative**: Create `config/additional-ips.conf`:
```
IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.11 MAC=00:50:56:00:01:03 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
```

### Step 3: Verify MAC Address Configuration

**⚠️ CRITICAL**: This step prevents network issues later!

```bash
sudo ./install.sh --check-mac
```

This command will:
- Verify your MAC address configuration
- Check if additional IPs are properly configured
- Warn about potential issues

**Common Issues:**
- Missing MAC addresses (get them from Hetzner control panel)
- Incorrect format (must be format: 00:50:56:00:01:02)
- Mismatched IP/MAC pairs

### Step 4: Drive Preparation (Optional)

If your server has multiple drives, optimize them:

```bash
# Scan system and show drive recommendations
sudo ./install.sh --preparedrives

# Preview recommended configuration
sudo ./install.sh --preparedrives --config <recommended> --dry-run

# Apply optimal configuration
sudo ./install.sh --preparedrives --config <recommended>
```

**Benefits:**
- Automatic RAID setup based on your hardware
- Optimal performance and redundancy
- Works with any drive sizes and combinations

### Step 5: Install Caddy Reverse Proxy

```bash
sudo ./install.sh --caddy
```

**What this does:**
- Installs Caddy web server
- Configures automatic HTTPS with Let's Encrypt
- Sets up reverse proxy for Proxmox
- Secures Proxmox behind your domain

**After completion:**
- Proxmox accessible at: `https://your-domain.com`
- Automatic SSL certificate renewal
- Secure HTTPS-only access

### Step 6: Configure Network

```bash
# Preview network changes
sudo ./install.sh --network --dry-run

# Apply network configuration
sudo ./install.sh --network
```

**What this does:**
- Creates network bridges (vmbr0=WAN, vmbr1=LAN, vmbr2=DMZ)
- Configures additional IP addresses with proper MAC addresses
- Preserves SSH connectivity
- Creates emergency restore script at `/root/restore-network.sh`

**Safety features:**
- Automatic backup of current network configuration
- SSH connection preserved during changes
- Emergency rollback capability

### Step 7: Create pfSense Firewall VM

```bash
# Preview pfSense VM creation
sudo ./install.sh --pfsense --dry-run

# Create pfSense VM
sudo ./install.sh --pfsense
```

**What this creates:**
- pfSense VM with ID 100 (configurable)
- Dual network interfaces: WAN (vmbr0) and LAN (vmbr1)
- Proper MAC address assignment for Hetzner additional IPs
- ISO mounted and ready for installation

**Next steps after VM creation:**
1. Start VM: `qm start 100`
2. Access VM console through Proxmox web interface
3. Install pfSense following on-screen prompts
4. Configure WAN interface with your additional IP
5. Configure LAN interface (typically 192.168.1.1/24)

### Step 8: Create Firewall Admin Container

```bash
# Preview admin container creation
sudo ./install.sh --firewalladmin --dry-run

# Create admin container
sudo ./install.sh --firewalladmin
```

**What this creates:**
- Fedora container with desktop environment
- Firefox browser for pfSense web interface access
- Dual network interfaces: LAN (pfSense access) + WAN (internet)
- Network troubleshooting tools
- Secure admin user account

**Using the admin container:**
1. Start container: `pct start 200`
2. Access via Proxmox console
3. Login with admin credentials
4. Use Firefox to access pfSense at 192.168.1.1

## 🔧 Post-Installation Configuration

### pfSense Initial Setup

1. **Access pfSense**: Use admin container or VM console
2. **WAN Configuration**: 
   - IP: Your additional IP from Hetzner
   - Gateway: Additional IP gateway
   - DNS: 8.8.8.8, 1.1.1.1
3. **LAN Configuration**:
   - IP: 192.168.1.1/24
   - DHCP: Enable for 192.168.1.100-200
4. **Firewall Rules**: Configure as needed for your environment

### Proxmox Access

- **Main Interface**: `https://your-domain.com`
- **Direct Access**: `https://your-server-ip:8006` (if needed)
- **Admin Container**: Access via Proxmox console

### Security Recommendations

1. **Change Default Passwords**: Update all default passwords
2. **Enable 2FA**: Configure two-factor authentication where possible
3. **Firewall Rules**: Implement least-privilege access rules
4. **SSH Keys**: Use SSH keys instead of passwords
5. **Regular Updates**: Keep all systems updated

## 🐛 Troubleshooting

### Common Issues

**Network not working after configuration:**
```bash
# Check network bridges
ip link show | grep vmbr

# Restore emergency backup if needed
/root/restore-network.sh
```

**pfSense VM won't start:**
```bash
# Check VM configuration
qm config 100

# Check if ISO is mounted
ls -la /var/lib/vz/template/iso/
```

**Additional IPs not working:**
```bash
# Verify MAC addresses
./install.sh --check-mac

# Check VM network configuration
qm config 100 | grep net
```

**SSL Certificate Issues:**
```bash
# Check Caddy status
systemctl status caddy

# Verify DNS resolution
dig +short your-domain.com

# Check Caddy logs
journalctl -u caddy -f
```

### Emergency Recovery

**Network Recovery:**
```bash
# Emergency network restore
/root/restore-network.sh

# Or manual restore
cp /etc/network/interfaces.backup /etc/network/interfaces
systemctl restart networking
```

**Caddy Recovery:**
```bash
# Stop Caddy
systemctl stop caddy

# Check configuration
caddy validate --config /etc/caddy/Caddyfile

# Restart with original Proxmox access
systemctl start pveproxy
```

## 📚 Additional Resources

- **pfSense Documentation**: https://docs.netgate.com/pfsense/
- **Proxmox Documentation**: https://pve.proxmox.com/wiki/
- **Caddy Documentation**: https://caddyserver.com/docs/
- **Hetzner Network Setup**: Check Hetzner control panel for IP/MAC details

## 🎯 Next Steps

After successful installation:

1. **Configure pfSense**: Set up firewall rules, VPN, etc.
2. **Create VMs/Containers**: Deploy your applications
3. **Backup Setup**: Configure automated backups
4. **Monitoring**: Set up monitoring and alerting
5. **Documentation**: Document your specific configuration

---

This setup provides a robust, secure foundation for your Hetzner Proxmox environment with professional-grade networking and firewall capabilities.
