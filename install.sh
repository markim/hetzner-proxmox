#!/bin/bash

# Hetzner Proxmox Setup - Main Installation Script
# This script orchestrates the complete setup process

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Load default environment (will be overridden by parse_args if needed)
# Only load_env if we're not just showing help
if [[ "${1:-}" != "--help" ]] && [[ "${1:-}" != "-h" ]] && [[ "${1:-}" != "" ]]; then
    load_env 2>/dev/null || true
fi

# Usage information
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Automated setup for Hetzner Proxmox server with Caddy reverse proxy and HTTPS.

COMMANDS:
    (no command)        Show this help and available commands
    --drives            Scan drives and configure optimal RAID arrays
    --caddy             Install and configure Caddy with HTTPS (current functionality)
    --network           Configure network interfaces for additional Hetzner IPs
    --pfsense           Create and configure pfSense firewall VM (requires --network first)
    --firewalladmin     Create Fedora container for firewall administration (requires --pfsense first)
    --check-mac         Verify MAC address configuration for additional IPs

OPTIONS:
    -h, --help          Show this help message
    -c, --config FILE   Use specific environment file (default: .env)
    -v, --verbose       Enable verbose logging

EXAMPLES:
    $0                          # Show available commands (safe - shows help only)
    $0 --check-mac              # Verify MAC address configuration (recommended first step)
    $0 --drives                 # Scan drives and show optimal RAID configurations
    $0 --caddy                  # Install Caddy with current configuration
    $0 --network                # Configure network interfaces for additional IPs
    $0 --pfsense                # Create pfSense VM after network configuration
    $0 --firewalladmin          # Create firewall admin container after pfSense setup

RECOMMENDED WORKFLOW:
    1. $0 --check-mac           # Verify MAC addresses are correct
    3. $0 --network             # Apply network configuration
    5. $0 --caddy               # Install Caddy reverse proxy
    6. $0 --pfsense             # (Optional) Create pfSense firewall
    7. $0 --firewalladmin       # (Optional) Create admin VM for pfSense

REQUIREMENTS:
    - Fresh Proxmox installation on Hetzner server
    - Domain name pointing to server IP (for --caddy)
    - Properly configured .env file

NETWORK SETUP:
    Configure additional IPs in one of these ways:
    1. Create config/additional-ips.conf file
    2. Set structured environment variables (ADDITIONAL_IP_1, ADDITIONAL_MAC_1, etc.)
    
    See .env.example for configuration examples.

SAFETY NOTES:
    - Network configuration includes automatic backup and restore capabilities
    - SSH connectivity is preserved during network changes
    - Emergency restore script is created: /root/restore-network.sh

EOF
}

# Parse command line arguments
parse_args() {
    local config_file=""
    local command=""
    
    # Parse command first
    if [[ $# -gt 0 ]] && [[ "$1" =~ ^--.* ]]; then
        case $1 in
            --caddy)
                command="caddy"
                shift
                ;;
            --network)
                command="network"
                shift
                ;;
            --pfsense)
                command="pfsense"
                shift
                ;;
            --firewalladmin)
                command="firewalladmin"
                shift
                ;;
            --check-mac)
                command="check-mac"
                shift
                ;;
            --drives)
                command="drives"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                # Continue to option parsing
                ;;
        esac
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            --raid-config)
                export RAID_CONFIG="$2"
                shift 2
                ;;
            --caddy|--network|--pfsense|--firewalladmin|--check-mac|--drives)
                # Already handled above
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Load environment
    if [[ -n "$config_file" ]]; then
        load_env "$SCRIPT_DIR/$config_file"
    else
        load_env "$SCRIPT_DIR/.env"
    fi
    
    export COMMAND="$command"
    
}

