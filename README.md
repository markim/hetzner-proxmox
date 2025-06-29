# Hetzner Proxmox Setup

Automated setup scripts for configuring a Hetzner server with Proxmox, including network configuration for additional IPs, pfSense firewall integration, and Caddy reverse proxy with HTTPS.

## Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/hetzner-proxmox.git
   cd hetzner-proxmox
   ```

2. **Configure environment:**
   ```bash
   cp .env.example .env
   # Edit .env with your domain, email, and network configuration
   nano .env
   ```

3. **Complete setup in order:**
   ```bash
   # 0. IMPORTANT: Check MAC address configuration first
   sudo ./install.sh --check-mac
   
   # 1. OPTIONAL: Prepare drives with optimal RAID configuration
   sudo ./install.sh --preparedrives
   
   # 2. Install Caddy reverse proxy
   sudo ./install.sh --caddy
   
   # 3. Configure network for pfSense integration  
   sudo ./install.sh --network
   
   # 4. Create pfSense firewall VM
   sudo ./install.sh --pfsense
   
   # 5. Create firewall admin container
   sudo ./install.sh --firewalladmin
   ```

## 📖 Complete Setup Guide

**For detailed step-by-step instructions, see: [Complete Setup Guide](docs/complete-setup-guide.md)**

This guide covers the entire process from start to finish, including network architecture, security considerations, and post-setup configuration.

## Available Commands

- `./install.sh` - Show available commands and help
- `./install.sh --check-mac` - Verify MAC address configuration for additional IPs (RECOMMENDED FIRST)
- `./install.sh --a` - Scan drives and configure optimal RAID arrays (OPTIONAL - after installimage)
- `./install.sh --network` - Configure network bridges for pfSense integration
- `./install.sh --caddy` - Install and configure Caddy with HTTPS
- `./install.sh --pfsense` - Create and configure pfSense firewall VM
- `./install.sh --firewalladmin` - Create Fedora container for firewall administration
- `./install.sh --all` - Complete setup (future implementation)

### Command Options

- `-h, --help` - Show detailed help
- `-c, --config FILE` - Use custom environment file
- `-d, --dry-run` - Preview changes without executing
- `-v, --verbose` - Enable verbose logging

## What This Does

### Complete Infrastructure Setup
1. **Drive Preparation** (Optional) - Intelligent RAID configuration based on detected drives
2. **Caddy Installation** - Reverse proxy with automatic SSL certificates
3. **Network Configuration** - Bridge setup for pfSense integration with additional IPs
4. **pfSense Setup** - Firewall VM creation with proper network interfaces
5. **Firewall Admin Container** - Fedora container for secure pfSense administration

### Network Architecture
```
Internet → Additional IPs → vmbr0 (WAN) → pfSense → vmbr1 (LAN) / vmbr2 (DMZ)
                                              ↓
                                        VMs/Containers
```
- Scans and optimally configures drives for RAID (if multiple drives available)
- Creates automatic backups and emergency restore scripts
- Prepares network for pfSense firewall integration
- Sets up container bridges for Proxmox

### Drive Preparation (`--preparedrives`)
- Automatically scans all available drives in your system
- Groups drives by size and analyzes possible RAID configurations
- Suggests optimal RAID setup based on detected hardware
- Supports any drive sizes and combinations (no hardcoded assumptions)
- Preview mode to safely show changes before applying
- Works with Hetzner's installimage workflow

### Caddy Setup (`--caddy`)
- Installs and configures Caddy web server
- Sets up automatic HTTPS with Let's Encrypt
- Configures Caddy as a reverse proxy for Proxmox
- Secures Proxmox behind HTTPS on your custom domain
- Sets up proper logging and monitoring

### Firewall Admin Container (`--firewalladmin`)
- Creates Fedora 42-based LXC container for pfSense administration
- Dual network interfaces: LAN access to pfSense + WAN internet access
- Pre-installed Firefox browser for pfSense web interface
- Network troubleshooting and monitoring tools
- Secure admin user with desktop environment
- Quick access scripts for common firewall tasks

## Prerequisites

- Fresh Hetzner server with Proxmox installed via installimage
- Domain name pointing to your server's IP (for Caddy setup)
- Additional IP addresses from Hetzner (for network setup)
- Root access to the server
- Any combination of drives (the script will scan and adapt to your hardware)

## Configuration

All configuration is done via environment variables in the `.env` file:

### Basic Configuration
- `DOMAIN`: Your domain name (e.g., proxmox.example.com)
- `EMAIL`: Your email for Let's Encrypt certificates
- `PROXMOX_PORT`: Proxmox web interface port (default: 8006)

### Network Configuration
- `ADDITIONAL_IPS`: Additional IP addresses from Hetzner
  - Format: `IP:MAC:GATEWAY:NETMASK,IP:MAC:GATEWAY:NETMASK`
  - Example: `YOUR_ADDITIONAL_IP:YOUR_MAC_ADDRESS:YOUR_GATEWAY_IP:YOUR_NETMASK`
  - **⚠️ CRITICAL**: MAC addresses are REQUIRED for each additional IP

**MAC Address Requirement:**
Hetzner requires specific MAC addresses for each additional IP. Without correct MAC addresses, your additional IPs will not work! Use `./install.sh --check-mac` to verify your configuration before proceeding.

See [Network Configuration Guide](docs/network-configuration.md) for detailed setup instructions.

## Manual Installation

If you prefer to run individual components:

```bash
# Install Caddy
./scripts/install-caddy.sh

# Configure Proxmox settings
./scripts/configure-proxmox.sh your-domain.com

# Setup HTTPS reverse proxy
./scripts/setup-https.sh your-domain.com

# Configure firewall
./scripts/configure-firewall.sh
```

## Configuration

### Environment Variables

You can customize the installation by setting these environment variables:

- `PROXMOX_PORT`: Proxmox web interface port (default: 8006)
- `CADDY_CONFIG_DIR`: Caddy configuration directory (default: /etc/caddy)
- `DOMAIN`: Your domain name (required)

### Custom Configuration

Modify the template files in the `config/` directory before running the setup:

- `config/Caddyfile.template`: Caddy reverse proxy configuration
- `config/proxmox.conf.template`: Additional Proxmox settings

## Security Considerations

- The script disables Proxmox web interface direct access on port 8006
- All traffic is routed through Caddy with HTTPS
- UFW firewall is configured with minimal required ports
- Root login via SSH should be disabled after setup (not automated)

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues and solutions.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Support

If you encounter issues:
1. Check the troubleshooting guide
2. Review the logs: `journalctl -u caddy -f`
3. Open an issue with detailed information

---

**Warning**: This script makes system-level changes. Always test in a development environment first.
