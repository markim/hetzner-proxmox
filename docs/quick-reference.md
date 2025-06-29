# Quick Reference

## 🚀 Setup Workflow

```bash
# 1. Setup
git clone <repo> && cd hetzner-proxmox
cp .env.example .env && nano .env

# 2. Verify (CRITICAL)
sudo ./install.sh --check-mac

# 3. Install components
sudo ./install.sh --preparedrives    # Optional: optimize drives
sudo ./install.sh --caddy            # HTTPS reverse proxy  
sudo ./install.sh --network          # Network bridges
sudo ./install.sh --pfsense          # Firewall VM
sudo ./install.sh --firewalladmin    # Admin container
```

## 📋 Common Commands

| Task | Command |
|------|---------|
| **Check MAC config** | `./install.sh --check-mac` |
| **Preview changes** | `./install.sh --network --dry-run` |
| **Check service status** | `systemctl status caddy` |
| **View logs** | `journalctl -u caddy -f` |
| **List VMs** | `qm list` |
| **List containers** | `pct list` |
| **Emergency network restore** | `/root/restore-network.sh` |

## 🔧 VM/Container Management

```bash
# pfSense VM (ID: 100)
qm start 100           # Start VM
qm stop 100            # Stop VM  
qm status 100          # Check status
qm config 100          # View config

# Firewall Admin Container (ID: 200)
pct start 200          # Start container
pct stop 200           # Stop container
pct enter 200          # Enter container
pct config 200         # View config
```

## 🌐 Access URLs

- **Proxmox**: `https://your-domain.com`
- **pfSense**: Access via admin container at `192.168.1.1`
- **Emergency Proxmox**: `https://your-server-ip:8006`

## 🚨 Emergency Recovery

```bash
# Network issues
/root/restore-network.sh

# Reset Proxmox access
systemctl start pveproxy

# Reset Caddy
systemctl restart caddy
```

## ⚙️ Configuration Files

- **Main config**: `.env`
- **Alternative IPs**: `config/additional-ips.conf`
- **Caddy config**: `/etc/caddy/Caddyfile`
- **Network backup**: `/etc/network/interfaces.backup`

## 🔍 Troubleshooting Steps

1. **Check MAC addresses**: `./install.sh --check-mac`
2. **Verify DNS**: `dig +short your-domain.com`  
3. **Check services**: `systemctl status caddy pveproxy`
4. **Check network**: `ip link show | grep vmbr`
5. **View logs**: `journalctl -u caddy --since "1 hour ago"`

For detailed troubleshooting, see: [docs/troubleshooting.md](docs/troubleshooting.md)