# Validate environment and requirements
validate_setup() {
    log "INFO" "Validating setup requirements..."
    
    # Different validation based on command
    case "${COMMAND:-}" in
        "caddy")
            # Check if required environment variables are set for Caddy
            validate_env "DOMAIN" "EMAIL"
            
            # Validate domain format
            if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
                log "ERROR" "Invalid domain name: $DOMAIN"
                exit 1
            fi
            ;;
        "network")
            # Network-specific validation is handled in the network script
            log "INFO" "Network validation will be performed by configure-network.sh"
            ;;
        "pfsense")
            # pfSense-specific validation is handled in the pfSense script
            log "INFO" "pfSense validation will be performed by setup-pfsense.sh"
            # Check that network configuration has been run first
            if ! ip link show vmbr0 >/dev/null 2>&1 || ! ip link show vmbr1 >/dev/null 2>&1; then
                log "ERROR" "Network bridges not found. Run network configuration first:"
                log "ERROR" "  $0 --network"
                exit 1
            fi
            ;;
        "firewalladmin")
            # Firewall admin specific validation is handled in the firewall admin script
            log "INFO" "Firewall admin validation will be performed by setup-firewall-admin.sh"
            # Check that network configuration and pfSense have been set up first
            if ! ip link show vmbr0 >/dev/null 2>&1 || ! ip link show vmbr1 >/dev/null 2>&1; then
                log "ERROR" "Network bridges not found. Run network configuration first:"
                log "ERROR" "  $0 --network"
                exit 1
            fi
            local pfsense_vm_id="${PFSENSE_VM_ID:-100}"
            if ! qm status "$pfsense_vm_id" >/dev/null 2>&1; then
                log "ERROR" "pfSense VM not found. Set up pfSense first:"
                log "ERROR" "  $0 --pfsense"
                exit 1
            fi
            ;;
        "check-mac")
            # MAC address check doesn't require special validation - it just checks configuration
            log "INFO" "MAC address configuration check - no prerequisites required"
            ;;
        "drives")
            # Drives configuration - check we have the required tools
            log "INFO" "Drive configuration - checking for required tools"
            if ! command -v lsblk &> /dev/null; then
                log "ERROR" "lsblk command not found. Required for drive management."
                exit 1
            fi
            if ! command -v mdadm &> /dev/null; then
                log "ERROR" "mdadm command not found. Required for RAID management."
                exit 1
            fi
            ;;
        *)
            # No command specified - just show usage
            log "INFO" "No command specified. Available commands:"
            usage
            exit 0
            ;;
    esac
    
    # Check if Proxmox is installed
    if ! command -v pvesh &> /dev/null; then
        log "ERROR" "Proxmox VE not found. Please install Proxmox first."
        exit 1
    fi
    
    # Check if we're on Debian
    if ! grep -q "debian" /etc/os-release; then
        log "ERROR" "This script is designed for Debian systems."
        exit 1
    fi
    
    # Check internet connectivity
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log "ERROR" "No internet connectivity. Please check your network connection."
        exit 1
    fi
    
    log "INFO" "Validation completed successfully."
}


run_script() {
    local script="$1"
    local script_path="$SCRIPT_DIR/$script"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Script not found: $script_path"
        exit 1
    fi
    
    log "INFO" "Executing: $script"
    if ! bash "$script_path"; then
        log "ERROR" "Failed to execute: $script"
        exit 1
    fi
}


# Run Caddy setup (original functionality)
run_caddy_setup() {
    log "INFO" "Starting Hetzner Proxmox Caddy setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Validate setup for Caddy
    validate_setup
    
    # Run Caddy setup script
    local script_path="$SCRIPT_DIR/scripts/setup-caddy.sh"
    
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Caddy setup script not found: $script_path"
        exit 1
    fi
    
    # Build arguments for the Caddy setup script
    local caddy_args=()
    
    # Add verbose flag if set
    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        caddy_args+=("--verbose")
    fi
     log "INFO" "Executing Caddy setup script..."

    if ! bash "$script_path" "${caddy_args[@]}"; then
        log "ERROR" "Caddy setup failed"
        exit 1
    fi

    # Also run HTTPS configuration script
    local https_script_path="$SCRIPT_DIR/scripts/setup-https.sh"
    
    if [[ ! -f "$https_script_path" ]]; then
        log "ERROR" "HTTPS setup script not found: $https_script_path"
        exit 1
    fi

    log "INFO" "Executing HTTPS configuration script..."

    if ! bash "$https_script_path" "${caddy_args[@]}"; then
        log "ERROR" "HTTPS configuration failed"
        exit 1
    fi
    
    log "INFO" "✅ Caddy Setup Complete!"
    log "INFO" "Caddy is now installed, configured, and running"
    log "INFO" ""
    log "INFO" "You should now be able to access Proxmox at: https://$DOMAIN"
    log "INFO" ""
    log "INFO" "If HTTPS is not working yet:"
    log "INFO" "1. Ensure your domain DNS points to this server's IP"
    log "INFO" "2. Check that ports 80 and 443 are open"
    log "INFO" "3. Monitor Caddy logs: journalctl -u caddy -f"
    log "INFO" "4. Check Caddy access logs: tail -f $CADDY_LOG_FILE"
    log "INFO" ""
    log "INFO" "Important Notes:"
    log "INFO" "- SSL certificates are automatically managed by Caddy"
    log "INFO" "- Ensure your firewall allows traffic on ports 80 and 443"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}


