# Multi-IP Setup Guide for Hetzner Proxmox with pfSense Firewall

This guide shows you how to set up multiple IP addresses with DNS records and a pfSense firewall for your Proxmox containers on Hetzner.

## Architecture Overview

```
Internet
    ↓
Hetzner Additional IPs (203.0.113.10, .11, .12, etc.)
    ↓
vmbr0 (WAN Bridge) - All IPs configured here
    ↓
pfSense VM (Firewall/Router)
    ↓
vmbr1 (LAN Bridge - 192.168.1.0/24) → Internal Containers
    ↓
vmbr2 (DMZ Bridge - 10.0.2.0/24) → Public Services
```

## Step 1: Configure Your Additional IPs from Hetzner

### Get Your IP Information from Hetzner

1. **For Hetzner Cloud**: Go to Console → Your Project → Server → Networking → Additional IPs
2. **For Hetzner Robot**: Go to https://robot.hetzner.com → Your Server → IPs tab
3. **Note down**: IP address, MAC address, Gateway, and Netmask for each additional IP

### Configure the IPs

1. Copy the configuration template:
```bash
cd /root/hetzner-proxmox
cp config/additional-ips.conf.example config/additional-ips.conf
```

2. Edit the configuration with your actual Hetzner IP details:
```bash
nano config/additional-ips.conf
```

Example configuration:
```
# Replace these with your actual Hetzner IPs
IP=203.0.113.10 MAC=00:50:56:00:01:02 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.11 MAC=00:50:56:00:01:03 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
IP=203.0.113.12 MAC=00:50:56:00:01:04 GATEWAY=203.0.113.1 NETMASK=255.255.255.192
```

## Step 2: Apply Network Configuration

Run the network configuration script to set up bridges and additional IPs:

```bash
# Check MAC address configuration first
./install.sh --check-mac

# Apply network configuration (this will backup current config)
./scripts/configure-network.sh
```

**Important**: This will modify your network configuration. Make sure you have console access to your server in case SSH connectivity is interrupted.

## Step 3: Set Up pfSense Firewall

Install and configure pfSense VM:

```bash
# Install pfSense VM
./scripts/setup-pfsense.sh

# Or use the main installer
./install.sh --pfsense
```

This creates:
- **pfSense VM** on vmbr0 (WAN) with access to all your additional IPs
- **LAN interface** on vmbr1 (192.168.1.0/24) for internal containers
- **DMZ interface** on vmbr2 (10.0.2.0/24) for public-facing services

## Step 4: Create Containers with Specific IP Assignments

### Container Network Strategy

You have two main approaches:

**Option A: NAT with Port Forwarding (Recommended for most use cases)**
- Containers get internal IPs (192.168.1.x or 10.0.2.x)
- pfSense forwards specific ports from your public IPs to containers
- More secure, easier to manage

**Option B: Direct IP Assignment (Advanced)**
- Containers get public IPs directly
- pfSense provides firewall protection
- More complex but allows full IP control

### Example: NAT Setup with Port Forwarding

1. **Create a web server container:**
```bash
# Create container on DMZ network
pct create 300 /var/lib/vz/template/cache/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname webserver \
  --memory 1024 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr2,ip=10.0.2.10/24,gw=10.0.2.1 \
  --storage local-lvm \
  --rootfs local-lvm:8
```

2. **Configure pfSense port forwarding:**
   - Access pfSense web interface: https://192.168.1.1
   - Go to Firewall → NAT → Port Forward
   - Add rule: External IP `203.0.113.10`, Port `80` → Internal IP `10.0.2.10`, Port `80`

3. **Set up DNS:**
   - Point `web.yourdomain.com` → `203.0.113.10`
   - Point `mail.yourdomain.com` → `203.0.113.11`
   - Point `app.yourdomain.com` → `203.0.113.12`

## Step 5: Container Examples for Different Services

### Web Server Container (203.0.113.10)
```bash
# Create web server container
pct create 300 /var/lib/vz/template/cache/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname webserver \
  --memory 2048 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr2,ip=10.0.2.10/24,gw=10.0.2.1 \
  --storage local-lvm \
  --rootfs local-lvm:20

# Start and configure
pct start 300
pct exec 300 -- bash -c "
  apt update && apt install -y nginx
  systemctl enable nginx
  systemctl start nginx
"
```

