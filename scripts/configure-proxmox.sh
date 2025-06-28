#!/bin/bash

# Configure Proxmox for reverse proxy setup
# This script optimizes Proxmox settings for use behind Caddy

set -euo pipefail

readonly SCRIPT_NAME="configure-proxmox"

# Source common functions
source "$(dirname "$0")/../lib/common.sh"

# Load environment variables
load_env

# Configure Proxmox for reverse proxy
configure_proxmox_web() {
    log "INFO" "Configuring Proxmox web interface..."
    
    local datacenter_cfg="/etc/pve/datacenter.cfg"
    
    # Backup existing configuration
    backup_file "$datacenter_cfg"
    
    # Configure console settings for better WebSocket support
    log "INFO" "Updating datacenter configuration..."
    
    # Create or update datacenter.cfg with console settings
    if ! grep -q "console:" "$datacenter_cfg" 2>/dev/null; then
        echo "console: html5" >> "$datacenter_cfg"
        log "INFO" "Added HTML5 console configuration"
    fi
    
    # Restart pve services to apply changes
    log "INFO" "Restarting Proxmox services..."
    systemctl restart pveproxy >/dev/null 2>&1
    systemctl restart pvedaemon >/dev/null 2>&1
    
    # Wait for services to restart
    sleep 5
    
    # Verify services are running
    if is_service_active "pveproxy" && is_service_active "pvedaemon"; then
        log "INFO" "Proxmox services restarted successfully"
    else
        log "ERROR" "Failed to restart Proxmox services"
        return 1
    fi
    
    # Check if pveproxy is listening on the expected port
    if command -v netstat >/dev/null && netstat -tuln | grep -q ":8006"; then
        log "INFO" "Proxmox web interface is accessible on port 8006"
    elif command -v ss >/dev/null && ss -tuln | grep -q ":8006"; then
        log "INFO" "Proxmox web interface is accessible on port 8006"
    else
        log "WARN" "Could not verify Proxmox web interface port status"
    fi
}

# Configure Proxmox network settings
configure_network() {
    log "INFO" "Configuring network settings for reverse proxy..."
    
    # Use PUBLIC_IP from environment configuration
    if [[ -n "${PUBLIC_IP:-}" && "$PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log "INFO" "Using configured PUBLIC_IP: $PUBLIC_IP"
        export PUBLIC_IP="$PUBLIC_IP"
    else
        log "WARN" "PUBLIC_IP not set or invalid in .env file. Using 127.0.0.1 as fallback."
        log "WARN" "Please set PUBLIC_IP in your .env file for proper configuration."
        export PUBLIC_IP="127.0.0.1"
    fi
}

# Update system packages
update_system() {
    log "INFO" "Updating system packages..."
    
    # Update package lists (suppress warnings)
    apt-get update -qq 2>/dev/null || apt-get update -qq
    
    # Upgrade packages
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>/dev/null
    
    # Install additional useful packages
    apt-get install -y -qq \
        curl \
        wget \
        unzip \
        htop \
        iotop \
        netstat-nat \
        ufw 2>/dev/null
    
    log "INFO" "System update completed"
}

# Configure basic firewall
configure_basic_firewall() {
    log "INFO" "Configuring basic firewall rules..."
    
    # Reset UFW to defaults (suppress output)
    ufw --force reset >/dev/null 2>&1
    
    # Set default policies
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    
    # Allow SSH (be careful not to lock ourselves out)
    ufw allow ssh >/dev/null 2>&1
    
    # Allow HTTP and HTTPS for Caddy
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    
    # Allow Proxmox clustering ports if needed (internal network only)
    # ufw allow from 10.0.0.0/8 to any port 5404:5405
    # ufw allow from 192.168.0.0/16 to any port 5404:5405
    
    # Enable UFW
    ufw --force enable >/dev/null 2>&1
    
    log "INFO" "Basic firewall configured"
}

# Optimize Proxmox settings
optimize_proxmox() {
    log "INFO" "Applying Proxmox optimizations..."
    
    # Disable enterprise repository if not licensed
    local enterprise_list="/etc/apt/sources.list.d/pve-enterprise.list"
    if [[ -f "$enterprise_list" ]]; then
        log "INFO" "Disabling enterprise repository..."
        sed -i 's/^deb/#deb/' "$enterprise_list"
    fi
    
    # Add no-subscription repository only if it doesn't already exist
    local no_sub_list="/etc/apt/sources.list.d/pve-no-subscription.list"
    local repo_line="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
    
    # Check if repository already exists in any sources list file
    if ! grep -r "pve.*bookworm.*pve-no-subscription" /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null | grep -v "^#" >/dev/null; then
        echo "$repo_line" > "$no_sub_list"
        log "INFO" "Added no-subscription repository"
    else
        log "INFO" "No-subscription repository already configured"
    fi
    
    # Clean up any duplicate repository entries
    if [[ -f "$no_sub_list" ]]; then
        # Remove duplicates and keep only one uncommented entry
        grep -v "^#" "$no_sub_list" | sort -u > "${no_sub_list}.tmp" 2>/dev/null || true
        if [[ -s "${no_sub_list}.tmp" ]]; then
            mv "${no_sub_list}.tmp" "$no_sub_list"
        else
            rm -f "${no_sub_list}.tmp"
        fi
    fi
    
    # Update package lists with new repository (suppress warnings)
    apt-get update -qq 2>/dev/null || apt-get update -qq
}

# Main function
main() {
    log "INFO" "Starting Proxmox configuration..."
    
    # Check if running as root
    check_root
    
    # Check essential dependencies (ufw will be installed in update_system)
    check_dependencies "systemctl" "apt-get"
    
    # Update system (this installs ufw)
    update_system
    
    # Now check for ufw after it's been installed
    check_dependencies "ufw"
    
    # Configure network detection
    configure_network
    
    # Optimize Proxmox
    optimize_proxmox
    
    # Configure Proxmox for reverse proxy
    configure_proxmox_web
    
    # Configure basic firewall
    configure_basic_firewall
    
    log "INFO" "Proxmox configuration completed successfully"
}

# Run main function
main "$@"