# Run network setup
run_network_setup() {
    log "INFO" "Starting Hetzner Proxmox network configuration..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    # Run network configuration script
    run_script "scripts/configure-network.sh"

    log "INFO" "✅ Network Configuration Complete!"
    log "INFO" "Network bridges have been configured successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Install Caddy: $0 --caddy"
    log "INFO" "2. Create pfSense VM: $0 --pfsense"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run pfSense setup
run_pfsense_setup() {
    log "INFO" "Starting Hetzner Proxmox pfSense setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run pfSense setup script
    run_script "scripts/setup-pfsense.sh"

    log "INFO" "✅ pfSense Setup Complete!"
    log "INFO" "pfSense VM has been created successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Access pfSense via Proxmox console to complete initial setup"
    log "INFO" "2. Create firewall admin VM: $0 --firewalladmin"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run firewall admin setup
run_firewall_admin_setup() {
    log "INFO" "Starting Hetzner Proxmox firewall admin setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run firewall admin setup script
    run_script "scripts/setup-firewall-admin.sh"

    log "INFO" "✅ Firewall Admin Setup Complete!"
    log "INFO" "Firewall admin VM has been created successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Access the admin VM via Proxmox console"
    log "INFO" "2. Use the admin VM to configure pfSense via web interface"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run MAC address check
run_mac_check() {
    log "INFO" "Starting MAC address verification..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run MAC address check script
    run_script "scripts/check-mac-addresses.sh"
    
    log "INFO" "✅ MAC Address Check Complete!"
    log "INFO" ""
    log "INFO" "If MAC addresses are correctly configured, proceed with:"
    log "INFO" "1. Network setup: $0 --network"
    log "INFO" "2. Caddy setup: $0 --caddy"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Run drives setup
run_drives_setup() {
    log "INFO" "Starting drive configuration and RAID setup..."
    log "INFO" "Logs are being written to: $LOG_FILE"
    
    # Run drives setup script
    run_script "scripts/setup-drives.sh"
    
    log "INFO" "✅ Drive Configuration Complete!"
    log "INFO" "Drive mirrors have been configured successfully"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. Verify storage pools in Proxmox web interface"
    log "INFO" "2. Configure network: $0 --network"
    log "INFO" "3. Install Caddy: $0 --caddy"
    log "INFO" ""
    log "INFO" "Logs are available at: $LOG_FILE"
}

# Main installation function
main() {
    case "${COMMAND:-}" in
        "caddy")
            run_caddy_setup
            ;;
        "network")
            run_network_setup
            ;;
        "pfsense")
            run_pfsense_setup
            ;;
        "firewalladmin")
            run_firewall_admin_setup
            ;;
        "check-mac")
            run_mac_check
            ;;
        "drives")
            run_drives_setup
            ;;
        *)
            # No command specified - show usage and exit safely
            log "INFO" "Hetzner Proxmox Setup Script"
            log "INFO" "=============================="
            echo
            log "INFO" "⚠️  No command specified. This script requires explicit commands for safety."
            echo
            log "INFO" "Available commands:"
            log "INFO" "  --check-mac      ⭐ START HERE - Verify MAC address configuration"
            log "INFO" "  --format-drives  ⚠️  Format all non-system drives and remove RAID arrays"
            log "INFO" "  --drives         🔧 Prepare drives and configure RAID arrays"
            log "INFO" "  --caddy          🌐 Install Caddy reverse proxy with HTTPS"
            log "INFO" "  --network        🔗 Configure network interfaces for additional IPs"
            log "INFO" "  --pfsense        🔥 Create pfSense firewall VM (requires --network first)"
            log "INFO" "  --firewalladmin  🖥️  Create firewall admin container (requires --pfsense first)"
            echo
            log "INFO" "Safety features:"
            log "INFO" "  --verbose        Enable detailed logging"
            log "INFO" "  --help           Show detailed usage information"
            echo
            log "INFO" "Recommended first-time workflow:"
            log "INFO" "  1. $0 --check-mac     # Verify your configuration"
            log "INFO" "  2. $0 --network       # Preview network changes"
            log "INFO" "  3. $0 --caddy         # Preview Caddy installation"
            echo
            log "INFO" "⚠️  NEVER run without specifying a command - this prevents accidental execution!"
            exit 0
            ;;
    esac
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse command line arguments
    parse_args "$@"
    
    # Validate setup requirements
    validate_setup
    
    # Execute main function
    main
fi