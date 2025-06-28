# Installation Guide

This guide walks you through the complete setup process for configuring a Hetzner server with Proxmox behind a Caddy reverse proxy.

## Prerequisites

### Server Requirements
- Fresh Hetzner VPS or dedicated server
- Proxmox VE installed via Hetzner's `installimage`
- At least 4GB RAM (8GB+ recommended)
- 50GB+ storage space
- Root SSH access

### Domain Requirements
- Domain name you control
- DNS A record pointing to your server's IP address
- Access to modify DNS records

### Network Requirements
- Ports 80 and 443 accessible from the internet
- SSH access (port 22)

## Step-by-Step Installation

### 1. Prepare Your Server

After installing Proxmox via Hetzner's installimage:

```bash
----- Done installing Proxmox VE -----


                  INSTALLATION COMPLETE
   You can now reboot and log in to your new system with the
 same credentials that you used to log into the rescue system.

root@rescue ~ # 

```


```bash
# Update the system
apt update && apt upgrade -y

# Set new password
passwd

# Clone the repository
git clone https://github.com/yourusername/hetzner-proxmox.git
cd hetzner-proxmox
```

### 2. Configure Environment

```bash
# Copy the example environment file
cp .env.example .env

# Edit the configuration
nano .env
```

Required settings in `.env`:
```bash
DOMAIN=proxmox.example.com
EMAIL=your-email@example.com
PROXMOX_PORT=8006
```

### 3. Run the Installation

```bash
# Make the script executable
chmod +x install.sh

# Run a dry-run first to see what will happen
sudo ./install.sh --dry-run

# Run the actual installation
sudo ./install.sh
```

### 4. Verify Installation

1. **Check services are running:**
   ```bash
   systemctl status caddy
   systemctl status pveproxy
   ```

2. **Test HTTPS access:**
   ```bash
   curl -I https://your-domain.com
   ```

3. **Access Proxmox web interface:**
   - Open `https://your-domain.com` in your browser
   - Login with root credentials

## Manual Installation

If you prefer to run components individually:

### Install Caddy
```bash
sudo ./scripts/install-caddy.sh
```

### Configure Proxmox
```bash
sudo ./scripts/configure-proxmox.sh
```

### Setup HTTPS
```bash
sudo ./scripts/setup-https.sh
```

## Configuration Options

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DOMAIN` | Your domain name | - | Yes |
| `EMAIL` | Email for Let's Encrypt | - | Yes |
| `PROXMOX_PORT` | Proxmox web port | 8006 | No |
| `CADDY_CONFIG_DIR` | Caddy config directory | /etc/caddy | No |
| `LOG_FILE` | Log file path | /var/log/hetzner-proxmox-setup.log | No |
| `ENABLE_STAGING` | Use Let's Encrypt staging | false | No |

### Advanced Configuration

#### Custom Caddy Configuration

To customize the Caddy configuration, edit `config/Caddyfile.template` before running the installation.

#### Firewall Rules

The installation configures UFW with secure defaults:
- Allow SSH (port 22)
- Allow HTTP (port 80) for Let's Encrypt
- Allow HTTPS (port 443) for web access
- Block direct Proxmox access (port 8006)

#### SSL Certificates

By default, the script uses Let's Encrypt production certificates. For testing, set:
```bash
ENABLE_STAGING=true
```

## Post-Installation

### Security Hardening

1. **Change default passwords:**
   ```bash
   passwd root  # Change root password
   # Change Proxmox web interface password
   ```

2. **Configure SSH security:**
   ```bash
   # Edit SSH config
   nano /etc/ssh/sshd_config
   
   # Recommended settings:
   PermitRootLogin no
   PasswordAuthentication no
   PubkeyAuthentication yes
   ```

3. **Enable automatic updates:**
   ```bash
   apt install unattended-upgrades
   dpkg-reconfigure unattended-upgrades
   ```

### Backup Configuration

Create regular backups of your configuration:

```bash
# Backup Caddy configuration
cp -r /etc/caddy /root/backups/caddy-$(date +%Y%m%d)

# Backup Proxmox configuration
tar -czf /root/backups/proxmox-config-$(date +%Y%m%d).tar.gz /etc/pve
```

## Monitoring

### Check Service Status
```bash
# Caddy status
systemctl status caddy
journalctl -u caddy -f

# Proxmox status
systemctl status pveproxy
systemctl status pvedaemon

# Firewall status
ufw status verbose
```

### Log Files
- Main setup log: `/var/log/hetzner-proxmox-setup.log`
- Caddy logs: `/var/log/caddy/access.log`
- Proxmox logs: `journalctl -u pveproxy`

## Updates

### Updating Caddy
```bash
apt update && apt upgrade caddy
systemctl restart caddy
```

### Updating Proxmox
```bash
apt update && apt upgrade
# Follow Proxmox upgrade procedures
```

### Updating Scripts
```bash
cd hetzner-proxmox
git pull origin main
# Review changes and re-run if needed
```
