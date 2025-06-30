# Troubleshooting Guide

Quick solutions for common issues with the Hetzner Proxmox setup.

## 🚨 Emergency Recovery

### Network Issues
```bash
# Emergency network restore (auto-created during setup)
/root/restore-network.sh

# Manual network restore
cp /etc/network/interfaces.backup /etc/network/interfaces
systemctl restart networking
```

### Lost Proxmox Access
```bash
# Re-enable direct Proxmox access
systemctl start pveproxy
systemctl enable pveproxy

# Access via: https://your-server-ip:8006
```

## 🔧 Common Issues

### 1. MAC Address Problems

**Symptoms:** Additional IPs not working, VMs can't reach internet

**Diagnosis:**
```bash
./install.sh --check-mac
```

**Solutions:**
- Get correct MAC addresses from Hetzner control panel
- Update `.env` or `config/additional-ips.conf` with correct MACs
- Restart affected VMs after MAC address correction

### 2. Caddy Won't Start

**Symptoms:** `systemctl status caddy` shows failed state

**Diagnosis:**
```bash
# Check what's using ports 80/443
sudo lsof -i :80
sudo lsof -i :443

# Validate Caddy configuration
sudo caddy validate --config /etc/caddy/Caddyfile
```

**Solutions:**
```bash
# Stop conflicting services
sudo systemctl stop apache2 nginx
sudo systemctl disable apache2 nginx

# Check DNS resolution
dig +short your-domain.com

# Restart Caddy
sudo systemctl restart caddy
```

### 3. SSL Certificate Issues

**Symptoms:** "Certificate not found" errors, browser shows "Not Secure"

**Diagnosis:**
```bash
# Check DNS resolution
dig +short your-domain.com
nslookup your-domain.com

# Check Caddy logs
journalctl -u caddy -f

# Test domain reachability
curl -I http://your-domain.com
```

**Solutions:**
```bash
# Fix DNS if needed (must point to your server's IP)
# Wait for DNS propagation (up to 24 hours)

# Force certificate renewal
systemctl stop caddy
rm -rf /var/lib/caddy/certificates/acme-v02.api.letsencrypt.org-directory/
systemctl start caddy
```

### 4. pfSense VM Issues

**Symptoms:** VM won't start, no network connectivity

**Diagnosis:**
```bash
# Check VM status
qm status 100

# Check VM configuration  
qm config 100

# Check if pfSense ISO exists
ls -la /var/lib/vz/template/iso/pfSense*
```

**Solutions:**
```bash
# Start VM
qm start 100

# If ISO missing, re-run pfSense setup
sudo ./install.sh --pfsense

# Check network bridges exist
ip link show | grep vmbr
```

### 5. Network Bridge Problems

**Symptoms:** VMs have no network, bridge interfaces missing

**Diagnosis:**
```bash
# Check bridges
ip link show | grep vmbr
brctl show

# Check network configuration
cat /etc/network/interfaces
```

**Solutions:**
```bash
# Re-run network configuration
sudo ./install.sh --network

# Or manual bridge creation
auto vmbr0
iface vmbr0 inet static
    address YOUR_MAIN_IP/NETMASK
    gateway YOUR_GATEWAY
    bridge-ports eth0
    bridge-stp off
    bridge-fd 0
```

### 6. Firewall Admin Container Issues

**Symptoms:** Container won't start, no desktop environment

**Diagnosis:**
```bash
# Check container status
pct status 200

# Check container configuration
pct config 200

# Check logs
pct logs 200
```

**Solutions:**
```bash
# Start container
pct start 200

# Enter container for debugging
pct enter 200

# Re-create if needed
pct destroy 200
sudo ./install.sh --firewalladmin
```

## 🔍 Diagnostic Commands

### System Status
```bash
# Check all services
systemctl status caddy pveproxy pvedaemon

# Check network interfaces
ip addr show
ip route show

# Check running VMs/containers
qm list
pct list
```

### Network Debugging
```bash
# Test connectivity
ping -c 3 8.8.8.8
ping -c 3 your-domain.com

# Check DNS resolution
nslookup your-domain.com
dig your-domain.com

# Check firewall rules
iptables -L -n
ufw status
```

### Log Analysis
```bash
# Caddy logs
journalctl -u caddy -f

# Proxmox logs
journalctl -u pveproxy -f
journalctl -u pvedaemon -f

# System logs
tail -f /var/log/syslog
dmesg | tail
```

## 🛠️ Advanced Troubleshooting

### Reset Component
```bash
# Reset Caddy configuration
sudo ./install.sh --caddy            # Reapply

# Reset network configuration
sudo ./install.sh --network            # Reapply
```

### Manual Configuration Check
```bash
# Verify environment configuration
cat .env | grep -v '^#' | grep -v '^$'

# Check additional IP configuration
cat config/additional-ips.conf

# Validate network interfaces
ip link show
cat /etc/network/interfaces
```

### Performance Issues
```bash
# Check system resources
htop
df -h
free -h

# Check VM resource usage
qm monitor 100
pct monitor 200

# Check network performance
iftop
nethogs
```

## 📞 Getting Help

### Before Asking for Help

1. **Run diagnostics:**
   ```bash
   ./install.sh --check-mac
   systemctl status caddy
   qm list && pct list
   ```

2. **Check logs:**
   ```bash
   journalctl -u caddy --since "1 hour ago"
   tail -f /var/log/syslog
   ```


### Information to Include

When reporting issues, include:
- Output of diagnostic commands above
- Your network configuration (sanitized IP addresses)
- Error messages from logs
- Steps that led to the issue
- Your server specifications (CPU, RAM, drives)

### Common Solutions Checklist

- [ ] MAC addresses configured correctly
- [ ] DNS pointing to correct IP
- [ ] No conflicting services on ports 80/443
- [ ] Network bridges exist and configured
- [ ] VMs have sufficient resources allocated
- [ ] All services started and enabled
- [ ] Firewall rules not blocking traffic

---

**Remember:** Most issues are related to MAC address configuration or DNS resolution. Start with `./install.sh --check-mac` and verify your domain's DNS settings.

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

### 2.1. pfSense SSL Certificate Issues

**Symptoms:**
- Browser shows "SSL connection error" when accessing pfSense at 192.168.1.1
- "Certificate not trusted" or "Invalid certificate" errors
- Cannot access pfSense web interface from Puppy Linux

**Solutions:**

Accept the self-signed certificate:
```bash
# pfSense generates its own self-signed certificate on first boot
# You must accept the browser security warning to proceed
```

Verify pfSense is running and accessible:
```bash
# From Proxmox host or Puppy Linux VM
ping 192.168.1.1
curl -k https://192.168.1.1  # -k flag ignores SSL certificate issues
```

Check if pfSense VM is running:
```bash
# On Proxmox host
qm status 100  # or your pfSense VM ID
qm start 100   # if it's stopped
```

Reset pfSense certificate (if needed):
```bash
# Access pfSense console and regenerate certificate
# This is rarely needed as the default certificate should work
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
