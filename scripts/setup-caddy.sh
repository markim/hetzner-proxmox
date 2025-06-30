#!/bin/bash

# Install Caddy Web Server
# This script installs Caddy from the official repository

set -euo pipefail

# Source common functions
source "$(dirname "$0")/../lib/common.sh"

# Load environment variables
load_env

# Install Caddy
install_caddy() {
    # Add Caddy repository
    log "INFO" "Adding Caddy repository..."
    
    # Download Caddy GPG key only if it doesn't exist
    local keyring_file="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    if [[ ! -f "$keyring_file" ]]; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o "$keyring_file"
        log "INFO" "Downloaded Caddy GPG key"
    else
        log "INFO" "Caddy GPG key already exists"
    fi
    
    # Add repository only if it doesn't already exist
    local sources_list="/etc/apt/sources.list.d/caddy-stable.list"
    if [[ ! -f "$sources_list" ]] || ! grep -q "caddy/stable" "$sources_list" 2>/dev/null; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee "$sources_list" >/dev/null
        log "INFO" "Added Caddy repository"
    else
        log "INFO" "Caddy repository already configured"
    fi
    
    # Update package list with new repository (suppress warnings)
    apt-get update -qq 2>/dev/null || apt-get update -qq
    
    # Install Caddy
    log "INFO" "Installing Caddy..."
    apt-get install -y -qq caddy 2>/dev/null
    
    # Verify installation
    if ! command -v caddy &> /dev/null; then
        log "ERROR" "Caddy installation failed"
        return 1
    fi
    
    local caddy_version
    caddy_version=$(caddy version | head -n1)
    log "INFO" "Caddy installed successfully: $caddy_version"
    
    # Create caddy configuration directory if it doesn't exist
    mkdir -p "$CADDY_CONFIG_DIR"
    
    # Set proper ownership
    chown -R caddy:caddy "$CADDY_CONFIG_DIR"
    
    # Create log directory
    mkdir -p /var/log/caddy
    chown -R caddy:caddy /var/log/caddy
    
    # Stop caddy service for now (will be started after configuration)
    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true
    
    log "INFO" "Caddy installation completed"
    return 0
}

# Main function
main() {
    log "INFO" "Starting Caddy installation..."
    
    # Check if running as root
    check_root

    if install_caddy; then
        log "INFO" "Caddy installation script completed successfully"
    else
        log "ERROR" "Caddy installation script failed"
        exit 1
    fi
}

# Run main function
main "$@"
