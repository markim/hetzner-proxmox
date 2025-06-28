# Troubleshooting Guide

This guide helps you diagnose and fix common issues with the Hetzner Proxmox setup.

## Common Issues

### 1. Caddy Won't Start

**Symptoms:**
- `systemctl status caddy` shows failed state
- Error: "bind: address already in use"

**Solutions:**

Check what's using port 80/443:
```bash
sudo netstat -tlnp | grep ':80\|:443'
sudo lsof -i :80
sudo lsof -i :443
```

Stop conflicting services:
```bash
# Common conflicting services
sudo systemctl stop apache2
sudo systemctl stop nginx
sudo systemctl disable apache2
sudo systemctl disable nginx
```

Check Caddy configuration:
```bash
sudo caddy validate --config /etc/caddy/Caddyfile
```

### 2. SSL Certificate Issues

**Symptoms:**
- "Certificate not found" errors
- Browser shows "Not Secure"
- Let's Encrypt rate limit errors

**Solutions:**

Check DNS configuration:
```bash
# Verify DNS points to your server
dig +short your-domain.com
nslookup your-domain.com
```

Test Let's Encrypt connectivity:
```bash
# Test ACME challenge
curl -I http://your-domain.com/.well-known/acme-challenge/test
```

Use staging environment for testing:
```bash
# In .env file
ENABLE_STAGING=true
```

Check Caddy logs:
```bash
sudo journalctl -u caddy -f
tail -f /var/log/caddy/access.log
```

### 3. Proxmox Not Accessible

**Symptoms:**
- https://your-domain.com returns 502 error
- "Bad Gateway" messages

**Solutions:**

Check Proxmox services:
```bash
sudo systemctl status pveproxy
sudo systemctl status pvedaemon
```

Restart Proxmox services:
```bash
sudo systemctl restart pveproxy
sudo systemctl restart pvedaemon
```

Check if Proxmox is listening:
```bash
sudo netstat -tlnp | grep :8006
```

Test local connectivity:
```bash
curl -k https://localhost:8006
```

### 4. Firewall Issues

**Symptoms:**
- Can't access the server
- Services unreachable from outside

**Solutions:**

Check UFW status:
```bash
sudo ufw status verbose
```

Allow required ports:
```bash
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS
```

Check iptables rules:
```bash
sudo iptables -L -n
```

### 5. DNS Issues

**Symptoms:**
- Domain doesn't resolve to server IP
- SSL certificate fails to obtain

**Solutions:**

Verify DNS propagation:
```bash
# Check from multiple locations
dig @8.8.8.8 your-domain.com A
dig @1.1.1.1 your-domain.com A
```

Wait for DNS propagation (can take up to 48 hours).

Check your domain registrar's DNS settings.

### 6. Permission Issues

**Symptoms:**
- "Permission denied" errors
- Services can't write to log files

**Solutions:**

Fix Caddy permissions:
```bash
sudo chown -R caddy:caddy /etc/caddy
sudo chown -R caddy:caddy /var/lib/caddy
sudo chown -R caddy:caddy /var/log/caddy
```

Fix log file permissions:
```bash
sudo touch /var/log/hetzner-proxmox-setup.log
sudo chmod 644 /var/log/hetzner-proxmox-setup.log
```

## Diagnostic Commands

### System Information
```bash
# System status
uptime
df -h
free -h
cat /etc/os-release

# Network information
ip addr show
ip route show
```

### Service Status
```bash
# All services
sudo systemctl status caddy pveproxy pvedaemon

# Detailed service info
sudo systemctl cat caddy
sudo systemctl cat pveproxy
```

### Log Analysis
```bash
# Recent logs
sudo journalctl -xe
sudo journalctl -u caddy --since "1 hour ago"
sudo journalctl -u pveproxy --since "1 hour ago"

# Follow live logs
sudo journalctl -f
sudo tail -f /var/log/hetzner-proxmox-setup.log
```

### Network Testing
```bash
# Test external connectivity
ping -c 4 8.8.8.8
curl -I https://google.com

# Test local services
curl -I http://localhost
curl -k -I https://localhost:8006

# Port scanning
nmap -p 22,80,443,8006 localhost
```

## Recovery Procedures

### Restore Backup Configuration

If you have backups, restore them:
```bash
# Restore Caddy config
sudo cp /path/to/backup/Caddyfile /etc/caddy/Caddyfile
sudo systemctl restart caddy

# Restore Proxmox config
sudo tar -xzf /path/to/backup/proxmox-config.tar.gz -C /
sudo systemctl restart pveproxy pvedaemon
```

### Reset to Defaults

Remove custom configurations:
```bash
# Reset Caddy
sudo systemctl stop caddy
sudo rm -f /etc/caddy/Caddyfile
sudo systemctl start caddy

# Reset UFW
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw --force enable
```

### Complete Reinstall

If all else fails:
```bash
# Remove Caddy
sudo apt remove --purge caddy
sudo rm -rf /etc/caddy

# Remove configurations
sudo rm -f /etc/apt/sources.list.d/caddy-stable.list

# Run setup again
sudo ./install.sh
```

## Getting Help

### Log Collection

When seeking help, collect these logs:
```bash
# Create debug package
mkdir ~/debug-info
sudo journalctl -u caddy > ~/debug-info/caddy.log
sudo journalctl -u pveproxy > ~/debug-info/pveproxy.log
sudo ufw status verbose > ~/debug-info/firewall.txt
ip addr show > ~/debug-info/network.txt
cat /etc/caddy/Caddyfile > ~/debug-info/caddyfile.txt
tar -czf ~/debug-info.tar.gz ~/debug-info/
```

### Environment Information

Provide this information when asking for help:
- Operating system version: `cat /etc/os-release`
- Proxmox version: `pveversion`
- Caddy version: `caddy version`
- Domain name (redacted if sensitive)
- Error messages from logs
- What you were trying to do when the issue occurred

### Support Channels

- GitHub Issues: Submit detailed bug reports
- Proxmox Forums: For Proxmox-specific issues
- Caddy Community: For Caddy-related problems

## Prevention

### Regular Maintenance

```bash
# Weekly maintenance script
#!/bin/bash
apt update && apt upgrade -y
systemctl restart caddy
systemctl restart pveproxy
ufw --force reload
journalctl --vacuum-time=30d
```

### Monitoring

Set up basic monitoring:
```bash
# Install monitoring tools
apt install htop iotop netstat-nat

# Check disk space
df -h | grep -E '9[0-9]%|100%'

# Check memory usage
free -h

# Check service status
systemctl is-active caddy pveproxy pvedaemon
```

### Backup Strategy

Regular backups prevent data loss:
```bash
# Daily backup script
#!/bin/bash
DATE=$(date +%Y%m%d)
mkdir -p /root/backups
tar -czf /root/backups/config-$DATE.tar.gz /etc/caddy /etc/pve
find /root/backups -name "config-*.tar.gz" -mtime +30 -delete
```