### Mail Server Container (203.0.113.11)
```bash
# Create mail server container
pct create 301 /var/lib/vz/template/cache/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname mailserver \
  --memory 4096 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr2,ip=10.0.2.11/24,gw=10.0.2.1 \
  --storage local-lvm \
  --rootfs local-lvm:50

# Mail servers need more setup - consider using a dedicated guide
```

### Database/App Server Container (203.0.113.12)
```bash
# Create application server container
pct create 302 /var/lib/vz/template/cache/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
  --hostname appserver \
  --memory 4096 \
  --cores 4 \
  --net0 name=eth0,bridge=vmbr2,ip=10.0.2.12/24,gw=10.0.2.1 \
  --storage local-lvm \
  --rootfs local-lvm:100
```

## Step 6: pfSense Firewall Configuration

### Access pfSense Web Interface

1. **Initial setup via console** (if needed):
   - Console into pfSense VM
   - Set LAN IP: 192.168.1.1/24
   - Set WAN to use DHCP or static IP

2. **Web interface access**:
   - From a container: http://192.168.1.1
   - From outside: Set up VPN or SSH tunnel

### Key pfSense Configurations

1. **WAN Interface Setup**:
   - Configure with your main IP
   - Set up additional IP aliases for your extra IPs

2. **Firewall Rules**:
   - Block all inbound traffic by default
   - Create specific allow rules for services
   - Set up port forwarding as needed

3. **NAT Port Forwarding Examples**:
   ```
   External IP: 203.0.113.10, Port 80  → 10.0.2.10:80 (Web Server)
   External IP: 203.0.113.10, Port 443 → 10.0.2.10:443 (Web Server SSL)
   External IP: 203.0.113.11, Port 25  → 10.0.2.11:25 (SMTP)
   External IP: 203.0.113.11, Port 587 → 10.0.2.11:587 (SMTP Submission)
   External IP: 203.0.113.12, Port 3000 → 10.0.2.12:3000 (App Server)
   ```

## Step 7: DNS Configuration

Set up DNS records pointing to your additional IPs:

```
# A Records
web.yourdomain.com      → 203.0.113.10
mail.yourdomain.com     → 203.0.113.11
app.yourdomain.com      → 203.0.113.12

# MX Record (for mail)
yourdomain.com          → mail.yourdomain.com

# Optional: Reverse DNS (set in Hetzner control panel)
203.0.113.10 → web.yourdomain.com
203.0.113.11 → mail.yourdomain.com
203.0.113.12 → app.yourdomain.com
```

## Step 8: SSL/TLS Certificates

### Option A: Let's Encrypt in each container
```bash
# In each container
apt install -y certbot
certbot --nginx -d web.yourdomain.com
```

### Option B: Centralized SSL with pfSense + HAProxy
- Install HAProxy package in pfSense
- Configure SSL termination
- Forward HTTP traffic to containers

## Step 9: Monitoring and Management

### Monitor IP assignments:
```bash
# Check bridge configurations
ip addr show vmbr0
ip addr show vmbr1
ip addr show vmbr2

# Check routing
ip route

# Test connectivity from containers
pct exec 300 -- ping -c 3 8.8.8.8
```

### Access management:
- **pfSense**: https://192.168.1.1 (via SSH tunnel or VPN)
- **Proxmox**: https://your-main-ip:8006
- **Containers**: SSH to internal IPs via pfSense

## Security Best Practices

1. **Firewall**: Keep pfSense rules restrictive
2. **Updates**: Regular security updates for all containers
3. **Backups**: Regular Proxmox container backups
4. **Access**: Use key-based SSH authentication
5. **Monitoring**: Set up log monitoring and alerting

## Troubleshooting

### Network Issues:
```bash
# Check network configuration
./scripts/configure-network.sh --status

# Verify MAC addresses
./install.sh --check-mac

# Test connectivity
ping -c 3 203.0.113.10
```

### pfSense Issues:
- Check pfSense logs: Status → System Logs
- Verify interface assignments
- Check firewall rules and NAT configuration

### Container Issues:
```bash
# Check container status
pct status 300

# Check container network
pct exec 300 -- ip addr show
pct exec 300 -- ip route
```

This setup gives you:
✅ Multiple public IP addresses
✅ Firewall protection via pfSense
✅ DNS-accessible services
✅ Flexible container deployment
✅ Centralized network management
