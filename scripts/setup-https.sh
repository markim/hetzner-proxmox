#!/bin/bash

# Setup HTTPS with Caddy for Proxmox
# This script configures Caddy as a reverse proxy with automatic HTTPS

set -euo pipefail

# Source common functions
source "$(dirname "$0")/../lib/common.sh"

# Load environment variables
load_env

# Validate required environment variables
validate_required_vars() {
    validate_env "DOMAIN" "EMAIL" "PROXMOX_PORT"
    
    # Set default values for optional vars
    export ACME_EMAIL="${ACME_EMAIL:-$EMAIL}"
    export ENABLE_STAGING="${ENABLE_STAGING:-false}"
    
    # Set ACME CA directive based on staging flag
    if [[ "${ENABLE_STAGING}" == "true" ]]; then
        export ACME_CA_DIRECTIVE="acme_ca https://acme-staging-v02.api.letsencrypt.org/directory"
    else
        export ACME_CA_DIRECTIVE=""
    fi
}

# Configure Caddy for Proxmox reverse proxy
configure_caddy() {
    log "INFO" "Configuring Caddy for Proxmox reverse proxy..."
    
    local template_file
    template_file="$(dirname "$0")/../config/Caddyfile.template"
    local caddy_config="$CADDY_CONFIG_DIR/Caddyfile"
    
    # Ensure log directory exists with proper permissions
    mkdir -p /var/log/caddy
    chown -R caddy:caddy /var/log/caddy
    chmod -R 755 /var/log/caddy
    
    # Backup existing config if it exists
    backup_file "$caddy_config"
    
    # Process template
    process_template "$template_file" "$caddy_config"
    
    # Set proper ownership
    chown caddy:caddy "$caddy_config"
    chmod 644 "$caddy_config"
    
    log "INFO" "Caddy configuration updated"
}

# Test Caddy configuration
test_caddy_config() {
    log "INFO" "Testing Caddy configuration..."
    
    # Test and format the configuration
    if caddy fmt --overwrite "$CADDY_CONFIG_DIR/Caddyfile" >/dev/null 2>&1; then
        log "INFO" "Caddy configuration formatted"
    fi
    
    # Validate configuration with reduced output
    local validation_output
    if validation_output=$(caddy validate --config "$CADDY_CONFIG_DIR/Caddyfile" 2>&1); then
        log "INFO" "Caddy configuration is valid"
    else
        log "ERROR" "Caddy configuration is invalid"
        log "ERROR" "$validation_output"
        return 1
    fi
}


# Start and enable Caddy service
start_caddy() {
    log "INFO" "Starting Caddy service..."
    
    # Enable and start Caddy
    enable_service "caddy"
    
    # Wait a moment for service to start
    sleep 3
    
    # Check if Caddy is running properly
    if is_service_active "caddy"; then
        log "INFO" "Caddy is running successfully"
    else
        log "ERROR" "Caddy failed to start"
        log "INFO" "Checking Caddy status..."
        systemctl status caddy --no-pager || true
        return 1
    fi
}

# Verify HTTPS setup
verify_https() {
    log "INFO" "Verifying HTTPS setup..."
    
    local max_attempts=30
    local attempt=1
    local quiet_attempts=15
    
    log "INFO" "Waiting for SSL certificate to be obtained..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf "https://$DOMAIN" > /dev/null 2>&1; then
            log "INFO" "HTTPS is working! You can access Proxmox at: https://$DOMAIN"
            return 0
        fi
        
        # Only show progress for first half of attempts to reduce log noise
        if [[ $attempt -le $quiet_attempts ]]; then
            if [[ $((attempt % 5)) -eq 0 ]]; then
                log "INFO" "Still waiting for HTTPS... (attempt $attempt/$max_attempts)"
            fi
        else
            log "INFO" "Attempt $attempt/$max_attempts: Waiting for HTTPS to be ready..."
        fi
        
        sleep 10
        ((attempt++))
    done
    
    log "WARN" "HTTPS verification timed out. Please check:"
    log "INFO" "1. DNS is properly configured for $DOMAIN"
    log "INFO" "2. Ports 80 and 443 are accessible from the internet"
    log "INFO" "3. Caddy logs: journalctl -u caddy -f"
    
    return 1
}

# Main function
main() {
    log "INFO" "Starting HTTPS setup for Proxmox..."
    
    # Check if running as root
    check_root
    
    # Validate environment
    validate_required_vars
    
    # Check dependencies
    check_dependencies "caddy" "systemctl" "curl"
    
    # Configure Caddy
    if ! configure_caddy; then
        log "ERROR" "Failed to configure Caddy"
        exit 1
    fi
    
    # Test configuration
    if ! test_caddy_config; then
        log "ERROR" "Caddy configuration test failed"
        exit 1
    fi
    
    # Configure firewall
    configure_firewall
    
    # Start Caddy
    if ! start_caddy; then
        log "ERROR" "Failed to start Caddy"
        exit 1
    fi
    
    # Verify HTTPS
    if verify_https; then
        log "INFO" "HTTPS setup completed successfully!"
        log "INFO" "Access your Proxmox server at: https://$DOMAIN"
    else
        log "WARN" "HTTPS setup completed but verification failed"
        log "INFO" "Please check the logs and try accessing https://$DOMAIN manually"
    fi
}

# Run main function
main "$@"
